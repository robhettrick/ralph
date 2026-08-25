#!/usr/bin/env python3
"""Streamlit dashboard for ralph loop metrics.

Aggregates every run under .ralph/metrics/ (and .ralph/metrics-prev/) rather than
a single run, so cost and progress can be compared across runs and branches.
`ralph metrics` remains the per-run text summary; this is the cross-run view.

Run it from a ralph workspace:

    uv run --with streamlit --with plotly --with pandas \
      streamlit run ~/.config/ralph/scripts/metrics-dashboard.py
"""
import json
import os
import pathlib

import pandas as pd
import plotly.express as px
import streamlit as st

ARCHIVE_DIR = pathlib.Path(os.environ.get("RALPH_ARCHIVE_DIR", ".ralph"))
# metrics-prev holds runs rotated out by `ralph clean`; include it so history is
# not silently dropped from totals.
SEARCH_DIRS = ("metrics", "metrics-prev")

st.set_page_config(page_title="ralph metrics", page_icon="🔁", layout="wide")
st.title("ralph — loop cost and progress")


def _run_dirs(root: pathlib.Path):
    for sub in SEARCH_DIRS:
        base = root / sub
        if not base.is_dir():
            continue
        for d in sorted(base.iterdir()):
            if (d / "metrics.jsonl").is_file():
                yield sub, d


@st.cache_data(ttl=10)
def load(root_str: str) -> pd.DataFrame:
    root = pathlib.Path(root_str)
    rows = []
    for origin, d in _run_dirs(root):
        for line in (d / "metrics.jsonl").read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
            except json.JSONDecodeError:
                continue  # a partially written line; skip rather than fail
            # Run identity is the directory name: <branch>-<timestamp>-<pid>.
            # It is the only per-run key, since rows carry no run id.
            r["run"] = d.name
            r["archived"] = origin == "metrics-prev"
            # Flatten the nested groups so they can be filtered and charted.
            for group in ("tokens", "git"):
                g = r.pop(group, None) or {}
                for k, v in g.items():
                    r[f"{group}_{k}"] = v
            r["tools"] = r.get("tools") or {}
            rows.append(r)
    if not rows:
        return pd.DataFrame()

    df = pd.DataFrame(rows)
    for col in ("started", "ended"):
        if col in df:
            df[col] = pd.to_datetime(df[col], errors="coerce", utc=True)
    numeric = [
        "iteration", "wall_s", "api_s", "turns", "cost_usd",
        "plan_items_completed",
        "tokens_input", "tokens_output", "tokens_cache_read", "tokens_cache_write",
        "git_commits", "git_files_changed", "git_insertions", "git_deletions",
    ]
    for col in numeric:
        if col in df:
            df[col] = pd.to_numeric(df[col], errors="coerce").fillna(0)
    # Older rows predate commit/dirty capture; normalise so filters see a value.
    for col in ("commit", "branch", "model", "mode", "backend", "result_status"):
        if col not in df:
            df[col] = None
        df[col] = df[col].fillna("(unknown)")
    if "dirty" not in df:
        df["dirty"] = None
    if "git_noop" not in df:
        df["git_noop"] = False
    df["git_noop"] = df["git_noop"].fillna(False).astype(bool)
    df["churn"] = df["git_insertions"] + df["git_deletions"]
    return df.sort_values(["run", "iteration"])


path_input = st.sidebar.text_input("Archive directory", str(ARCHIVE_DIR))
df = load(path_input)

if df.empty:
    st.info(
        f"No metrics found under `{path_input}/metrics/` or `{path_input}/metrics-prev/`.\n\n"
        "Run the dashboard from a ralph workspace, or point the box above at one. "
        "Metrics are written per run unless `--no-metrics` was passed."
    )
    st.stop()

# ── Filters ──────────────────────────────────────────────────────────────────
with st.sidebar:
    st.header("Filters")
    branches = sorted(df["branch"].dropna().unique())
    sel_branch = st.multiselect("Branch", branches, default=branches)
    models = sorted(df["model"].dropna().unique())
    sel_model = st.multiselect("Model", models, default=models)
    modes = sorted(df["mode"].dropna().unique())
    sel_mode = st.multiselect("Mode", modes, default=modes)
    df = df[
        df["branch"].isin(sel_branch)
        & df["model"].isin(sel_model)
        & df["mode"].isin(sel_mode)
    ]
    runs = sorted(df["run"].dropna().unique())
    sel_runs = st.multiselect("Run", runs, default=[], help="Empty means all runs.")
    if sel_runs:
        df = df[df["run"].isin(sel_runs)]
    if not st.checkbox("Include archived runs", value=True,
                       help="Runs rotated into metrics-prev by `ralph clean`."):
        df = df[~df["archived"]]

view = df
if view.empty:
    st.warning("No rows match the current filters.")
    st.stop()

# ── Headline metrics ─────────────────────────────────────────────────────────
c1, c2, c3, c4, c5, c6 = st.columns(6)
c1.metric("Total spend", f"${view['cost_usd'].sum():,.2f}")
c2.metric("Runs", f"{view['run'].nunique():,}")
c3.metric("Iterations", f"{len(view):,}")
_noop = int(view["git_noop"].sum())
c4.metric(
    "No-op iterations",
    f"{_noop} ({_noop / len(view) * 100:.0f}%)",
    help="Iterations that produced no commit (or, in plan mode, no plan change). "
         "Spend here bought no change.",
)
c5.metric(
    "Mean cost / iteration",
    f"${view['cost_usd'].mean():,.2f}",
)
c6.metric(
    "Elapsed",
    f"{view['wall_s'].sum() / 3600:,.1f} h",
    help=(
        "Summed iteration wall-clock time (ended - started), i.e. how long the "
        "loop actually took. Distinct from API time, shown in the tables: "
        f"these iterations used {view['api_s'].sum() / 3600:,.1f} h of summed "
        "API time, which can exceed elapsed time when an iteration runs "
        "subagents concurrently — it is a workload total, not a duration."
    ),
)

_wasted = view.loc[view["git_noop"], "cost_usd"].sum()
if _wasted > 0:
    st.caption(f"⚠ ${_wasted:,.2f} of the total was spent on no-op iterations.")

# ── Cost per run ─────────────────────────────────────────────────────────────
per_run = (
    view.groupby(["run", "branch", "model", "mode"], as_index=False)
    .agg(
        cost_usd=("cost_usd", "sum"),
        iterations=("iteration", "size"),
        wall_s=("wall_s", "sum"),
        api_s=("api_s", "sum"),
        commits=("git_commits", "sum"),
        churn=("churn", "sum"),
        plan_done=("plan_items_completed", "sum"),
        noops=("git_noop", "sum"),
    )
    .sort_values("cost_usd", ascending=False)
)

left, right = st.columns([3, 2])
with left:
    st.subheader("Cost per run")
    st.plotly_chart(
        px.bar(per_run, x="run", y="cost_usd", color="branch",
               labels={"cost_usd": "Cost (USD)", "run": "", "branch": "Branch"}),
        use_container_width=True,
    )
with right:
    st.subheader("Spend by branch")
    st.plotly_chart(
        px.bar(
            view.groupby(["branch", "mode"], as_index=False)["cost_usd"].sum()
                .sort_values("cost_usd", ascending=False),
            x="cost_usd", y="branch", color="mode", orientation="h",
            labels={"cost_usd": "Cost (USD)", "branch": "", "mode": "Mode"},
        ),
        use_container_width=True,
    )

# ── Cost against progress ────────────────────────────────────────────────────
st.subheader("Cost against progress, by iteration")
st.plotly_chart(
    px.scatter(
        view, x="iteration", y="cost_usd", color="model", symbol="mode",
        size="churn", size_max=28, hover_data=["run", "branch", "commit", "turns"],
        labels={"cost_usd": "Cost (USD)", "iteration": "Iteration", "model": "Model"},
    ),
    use_container_width=True,
)

lc, rc = st.columns(2)
with lc:
    st.subheader("Mean cost per iteration, by model and mode")
    st.plotly_chart(
        px.bar(
            view.groupby(["model", "mode"], as_index=False)["cost_usd"].mean(),
            x="model", y="cost_usd", color="mode", barmode="group",
            labels={"cost_usd": "Mean cost (USD)", "model": "Model", "mode": "Mode"},
        ),
        use_container_width=True,
    )
with rc:
    st.subheader("Cumulative spend")
    cum = view.sort_values("started").assign(cumulative=lambda d: d["cost_usd"].cumsum())
    st.plotly_chart(
        px.line(cum, x="started", y="cumulative", color="branch",
                labels={"cumulative": "Cumulative (USD)", "started": "", "branch": "Branch"}),
        use_container_width=True,
    )

# ── Tool usage: ralph-specific signal reveng has no equivalent for ───────────
tool_counts = {}
for d in view["tools"]:
    if isinstance(d, dict):
        for k, v in d.items():
            tool_counts[k] = tool_counts.get(k, 0) + int(v or 0)
if tool_counts:
    st.subheader("Tool calls")
    tools_df = (
        pd.DataFrame({"tool": list(tool_counts), "calls": list(tool_counts.values())})
        .sort_values("calls", ascending=False)
    )
    st.plotly_chart(
        px.bar(tools_df, x="calls", y="tool", orientation="h",
               labels={"calls": "Calls", "tool": ""}),
        use_container_width=True,
    )

st.subheader("Runs")
st.dataframe(
    per_run.assign(
        cost_usd=lambda d: d["cost_usd"].round(4),
        wall_s=lambda d: d["wall_s"].round(0),
        api_s=lambda d: d["api_s"].round(0),
    ),
    use_container_width=True,
    hide_index=True,
)

st.subheader("Iterations")
cols = [c for c in (
    "run", "branch", "commit", "dirty", "iteration", "mode", "model",
    "wall_s", "api_s", "turns", "cost_usd", "git_commits", "churn",
    "plan_items_completed", "git_noop", "result_status",
) if c in view]
st.dataframe(
    view[cols].assign(cost_usd=lambda d: d["cost_usd"].round(4)),
    use_container_width=True,
    hide_index=True,
)
