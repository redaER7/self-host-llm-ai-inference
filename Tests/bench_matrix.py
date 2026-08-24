#!/usr/bin/env python3
"""bench_matrix.py — interactive matrix sweep for deployed vLLM models.

Usage:
    python3 Tests/bench_matrix.py --model casperhansen/deepseek-r1-distill-qwen-32b-awq --contexts 8192
    python3 Tests/bench_matrix.py --model ... --contexts 8192,32768 --force
    python3 Tests/bench_matrix.py --url https://llm.yacodata.com/v1/chat/completions --dry-run
"""

import asyncio, aiohttp, json, os, random, re, sys, time, csv, argparse
from datetime import datetime
from pathlib import Path
from prompts import PROMPTS

# ── Defaults ──────────────────────────────────────────────────────────────────

DEFAULT_URL = "https://llm.yacodata.com/v1/chat/completions"
CONTEXTS = [8192, 32768, 131072, 262144]
INPUT_FRACS = [0.5, 0.8]
CONCURRENCY_LEVELS = [2,4,8,16]
MAX_TOKENS_BASE = [512, 2048]
MAX_TOKENS_LONG = 8192
LONG_CONTEXTS = [131072, 262144]
STREAM_OPTIONS = [True, False]
REPEATS = 1
WARMUP = 0
TTFT_PROBES = 5
BUDGET_SECONDS = 240
MAX_CONCURRENT_BATCHES = 10
REASONING_RESERVE = 512   # headroom for <think> tokens counted against context
MIN_EFFECTIVE_TOKENS = 128

# ── Helpers ───────────────────────────────────────────────────────────────────


def percentile(data, p):
    if not data:
        return 0
    s = sorted(data)
    k = max(0, min(len(s) - 1, int(len(s) * p / 100)))
    return s[k]


def fmt_pct(data):
    if not data:
        return "  —"
    return f"min {min(data):.1f}s  p50 {percentile(data, 50):.1f}s  p95 {percentile(data, 95):.1f}s  max {max(data):.1f}s"


def sanitize(name):
    return "".join(c if c.isalnum() or c in "-_" else "-" for c in name)


def build_prompt(target_tokens):
    """Build a prompt of approximately target_tokens by repeating PROMPTS."""
    target_chars = target_tokens * 4
    parts = []
    total = 0
    i = 0
    while total < target_chars:
        parts.append(PROMPTS[i % len(PROMPTS)])
        total += len(parts[-1]) + 1
        i += 1
    return "\n".join(parts)[:target_chars]


def get_results_dir(model_name):
    date_str = datetime.now().strftime("%Y%m%d")
    return Path(__file__).resolve().parent / "results" / f"Test-{sanitize(model_name)}-{date_str}"


def get_tested_contexts(results_dir, contexts):
    tested = []
    for ctx in contexts:
        if (results_dir / f"ctx{ctx}.log").exists():
            tested.append(ctx)
    return tested


# ── Request functions ──────────────────────────────────────────────────────────


async def send_request(session, url, idx, payload):
    start = time.monotonic()
    try:
        async with session.post(url, json=payload) as resp:
            body = await resp.json()
            elapsed = time.monotonic() - start
            usage = body.get("usage", {})
            tokens = usage.get("completion_tokens", 0)
            return {
                "idx": idx,
                "max_tokens": payload["max_tokens"],
                "ttft": None,
                "duration": elapsed,
                "tokens": tokens,
                "tok_s": tokens / elapsed if elapsed > 0 and tokens else 0,
                "status": resp.status,
                "error": None,
            }
    except Exception as e:
        elapsed = time.monotonic() - start
        return {
            "idx": idx,
            "max_tokens": payload["max_tokens"],
            "ttft": None,
            "duration": elapsed,
            "tokens": 0,
            "tok_s": 0,
            "status": 0,
            "error": str(e),
        }


async def send_streaming_ttft(session, url, idx, payload):
    start = time.monotonic()
    try:
        async with session.post(url, json={**payload, "stream": True}) as resp:
            ttft = None
            while True:
                line = await resp.content.readline()
                if not line:
                    break
                line = line.strip()
                if line.startswith(b"data: [DONE]"):
                    break
                if line.startswith(b"data: "):
                    if ttft is None:
                        ttft = time.monotonic() - start
                    break
            return {"idx": idx, "ttft": ttft, "status": resp.status, "error": None}
    except Exception as e:
        return {"idx": idx, "ttft": None, "status": 0, "error": str(e)}


async def send_streaming_full(session, url, idx, payload):
    start = time.monotonic()
    ttft = None
    try:
        async with session.post(url, json={**payload, "stream": True}) as resp:
            last_usage = None
            while True:
                line = await resp.content.readline()
                if not line:
                    break
                line = line.strip()
                if not line or line.startswith(b":"):
                    continue
                if line.startswith(b"data: [DONE]"):
                    break
                if line.startswith(b"data: "):
                    if ttft is None:
                        ttft = time.monotonic() - start
                    data = line[5:].strip()
                    try:
                        chunk = json.loads(data)
                        if "usage" in chunk:
                            last_usage = chunk["usage"]
                    except json.JSONDecodeError:
                        pass
            elapsed = time.monotonic() - start
            tokens = last_usage.get("completion_tokens", 0) if last_usage else 0
            return {
                "idx": idx,
                "max_tokens": payload["max_tokens"],
                "ttft": ttft,
                "duration": elapsed,
                "tokens": tokens,
                "tok_s": tokens / elapsed if elapsed > 0 and tokens else 0,
                "status": resp.status,
                "error": None,
            }
    except Exception as e:
        elapsed = time.monotonic() - start
        return {
            "idx": idx,
            "max_tokens": payload["max_tokens"],
            "ttft": None,
            "duration": elapsed,
            "tokens": 0,
            "tok_s": 0,
            "status": 0,
            "error": str(e),
        }


# ── Batch runners ─────────────────────────────────────────────────────────────


async def run_ttft_probes(session, url, model, prompt, concurrency, n_probes=5):
    tasks = []
    for i in range(min(concurrency, n_probes)):
        payload = {
            "model": model,
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": random.randint(100, 1000),
        }
        tasks.append(send_streaming_ttft(session, url, i + 1, payload))
    results = await asyncio.gather(*tasks)
    ttft_vals = [r["ttft"] for r in results if r["ttft"] and r["status"] == 200]
    return results, ttft_vals


async def run_throughput_batch(session, url, model, prompt, concurrency, max_tokens, stream):
    tasks = []
    for i in range(concurrency):
        payload = {
            "model": model,
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": max_tokens,
        }
        if stream:
            tasks.append(send_streaming_full(session, url, i + 1, payload))
        else:
            tasks.append(send_request(session, url, i + 1, payload))
    results = await asyncio.gather(*tasks)

    durations = [r["duration"] for r in results if r["status"] == 200]
    tok_rates = [r["tok_s"] for r in results if r["status"] == 200]
    tok_counts = [r["tokens"] for r in results if r["status"] == 200]
    errors = sum(1 for r in results if r["status"] != 200)
    success = concurrency - errors
    total_tokens = sum(tok_counts)
    total_time = max(durations) if durations else 0

    return {
        "results": sorted(results, key=lambda x: x["idx"]),
        "durations": durations,
        "tok_rates": tok_rates,
        "tok_counts": tok_counts,
        "errors": errors,
        "success": success,
        "agg_req_s": success / total_time if total_time > 0 else 0,
        "agg_tok_s": total_tokens / total_time if total_time > 0 else 0,
    }


# ── Logging ───────────────────────────────────────────────────────────────────


def log_batch_header(f, config):
    f.write(f"\n{'━'*60}\n")
    f.write(
        f"ctx={config['context']}  input_frac={config['input_frac']}  "
        f"concurrency={config['concurrency']}  max_tokens={config['max_tokens']}  "
        f"stream={'on' if config['stream'] else 'off'}  repeat={config['repeat']}\n"
    )
    f.write(f"{'━'*60}\n")


def log_ttft(f, ttft_results, ttft_vals):
    f.write("\n─ TTFT (streaming) ─────────────────────────────────────\n")
    for r in ttft_results:
        s = (
            f"{r['ttft']:.2f}s"
            if r["ttft"] and r["status"] == 200
            else f"ERR({r.get('error') or r['status']})"
        )
        f.write(f"  #{r['idx']:>2}  TTFT = {s}\n")
    f.write(f"\n  TTFT: {fmt_pct(ttft_vals)}\n\n")


def log_throughput(f, throughput, stream):
    mode = "streaming" if stream else "non-streaming"
    f.write(f"─ Throughput ({mode}) ───────────────────────────\n")
    f.write(
        f"{'#':>2}  {'max_tok':>7}  {'duration':>8}  {'tokens':>6}  {'tok/s':>8}  {'status':>6}\n"
    )
    f.write("─" * 55 + "\n")
    for r in throughput["results"]:
        status_str = f"{r['status']}" if r["status"] == 200 else f"ERR({r['error']})"
        f.write(
            f"{r['idx']:>2}  {r['max_tokens']:>7}  {r['duration']:>8.1f}s  "
            f"{r['tokens']:>6}  {r['tok_s']:>8.1f}  {status_str:>6}\n"
        )


def log_summary(f, throughput, ttft_vals, budget):
    f.write(f"\n─ Summary ──────────────────────────────────────────────\n")
    total = throughput["success"] + throughput["errors"]
    f.write(
        f"  Success:  {throughput['success']}/{total}  "
        f"({100 * throughput['success'] / total:.0f}%)  |  {throughput['errors']} errors\n"
    )
    if throughput["durations"]:
        f.write(
            f"  Throughput:  {throughput['agg_req_s']:.1f} req/s  |  {throughput['agg_tok_s']:.0f} tok/s\n"
        )
        f.write(f"  Latency:     {fmt_pct(throughput['durations'])}\n")
        f.write(
            f"  Tokens/req:  min {min(throughput['tok_counts'])}  "
            f"p50 {percentile(throughput['tok_counts'], 50):.0f}  "
            f"p95 {percentile(throughput['tok_counts'], 95):.0f}  "
            f"max {max(throughput['tok_counts'])}\n"
        )
        f.write(
            f"  Tok/s:       min {min(throughput['tok_rates']):.1f}  "
            f"p50 {percentile(throughput['tok_rates'], 50):.1f}  "
            f"p95 {percentile(throughput['tok_rates'], 95):.1f}  "
            f"max {max(throughput['tok_rates']):.1f}\n"
        )
        if max(throughput["durations"]) > budget:
            f.write(f"  ⚠ Budget exceeded ({budget}s)\n")
    f.write("\n")


def log_jsonl(jsonl_path, config, ttft_results, throughput, round_num):
    ts = datetime.now().isoformat()
    with open(jsonl_path, "a") as f:
        for r in ttft_results:
            f.write(
                json.dumps(
                    {
                        "ts": ts,
                        "cfg": config,
                        "phase": "ttft",
                        "round": round_num,
                        "idx": r["idx"],
                        "ttft": r["ttft"],
                        "status": r["status"],
                        "error": r.get("error"),
                    }
                )
                + "\n"
            )
        for r in throughput["results"]:
            f.write(
                json.dumps(
                    {
                        "ts": ts,
                        "cfg": config,
                        "phase": "throughput",
                        "round": round_num,
                        "idx": r["idx"],
                        "max_tokens": r["max_tokens"],
                        "ttft": r.get("ttft"),
                        "duration": r["duration"],
                        "tokens": r["tokens"],
                        "tok_s": r["tok_s"],
                        "status": r["status"],
                        "error": r.get("error"),
                    }
                )
                + "\n"
            )


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


# ── Summaries ─────────────────────────────────────────────────────────────────


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
                "agg_tok_s": med("agg_tok_s"),
                "ttft_p50": med("ttft_p50"),
                "ttft_p95": med("ttft_p95"),
                "lat_p50": med("lat_p50"),
                "lat_p95": med("lat_p95"),
                "decode_p50": med("decode_p50"),
                "decode_p95": med("decode_p95"),
                "errors": sum(int(float(r["errors"])) for r in rs),
                "reps": len(rs),
            }
        )
    return sorted(out, key=lambda g: (-float(g["input_frac"]), -int(g["concurrency"]),
                                      -int(g["max_tokens"]), g["stream"] == "True"))


def _fmt_summary(groups, show_ctx=False):
    hdr_ctx = "ctx      " if show_ctx else ""
    lines = [
        f"{hdr_ctx}in_frac  c   mt     stream | agg_tok/s  ttft_p50  ttft_p95 | lat_p50  lat_p95 | dec_tok/s p50→p95",
        "-" * (105 if show_ctx else 98),
    ]
    for g in groups:
        ctx_cell = f"{g['context']:<9}" if show_ctx else ""
        err = f"  ⚠{g['errors']}err" if int(g["errors"]) else ""
        lines.append(
            f"{ctx_cell}{float(g['input_frac']):<8}"
            f"{int(g['concurrency']):<4}"
            f"{int(g['max_tokens']):<7}"
            f"{'on' if g['stream'] == 'True' else 'off':<7}| "
            f"{g['agg_tok_s']:>8.0f}  "
            f"{g['ttft_p50']:>8.1f}  {g['ttft_p95']:>8.1f} | "
            f"{g['lat_p50']:>7.1f}  {g['lat_p95']:>7.1f} | "
            f"{g['decode_p50']:>5.0f} → {g['decode_p95']:<5.0f}{err}"
        )
    return "\n".join(lines)


def _best_config_line(groups):
    best = max(groups, key=lambda g: g["agg_tok_s"])
    stream = "on" if best["stream"] == "True" else "off"
    return (
        f"  BEST: in_frac={best['input_frac']} c={best['concurrency']} "
        f"mt={best['max_tokens']} stream={stream} → "
        f"{best['agg_tok_s']:.0f} tok/s aggregate"
    )


def write_summaries(results_dir, csv_path):
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
        with open(results_dir / f"summary-ctx{ctx}.log", "w") as f:
            f.write(f"# Summary ctx={ctx} — {model}\n")
            f.write(f"# generated {datetime.now().strftime('%Y-%m-%d %H:%M')} · "
                    f"{n_batches} batches · {total_err} errors\n\n")
            f.write(_fmt_summary(ctx_groups) + "\n\n")
            f.write(_best_config_line(ctx_groups) + "\n")

    # All-contexts summary
    all_groups = _group_median(rows, key)
    with open(results_dir / "summary-all-contexts.log", "w") as f:
        f.write(f"# Summary — all contexts — {model}\n")
        f.write(f"# generated {datetime.now().strftime('%Y-%m-%d %H:%M')} · "
                f"{len(rows)} batches · {sum(int(float(r['errors'])) for r in rows)} errors\n\n")
        f.write(_fmt_summary(all_groups, show_ctx=True) + "\n")
        f.write("\nBest config per context:\n")
        for ctx in contexts:
            f.write(f"context {ctx}:\n")
            f.write(_best_config_line([g for g in all_groups if g["context"] == ctx]) + "\n")


# ── Main ──────────────────────────────────────────────────────────────────────





async def main():
    parser = argparse.ArgumentParser(
        description="Matrix sweep benchmark for deployed vLLM models"
    )
    parser.add_argument(
        "--url",
        default=os.environ.get("LLM_URL", DEFAULT_URL),
        help="vLLM chat completions endpoint",
    )
    parser.add_argument(
        "--budget", type=int, default=BUDGET_SECONDS, help="per-batch wall-clock budget (s)"
    )
    parser.add_argument(
        "--repeats", type=int, default=REPEATS, help="repeats per config (excl. warmup)"
    )
    parser.add_argument(
        "--contexts",
        default=None,
        help="comma-separated context lengths (default: 8192,32768,131072,262144)",
    )
    parser.add_argument(
        "--model", default=None, help="model name (default: prompt interactively)"
    )
    parser.add_argument("--dry-run", action="store_true", help="print matrix without executing")
    parser.add_argument("--force", action="store_true", help="overwrite existing results")
    args = parser.parse_args()

    # ── Resolve contexts ───────────────────────────────────────────────────
    if args.contexts:
        try:
            contexts = [int(c.strip()) for c in args.contexts.split(",")]
        except ValueError:
            print("ERROR: --contexts must be comma-separated integers.")
            sys.exit(1)
    else:
        contexts = CONTEXTS

    # ── 1. Model name ─────────────────────────────────────────────────────
    model_name = args.model
    if not model_name:
        model_name = input("Model name: ").strip()
    if not model_name:
        print("ERROR: model name required.")
        sys.exit(1)

    # ── 2. Results dir ────────────────────────────────────────────────────
    results_dir = get_results_dir(model_name)
    results_dir.mkdir(parents=True, exist_ok=True)
    print(f"\nResults dir: {results_dir}/")

    # ── 3. Context menu ───────────────────────────────────────────────────
    tested = get_tested_contexts(results_dir, contexts)
    print("\nSelect context to test:")
    for i, ctx in enumerate(contexts):
        mark = " ✓ tested (skip)" if ctx in tested else ""
        print(f"  [{i + 1}] {ctx}{mark}")

    choice = input("\n> ").strip()
    try:
        ctx_idx = int(choice) - 1
        context = contexts[ctx_idx]
    except (ValueError, IndexError):
        print("ERROR: invalid choice.")
        sys.exit(1)

    if context in tested and not args.force:
        print(f"Context {context} already tested. Skipping.")
        sys.exit(0)
    if context in tested and args.force:
        print(f"Context {context} already tested. Overwriting (--force).")
        log_path = results_dir / f"ctx{context}.log"
        jsonl_path = results_dir / f"ctx{context}.jsonl"
        for p in (log_path, jsonl_path):
            if p.exists():
                p.unlink()

    # ── 4. Sweep ──────────────────────────────────────────────────────────
    url = args.url
    max_tokens_list = MAX_TOKENS_BASE + (
        [MAX_TOKENS_LONG] if context in LONG_CONTEXTS else []
    )
    rounds = args.repeats + WARMUP
    total_batches = (
        len(INPUT_FRACS)
        * len(CONCURRENCY_LEVELS)
        * len(max_tokens_list)
        * len(STREAM_OPTIONS)
        * rounds
    )

    print(f"\nRunning sweep for ctx={context}")
    print(f"  max_tokens: {max_tokens_list}")
    print(f"  concurrency: {CONCURRENCY_LEVELS}")
    print(f"  stream: on, off")
    print(f"  {total_batches} batches  (budget: {args.budget}s each)\n")

    if args.dry_run:
        print("─ Dry run ───────────────────────────────────────────────")
        for input_frac in INPUT_FRACS:
            input_tokens = int(context * input_frac)
            for concurrency in CONCURRENCY_LEVELS:
                for max_tokens in max_tokens_list:
                    for stream in STREAM_OPTIONS:
                        for repeat in range(rounds):
                            print(
                                f"  ctx={context}  in={input_tokens}  c={concurrency:>2}  "
                                f"mt={max_tokens:>5}  stream={'on' if stream else 'off'}  "
                                f"rep {repeat + 1}/{args.repeats}"
                            )
        print(f"\nTotal: {total_batches} batches")
        return

    log_path = results_dir / f"ctx{context}.log"
    jsonl_path = results_dir / f"ctx{context}.jsonl"
    csv_path = results_dir / "index.csv"

    semaphore = asyncio.Semaphore(MAX_CONCURRENT_BATCHES)
    batch_num = 0

    async def run_batch(session, batch_num, input_frac, concurrency, max_tokens, stream, repeat):
        async with semaphore:
            input_tokens = int(context * input_frac)
            prompt = build_prompt(input_tokens)

            # Clamp so prompt + output + reasoning reserve fits in max-model-len
            effective_mt = min(max_tokens, context - input_tokens - REASONING_RESERVE)
            if effective_mt < MIN_EFFECTIVE_TOKENS:
                print(
                    f"  [{batch_num}/{total_batches}] "
                    f"c={concurrency:>2} mt={max_tokens:>5} "
                    f"stream={'on' if stream else 'off'}  rep {repeat + 1}/{args.repeats}  "
                    f"SKIP (in={input_tokens} leaves only {effective_mt} output tokens)"
                )
                return

            config = {
                "context": context,
                "input_frac": input_frac,
                "input_tokens": input_tokens,
                "concurrency": concurrency,
                "max_tokens": effective_mt,
                "stream": stream,
                "repeat": repeat,
            }

            ttft_results, ttft_vals = await run_ttft_probes(
                session, url, model_name, prompt, concurrency
            )

            throughput = await run_throughput_batch(
                session,
                url,
                model_name,
                prompt,
                concurrency,
                effective_mt,
                stream,
            )

            agg = throughput["agg_tok_s"]
            budget_ok = (
                throughput["durations"]
                and max(throughput["durations"]) <= args.budget
            )
            status = "ok" if budget_ok else f"⚠>{args.budget}s"
            ttft_p50 = percentile(ttft_vals, 50)

            print(
                f"  [{batch_num}/{total_batches}] "
                f"c={concurrency:>2} mt={max_tokens:>5} "
                f"stream={'on' if stream else 'off'}  rep {repeat + 1}/{args.repeats}  "
                f"ttft={ttft_p50:.1f}s  {agg:>5.0f} tok/s  {status}"
            )

            with open(log_path, "a") as f:
                log_batch_header(f, config)
                log_ttft(f, ttft_results, ttft_vals)
                log_throughput(f, throughput, stream)
                log_summary(f, throughput, ttft_vals, args.budget)
            log_jsonl(jsonl_path, config, ttft_results, throughput, repeat)
            append_index(csv_path, config, throughput, ttft_vals, args.budget)

    async with aiohttp.ClientSession(
        timeout=aiohttp.ClientTimeout(total=600),
        connector=aiohttp.TCPConnector(limit=max(CONCURRENCY_LEVELS) * MAX_CONCURRENT_BATCHES),
    ) as session:
        tasks = []
        for input_frac in INPUT_FRACS:
            for concurrency in CONCURRENCY_LEVELS:
                for max_tokens in max_tokens_list:
                    for stream in STREAM_OPTIONS:
                        for repeat in range(rounds):
                            batch_num += 1
                            tasks.append(
                                run_batch(
                                    session, batch_num, input_frac,
                                    concurrency, max_tokens, stream, repeat,
                                )
                            )
        await asyncio.gather(*tasks)

    write_summaries(results_dir, csv_path)

    print(f"\nDone. Results in {results_dir}/")


if __name__ == "__main__":
    asyncio.run(main())
