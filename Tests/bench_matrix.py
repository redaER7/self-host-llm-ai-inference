#!/usr/bin/env python3
"""bench_matrix.py — interactive matrix sweep for deployed vLLM models.

Usage:
    python3 Tests/bench_matrix.py --model casperhansen/deepseek-r1-distill-qwen-32b-awq --contexts 8192
    python3 Tests/bench_matrix.py --model ... --contexts 8192,32768 --force
    python3 Tests/bench_matrix.py --url https://llm.yacodata.com/v1/chat/completions --dry-run
"""

import asyncio, aiohttp, json, os, random, sys, time, csv, argparse
from datetime import datetime
from pathlib import Path
from urllib.parse import urlparse
from prompts import PROMPTS
from PostProcess import TTFT_TIERS, append_index, percentile, write_summaries

# ── Defaults ──────────────────────────────────────────────────────────────────

DEFAULT_URL = "https://llm.yacodata.com/v1/chat/completions"
CONTEXTS = [8192, 32768, 131072, 262144]
INPUT_FRACS = [0.1]
CONCURRENCY_LEVELS = [2,4,8,16]
MAX_TOKENS_BASE = [512, 2048]
MAX_TOKENS_LONG = 8192
LONG_CONTEXTS = [131072, 262144]
STREAM_OPTIONS = [True, False]
REPEATS = 2
WARMUP = 1
TTFT_PROBES = 5
BUDGET_SECONDS = 240
REASONING_RESERVE = 512   # headroom for <think> tokens counted against context
MIN_EFFECTIVE_TOKENS = 128

# ── Helpers ───────────────────────────────────────────────────────────────────




def fmt_pct(data):
    if not data:
        return "  —"
    return f"min {min(data):.1f}s  p50 {percentile(data, 50):.1f}s  p95 {percentile(data, 95):.1f}s  max {max(data):.1f}s"


def sanitize(name):
    return "".join(c if c.isalnum() or c in "-_" else "-" for c in name)


def build_prompt(target_tokens, seed=None):
    """Build a prompt of approximately target_tokens by repeating PROMPTS.

    With a seed, the PROMPTS pool is shuffled first so each seed yields a
    different block order (same length) — busts vLLM prefix-cache hits while
    keeping the token budget exact.
    """
    target_chars = target_tokens * 4
    parts = []
    total = 0
    i = 0
    if seed is not None:
        prompts = PROMPTS.copy()
        random.Random(seed).shuffle(prompts)
    else:
        prompts = PROMPTS
    while total < target_chars:
        parts.append(prompts[i % len(prompts)])
        total += len(parts[-1]) + 1
        i += 1
    return "\n".join(parts)[:target_chars]


def get_results_dir(model_name, url=None):
    date_str = datetime.now().strftime("%Y%m%d")
    host = urlparse(url).hostname if url else None
    host = host or "unknown"
    # host is filesystem-safe (hostname chars), keep dots for readability e.g. llm.yacodata.com
    return Path(__file__).resolve().parent / "results" / f"Test-{sanitize(model_name)}-{host}-{date_str}"


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
            elapsed = time.monotonic() - start
            try:
                body = await resp.json()
            except Exception:
                body = {}
            error = None
            if resp.status != 200:
                try:
                    err_text = json.dumps(body) if body else await resp.text()
                except Exception:
                    err_text = ""
                error = f"{resp.status}: {err_text[:500]}"
            usage = body.get("usage", {}) if isinstance(body, dict) else {}
            tokens = usage.get("completion_tokens", 0)
            return {
                "idx": idx,
                "max_tokens": payload["max_tokens"],
                "ttft": None,
                "duration": elapsed,
                "tokens": tokens,
                "tok_s": tokens / elapsed if elapsed > 0 and tokens else 0,
                "status": resp.status,
                "error": error,
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
            error = None
            if resp.status != 200:
                try:
                    err_text = await resp.text()
                except Exception:
                    err_text = ""
                error = f"{resp.status}: {err_text[:500]}"
            return {"idx": idx, "ttft": ttft, "status": resp.status, "error": error}
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
            error = None
            if resp.status != 200:
                try:
                    err_text = await resp.text()
                except Exception:
                    err_text = ""
                error = f"{resp.status}: {err_text[:500]}"
            return {
                "idx": idx,
                "max_tokens": payload["max_tokens"],
                "ttft": ttft,
                "duration": elapsed,
                "tokens": tokens,
                "tok_s": tokens / elapsed if elapsed > 0 and tokens else 0,
                "status": resp.status,
                "error": error,
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


async def run_ttft_probes(session, url, model, prompt_seed, concurrency, n_probes=5):
    tasks = []
    for i in range(min(concurrency, n_probes)):
        payload = {
            "model": model,
            "messages": [{"role": "user", "content": build_prompt(*prompt_seed(i))}],
            "max_tokens": random.randint(100, 1000),
        }
        tasks.append(send_streaming_ttft(session, url, i + 1, payload))
    results = await asyncio.gather(*tasks)
    ttft_vals = [r["ttft"] for r in results if r["ttft"] and r["status"] == 200]
    return results, ttft_vals


async def run_throughput_batch(session, url, model, prompt_seed, concurrency, max_tokens, stream):
    tasks = []
    for i in range(concurrency):
        payload = {
            "model": model,
            "messages": [{"role": "user", "content": build_prompt(*prompt_seed(i))}],
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
            else f"ERR({r['status']}: {r.get('error') or 'no body'})"
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
        status_str = f"{r['status']}" if r["status"] == 200 else f"ERR({r['status']}: {r.get('error') or 'no body'})"
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
    parser.add_argument(
        "--gpu", default="—", help='GPU label recorded in summary tables (e.g. "RTX 4090 Pro 48GB")'
    )
    parser.add_argument("--dry-run", action="store_true", help="print matrix without executing")
    parser.add_argument("--force", action="store_true", help="redo everything for the context (purges its results)")
    parser.add_argument(
        "--resume",
        action="store_true",
        help="continue an interrupted sweep: keep completed batches, run only the missing ones",
    )
    parser.add_argument(
        "--shared-prompt",
        action="store_true",
        help="use one identical prompt for every request (legacy; lets vLLM prefix cache dedupe prefill)",
    )
    parser.add_argument(
        "--api-key",
        default=None,
        help="Bearer token for third-party providers (or env LLM_API_KEY / TOKEN_HARBOR); added as Authorization: Bearer <key>",
    )
    args = parser.parse_args()
    # Resolve API key from env fallbacks (argparse normalizes --api-key and --api_key interchangeably)
    if not args.api_key:
        args.api_key = os.environ.get("LLM_API_KEY") or os.environ.get("TOKEN_HARBOR")

    if args.force and args.resume:
        print("ERROR: --force and --resume are mutually exclusive.")
        sys.exit(1)

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
    results_dir = get_results_dir(model_name, args.url)
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

    done_batches = set()
    if context in tested and not args.force and not args.resume:
        print(f"Context {context} already tested. Skipping (use --force to redo, --resume to continue).")
        sys.exit(0)
    if context in tested and args.force:
        print(f"Context {context} already tested. Overwriting (--force).")
        log_path = results_dir / f"ctx{context}.log"
        jsonl_path = results_dir / f"ctx{context}.jsonl"
        for p in (log_path, jsonl_path):
            if p.exists():
                p.unlink()
        # Purge this context's rows from index.csv so force is a true clean slate
        csv_path_force = results_dir / "index.csv"
        if csv_path_force.exists():
            with open(csv_path_force, newline="") as f:
                rows = list(csv.DictReader(f))
                fieldnames = rows[0].keys() if rows else []
            kept = [r for r in rows if int(r["context"]) != int(context)]
            tmp_path = csv_path_force.with_suffix(".tmp")
            with open(tmp_path, "w", newline="") as f:
                writer = csv.DictWriter(f, fieldnames=list(fieldnames))
                writer.writeheader()
                writer.writerows(kept)
            tmp_path.replace(csv_path_force)
    if args.resume and (results_dir / "index.csv").exists():
        with open(results_dir / "index.csv", newline="") as f:
            for r in csv.DictReader(f):
                if int(r["context"]) != int(context):
                    continue
                done_batches.add(
                    (
                        float(r["input_frac"]),
                        int(r["concurrency"]),
                        int(float(r["max_tokens"])),
                        r["stream"] == "True",
                        int(r["repeat"]),
                    )
                )

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
    print(f"  prompts: {'shared (cache-friendly)' if args.shared_prompt else 'randomized per request (cache-busting)'}")
    if args.api_key:
        src = "--api-key" if "--api-key" in sys.argv or "--api_key" in sys.argv else "env"
        print(f"  auth: bearer token from {src} (not logged)")
    if args.resume and done_batches:
        n_done = sum(
            1
            for input_frac in INPUT_FRACS
            for concurrency in CONCURRENCY_LEVELS
            for max_tokens in max_tokens_list
            for stream in STREAM_OPTIONS
            for repeat in range(rounds)
            if (float(input_frac), int(concurrency), int(min(max_tokens, int(context * input_frac) - REASONING_RESERVE)), bool(stream), int(repeat)) in done_batches
        )
        print(f"  resume: {n_done}/{total_batches} batches already completed — they will be skipped")
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
                                f"  ctx={context}  frac={input_frac}  in={input_tokens}  c={concurrency:>2}  "
                                f"mt={max_tokens:>5}  stream={'on' if stream else 'off'}  "
                                f"rep {repeat + 1}/{args.repeats}"
                            )
        print(f"\nTotal: {total_batches} batches")
        return

    log_path = results_dir / f"ctx{context}.log"
    jsonl_path = results_dir / f"ctx{context}.jsonl"
    csv_path = results_dir / "index.csv"

    batch_num = 0

    async def run_batch(session, batch_num, input_frac, concurrency, max_tokens, stream, repeat):
        input_tokens = int(context * input_frac)

        # Per-request prompt seeds: deterministic per (batch, repeat, phase, request)
        # so sweeps are reproducible. With --shared-prompt every request gets the
        # same unseeded prompt (legacy behavior — vLLM prefix cache will dedupe).
        if args.shared_prompt:
            def prompt_seed(i, phase="t"):
                return (input_tokens,)
        else:
            def prompt_seed(i, phase="t"):
                return (input_tokens, f"{batch_num}-{repeat}-{phase}-{i}")

        # Clamp so prompt + output + reasoning reserve fits in max-model-len
        effective_mt = min(max_tokens, context - input_tokens - REASONING_RESERVE)
        if effective_mt < MIN_EFFECTIVE_TOKENS:
            print(
                f"  [{batch_num}/{total_batches}] "
                f"frac={input_frac} c={concurrency:>2} mt={max_tokens:>5} "
                f"stream={'on' if stream else 'off'}  rep {repeat + 1}/{args.repeats}  "
                f"SKIP (in={input_tokens} leaves only {effective_mt} output tokens)"
            )
            return
        if args.resume and (
            float(input_frac),
            int(concurrency),
            int(effective_mt),
            bool(stream),
            int(repeat),
        ) in done_batches:
            print(
                f"  [{batch_num}/{total_batches}] "
                f"frac={input_frac} c={concurrency:>2} mt={max_tokens:>5} "
                f"stream={'on' if stream else 'off'}  rep {repeat + 1}/{args.repeats}  "
                "SKIP (already done)"
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
            session, url, model_name,
            lambda i: prompt_seed(i, phase="p"), concurrency
        )

        throughput = await run_throughput_batch(
            session,
            url,
            model_name,
            prompt_seed,
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
            f"frac={input_frac} c={concurrency:>2} mt={max_tokens:>5} "
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

    headers = {"Authorization": f"Bearer {args.api_key}"} if args.api_key else None
    async with aiohttp.ClientSession(
        timeout=aiohttp.ClientTimeout(total=600),
        connector=aiohttp.TCPConnector(limit=max(CONCURRENCY_LEVELS)),
        headers=headers,
    ) as session:
        for input_frac in INPUT_FRACS:
            for concurrency in CONCURRENCY_LEVELS:
                for max_tokens in max_tokens_list:
                    for stream in STREAM_OPTIONS:
                        for repeat in range(rounds):
                            batch_num += 1
                            await run_batch(
                                session, batch_num, input_frac,
                                concurrency, max_tokens, stream, repeat,
                            )

    write_summaries(results_dir, csv_path, gpu=args.gpu)

    print(f"\nDone. Results in {results_dir}/")


if __name__ == "__main__":
    asyncio.run(main())
