#!/usr/bin/env bats

load test_helper

# The test scope a build iteration runs at: every suite on each Nth iteration
# and on the last one, only the tests the change reaches on the rest. The loop
# decides it and hands it to the agent as {{TEST_SCOPE}} in the build prompt.

# A local build prompt that prints nothing but the scope, one line per
# iteration, and a plan with more open items than any test runs iterations.
setup_scope_workspace() {
    "$RALPH" init
    echo "Scope: {{TEST_SCOPE}}" > PROMPT_build.md
    {
        printf -- '## Items\n\n'
        for i in $(seq 1 20); do
            printf -- '- [ ] **Item %s**\n' "$i"
        done
    } > IMPLEMENTATION_PLAN.md
}

# The scope word the prompt was given on each iteration, in order.
scope_words() {
    grep -oE '^Scope: (Full|Targeted)' <<<"$output" | cut -d' ' -f2 | paste -sd' ' -
}

@test "build runs every suite on every tenth iteration and the last one" {
    setup_scope_workspace

    run "$RALPH" build --dry-run -n 12
    [[ "$status" -eq 0 ]]
    [[ "$(scope_words)" == "Targeted Targeted Targeted Targeted Targeted Targeted Targeted Targeted Targeted Full Targeted Full" ]]
}

@test "a targeted iteration names the next full one" {
    setup_scope_workspace

    run "$RALPH" build --dry-run -n 15
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Scope: Targeted — iteration 3 of 15; the next full run is iteration 10."* ]]
    # The next multiple of ten is past the end, so the last iteration is next.
    [[ "$output" == *"Scope: Targeted — iteration 11 of 15; the next full run is iteration 15."* ]]
    [[ "$output" == *"Scope: Full — iteration 15 is the last of this run."* ]]
}

@test "--full-tests-every sets the interval" {
    setup_scope_workspace

    run "$RALPH" build --dry-run -n 6 --full-tests-every 2
    [[ "$status" -eq 0 ]]
    [[ "$(scope_words)" == "Targeted Full Targeted Full Targeted Full" ]]
}

@test "--full-tests-every 1 runs every suite on every iteration" {
    setup_scope_workspace

    run "$RALPH" build --dry-run -n 3 --full-tests-every=1
    [[ "$status" -eq 0 ]]
    [[ "$(scope_words)" == "Full Full Full" ]]
}

# The loop can end before its iteration cap when the plan runs out, so the
# iteration that takes the last open item is the last one in practice.
@test "an iteration taking the last open plan item runs every suite" {
    "$RALPH" init
    echo "Scope: {{TEST_SCOPE}}" > PROMPT_build.md
    printf -- '## Items\n\n- [x] **Shipped**\n- [ ] **Last one**\n' > IMPLEMENTATION_PLAN.md

    run "$RALPH" build --dry-run -n 3
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Scope: Full — this iteration takes the last open plan item."* ]]
    [[ "$output" != *"Scope: Targeted"* ]]
}

@test "build announces the test scope under the iteration banner" {
    setup_scope_workspace

    run "$RALPH" build --dry-run -n 1
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Tests:   Full — iteration 1 is the last of this run."* ]]
}

@test "--full-tests-every rejects a value that is not a positive integer" {
    setup_scope_workspace

    for value in 0 -1 abc 2.5; do
        run "$RALPH" build --dry-run -n 1 --full-tests-every "$value"
        [[ "$status" -eq 1 ]]
        [[ "$output" == *"--full-tests-every must be a positive integer, got '$value'"* ]]
    done
}

@test "plan mode announces no test scope" {
    "$RALPH" init

    run "$RALPH" plan --dry-run -n 1
    [[ "$status" -eq 0 ]]
    [[ "$output" != *"Tests:"* ]]
}
