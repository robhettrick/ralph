#!/usr/bin/env bash
# Post the filtered review to the PR. Needs: gh (authenticated with a token
# that has pull-requests: write), jq, and review.json from filter_findings.py.
#
#   post_review.sh <owner/repo> <pr-number> review.json
#
# Behaviour:
#   - Dismisses any earlier CHANGES_REQUESTED review left by this bot, so a
#     fixed PR is not blocked by a stale verdict.
#   - Posts one review with inline comments. If GitHub rejects the payload
#     (usually a line that is not in the diff), retries with the comments
#     folded into the review body so nothing is lost.
#   - Always maintains one sticky status comment per PR (edited in place);
#     posts a review with inline comments only when something survived the gate.
set -euo pipefail

repo="$1"; pr="$2"; review="$3"
bot_login="${BOT_LOGIN:-github-actions[bot]}"
event=$(jq -r .event "$review")
stats=$(jq -c .stats "$review")
echo "review stats: $stats event: $event"

# 1. Dismiss stale blocking reviews from a previous run.
gh api "repos/$repo/pulls/$pr/reviews" --paginate \
  --jq ".[] | select(.user.login==\"$bot_login\" and .state==\"CHANGES_REQUESTED\") | .id" |
while read -r id; do
  [ -n "$id" ] || continue
  gh api -X PUT "repos/$repo/pulls/$pr/reviews/$id/dismissals" \
    -f message="Superseded by a newer Claude review run." -f event=DISMISS >/dev/null \
    && echo "dismissed stale review $id"
done

# 2. Sticky status line: one bot comment per PR, edited in place each run, so a
#    reader can see the PR was checked (and how much was considered) without
#    opening the Actions tab. Inline findings still go through the review below.
marker="<!-- claude-review-status -->"
raw=$(jq -r .stats.raw "$review"); kept=$(jq -r .stats.kept "$review"); filtered=$(jq -r .stats.filtered "$review")
sha=$(git rev-parse --short HEAD 2>/dev/null || echo "HEAD")
run_url="${GITHUB_SERVER_URL:-https://github.com}/$repo/actions/runs/${GITHUB_RUN_ID:-}"
if [ "$kept" = "0" ]; then
  verdict="nothing to post"
else
  verdict="$kept posted as review comments"
fi
status="$marker
**Claude review** of \`$sha\`: $raw finding(s) considered, $verdict, $filtered filtered below the bar ([filter log]($run_url))."
existing=$(gh api "repos/$repo/issues/$pr/comments" --paginate --jq ".[] | select(.user.login==\"$bot_login\" and (.body | startswith(\"$marker\"))) | .id" | head -1)
if [ -n "$existing" ]; then
  gh api -X PATCH "repos/$repo/issues/comments/$existing" -f body="$status" >/dev/null && echo "status comment updated"
else
  gh api -X POST "repos/$repo/issues/$pr/comments" -f body="$status" >/dev/null && echo "status comment created"
fi

# 3. Nothing to say beyond the status line.
if [ "$event" = "APPROVE_NOOP" ]; then
  echo "clean pass, no review posted"
  exit 0
fi

# 4. Post the review; fall back to body-only on 422.
payload=$(jq '{event, body, comments}' "$review")
if ! out=$(echo "$payload" | gh api -X POST "repos/$repo/pulls/$pr/reviews" --input - 2>&1); then
  echo "inline post rejected, falling back to body-only: $out" >&2
  folded=$(jq -r '
    .body + "\n\n" +
    ([.comments[] | "### `\(.path):\(.line)`\n\(.body)"] | join("\n\n"))' "$review")
  jq -n --arg event "$event" --arg body "$folded" '{event:$event, body:$body}' |
    gh api -X POST "repos/$repo/pulls/$pr/reviews" --input - >/dev/null
fi
echo "posted $event"
