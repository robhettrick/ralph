#!/usr/bin/env bats

load test_helper

create_prompt_recording_backend() {
    mkdir -p "$TEST_DIR/bin"
    cat > "$TEST_DIR/bin/claude" <<MOCK
#!/usr/bin/env bash
grep -o 'Run full suite: [a-z{}_A-Z]*' >> "$TEST_DIR/seen"
echo '{"type":"result","subtype":"success","num_turns":1,"result":"ok"}'
MOCK
    chmod +x "$TEST_DIR/bin/claude"
    echo 'Run full suite: {{RUN_FULL_SUITE}}' > "$RALPH_CONFIG_DIR/prompts/build.md"
}

@test "without --full-suite-every every iteration is told to run the full suite" {
    "$RALPH" init
    printf -- '- [ ] one\n' > IMPLEMENTATION_PLAN.md
    create_prompt_recording_backend

    PATH="$TEST_DIR/bin:$PATH" run "$RALPH" build -n 2 --skip-push -y
    [[ "$status" -eq 0 ]]
    [[ "$(cat "$TEST_DIR/seen")" == $'Run full suite: yes\nRun full suite: yes' ]]
}

@test "--full-suite-every N says yes on iteration 1 and every Nth after it" {
    "$RALPH" init
    printf -- '- [ ] one\n' > IMPLEMENTATION_PLAN.md
    create_prompt_recording_backend

    PATH="$TEST_DIR/bin:$PATH" run "$RALPH" build -n 5 --skip-push -y --full-suite-every 2
    [[ "$status" -eq 0 ]]
    [[ "$(cat "$TEST_DIR/seen")" == $'Run full suite: yes\nRun full suite: no\nRun full suite: yes\nRun full suite: no\nRun full suite: yes' ]]
    [[ "$output" == *"Suite:   full suite every 2 iterations"* ]]
    [[ "$output" == *"Full suite: no"* ]]
}

@test "metrics record whether the iteration was told to run the full suite" {
    "$RALPH" init
    printf -- '- [ ] one\n' > IMPLEMENTATION_PLAN.md
    create_prompt_recording_backend

    PATH="$TEST_DIR/bin:$PATH" "$RALPH" build -n 2 --skip-push -y --full-suite-every 2

    local f
    # shellcheck disable=SC2012  # newest-by-mtime needs ls; paths are ralph-generated (no odd filenames)
    f=$(ls -1t .ralph/metrics/*/metrics.jsonl | head -1)
    [[ "$(jq -r '.full_suite' "$f" | paste -sd, -)" == "true,false" ]]
}

@test "--full-suite-every rejects a value that is not a positive integer" {
    "$RALPH" init
    run "$RALPH" build --dry-run -n 1 --full-suite-every 0
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"--full-suite-every must be a positive integer"* ]]
}

@test "--full-suite-every is refused outside build mode" {
    "$RALPH" init
    run "$RALPH" plan --dry-run -n 1 --full-suite-every 4
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"applies to 'ralph build' only"* ]]
}
