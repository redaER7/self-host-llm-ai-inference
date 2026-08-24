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

### Parameters

#### Context (`--max-model-len`, restart required)

vLLM pre-allocates KV cache at startup from `--max-model-len`. Changing it requires a vLLM restart. Default ladder (RTX 4090 Pro 48GB):

| Context | Input tokens (50%) | Input tokens (80%) |
|---|---|---|
| 8 192 | 4 096 | 6 554 |
| 32 768 | 16 384 | 26 214 |
| 131 072 | 65 536 | 104 858 |
| 262 144 | 131 072 | 209 715 |

Override with `--contexts` per model (see CLI flags).

#### Input fraction

Fraction of `--max-model-len` used as prompt size per request. Two levels per context: 0.5 and 0.8. Exercises the KV cache at different occupancy levels without restart.

#### Concurrency

Number of simultaneous requests per batch. Measures how vLLM schedules under load.

| Values | Notes |
|---|---|
| 1, 4, 8, 12, 16, 24, 30 | Higher values stress scheduler + KV allocation |

#### Max tokens (output)

Maximum tokens generated per request. `min_tokens = max_tokens` forces sustained decode.

| Context < 131k | Context ≥ 131k |
|---|---|
| 512, 2048 | 512, 2048, **8192** |

8192 gated to large contexts — measures sustained decode in the regime that matters (long context + long output).

#### Streaming

| Value | What it measures |
|---|---|
| on | Full SSE stream consumed — TTFT + total duration + tokens |
| off | Non-streaming — total duration + tokens only |

TTFT probes are always streaming (measures time to first token).

#### Repeats

3 reps per config. No warmup.

### Batch budget

Each batch (concurrent group) has a wall-clock budget (default 240s). Exceeding it logs a warning in `index.csv` as `budget_exceeded=yes` but does not abort the sweep.

### CLI flags

```
--url URL            vLLM endpoint (default: env LLM_URL or https://llm.yacodata.com/v1/chat/completions)
--contexts LIST      comma-separated context lengths (default: 8192,32768,131072,262144)
                     per-model ladders:
                       Qwen3.6-27B:      8192,32768,65536,131072
                       Gemma 4 31B:      8192,32768,131072,262144
                       R1-Distill-32B:   8192,32768,65536
--budget SECONDS     per-batch budget (default: 240)
--repeats N          repeats per config (default: 3)
--dry-run            print full matrix without executing
```

Batches run concurrently — up to 10 at a time (configurable via `MAX_CONCURRENT_BATCHES` constant).

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
