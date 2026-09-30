#!/usr/bin/env bats

load test_helper

# Helper: install a mock claude that emits stream-json, commits a file and
# ticks the first incomplete plan item.
create_committing_backend() {
    mkdir -p "$TEST_DIR/bin"
    cat > "$TEST_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
cat > /dev/null
echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Read","input":{}}]}}'
echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Bash","input":{}}]}}'
echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t3","name":"Bash","input":{}}]}}'
echo "work $RANDOM" >> src.txt
git add src.txt >/dev/null 2>&1
git commit -q -m "mock work"
sed -i.bak '1s/- \[ \]/- [x]/' IMPLEMENTATION_PLAN.md 2>/dev/null && rm -f IMPLEMENTATION_PLAN.md.bak
echo '{"type":"result","subtype":"success","duration_ms":8000,"duration_api_ms":6500,"num_turns":12,"result":"Done.","session_id":"s1","total_cost_usd":1.25,"usage":{"input_tokens":2500,"cache_creation_input_tokens":40000,"cache_read_input_tokens":350000,"output_tokens":8200}}'
MOCK
    chmod +x "$TEST_DIR/bin/claude"
}

# Helper: mock claude that emits a result event but changes nothing.
create_noop_backend() {
    mkdir -p "$TEST_DIR/bin"
    cat > "$TEST_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
cat > /dev/null
echo '{"type":"result","subtype":"success","duration_ms":500,"duration_api_ms":400,"num_turns":2,"result":"Nothing to do.","session_id":"s2","total_cost_usd":0.01,"usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5}}'
MOCK
    chmod +x "$TEST_DIR/bin/claude"
}

latest_metrics_file() {
    # shellcheck disable=SC2012  # newest-by-mtime needs ls; paths are ralph-generated (no odd filenames)
    ls -1t .ralph/metrics/*/metrics.jsonl | head -1
}

@test "build records one metrics line per iteration" {
    "$RALPH" init
    printf -- '- [ ] one\n- [ ] two\n- [ ] three\n' > IMPLEMENTATION_PLAN.md
    create_committing_backend

    PATH="$TEST_DIR/bin:$PATH" run "$RALPH" build -n 2 --skip-push -y
    [[ "$status" -eq 0 ]]

    local f
    f=$(latest_metrics_file)
    [[ -f "$f" ]]
    [[ $(wc -l < "$f") -eq 2 ]]
}

@test "metrics line contains result-event and git fields" {
    "$RALPH" init
    printf -- '- [ ] one\n- [ ] two\n' > IMPLEMENTATION_PLAN.md
    create_committing_backend

    PATH="$TEST_DIR/bin:$PATH" "$RALPH" build -n 1 --skip-push -y

    local f line
    f=$(latest_metrics_file)
    line=$(tail -1 "$f")
    [[ $(jq -r '.turns' <<<"$line") == "12" ]]
    [[ $(jq -r '.cost_usd' <<<"$line") == "1.25" ]]
    [[ $(jq -r '.tokens.cache_read' <<<"$line") == "350000" ]]
    [[ $(jq -r '.git.commits' <<<"$line") == "1" ]]
    [[ $(jq -r '.git.noop' <<<"$line") == "false" ]]
    [[ $(jq -r '.plan_items_completed' <<<"$line") == "1" ]]
    [[ $(jq -r '.tools.Bash' <<<"$line") == "2" ]]
    [[ $(jq -r '.mode' <<<"$line") == "build" ]]
}

@test "raw stream is retained per iteration" {
    "$RALPH" init
    printf -- '- [ ] one\n- [ ] two\n' > IMPLEMENTATION_PLAN.md
    create_committing_backend

    PATH="$TEST_DIR/bin:$PATH" "$RALPH" build -n 1 --skip-push -y

    local dir
    dir=$(dirname "$(latest_metrics_file)")
    [[ -f "$dir/iter-001.stream.jsonl" ]]
    grep -q '"type":"result"' "$dir/iter-001.stream.jsonl"
}

@test "noop iteration is recorded with noop=true and zero commits" {
    "$RALPH" init
    printf -- '- [ ] one\n' > IMPLEMENTATION_PLAN.md
    create_noop_backend

    PATH="$TEST_DIR/bin:$PATH" "$RALPH" build -n 1 --skip-push -y

    local line
    line=$(tail -1 "$(latest_metrics_file)")
    [[ $(jq -r '.git.noop' <<<"$line") == "true" ]]
    [[ $(jq -r '.git.commits' <<<"$line") == "0" ]]
}

@test "plan iteration that edits the plan records noop=false" {
    "$RALPH" init
    mkdir -p "$TEST_DIR/bin"
    # Plan mode never commits, so the noop flag must come from the plan
    # artifacts rather than from HEAD.
    cat > "$TEST_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
cat > /dev/null
echo "- [ ] **Task one**" >> IMPLEMENTATION_PLAN.md
echo '{"type":"result","subtype":"success","duration_ms":500,"duration_api_ms":400,"num_turns":2,"result":"Planned.","session_id":"s3","total_cost_usd":0.01,"usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5}}'
MOCK
    chmod +x "$TEST_DIR/bin/claude"

    PATH="$TEST_DIR/bin:$PATH" "$RALPH" plan -n 1 --skip-push -y

    local line
    line=$(tail -1 "$(latest_metrics_file)")
    [[ $(jq -r '.mode' <<<"$line") == "plan" ]]
    [[ $(jq -r '.git.noop' <<<"$line") == "false" ]]
    [[ $(jq -r '.git.commits' <<<"$line") == "0" ]]
}

@test "plan iteration that changes nothing records noop=true" {
    "$RALPH" init
    # One item present: a converging pass against an empty plan is a planning
    # failure and exits before metrics assert anything.
    printf -- '- [ ] **Seeded item** — x. → [001-x.md](plan/001-x.md)\n' >> IMPLEMENTATION_PLAN.md
    create_noop_backend

    PATH="$TEST_DIR/bin:$PATH" "$RALPH" plan -n 1 --skip-push -y

    local line
    line=$(tail -1 "$(latest_metrics_file)")
    [[ $(jq -r '.mode' <<<"$line") == "plan" ]]
    [[ $(jq -r '.git.noop' <<<"$line") == "true" ]]
}

@test "degraded backend output still records a metrics line with nulls" {
    "$RALPH" init
    printf -- '- [ ] one\n' > IMPLEMENTATION_PLAN.md
    mkdir -p "$TEST_DIR/bin"
    cat > "$TEST_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
cat > /dev/null
echo '{"type":"result","result":"bare"}'
MOCK
    chmod +x "$TEST_DIR/bin/claude"

    PATH="$TEST_DIR/bin:$PATH" run "$RALPH" build -n 1 --skip-push -y
    [[ "$status" -eq 0 ]]

    local line
    line=$(tail -1 "$(latest_metrics_file)")
    [[ $(jq -r '.turns' <<<"$line") == "null" ]]
    [[ $(jq -r '.cost_usd' <<<"$line") == "null" ]]
    [[ $(jq -r '.git.commits' <<<"$line") == "0" ]]
}

@test "--no-metrics disables capture" {
    "$RALPH" init
    printf -- '- [ ] one\n' > IMPLEMENTATION_PLAN.md
    create_noop_backend

    PATH="$TEST_DIR/bin:$PATH" run "$RALPH" build -n 1 --skip-push -y --no-metrics
    [[ "$status" -eq 0 ]]
    [[ ! -d ".ralph/metrics" ]]
}

@test "dry-run does not create metrics" {
    "$RALPH" init
    printf -- '- [ ] one\n' > IMPLEMENTATION_PLAN.md

    run "$RALPH" build -n 1 --dry-run
    [[ "$status" -eq 0 ]]
    [[ ! -d ".ralph/metrics" ]]
}

@test "plan mode records metrics" {
    "$RALPH" init
    printf -- '- [ ] one\n' > IMPLEMENTATION_PLAN.md
    create_noop_backend

    PATH="$TEST_DIR/bin:$PATH" "$RALPH" plan -n 1 -y

    local line
    line=$(tail -1 "$(latest_metrics_file)")
    [[ $(jq -r '.mode' <<<"$line") == "plan" ]]
    [[ $(jq -r '.turns' <<<"$line") == "2" ]]
}

@test "loop output includes a per-iteration metrics summary line" {
    "$RALPH" init
    printf -- '- [ ] one\n- [ ] two\n' > IMPLEMENTATION_PLAN.md
    create_committing_backend

    PATH="$TEST_DIR/bin:$PATH" run "$RALPH" build -n 1 --skip-push -y
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"12 turns"* ]]
    [[ "$output" == *"1 commits"* ]]
    [[ "$output" == *"Metrics recorded:"* ]]
}

@test "ralph metrics summarises the latest run" {
    "$RALPH" init
    printf -- '- [ ] one\n- [ ] two\n- [ ] three\n' > IMPLEMENTATION_PLAN.md
    create_committing_backend

    PATH="$TEST_DIR/bin:$PATH" "$RALPH" build -n 2 --skip-push -y

    run "$RALPH" metrics
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"2 iterations"* ]]
    [[ "$output" == *"cost \$2.5"* ]]
    [[ "$output" == *"commits 2"* ]]
}

@test "ralph metrics with no runs errors helpfully" {
    "$RALPH" init
    run "$RALPH" metrics
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"No metrics found"* ]]
}

@test "metrics failure does not fail the loop" {
    "$RALPH" init
    printf -- '- [ ] one\n' > IMPLEMENTATION_PLAN.md
    create_noop_backend

    # Uncreatable metrics dir (a file squats on the path — robust even when
    # tests run as root, where chmod-based denial doesn't bite): capture must
    # disable itself with a warning and the loop must still run to completion.
    mkdir -p .ralph
    touch .ralph/metrics

    PATH="$TEST_DIR/bin:$PATH" run "$RALPH" build -n 1 --skip-push -y
    rm -f .ralph/metrics

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"metrics disabled for this run"* ]]
    [[ "$output" == *"Nothing to do."* ]]
}

@test "metrics line records system load and the CPU split" {
    [[ -r /proc/loadavg && -r /proc/stat ]] || skip "needs /proc"
    "$RALPH" init
    printf -- '- [ ] one\n' > IMPLEMENTATION_PLAN.md
    create_noop_backend

    PATH="$TEST_DIR/bin:$PATH" "$RALPH" build -n 1 --skip-push -y

    local line
    line=$(tail -1 "$(latest_metrics_file)")
    [[ $(jq -r '.system.start.load | length' <<<"$line") == "3" ]]
    [[ $(jq -r '.system.end.load | length' <<<"$line") == "3" ]]
    [[ $(jq -r '.system.cpus' <<<"$line") -ge 1 ]]
    [[ $(jq -r '.system.host_cpu_pct | type' <<<"$line") =~ ^(number|null)$ ]]
    [[ $(jq -r '.system.end.containers | type' <<<"$line") == "array" ]]
}

@test "process list is dumped at the start and end of each iteration" {
    "$RALPH" init
    printf -- '- [ ] one\n' > IMPLEMENTATION_PLAN.md
    create_noop_backend

    PATH="$TEST_DIR/bin:$PATH" "$RALPH" build -n 1 --skip-push -y

    local dir
    dir=$(dirname "$(latest_metrics_file)")
    grep -q 'PID' "$dir/iter-001.ps-start.txt"
    grep -q 'PID' "$dir/iter-001.ps-end.txt"
    [[ $(tail -1 "$(latest_metrics_file)" | jq -r '.system.stray_procs | length') == "0" ]]
}

@test "a process the backend leaves running is recorded as a stray" {
    "$RALPH" init
    printf -- '- [ ] one\n' > IMPLEMENTATION_PLAN.md
    mkdir -p "$TEST_DIR/bin"
    cat > "$TEST_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
cat > /dev/null
nohup sleep 4242 </dev/null >/dev/null 2>&1 3>&- 4>&- 63>&- &
sleep 2
echo '{"type":"result","subtype":"success","num_turns":1,"result":"Left one running."}'
MOCK
    chmod +x "$TEST_DIR/bin/claude"

    PATH="$TEST_DIR/bin:$PATH" "$RALPH" build -n 1 --skip-push -y
    pkill -f 'sleep 4242' || true

    local line
    line=$(tail -1 "$(latest_metrics_file)")
    [[ $(jq -r '[.system.stray_procs[].args] | any(. == "sleep 4242")' <<<"$line") == "true" ]]
}

@test "the sampler records a line per interval while the backend runs" {
    "$RALPH" init
    printf -- '- [ ] one\n' > IMPLEMENTATION_PLAN.md
    mkdir -p "$TEST_DIR/bin"
    cat > "$TEST_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
cat > /dev/null
sleep 3
echo '{"type":"result","subtype":"success","num_turns":1,"result":"Slow."}'
MOCK
    chmod +x "$TEST_DIR/bin/claude"

    RALPH_SAMPLE_INTERVAL=1 PATH="$TEST_DIR/bin:$PATH" "$RALPH" build -n 1 --skip-push -y

    local dir samples
    dir=$(dirname "$(latest_metrics_file)")
    sleep 2
    samples=$(wc -l < "$dir/iter-001.samples.jsonl")
    [[ "$samples" -ge 1 ]]
    jq -e 'has("load1") and has("host_cpu_pct") and has("top")' < <(head -1 "$dir/iter-001.samples.jsonl")
    jq -e 'has("mem_available_mb") and has("swap_used_mb") and has("swap_in_pages") and has("swap_out_pages")' \
        < <(head -1 "$dir/iter-001.samples.jsonl")
    sleep 2
    [[ $(wc -l < "$dir/iter-001.samples.jsonl") -eq "$samples" ]]
}

@test "metrics line summarises memory, swap and the longest gap between samples" {
    [[ -r /proc/meminfo && -r /proc/vmstat ]] || skip "needs /proc"
    "$RALPH" init
    printf -- '- [ ] one\n' > IMPLEMENTATION_PLAN.md
    mkdir -p "$TEST_DIR/bin"
    cat > "$TEST_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
cat > /dev/null
sleep 4
echo '{"type":"result","subtype":"success","num_turns":1,"result":"Slow."}'
MOCK
    chmod +x "$TEST_DIR/bin/claude"

    RALPH_SAMPLE_INTERVAL=1 PATH="$TEST_DIR/bin:$PATH" "$RALPH" build -n 1 --skip-push -y

    local line
    line=$(tail -1 "$(latest_metrics_file)")
    [[ $(jq -r '.system.mem_available_min_mb | type' <<<"$line") == "number" ]]
    [[ $(jq -r '.system.swap_used_max_mb | type' <<<"$line") == "number" ]]
    [[ $(jq -r '.system.swap_in_pages | type' <<<"$line") == "number" ]]
    [[ $(jq -r '.system.swap_out_pages | type' <<<"$line") == "number" ]]
    [[ $(jq -r '.system.sample_gap_max_s' <<<"$line") -ge 1 ]]
}

@test "vitest summaries in tool results are recorded as test runs" {
    "$RALPH" init
    printf -- '- [ ] one\n' > IMPLEMENTATION_PLAN.md
    mkdir -p "$TEST_DIR/bin"
    cat > "$TEST_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
cat > /dev/null
summary=$(printf '\\u001b[2m Test Files \\u001b[22m 1 failed | 226 passed (227)\\n      Tests  2 failed | 4979 passed (4981)\\n   Start at  12:00:00\\n   Duration  265.56s (transform 12.60s, setup 0ms, import 353.48s, tests 377.40s, environment 445ms)')
echo "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"t1\",\"content\":\"$summary\"}]}}"
echo '{"type":"result","subtype":"success","num_turns":1,"result":"Tested."}'
MOCK
    chmod +x "$TEST_DIR/bin/claude"

    PATH="$TEST_DIR/bin:$PATH" "$RALPH" build -n 1 --skip-push -y

    local line
    line=$(tail -1 "$(latest_metrics_file)")
    [[ $(jq -r '.test_runs | length' <<<"$line") == "1" ]]
    [[ $(jq -r '.test_runs[0].files_passed' <<<"$line") == "226" ]]
    [[ $(jq -r '.test_runs[0].files_failed' <<<"$line") == "1" ]]
    [[ $(jq -r '.test_runs[0].tests_passed' <<<"$line") == "4979" ]]
    [[ $(jq -r '.test_runs[0].duration_s' <<<"$line") == "265.56" ]]
    [[ $(jq -r '.test_runs[0].transform_s' <<<"$line") == "12.6" ]]
    [[ $(jq -r '.test_runs[0].tests_s' <<<"$line") == "377.4" ]]
}

@test "ralph metrics shows load, CPU split, strays and test durations" {
    "$RALPH" init
    printf -- '- [ ] one\n' > IMPLEMENTATION_PLAN.md
    create_noop_backend

    PATH="$TEST_DIR/bin:$PATH" "$RALPH" build -n 1 --skip-push -y

    run "$RALPH" metrics
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"LOAD"* ]]
    [[ "$output" == *"HOST%/SBX%"* ]]
    [[ "$output" == *"STRAYS"* ]]
    [[ "$output" == *"TESTS"* ]]
}
