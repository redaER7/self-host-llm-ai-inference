"""Log postprocessing for bench_matrix sweeps.

Reads index.csv produced by a sweep and renders:
  - summary-ctx{N}.log        per-context tables + BEST sections
  - summary-all-contexts.log  cross-context tables + BEST per concurrency

Imported by bench_matrix.py for append_index (row writer) and write_summaries
(end-of-sweep regeneration).
"""

import csv
import re
from datetime import datetime
from pathlib import Path

TTFT_TIERS = [1, 2, 5, 8, 10, 20, 50, 100]   # seconds — best-config latency classes


def percentile(data, p):
    if not data:
        return 0
    s = sorted(data)
    k = max(0, min(len(s) - 1, int(len(s) * p / 100)))
    return s[k]


# ── Index CSV ─────────────────────────────────────────────────────────────────


def append_index(csv_path, config, throughput, ttft_vals, budget):
    file_exists = csv_path.exists()
    with open(csv_path, "a", newline="") as f:
        writer = csv.writer(f)
        if not file_exists:
            writer.writerow(
                [
                    "context",
                    "input_frac",
                    "input_tokens",
                    "concurrency",
                    "max_tokens",
                    "stream",
                    "repeat",
                    "success",
                    "errors",
                    "agg_req_s",
                    "agg_tok_s",
                    "ttft_p50",
                    "ttft_p95",
                    "lat_p50",
                    "lat_p95",
                    "decode_p50",
                    "decode_p95",
                    "budget_exceeded",
                    "timestamp",
                ]
            )
        lat_p50 = percentile(throughput["durations"], 50)
        lat_p95 = percentile(throughput["durations"], 95)
        decode_p50 = percentile(throughput["tok_rates"], 50)
        decode_p95 = percentile(throughput["tok_rates"], 95)
        ttft_p50 = percentile(ttft_vals, 50) if ttft_vals else 0
        ttft_p95 = percentile(ttft_vals, 95) if ttft_vals else 0
        budget_exceeded = (
            "yes"
            if throughput["durations"] and max(throughput["durations"]) > budget
            else "no"
        )
        writer.writerow(
            [
                config["context"],
                config["input_frac"],
                config["input_tokens"],
                config["concurrency"],
                config["max_tokens"],
                config["stream"],
                config["repeat"],
                throughput["success"],
                throughput["errors"],
                f"{throughput['agg_req_s']:.2f}",
                f"{throughput['agg_tok_s']:.0f}",
                f"{ttft_p50:.2f}",
                f"{ttft_p95:.2f}",
                f"{lat_p50:.1f}",
                f"{lat_p95:.1f}",
                f"{decode_p50:.1f}",
                f"{decode_p95:.1f}",
                budget_exceeded,
                datetime.now().isoformat(),
            ]
        )


def _read_index_rows(csv_path):
    if not csv_path.exists():
        return []
    with open(csv_path, newline="") as f:
        return list(csv.DictReader(f))


def _group_median(rows, key_fields):
    """Group rows by key_fields; median across repeats for each metric."""
    groups = {}
    for r in rows:
        k = tuple(r[f] for f in key_fields)
        groups.setdefault(k, []).append(r)
    out = []
    for k, rs in groups.items():
        def med(field):
            vals = [float(r[field]) for r in rs]
            return percentile(vals, 50)
        out.append(
            {
                **dict(zip(key_fields, k)),
                "input_tokens": med("input_tokens"),
                "agg_tok_s": med("agg_tok_s"),
                "ttft_p50": med("ttft_p50"),
                "ttft_p95": med("ttft_p95"),
                "lat_p50": med("lat_p50"),
                "lat_p95": med("lat_p95"),
                "decode_p50": med("decode_p50"),
                "decode_p95": med("decode_p95"),
                "errors": sum(int(float(r["errors"])) for r in rs),
                "requests": sum(int(float(r["success"])) + int(float(r["errors"])) for r in rs),
                "reps": len(rs),
            }
        )
    return sorted(out, key=lambda g: (-float(g["input_frac"]), -int(g["concurrency"]),
                                      -int(g["max_tokens"]), g["stream"] == "True"))


# ── Rendering ─────────────────────────────────────────────────────────────────


def _fmt_toks(n):
    """Human-readable token count: 512 → '512', 131072 → '131k', 2097152 → '2.1M'."""
    n = int(n)
    if n >= 1_000_000:
        v = n / 1_000_000
        return f"{v:.1f}M".replace(".0M", "M")
    if n >= 1000:
        return f"{n // 1000}k"
    return str(n)


def _fmt_summary(groups, show_ctx=False):
    hdr_ctx = "ctx      " if show_ctx else ""
    lines = [
        f"{hdr_ctx}in_frac  in_toks  c   mt     stream | agg_tok/s  ttft_p50  ttft_p95 | lat_p50  lat_p95 | dec_tok/s p50→p95",
        "-" * (114 if show_ctx else 107),
    ]
    for g in groups:
        ctx_cell = f"{g['context']:<9}" if show_ctx else ""
        err = f"  ⚠{g['errors']}err" if int(g["errors"]) else ""
        lines.append(
            f"{ctx_cell}{float(g['input_frac']):<8}"
            f"{_fmt_toks(g['input_tokens']):>7}  "
            f"{int(g['concurrency']):<4}"
            f"{int(g['max_tokens']):<7}"
            f"{'on' if g['stream'] == 'True' else 'off':<7}| "
            f"{g['agg_tok_s']:>8.0f}  "
            f"{g['ttft_p50']:>8.1f}  {g['ttft_p95']:>8.1f} | "
            f"{g['lat_p50']:>7.1f}  {g['lat_p95']:>7.1f} | "
            f"{g['decode_p50']:>5.0f} → {g['decode_p95']:<5.0f}{err}"
        )
    return "\n".join(lines)


def _best_config(groups):
    """Highest-throughput config within the tightest TTFT tier that has candidates."""
    for tier in TTFT_TIERS:
        pool = [g for g in groups if g["ttft_p50"] < tier]
        if pool:
            return {**max(pool, key=lambda g: g["agg_tok_s"]), "tier": f"<{tier}s"}
    return {**max(groups, key=lambda g: g["agg_tok_s"]), "tier": ">100s"}


def _fmt_best_body(best):
    """Config + metrics part of a BEST line (no leading label)."""
    stream = "on" if best["stream"] == "True" else "off"
    total = int(best["requests"])
    ok = total - int(best["errors"])
    pct = 100.0 * ok / total if total else 0.0
    success = f"{pct:.0f}%" if not int(best["errors"]) else f"{pct:.0f}% ({ok}/{total})"
    return (
        f"in_frac={best['input_frac']} in_toks={_fmt_toks(best['input_tokens'])} "
        f"c={best['concurrency']} "
        f"mt={best['max_tokens']} stream={stream} → "
        f"{best['agg_tok_s']:.0f} tok/s agg · "
        f"TTFT {best['ttft_p50']:.1f}s (p95 {best['ttft_p95']:.1f}s) · "
        f"latency {best['lat_p50']:.1f}s (p95 {best['lat_p95']:.1f}s) · "
        f"decode {best['decode_p50']:.0f} tok/s · "
        f"success {success}"
    )


def _fmt_best_line(best):
    label = (
        f"BEST (TTFT {best['tier']})"
        if best["tier"] != ">100s"
        else "BEST (fallback: no config under 100s TTFT)"
    )
    return f"  {label}: {_fmt_best_body(best)}"


def _best_by_concurrency(groups):
    """Best config per concurrency level (same TTFT-tier logic as _best_config)."""
    by_c = {}
    for g in groups:
        by_c.setdefault(int(g["concurrency"]), []).append(g)
    return {c: _best_config(gs) for c, gs in sorted(by_c.items())}


def _fmt_best_per_concurrency(groups, show_ctx=False):
    """'BEST per concurrency' section; per context when show_ctx is set."""
    lines = []
    if show_ctx:
        for ctx in sorted({g["context"] for g in groups}, key=int):
            ctx_groups = [g for g in groups if g["context"] == ctx]
            for c, best in _best_by_concurrency(ctx_groups).items():
                lines.append(f"  ctx={ctx:<7}c={c:<3}→ {_fmt_best_body(best)}")
    else:
        for c, best in _best_by_concurrency(groups).items():
            lines.append(f"  c={c:<3}→ {_fmt_best_body(best)}")
    return "\n".join(lines)


def _campaign_table(best_by_ctx, model, gpu):
    """Markdown-style comparison table, one row per context (best config)."""
    lines = [
        "| Model | GPU | Ctx | Concurrency | TTFT p50 | TTFT p95 | Throughput (agg.) | Per-Stream TPS | p95 Latency | Success | TTFT Class |",
        "|---|---|---|---|---|---|---|---|---|---|---|",
    ]
    for ctx in sorted(best_by_ctx, key=int):
        b = best_by_ctx[ctx]
        total = int(b["requests"])
        ok = total - int(b["errors"])
        pct = 100.0 * ok / total if total else 0.0
        success = f"{pct:.0f}%" if not int(b["errors"]) else f"{pct:.0f}% ({ok}/{total})"
        lines.append(
            f"| {model} | {gpu} | {ctx} | {b['concurrency']} | "
            f"{b['ttft_p50']:.1f}s | {b['ttft_p95']:.1f}s | "
            f"{b['agg_tok_s']:.0f} tok/s | {b['decode_p50']:.0f} tok/s | "
            f"{b['lat_p95']:.1f}s | {success} | {b['tier']} |"
        )
    return "\n".join(lines)


# ── Entry points ──────────────────────────────────────────────────────────────


def write_summaries(results_dir, csv_path, gpu="—"):
    rows = _read_index_rows(csv_path)
    if not rows:
        return

    key = ("context", "input_frac", "concurrency", "max_tokens", "stream")
    model = re.sub(r"-\d{8}$", "", results_dir.name.replace("Test-", "", 1))

    # Per-context summaries
    contexts = sorted({r["context"] for r in rows}, key=int)
    for ctx in contexts:
        ctx_groups = _group_median([r for r in rows if r["context"] == ctx], key)
        n_batches = sum(g["reps"] for g in ctx_groups)
        total_err = sum(int(g["errors"]) for g in ctx_groups)
        best = _best_config(ctx_groups)
        with open(results_dir / f"summary-ctx{ctx}.log", "w") as f:
            f.write(f"# Summary ctx={ctx} — {model}\n")
            f.write(f"# generated {datetime.now().strftime('%Y-%m-%d %H:%M')} · "
                    f"{n_batches} batches · {total_err} errors\n\n")
            f.write(_fmt_summary(ctx_groups) + "\n\n")
            f.write(_fmt_best_line(best) + "\n\n")
            f.write("BEST per concurrency\n")
            f.write(_fmt_best_per_concurrency(ctx_groups) + "\n\n")
            f.write(_campaign_table({ctx: best}, model, gpu) + "\n")

    # All-contexts summary
    all_groups = _group_median(rows, key)
    best_by_ctx = {ctx: _best_config([g for g in all_groups if g["context"] == ctx])
                   for ctx in contexts}
    with open(results_dir / "summary-all-contexts.log", "w") as f:
        f.write(f"# Summary — all contexts — {model}\n")
        f.write(f"# GPU: {gpu}\n")
        f.write(f"# generated {datetime.now().strftime('%Y-%m-%d %H:%M')} · "
                f"{len(rows)} batches · {sum(int(float(r['errors'])) for r in rows)} errors\n\n")
        f.write(_fmt_summary(all_groups, show_ctx=True) + "\n\n")
        f.write("BEST per concurrency (per context)\n")
        f.write(_fmt_best_per_concurrency(all_groups, show_ctx=True) + "\n\n")
        f.write(_campaign_table(best_by_ctx, model, gpu) + "\n")
