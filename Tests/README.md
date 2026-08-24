# Tests

Benchmarks for vLLM inference endpoints — single-request, concurrent load, and matrix sweeps.

## Scripts

| Script | Purpose |
|---|---|
| `bench_concurrent.py` | Concurrent load test (single config). 5 streaming TTFT probes + N non-streaming throughput requests. |
| `bench_matrix.py` | Interactive matrix sweep. Prompts for model + context, sweeps all param combos, logs results. |
| `case_gamma_concurrent.py` | Dual-model concurrent test (7B + 14B via MIG). |
| `hetzner_bench_concurrent.py` | Concurrent test for Hetzner experimental inference API. |
| `deploy-context.sh` | Helper: patch vLLM manifest + restart + wait for readiness. |
| `prompts.py` | Shared prompt banks (`MATH_PROMPTS`, `CODE_PROMPTS`, `PROMPTS`). |

## bench_matrix.py — parameter sweep

### Flow

```
Model name → Results dir → Context pick → Sweep → Log
```

Results stored in `Tests/results/Test-{MODEL}-{YYYYMMDD}/`:
- `ctx{N}.log` — human-readable tables per context
- `ctx{N}.jsonl` — per-request records (plot-ready)
- `index.csv` — append-only summary (one row per batch)
- `summary-ctx{N}.log` — per-context rollup: median across repeats per config group, TTFT p50/p95, best config + campaign table
- `summary-all-contexts.log` — cross-context comparison (regenerated from index.csv after each sweep) + campaign table with best config per context

**Best-config selection**: within each context, configs are filtered by the tightest TTFT-p50 tier that has candidates (`TTFT_TIERS = [1, 2, 5, 8, 10, 20, 50, 100]` seconds); the highest-throughput config within that pool wins. The achieved class is shown as a `TTFT Class` column / `(TTFT <Ns)` tag. If nothing lands under 100 s, falls back to plain highest throughput, annotated as fallback.

### Parameters varied

Each parameter below is defined, with the mechanism it exercises and how to read its results. Current values live in the `bench_matrix.py` header (`CONTEXTS`, `INPUT_FRACS`, `CONCURRENCY_LEVELS`, `MAX_TOKENS_BASE`, `REPEATS`, …) — they are tuned per campaign and intentionally not duplicated here.

| Parameter | Definition | Mechanism / what it stresses | How to read results |
|---|---|---|---|
| **Context** (`--max-model-len`) | Upper bound on prompt + output tokens per request, set at vLLM startup via `--max-model-len` (per-model ladder passed with `--contexts`) | vLLM pre-allocates the KV-cache pool from this value — larger contexts reserve more VRAM upfront and change what concurrency is affordable; changing it requires a vLLM restart (`deploy-context.sh`) | Compare contexts on aggregate tok/s and TTFT growth: TTFT should rise roughly linearly with prefill length; throughput collapse at high context signals KV pressure |
| **Input fraction** (e.g. 0.5, 0.8) | Prompt size as a fraction of context: `input_tokens = context × frac` | Exercises prefill compute and KV occupancy — 0.8 fills the cache heavily and leaves little output headroom (interacts with the max_tokens clamp) | At same concurrency, higher fraction should show longer TTFT (prefill-bound); if latency degrades super-linearly, KV eviction/prefix-cache misses are at play |
| **Concurrency** (levels list in script) | Number of simultaneous in-flight requests per batch | Stresses vLLM's continuous-batching scheduler: request admission, batch composition, KV allocation across sequences | Healthy scaling = aggregate tok/s rises with concurrency while per-request decode stays flat; TTFT inflation under load = queueing; errors/timeouts = saturation ceiling |
| **Max tokens** (output cap) | Maximum tokens generated per request (`max_tokens` in the API payload) | Measures sustained decode speed over long generations; note: generation stops early at EOS — self-hosted vLLM has no forced minimum, so token counts may fall short of the cap | Per-request decode tok/s (p50→p95 spread) shows stream consistency; wide p50↔p95 gaps mean some requests were starved by scheduler contention |
| **Streaming** (on / off) | `stream: true` consumes an SSE stream chunk-by-chunk; `stream: false` waits for the full response body | on ≈ real interactive client behavior (TTFT measurable); off isolates pure end-to-end completion time without client-side streaming overhead | Streaming vs non-streaming deltas expose gateway buffering effects; large off-vs-on latency gap points to proxy/response buffering |
| **Repeats** (no warmup) | Each config group runs N times; summaries report the **median across repeats** | Averages out transient noise (network jitter, background pods); no warmup run — first-touch cold paths show up in rep 1 | If medians are stable across reps, trust p95s too; if reps diverge wildly, the endpoint was contended during the sweep |

**Clamping rule**: before sending, `effective_max_tokens = min(max_tokens, context − input_tokens − REASONING_RESERVE)` (reserve defaults to 512 for reasoning models whose `<think>` tokens count against context). Configs that would leave fewer than `MIN_EFFECTIVE_TOKENS` (128) output tokens are skipped entirely rather than sent (avoids guaranteed HTTP 400s).

### Execution model

Batches run **concurrently** — up to `MAX_CONCURRENT_BATCHES` batches at once via an asyncio semaphore. Within each batch, requests fire simultaneously (its configured concurrency level), preceded by streaming TTFT probes.

⚠ Because batches overlap, measurements reflect *mixed* load when the server is shared: a c=2 batch running next to a c=8 batch sees more than 2 concurrent requests. Treat absolute numbers as campaign-level, not lab-isolated.

### Batch budget

Each batch has a wall-clock budget (default 240 s, `--budget`). Exceeding it logs `budget_exceeded=yes` in `index.csv` but does not abort the sweep.

### Metrics glossary

| Metric | Meaning |
|---|---|
| `agg_req_s` | Successful requests ÷ wall-clock of the slowest request in the batch — request-level throughput |
| `agg_tok_s` | Total completion tokens ÷ wall-clock of the slowest request — **aggregate** throughput ("how much work per second") |
| `ttft_p50 / ttft_p95` | Time to first streamed token, percentile across TTFT probes — prefill + queueing latency as users experience it |
| `lat_p50 / lat_p95` | Full request duration percentiles — end-to-end response time |
| `decode_p50 / decode_p95` | **Per-request** generation speed (completion tokens ÷ duration), ranked across requests — "how fast one user's stream flows"; p50≈p95 = consistent streams, big gap = starved requests |
| `budget_exceeded` | Batch's longest request exceeded the wall-clock budget |

Rule of thumb: use `agg_tok_s` for capacity planning, `ttft_p50/p95` for UX, `decode_p50/p95` for stream quality.

### CLI flags

```
--url URL            vLLM endpoint (default: env LLM_URL or https://llm.yacodata.com/v1/chat/completions)
--model NAME         model name sent in payloads + results dir naming (prompts interactively if omitted)
--gpu LABEL          GPU label recorded in summary campaign tables (e.g. "RTX 4090 Pro 48GB")
--contexts LIST      comma-separated context lengths (default ladder in script; per-model override)
--budget SECONDS     per-batch budget (default: 240)
--repeats N          repeats per config (default in script)
--dry-run            print full matrix without executing
--force              delete existing ctx{N}.log/.jsonl for the chosen context and rerun
```

## deploy-context.sh

Patches the vLLM workload manifest with a new `--max-model-len`, applies it, waits for rollout, polls `/v1/models` until ready.

```bash
bash Tests/deploy-context.sh <max-model-len> [namespace] [manifest]

# Examples
bash Tests/deploy-context.sh 8192
bash Tests/deploy-context.sh 32768 beta
bash Tests/deploy-context.sh 131072 beta case_beta/kserve/llm-inference-service-config-workload.yaml
```

## prompts.py

Shared prompt banks used by all bench scripts (67 prompts total):

| List | Count | Domain |
|---|---|---|
| `MATH_PROMPTS` | 20 | Fourier analysis, PDEs, linear algebra, mechanics |
| `CODE_PROMPTS` | 9 | Python algorithms, systems design, ML, creative writing |
| `BIOCHEM_PROMPTS` | 4 | Enzyme kinetics, CRISPR, electrochemistry, population genetics |
| `LAW_PROMPTS` | 3 | Contract law, trade secrets, EU consumer protection |
| `FINANCE_PROMPTS` | 4 | Black-Scholes, CAPM, valuation multiples, Phillips curve |
| `MEDICINE_PROMPTS` | 3 | Cardiology, psychopharmacology, anticoagulation reversal |
| `HISTORY_PROMPTS` | 3 | Revolutions, Thucydides Trap, Weimar Republic |
| `PHILOSOPHY_PROMPTS` | 2 | Trolley problem, Ship of Theseus |
| `STATS_PROMPTS` | 4 | MLE, bias-variance, A/B testing, ROC curves |
| `DEVOPS_PROMPTS` | 4 | K8s, Docker, CAP theorem, CI/CD pipelines |
| `LINGUISTICS_PROMPTS` | 2 | Language typology, translation |
| `ENGINEERING_PROMPTS` | 1 | Structural systems, seismic design |
| `FACTUAL_PROMPTS` | 8 | Short factual (1-10 token answers) — tests low end of tok/s curve |
| `PROMPTS` | 67 | Combined superset |
