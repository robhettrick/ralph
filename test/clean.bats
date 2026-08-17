#!/usr/bin/env bats

load test_helper

@test "clean deletes existing artifacts" {
    "$RALPH" init
    run "$RALPH" clean
    [[ "$status" -eq 0 ]]
    [[ ! -f "IMPLEMENTATION_PLAN.md" ]]
    [[ ! -f "PROGRESS.md" ]]
}

@test "clean preserves local prompt templates" {
    "$RALPH" init --prompts
    run "$RALPH" clean
    [[ "$status" -eq 0 ]]
    [[ -f "PROMPT_plan.md" ]]
    [[ -f "PROMPT_build.md" ]]
}

@test "clean reports deleted files" {
    "$RALPH" init
    run "$RALPH" clean
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Deleted: IMPLEMENTATION_PLAN.md"* ]]
    [[ "$output" == *"Deleted: PROGRESS.md"* ]]
}

@test "clean handles no artifacts gracefully" {
    run "$RALPH" clean
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Nothing to clean."* ]]
}

@test "clean does not remove specs/ directory" {
    "$RALPH" init
    run "$RALPH" clean
    [[ "$status" -eq 0 ]]
    [[ -d "specs" ]]
}

@test "clean deletes per-task files under plan/" {
    "$RALPH" init
    printf '# 001. Thing\n' > plan/001-thing.md
    printf '# 002. Other\n' > plan/002-other.md
    run "$RALPH" clean
    [[ "$status" -eq 0 ]]
    [[ ! -f "plan/001-thing.md" ]]
    [[ ! -f "plan/002-other.md" ]]
    [[ "$output" == *"Deleted: plan/001-thing.md"* ]]
    # The directory is workspace scaffolding, like specs/ — it stays
    [[ -d "plan" ]]
}

# plan/ may predate ralph in the project, so clean only touches files matching
# the NNN-slug.md convention it generates.
@test "clean leaves files in plan/ that ralph did not create" {
    "$RALPH" init
    printf '# mine\n' > plan/roadmap.md
    printf '# 001. Thing\n' > plan/001-thing.md
    run "$RALPH" clean
    [[ "$status" -eq 0 ]]
    [[ ! -f "plan/001-thing.md" ]]
    [[ -f "plan/roadmap.md" ]]
}

@test "clean reports nothing to clean when only unrelated plan/ files exist" {
    mkdir -p plan
    printf '# mine\n' > plan/roadmap.md
    run "$RALPH" clean
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Nothing to clean."* ]]
    [[ -f "plan/roadmap.md" ]]
}
