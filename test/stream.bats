#!/usr/bin/env bats

load test_helper

# --stream renders the backend's event stream as readable lines while the
# iteration runs, in place of --verbose's after-the-fact JSON dump. It is a view
# only: the captured output that jq, the metrics file and the exit code depend
# on must pass through byte-for-byte.

# Mock claude emitting one of each event shape the formatter renders.
create_streaming_backend() {
    mkdir -p "$TEST_DIR/bin"
    cat > "$TEST_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
cat > /dev/null
echo '{"type":"assistant","message":{"content":[{"type":"text","text":"Starting Phase 1."}]}}'
echo '{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"secret reasoning"}]}}'
echo '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"npm test","description":"Run the test suite"}}]}}'
echo '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/workspace/src/deep/nested/module/handler.js"}}]}}'
echo '{"type":"user","message":{"content":[{"type":"tool_result","is_error":true,"content":"ENOENT: no such file"}]}}'
echo '{"type":"user","message":{"content":[{"type":"tool_result","is_error":false,"content":"quiet success"}]}}'
echo '{"type":"result","subtype":"success","num_turns":7,"total_cost_usd":0.42,"result":"Done.","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}'
MOCK
    chmod +x "$TEST_DIR/bin/claude"
}

# --- What the log shows ---

@test "--stream renders assistant commentary and tool calls" {
    "$RALPH" init
    printf -- '- [ ] (light) **Thing**\n' > IMPLEMENTATION_PLAN.md
    create_streaming_backend

    PATH="$TEST_DIR/bin:$PATH" run "$RALPH" build --stream -n 1 --skip-push -y --no-metrics
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"· Starting Phase 1."* ]]
    [[ "$output" == *"→ Bash Run the test suite"* ]]
}

@test "--stream summarises the result event" {
    "$RALPH" init
    printf -- '- [ ] (light) **Thing**\n' > IMPLEMENTATION_PLAN.md
    create_streaming_backend

    PATH="$TEST_DIR/bin:$PATH" run "$RALPH" build --stream -n 1 --skip-push -y --no-metrics
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"◆ success · 7 turns · \$0.42"* ]]
}

@test "--stream reports failed tool results and stays quiet about successful ones" {
    "$RALPH" init
    printf -- '- [ ] (light) **Thing**\n' > IMPLEMENTATION_PLAN.md
    create_streaming_backend

    PATH="$TEST_DIR/bin:$PATH" run "$RALPH" build --stream -n 1 --skip-push -y --no-metrics
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"✗ ENOENT: no such file"* ]]
    [[ "$output" != *"quiet success"* ]]
}

# Thinking blocks are the agent's private reasoning and the bulkiest content in
# the stream; the log is a summary of what it did, not a transcript.
@test "--stream omits thinking blocks" {
    "$RALPH" init
    printf -- '- [ ] (light) **Thing**\n' > IMPLEMENTATION_PLAN.md
    create_streaming_backend

    PATH="$TEST_DIR/bin:$PATH" run "$RALPH" build --stream -n 1 --skip-push -y --no-metrics
    [[ "$status" -eq 0 ]]
    [[ "$output" != *"secret reasoning"* ]]
}

# A deep path truncated from the right leaves every line looking identical, so
# paths lose their leading directories and keep the filename.
@test "--stream keeps the filename of a long path and drops the workspace prefix" {
    "$RALPH" init
    printf -- '- [ ] (light) **Thing**\n' > IMPLEMENTATION_PLAN.md
    create_streaming_backend

    PATH="$TEST_DIR/bin:$PATH" run "$RALPH" build --stream -n 1 --skip-push -y --no-metrics
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"handler.js"* ]]
    [[ "$output" != *"/workspace/"* ]]
}

@test "no --stream leaves the default output unchanged" {
    "$RALPH" init
    printf -- '- [ ] (light) **Thing**\n' > IMPLEMENTATION_PLAN.md
    create_streaming_backend

    PATH="$TEST_DIR/bin:$PATH" run "$RALPH" build -n 1 --skip-push -y --no-metrics
    [[ "$status" -eq 0 ]]
    [[ "$output" != *"→ Bash"* ]]
    [[ "$output" != *"◆ success"* ]]
    # The backend's final result is still printed, as it always was
    [[ "$output" == *"Done."* ]]
}

# --- The view must not disturb the run ---

@test "--stream leaves the captured stream file byte-intact for metrics" {
    "$RALPH" init
    printf -- '- [ ] (light) **Thing**\n' > IMPLEMENTATION_PLAN.md
    create_streaming_backend

    PATH="$TEST_DIR/bin:$PATH" run "$RALPH" build --stream -n 1 --skip-push -y
    [[ "$status" -eq 0 ]]

    local sf
    sf=$(find .ralph/metrics -name 'iter-001.stream.jsonl')
    [[ -f "$sf" ]]
    # Every line still parses as JSON, and none were dropped or duplicated
    [[ "$(wc -l < "$sf")" -eq 7 ]]
    [[ "$(jq -c . "$sf" | wc -l)" -eq 7 ]]
}

@test "--stream still records result-event metrics" {
    "$RALPH" init
    printf -- '- [ ] (light) **Thing**\n' > IMPLEMENTATION_PLAN.md
    create_streaming_backend

    PATH="$TEST_DIR/bin:$PATH" run "$RALPH" build --stream -n 1 --skip-push -y
    [[ "$status" -eq 0 ]]

    local f
    f=$(find .ralph/metrics -name metrics.jsonl)
    [[ "$(jq -r '.turns' "$f")" == "7" ]]
    [[ "$(jq -r '.cost_usd' "$f")" == "0.42" ]]
}

# Regression: the formatter is teed into the pipeline, so a naive implementation
# would report tee's exit status instead of the backend's.
@test "--stream preserves a failing backend's exit code" {
    "$RALPH" init
    printf -- '- [ ] (light) **Thing**\n' > IMPLEMENTATION_PLAN.md
    mkdir -p "$TEST_DIR/bin"
    cat > "$TEST_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
cat > /dev/null
echo '{"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}}'
echo "some failure" >&2
exit 7
MOCK
    chmod +x "$TEST_DIR/bin/claude"

    PATH="$TEST_DIR/bin:$PATH" run "$RALPH" build --stream -n 1 --skip-push -y --no-metrics
    [[ "$status" -eq 7 ]]
    [[ "$output" == *"backend command failed"* ]]
}

# A non-JSON line already aborts the iteration at the main jq parse, with or
# without --stream (that check is deliberate: an unparseable stream means the
# iteration can't be trusted). What matters here is that the formatter neither
# masks that failure nor adds one of its own: it skips the bad line, renders the
# good ones, and the run still fails the way it always did.
@test "--stream skips non-JSON lines without changing how the run fails" {
    "$RALPH" init
    printf -- '- [ ] (light) **Thing**\n' > IMPLEMENTATION_PLAN.md
    mkdir -p "$TEST_DIR/bin"
    cat > "$TEST_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
cat > /dev/null
echo 'not json at all'
echo '{"type":"assistant","message":{"content":[{"type":"text","text":"still going"}]}}'
echo '{"type":"result","subtype":"success","num_turns":1,"total_cost_usd":0.01,"result":"Done."}'
MOCK
    chmod +x "$TEST_DIR/bin/claude"

    PATH="$TEST_DIR/bin:$PATH" run "$RALPH" build --stream -n 1 --skip-push -y --no-metrics
    # Same failure as without --stream: the main jq parse rejects the stream
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"jq parse failure"* ]]
    # The formatter still rendered the well-formed lines around the bad one
    [[ "$output" == *"· still going"* ]]
}

# --- Backends that cannot stream ---

@test "--stream on a non-streaming backend explains itself instead of doing nothing" {
    "$RALPH" init
    printf -- '- [ ] (light) **Thing**\n' > IMPLEMENTATION_PLAN.md

    run "$RALPH" build --stream --dry-run -n 1 -b codex
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"--stream needs a backend that emits per-event JSON"* ]]
    [[ "$output" == *"'codex'"* ]]
}

@test "--stream is accepted silently on the claude backend" {
    "$RALPH" init
    printf -- '- [ ] (light) **Thing**\n' > IMPLEMENTATION_PLAN.md

    run "$RALPH" build --stream --dry-run -n 1
    [[ "$status" -eq 0 ]]
    [[ "$output" != *"needs a backend that emits"* ]]
}

@test "-s is accepted as the short form" {
    "$RALPH" init
    printf -- '- [ ] (light) **Thing**\n' > IMPLEMENTATION_PLAN.md
    create_streaming_backend

    PATH="$TEST_DIR/bin:$PATH" run "$RALPH" build -s -n 1 --skip-push -y --no-metrics
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"→ Bash Run the test suite"* ]]
}

# --- Interaction with --verbose ---

@test "--stream and --verbose can be combined" {
    "$RALPH" init
    printf -- '- [ ] (light) **Thing**\n' > IMPLEMENTATION_PLAN.md
    create_streaming_backend

    PATH="$TEST_DIR/bin:$PATH" run "$RALPH" build --stream --verbose -n 1 --skip-push -y --no-metrics
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"→ Bash Run the test suite"* ]]
    [[ "$output" == *"[verbose] Backend command:"* ]]
}
