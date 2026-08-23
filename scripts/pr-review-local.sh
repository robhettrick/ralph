#!/usr/bin/env bash
# Run the same review pipeline locally that CI runs, against the current branch.
#
#   scripts/pr-review-local.sh [base-branch] [--post <pr-number>]
#
# Without --post it prints the filtered review and leaves everything in
# .claude-review/ for you to read. With --post it submits the review to the PR
# exactly as CI would (needs `gh auth login`).
#
# Same prompt, same filter, same thresholds as .github/workflows/claude-pr-review.yml,
# so a local run is a faithful preview of what CI will say.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

base="${1:-main}"; shift || true
post_pr=""
if [ "${1:-}" = "--post" ]; then post_pr="$2"; fi

: "${MIN_SEVERITY:=high}"
: "${MIN_CONFIDENCE:=80}"
: "${MAX_INLINE_COMMENTS:=10}"

rm -rf .claude-review && mkdir -p .claude-review
echo '{"schema": 1, "status": "not_written", "findings": []}' > .claude-review/findings.json

# Discover npm trees (root and one level down) so this works on any layout.
trees=$(for f in package.json */package.json; do [ -f "$f" ] && dirname "$f"; done | grep -v node_modules | sort -u | tr '\n' ' ')
tests=""; lints=""; tools=""
for d in $trees; do
  if [ "$d" = "." ]; then p=""; else p="--prefix $d "; fi
  tests="$tests npm ${p}test ;"; lints="$lints npm ${p}run lint ;"
  tools="$tools,Bash(npm ${p}test:*),Bash(npm ${p}run lint:*)"
done
ctx="Repository: $(git remote get-url origin 2>/dev/null || echo local)
Base ref for diff: $base
HEAD: $(git rev-parse HEAD)
npm trees in this repo: $trees
Test commands: $tests
Lint commands: $lints
Shell test suite: bats test/ (run it; it is the test command for this repo)
Only run tests/lint for trees the diff touches. Do not install anything.
Minimum severity that will be posted: $MIN_SEVERITY (confidence >= $MIN_CONFIDENCE)"
python3 - "$ctx" <<'EOF'
import sys, pathlib
tpl = pathlib.Path('.github/claude/pr-review-prompt.md').read_text()
pathlib.Path('.claude-review/prompt.md').write_text(tpl.replace('{{RUN_CONTEXT}}', sys.argv[1]))
EOF

# Claude may run tests/lint but may not install; make sure the trees it will
# touch have dependencies, same as the CI workflow does before the review step.
for d in $trees; do
  if [ ! -d "$d/node_modules" ]; then
    echo "Installing dependencies in $d (one-off, so Claude can run its tests)..."
    (cd "$d" && npm ci --ignore-scripts --no-audit --no-fund >/dev/null) || echo "npm ci failed in $d; tests there will be reported as not run"
  fi
done

echo "Running Claude review; one line per tool call follows (a large diff takes several minutes)."
set +e
claude -p "Read the file .claude-review/prompt.md and follow it exactly. Your only output is .claude-review/findings.json." \
  --max-turns 80 --verbose --output-format stream-json \
  --disallowedTools "WebFetch,WebSearch" \
  --allowedTools "Read,Grep,Glob,Edit(.claude-review/findings.json),Bash(git diff:*),Bash(git log:*),Bash(git show:*),Bash(git merge-base:*),Bash(bats:*)$tools" \
| tee .claude-review/stream.jsonl \
| jq -r --unbuffered '
    select(.type=="assistant") | .message.content[]? |
    if .type=="tool_use" then "  > \(.name) \(.input.command // .input.file_path // .input.pattern // "" | tostring | .[0:100])"
    elif .type=="text" then "  . \(.text | .[0:120])" else empty end'
set -e
if grep -q '"status": "not_written"' .claude-review/findings.json 2>/dev/null; then
  echo "findings.json was never written. Final result event:" >&2
  jq -c 'select(.type=="result") | {is_error, subtype, num_turns, result: (.result // "" | .[0:600])}' .claude-review/stream.jsonl >&2
fi

python3 .github/claude/filter_findings.py .claude-review/findings.json \
  --out .claude-review/review.json --summary .claude-review/summary.md \
  --min-severity "$MIN_SEVERITY" --min-confidence "$MIN_CONFIDENCE" --max-comments "$MAX_INLINE_COMMENTS"

cat .claude-review/summary.md
echo
jq -r '.body, "", (.comments[] | "--- \(.path):\(.line)\n\(.body)\n")' .claude-review/review.json

if [ -n "$post_pr" ]; then
  repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
  BOT_LOGIN="$(gh api user --jq .login)" bash .github/claude/post_review.sh "$repo" "$post_pr" .claude-review/review.json
fi
