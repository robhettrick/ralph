#!/usr/bin/env python3
"""Turn Claude's raw findings into a single GitHub PR review, dropping the noise.

This is the gate. Claude proposes; this script disposes. It never calls a model,
so the rules here hold regardless of how well the prompt was followed.

Usage:
  filter_findings.py findings.json --out review.json [--min-severity high]
                     [--min-confidence 80] [--max-comments 10]
                     [--suppress-category maintainability ...]
  filter_findings.py findings.json --out review.json --dry-run   # print decisions

Writes `review.json` shaped for `POST /repos/{owner}/{repo}/pulls/{n}/reviews`
plus a `summary.md` of everything that was filtered, so the noise is archived
rather than lost.
"""
import argparse
import json
import re
import sys
from pathlib import Path

SEVERITY_RANK = {"blocking": 4, "high": 3, "medium": 2, "low": 1}
DEFAULT_SUPPRESSED = {"style", "formatting", "naming", "docs", "praise"}
BANNED_TITLE_PATTERNS = [
    r"\btrailing whitespace\b",
    r"\bwhitespace\b",
    r"\bindentation\b",
    r"\btable (padding|alignment)\b",
    r"\bmarkdown (table|formatting)\b",
    r"\bimport order\b",
    r"\bline length\b",
    r"\bconsider (adding|using|renaming)\b",
    r"\bmight want to\b",
    r"\bnit\b",
    r"\btypo\b",
]


PLACEHOLDER_STATUS = "not_written"  # the workflow pre-creates findings.json with this marker


def load(path: Path) -> dict:
    """Read Claude's output. Any failure to produce a real file is a pipeline
    error, reported via _error and turned into a non-zero exit by main(), so a
    broken run fails the check rather than passing as a clean review."""
    try:
        data = json.loads(path.read_text())
    except FileNotFoundError:
        return {"findings": [], "_error": f"{path} not found (Claude wrote nothing)"}
    except json.JSONDecodeError as exc:
        return {"findings": [], "_error": f"{path} is not valid JSON: {exc}"}
    if not isinstance(data, dict):
        return {"findings": [], "_error": "findings.json is not a JSON object"}
    if data.get("status") == PLACEHOLDER_STATUS:
        return {"findings": [], "_error": "findings.json still holds the placeholder (Claude never wrote it)"}
    if not isinstance(data.get("findings"), list):
        data["findings"] = []
        data["_error"] = "findings is not a list"
    return data


def classify(f: dict, args) -> tuple[bool, str]:
    """Return (keep, reason)."""
    sev = str(f.get("severity", "")).lower()
    if sev not in SEVERITY_RANK:
        return False, f"unknown severity {sev!r}"
    f["severity"] = sev  # normalise in place: dedupe/sort index SEVERITY_RANK by this
    if SEVERITY_RANK[sev] < SEVERITY_RANK[args.min_severity]:
        return False, f"severity {sev} below {args.min_severity}"
    if f.get("verified") is not True:
        return False, "not verified against working tree"
    conf = f.get("confidence")
    if not isinstance(conf, (int, float)) or conf < args.min_confidence:
        return False, f"confidence {conf} below {args.min_confidence}"
    cat = str(f.get("category", "")).lower()
    if cat in args.suppressed:
        return False, f"category {cat} suppressed"
    title = str(f.get("title", ""))
    for pat in BANNED_TITLE_PATTERNS:
        if re.search(pat, title, re.I):
            return False, f"title matches noise pattern /{pat}/"
    if not f.get("path") or not isinstance(f.get("line"), int):
        return False, "missing path or line (cannot anchor)"
    if not str(f.get("evidence", "")).strip():
        return False, "no evidence quoted"
    if not title.strip() or not str(f.get("why", "")).strip():
        return False, "missing title or why"
    return True, "kept"


def dedupe(findings: list[dict]) -> tuple[list[dict], list[tuple[dict, str]]]:
    """One finding per anchored line: keep the most severe, then most confident."""
    ordered = sorted(findings, key=lambda f: (-SEVERITY_RANK[f["severity"]], -f["confidence"]))
    seen: dict[tuple, dict] = {}
    dropped = []
    for f in ordered:
        key = (f["path"], f["line"])
        if key in seen:
            dropped.append((f, f"same line as {seen[key].get('id')} (one finding per line)"))
            continue
        seen[key] = f
    return list(seen.values()), dropped


def comment_body(f: dict) -> str:
    sev = f["severity"].upper()
    lines = [f"**[{sev}] {f.get('title', '')}**", "", str(f.get("why", "")).strip()]
    if f.get("fix"):
        lines += ["", f"**Fix:** {f['fix'].strip()}"]
    if f.get("other_locations"):
        lines += ["", "Also at: " + ", ".join(f"`{loc}`" for loc in f["other_locations"])]
    lines += ["", f"<sub>Verified: {f.get('verification', '').strip()} · confidence {f.get('confidence')}</sub>"]
    return "\n".join(lines)


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("findings")
    p.add_argument("--out", default="review.json")
    p.add_argument("--summary", default="summary.md")
    p.add_argument("--min-severity", default="high", choices=SEVERITY_RANK)
    p.add_argument("--min-confidence", type=int, default=80)
    p.add_argument("--max-comments", type=int, default=10)
    p.add_argument("--suppress-category", action="append", default=[])
    p.add_argument("--dry-run", action="store_true")
    args = p.parse_args()
    args.suppressed = DEFAULT_SUPPRESSED | {c.lower() for c in args.suppress_category}

    data = load(Path(args.findings))
    kept, filtered = [], []
    for f in data["findings"]:
        ok, reason = classify(f, args)
        (kept if ok else filtered).append((f, reason) if not ok else f)
    kept, dups = dedupe(kept)
    filtered += dups
    kept.sort(key=lambda f: (-SEVERITY_RANK[f["severity"]], -f["confidence"]))

    inline, overflow = kept[: args.max_comments], kept[args.max_comments :]
    blocking = [f for f in kept if f["severity"] == "blocking"]
    event = "REQUEST_CHANGES" if blocking else ("COMMENT" if kept else "APPROVE_NOOP")

    body = []
    if kept:
        body.append(f"Claude review: {len(blocking)} blocking, {len(kept) - len(blocking)} high.")
        if overflow:
            body.append("")
            body.append(f"{len(overflow)} further findings not shown inline:")
            body += [f"- **{f['severity']}** `{f['path']}:{f['line']}` {f.get('title', '')}" for f in overflow]
    if filtered:
        body.append("")
        body.append(
            f"<sub>{len(filtered)} lower-value or unverified findings filtered; see the `claude-review` workflow artifact.</sub>"
        )
    if data.get("_error"):
        body.append("")
        body.append(f"<sub>Review pipeline note: {data['_error']}</sub>")

    review = {
        "event": event,
        "body": "\n".join(body).strip(),
        "comments": [
            {"path": f["path"], "line": f["line"], "side": "RIGHT", "body": comment_body(f)}
            for f in inline
        ],
        "stats": {"raw": len(data["findings"]), "kept": len(kept), "filtered": len(filtered)},
    }

    summary = ["# Claude review: filter log", ""]
    summary.append(f"Raw findings: {len(data['findings'])}; posted: {len(kept)}; filtered: {len(filtered)}")
    if data.get("checks_run"):
        summary += ["", "Checks Claude reports running:"] + [f"- {c}" for c in data["checks_run"]]
    summary += ["", "## Posted"] + [
        f"- {f['severity']} ({f['confidence']}) `{f['path']}:{f['line']}` {f.get('title', '')}" for f in kept
    ]
    summary += ["", "## Filtered"] + [
        f"- {f.get('severity')} ({f.get('confidence')}) `{f.get('path')}:{f.get('line')}` {f.get('title')} <- {why}"
        for f, why in filtered
    ]

    if data.get("_error"):
        summary += ["", f"## Pipeline error", "", data["_error"]]

    if args.dry_run:
        print("\n".join(summary))
        print(json.dumps(review, indent=2))
        return 2 if data.get("_error") else 0
    Path(args.out).write_text(json.dumps(review, indent=2))
    Path(args.summary).write_text("\n".join(summary) + "\n")
    print(f"event={event} posted={len(kept)} filtered={len(filtered)}")
    if data.get("_error"):
        print(f"PIPELINE ERROR: {data['_error']}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
