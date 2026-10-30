#!/usr/bin/env bats

load test_helper

@test "default backend is claude when -b flag is not set" {
    "$RALPH" init
    run "$RALPH" build --dry-run -n 1
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Backend: claude"* ]]
}

@test "-b codex selects codex backend" {
    "$RALPH" init
    run "$RALPH" build --dry-run -n 1 -b codex
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Backend: codex"* ]]
    [[ "$output" == *"[dry-run] Would run: codex exec"* ]]
}

@test "unknown backend produces error listing supported backends" {
    "$RALPH" init
    run "$RALPH" build --dry-run -n 1 -b unknown
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"unknown backend 'unknown'"* ]]
    [[ "$output" == *"Supported backends:"* ]]
}

@test "dry-run with codex shows default model gpt-5.2-codex" {
    "$RALPH" init
    run "$RALPH" build --dry-run -n 1 -b codex
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Model:   gpt-5.2-codex"* ]]
    [[ "$output" == *"gpt-5.2-codex"* ]]
}

@test "dry-run with claude shows default model opus" {
    "$RALPH" init
    run "$RALPH" build --dry-run -n 1
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Model:   opus"* ]]
}

@test "-m flag overrides default model for any backend" {
    "$RALPH" init
    run "$RALPH" build --dry-run -n 1 -b codex -m custom-model
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Model:   custom-model"* ]]
    [[ "$output" == *"custom-model"* ]]
}

@test "-b copilot selects copilot backend" {
    "$RALPH" init
    run "$RALPH" build --dry-run -n 1 -b copilot
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Backend: copilot"* ]]
    [[ "$output" == *"[dry-run] Would run: copilot --output-format=json --yolo --model"* ]]
    [[ "$output" == *"-p <prompt>"* ]]
}

@test "dry-run with copilot shows default model claude-sonnet-4.6" {
    "$RALPH" init
    run "$RALPH" build --dry-run -n 1 -b copilot
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Model:   claude-sonnet-4.6"* ]]
    [[ "$output" == *"--model claude-sonnet-4.6"* ]]
}

@test "-m flag overrides default model for copilot" {
    "$RALPH" init
    run "$RALPH" build --dry-run -n 1 -b copilot -m custom-copilot-model
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Model:   custom-copilot-model"* ]]
    [[ "$output" == *"--model custom-copilot-model"* ]]
}

@test "unknown backend error lists copilot among supported backends" {
    "$RALPH" init
    run "$RALPH" build --dry-run -n 1 -b unknown
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Supported backends:"*"copilot"* ]]
}

@test "-b pi selects pi backend" {
    "$RALPH" init
    run "$RALPH" build --dry-run -n 1 -b pi
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Backend: pi"* ]]
    # No permission-flag positional, no stray empty arg between --model and --no-session
    [[ "$output" == *"[dry-run] Would run: pi -p --mode json --model anthropic/claude-opus-4-8 --no-session"* ]]
}

@test "dry-run with pi shows default model anthropic/claude-opus-4-8" {
    "$RALPH" init
    run "$RALPH" build --dry-run -n 1 -b pi
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Model:   anthropic/claude-opus-4-8"* ]]
    [[ "$output" == *"--model anthropic/claude-opus-4-8"* ]]
}

@test "-m flag overrides default model for pi" {
    "$RALPH" init
    run "$RALPH" build --dry-run -n 1 -b pi -m custom-pi-model
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Model:   custom-pi-model"* ]]
    [[ "$output" == *"--model custom-pi-model"* ]]
}

@test "unknown backend error lists pi among supported backends" {
    "$RALPH" init
    run "$RALPH" build --dry-run -n 1 -b unknown
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Supported backends:"*"pi"* ]]
}

# --- Command time limit under claude ---

# A mock claude that records the time limits it was started with, then fails
# so the loop stops after one call.
mock_claude_recording_timeouts() {
    mkdir -p "$TEST_DIR/bin"
    cat > "$TEST_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
env | grep '^BASH_.*TIMEOUT_MS=' | sort > "$PWD/claude-env"
exit 1
MOCK
    chmod +x "$TEST_DIR/bin/claude"
}

@test "claude is started with a 45-minute command time limit" {
    "$RALPH" init
    mock_claude_recording_timeouts
    unset BASH_DEFAULT_TIMEOUT_MS BASH_MAX_TIMEOUT_MS

    PATH="$TEST_DIR/bin:$PATH" run "$RALPH" build -n 1 --skip-push
    [[ "$(cat claude-env)" == $'BASH_DEFAULT_TIMEOUT_MS=2700000\nBASH_MAX_TIMEOUT_MS=2700000' ]]
}

@test "a command time limit already in the environment wins" {
    "$RALPH" init
    mock_claude_recording_timeouts

    BASH_DEFAULT_TIMEOUT_MS=60000 BASH_MAX_TIMEOUT_MS=90000 PATH="$TEST_DIR/bin:$PATH" \
        run "$RALPH" build -n 1 --skip-push
    [[ "$(cat claude-env)" == $'BASH_DEFAULT_TIMEOUT_MS=60000\nBASH_MAX_TIMEOUT_MS=90000' ]]
}
