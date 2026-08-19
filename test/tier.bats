#!/usr/bin/env bats

load test_helper

# Per-item model tiers: the planning agent marks each IMPLEMENTATION_PLAN.md
# index entry with an abstract `(light)`/`(heavy)` tier, and the build loop
# resolves that tier to one of the selected backend's model ids per iteration —
# so cheap work runs cheaply. The marker sits on the index line so the model is
# chosen without opening the item's task file under plan/.

# --- Tier resolution ---

@test "build resolves a light-tier item to the backend's light model" {
    "$RALPH" init
    printf -- '- [ ] (light) **Add an endpoint**\n' > IMPLEMENTATION_PLAN.md

    run "$RALPH" build --dry-run -n 1
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"--model sonnet"* ]]
    [[ "$output" != *"--model opus"* ]]
}

@test "build resolves a heavy-tier item to the backend's heavy model" {
    "$RALPH" init
    printf -- '- [ ] (heavy) **Refactor persistence**\n' > IMPLEMENTATION_PLAN.md

    run "$RALPH" build --dry-run -n 1
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"--model opus"* ]]
    [[ "$output" != *"--model sonnet"* ]]
}

@test "tiers map to the selected backend's own model namespace" {
    "$RALPH" init
    printf -- '- [ ] (light) **Add an endpoint**\n' > IMPLEMENTATION_PLAN.md

    run "$RALPH" build --dry-run -n 1 -b codex
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"--model gpt-5.2-codex-mini"* ]]
}

@test "tier matching is case-insensitive" {
    "$RALPH" init
    printf -- '- [ ] (LIGHT) **Add an endpoint**\n' > IMPLEMENTATION_PLAN.md

    run "$RALPH" build --dry-run -n 1
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"--model sonnet"* ]]
}

@test "the resolved model is announced alongside the next item" {
    "$RALPH" init
    printf -- '- [ ] (light) **B2. Next thing**\n' > IMPLEMENTATION_PLAN.md

    run "$RALPH" build --dry-run -n 1
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Next:    [sonnet] B2. Next thing"* ]]
}

# The real index format: tier marker, emphasis, description and task-file link
# all on one line. The tier drives the model; the announcement shows neither the
# marker nor the link.
@test "a full index entry resolves its tier and announces cleanly" {
    "$RALPH" init
    printf -- '- [ ] (light) **Add PATCH endpoint** — accept partial updates. → [002-patch.md](plan/002-patch.md)\n' \
        > IMPLEMENTATION_PLAN.md

    run "$RALPH" build --dry-run -n 1
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"--model sonnet"* ]]
    [[ "$output" == *"Next:    [sonnet] Add PATCH endpoint — accept partial updates."* ]]
    [[ "$output" != *"(light)"* ]]
    [[ "$output" != *"plan/002-patch.md"* ]]
}

@test "the header shows the tier map instead of a single run-level model" {
    "$RALPH" init
    printf -- '- [ ] (light) **Thing**\n' > IMPLEMENTATION_PLAN.md

    run "$RALPH" build --dry-run -n 1
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Model:   per item ("* ]]
    [[ "$output" == *"light=sonnet"* ]]
    [[ "$output" == *"heavy=opus"* ]]
}

# --- Which item's tier wins ---

@test "the tier of the first incomplete item is used, not a completed one's" {
    "$RALPH" init
    printf -- '- [x] (heavy) **Shipped**\n- [ ] (light) **Next**\n' > IMPLEMENTATION_PLAN.md

    run "$RALPH" build --dry-run -n 1
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"--model sonnet"* ]]
}

@test "a later item's tier does not apply to the current one" {
    "$RALPH" init
    printf -- '- [ ] (heavy) **First**\n- [ ] (light) **Second**\n' > IMPLEMENTATION_PLAN.md

    run "$RALPH" build --dry-run -n 1
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"--model opus"* ]]
    [[ "$output" != *"--model sonnet"* ]]
}

# Regression: while the tier lived on its own line under the item, a sed
# line-range ending at `/^- \[/` restarted on each subsequent item, so an
# untiered first entry silently inherited a later one's tier — running heavy
# work on the light model. The tier is now part of the entry itself, but the
# case is worth holding onto.
@test "an untiered entry does not inherit a later entry's tier" {
    "$RALPH" init
    printf -- '- [ ] **First, untiered**\n- [ ] **Second, untiered**\n- [ ] (light) **Third**\n' \
        > IMPLEMENTATION_PLAN.md

    run "$RALPH" build --dry-run -n 1
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"--model opus"* ]]
    [[ "$output" != *"--model sonnet"* ]]
}

# --- Fallbacks: tiering must never abort a long build ---

@test "an untiered entry in a tiered plan falls back to the backend default" {
    "$RALPH" init
    printf -- '- [ ] **Untiered item**\n- [ ] (light) **Tiered item**\n' \
        > IMPLEMENTATION_PLAN.md

    run "$RALPH" build --dry-run -n 1
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"--model opus"* ]]
    [[ "$output" != *"--model sonnet"* ]]
}

@test "an unknown tier warns and falls back rather than failing the loop" {
    "$RALPH" init
    printf -- '- [ ] (medium) **Odd item**\n' > IMPLEMENTATION_PLAN.md

    run "$RALPH" build --dry-run -n 1
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"unknown tier 'medium'"* ]]
    [[ "$output" == *"--model opus"* ]]
    [[ "$output" == *"Completed 1 iterations."* ]]
}

# Plans predating tier markers must be indistinguishable from before: one model
# for the run, a plain header, and no model prefix on the announcement.
@test "a plan with no tier markers anywhere runs exactly as before" {
    "$RALPH" init
    printf -- '- [x] **A1. Shipped**\n- [ ] **B2. Next**\n- [ ] **C3. Later**\n' > IMPLEMENTATION_PLAN.md

    run "$RALPH" build --dry-run -n 1
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Model:   opus"* ]]
    [[ "$output" != *"Model:   per item"* ]]
    [[ "$output" == *"Next:    B2. Next"* ]]
    [[ "$output" != *"[opus] B2. Next"* ]]
    [[ "$output" == *"--model opus"* ]]
    [[ "$output" == *"Completed 1 iterations."* ]]
}

# --- Precedence: an explicit -m always wins ---

@test "-m overrides a light-tier item" {
    "$RALPH" init
    printf -- '- [ ] (light) **Add an endpoint**\n' > IMPLEMENTATION_PLAN.md

    run "$RALPH" build --dry-run -n 1 -m opus
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Model:   opus"* ]]
    [[ "$output" == *"--model opus"* ]]
    [[ "$output" != *"--model sonnet"* ]]
}

@test "-m pins one model and suppresses the per-item header and announcement" {
    "$RALPH" init
    printf -- '- [ ] (light) **Thing**\n' > IMPLEMENTATION_PLAN.md

    run "$RALPH" build --dry-run -n 1 -m custom-model
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Model:   custom-model"* ]]
    [[ "$output" != *"Model:   per item"* ]]
    [[ "$output" == *"Next:    Thing"* ]]
    [[ "$output" != *"[custom-model] Thing"* ]]
}

# --- Modes other than build ---

@test "plan mode ignores tiers and uses the run-level model" {
    "$RALPH" init
    printf -- '- [ ] (light) **Thing**\n' > IMPLEMENTATION_PLAN.md

    run "$RALPH" plan --dry-run -n 1
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Model:   opus"* ]]
    [[ "$output" != *"Model:   per item"* ]]
    [[ "$output" == *"--model opus"* ]]
}

@test "review mode ignores tiers and uses the run-level model" {
    "$RALPH" init
    printf -- '- [ ] (light) **Thing**\n' > IMPLEMENTATION_PLAN.md

    run "$RALPH" review --dry-run -n 1
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Model:   opus"* ]]
    [[ "$output" == *"--model opus"* ]]
}

# --- Backend contract ---

# Guards the invariant a new backend could silently break: an unmapped tier
# would fall back to the default model, quietly undoing the tier's purpose.
@test "every backend maps every supported tier to a model" {
    "$RALPH" init

    local backend tier
    for backend in claude codex copilot pi; do
        for tier in light heavy; do
            printf -- '- [ ] (%s) **Thing**\n' "$tier" > IMPLEMENTATION_PLAN.md
            run "$RALPH" build --dry-run -n 1 -b "$backend"
            [[ "$status" -eq 0 ]]
            [[ "$output" != *"unknown tier"* ]]
            [[ "$output" == *"--model "* ]]
        done
    done
}

# --- Mixed-tier runs ---

@test "each iteration resolves its own tier as the plan advances" {
    "$RALPH" init
    printf -- '- [ ] (light) **First, light**\n' > IMPLEMENTATION_PLAN.md

    # Dry-run re-reads the plan each iteration but never mutates it, so both
    # iterations resolve the same (still-first) item — enough to prove the
    # resolution happens per iteration rather than once before the loop.
    run "$RALPH" build --dry-run -n 2
    [[ "$status" -eq 0 ]]
    [[ "$(grep -c -- '--model sonnet' <<<"$output")" -eq 2 ]]
}

# --- Interaction with the plan's section scoping ---

# Tier resolution reads through plan_items_body, like next_plan_item and the
# item count. Without that, a checkbox in the prose above '## Items' — the
# template's own tiered exemplar, or an example an agent pasted back at column
# zero — would choose the model for the iteration.
@test "a tier marker above the Items heading does not set the model" {
    "$RALPH" init
    awk '/^## Items[[:space:]]*$/ && !d { print "- [ ] (light) **Decoy above Items**"; print ""; d = 1 } { print }' \
        IMPLEMENTATION_PLAN.md > IMPLEMENTATION_PLAN.md.tmp
    mv -f IMPLEMENTATION_PLAN.md.tmp IMPLEMENTATION_PLAN.md
    printf -- '- [ ] (heavy) **Real item** — x. → [001-a.md](plan/001-a.md)\n' >> IMPLEMENTATION_PLAN.md

    run "$RALPH" build --dry-run -n 1
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Next:    [opus] Real item"* ]]
    [[ "$output" == *"--model opus"* ]]
    [[ "$output" != *"--model sonnet"* ]]
}

# The scaffolded template carries a tiered exemplar under '## Entry Format'.
# It must not make an otherwise untiered plan look tier-aware.
@test "the template's exemplar does not make an untiered plan report tiers" {
    "$RALPH" init
    printf -- '- [ ] **Untiered item** — x. → [001-a.md](plan/001-a.md)\n' >> IMPLEMENTATION_PLAN.md

    run "$RALPH" build --dry-run -n 1
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Model:   opus"* ]]
    [[ "$output" != *"Model:   per item"* ]]
}

# Markers merged in from main: neither shipped nor blocked entries may supply
# the tier, since neither is the item the iteration will attempt.
@test "shipped and blocked entries do not supply the tier" {
    "$RALPH" init
    {
        printf -- '- [x] (light) **Shipped** — done. → [001-a.md](plan/001-a.md)\n'
        printf -- '- [~] (light) **Blocked** — superseded. → [002-b.md](plan/002-b.md)\n'
        printf -- '- [ ] (heavy) **Real item** — x. → [003-c.md](plan/003-c.md)\n'
    } >> IMPLEMENTATION_PLAN.md

    run "$RALPH" build --dry-run -n 1
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Next:    [opus] Real item"* ]]
    [[ "$output" != *"--model sonnet"* ]]
}
