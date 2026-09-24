# GPU Interview Lab — Qwen3-8B BF16 on RTX PRO 4000 Blackwell

Hands-on drills for this case (KServe + vLLM + Envoy AI Gateway).
Concepts companion: `Prepare_GPU/README.md` (interview prep).
Total: ~3h. GPU: Vast.ai RTX PRO 4000 Blackwell 24 GB, driver 580 / CUDA 13.

Model: **Qwen/Qwen3-8B**, dtype **bfloat16** (~16 GiB weights), vLLM **v0.30.0**
(CUDA 13.0 image, sm120 Blackwell support). Conservative start:
`--max-model-len 4096`, `--max-num-seqs 4`, `--gpu-memory-utilization 0.90`
→ ~20 GB of 24 GB. The KV-cache headroom is deliberate: practises 3–4 need it.

## Practise 0 — Attach the Vast.ai GPU node (40 min)

Driver 580 is already on the box (`nvidia-smi` confirmed). Still needed:

```bash
# 1. NVIDIA container toolkit (Debian/Ubuntu)
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker  # or containerd, matching k3s
sudo systemctl restart k3s-agent  # after k3s join, if runtime changed

# 2. Join K3s as GPU agent (get URL+token from Hetzner CP), then label/taint (on CP):
K3S_URL=https://<CP_PUBLIC_IP>:6443 K3S_TOKEN=<TOKEN> \
  curl -sfL https://get.k3s.io | sh -s - agent --flannel-iface wg0 --node-ip 10.10.0.2
kubectl label node <vast-node> node-role.kubernetes.io/gpu-node=true
kubectl taint node <vast-node> gpu-node=true:NoSchedule

# 3. WireGuard to Hetzner CP (see case_beta/README.md "WireGuard Setup"):
export CP_NODE_IP=<CP_PUBLIC_IP>
bash wireguard/gpu-wireguard-setup.sh

# 4. Verify scheduling + visibility:
kubectl describe node <vast-node> | grep -A2 Allocatable   # expect nvidia.com/gpu: 1
kubectl run -n beta gpu-smoke --rm -it --restart=Never --image=nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda12.5 \
  --overrides='{"spec":{"nodeSelector":{"node-role.kubernetes.io/gpu-node":"true"},"tolerations":[{"key":"gpu-node","operator":"Equal","value":"true","effect":"NoSchedule"}]}}' \
  -- nvidia-smi -L
kubectl -n monitoring get pods -l app.kubernetes.io/name=dcgm-exporter -o wide  # DCGM must land/schedule on the new node
```

**Say it in the interview:** "K3s agent joined with a `gpu-node` label and `NoSchedule` taint; the NVIDIA device plugin advertises `nvidia.com/gpu`; the workload tolerates the taint. Cross-node traffic rides Flannel VXLAN over WireGuard."

## Practise 1 — Apply the model swap, smoke-test (30 min)

Files already updated (Qwen2.5-32B-AWQ → Qwen3-8B BF16):

| File | Change |
|---|---|
| `kserve/llm-inference-service-config-model.yaml` | `uri`/`name` → `hf://Qwen/Qwen3-8B` |
| `kserve/llm-inference-service-config-workload.yaml` | image `vllm/vllm-openai:v0.30.0`, `--dtype bfloat16`, removed `--quantization awq`, ctx 4096, seqs 4 |
| `envoy-ai-gateway/aigatewayroute.yaml` | header match → `Qwen/Qwen3-8B` |
| `envoy-ai-gateway/rate-limit.yaml` | rate-limit header selector → `Qwen/Qwen3-8B` |
| `test.sh` | `MODEL=Qwen/Qwen3-8B` (also fixed the stale 14B) |
| `docker_build.sh` | baked-image `MODEL_NAME` + pinned base `v0.30.0` |
| `case_beta/README.md` | tables + diagram synced |

```bash
cd /Users/redaer/Documents/WORK/00_YACODATA/00_PROSPECTS/self-host-llm-ai-inference/case_beta
kubectl apply -f kserve/llm-inference-service-config-model.yaml
kubectl apply -f kserve/llm-inference-service-config-workload.yaml
kubectl apply -f kserve/llm-inferenceservice.yaml
kubectl apply -f envoy-ai-gateway/aigatewayroute.yaml
kubectl apply -f envoy-ai-gateway/rate-limit.yaml

# Watch the rollout; time the cold start (weights ~16 GB download on empty cache):
kubectl -n beta get llminferenceservice llm-server -w
kubectl -n beta logs -l app.kubernetes.io/name=llm-server -c main -f | grep -iE "loading|memory|error|ready|startup" | head -30

bash test.sh   # expect real answers on tests 1-4
```

**Checkpoints (fix before moving on):**
- Pod `OOMKilled` or vLLM "out of memory" at startup → lower `--gpu-memory-utilization` to `0.85`, re-apply.
- `the model ... is not supported on ... sm120` / missing-kernel errors → image tag is wrong for Blackwell; try the next `v0.30.x`/nightly cu130 tag.
- Tool-call errors in logs (`hermes` parser vs Qwen3 format) → drop `--enable-auto-tool-choice --tool-call-parser hermes` and re-apply; basic chat/completions is unaffected.
- 404/route errors through the gateway → header `x-ai-eg-model: Qwen/Qwen3-8B` must match `aigatewayroute.yaml` exactly.

## Practise 2 — Telemetry drill: bench matrix + Grafana (40 min)

Goal: read the *same* GPU moment across the stack — Grafana dashboards primary,
the existing `Tests/bench_matrix.py` as the load generator (TTFT probes +
throughput batches, streaming on/off, JSONL + `index.csv` + summaries in
`Tests/results/Test-Qwen-Qwen3-8B-<host>-<date>/`).

```bash
# From the repo root. MUST run with cwd=Tests/ (bench_matrix imports prompts/PostProcess):
cd /Users/redaer/Documents/WORK/00_YACODATA/00_PROSPECTS/self-host-llm-ai-inference/Tests
python3 bench_matrix.py --model Qwen/Qwen3-8B --contexts 4096 --gpu "RTX PRO 4000 Blackwell 24GB" --dry-run
# ^ sanity-check the matrix first; then the same command without --dry-run.
# Payload "model" must equal the deployed model (gateway ext-proc routes on it).
# For the saturation/backpressure story, widen CONCURRENCY_LEVELS in the script
# header (default [2]) — e.g. [1,2,4,8].

# Terminal B — nvidia-smi lens during the sweep (on the GPU node):
nvidia-smi dmon -s pucvmet -d 1 -f /tmp/dmon.log &
# Meanwhile in Grafana:
#   vLLM dashboard → TTFT, tokens/sec, request queue depth, KV cache %
#   DCGM dashboard → DCGM_FI_DEV_GPU_UTIL, _MEM_COPY_UTIL, _GPU_TEMP,
#     _SM_CLOCK, _MEM_CLOCK, _POWER_USAGE, _FB_USED, _CLOCK_THROTTLE_REASONS
# Afterwards: benchmark numbers live in the results dir (index.csv, summary-*.log) —
# quote TTFT p50/p95, agg_tok_s, decode p50/p95 straight from the summaries.
```

**What to find and say:** "As concurrency ramps, `tokens/sec` plateaus while `request queue depth` grows — that's backpressure, not degradation. SM clock dips correlated with temp spikes and `CLOCK_THROTTLE_REASONS=thermal` under sustained load are normal protection; the *same* dip at the *same* workload next month is the degradation signal. A rising ECC correctable rate (`DCGM_FI_DEV_ECC_*` / `nvidia-smi -q -d ECC`) is the leading memory-health indicator."

Kill the background `dmon` when done (`kill %1`).

**Stretch — raw NVML corroboration (5 min, JD "programmatic telemetry" story):**
```bash
# Re-run the sweep, sampling the driver directly via NVML in parallel:
python3 01_nvml_probe.py --interval 1 --duration 300 --out /tmp/nvml.csv
# Compare /tmp/nvml.csv (util, temp, SM/mem clocks, power, VRAM, throttle bitmask)
# against the DCGM panel for the same window — they must agree.
```
Interview line: "I cross-checked the exporter against raw NVML — same moment, driver-level numbers, no pipeline in between."

## Practise 3 — KV-cache experiment: context ladder (30 min)

Use the existing `Tests/deploy-context.sh` (patches `--max-model-len`, applies,
waits for rollout, polls `/v1/models`), then run one matrix rung per context:

```bash
cd /Users/redaer/Documents/WORK/00_YACODATA/00_PROSPECTS/self-host-llm-ai-inference
# Round A: ctx 8192 (fits: ~4.7 GiB KV at batch 4 + 16 GiB weights)
bash Tests/deploy-context.sh 8192 beta case_beta/kserve/llm-inference-service-config-workload.yaml
cd Tests && python3 bench_matrix.py --model Qwen/Qwen3-8B --contexts 8192 --gpu "RTX PRO 4000 Blackwell 24GB" && cd ..
# Round B: ctx 16384 — watch for KV pressure / scheduler refusal in the pod logs:
# kubectl -n beta logs -l app.kubernetes.io/name=llm-server -c main --tail=20 | grep -iE "kv cache|memory|error|available"
# Restore the baseline afterwards:
bash Tests/deploy-context.sh 4096 beta case_beta/kserve/llm-inference-service-config-workload.yaml
```

⚠️ Portability catch: `deploy-context.sh` uses `sed -i ''` (macOS syntax) — on the
Ubuntu GPU node that invocation fails; run it from your Mac (kubectl context
pointed at Hetzner CP) or drop the `''`. The script only *patches a copy* in
`/tmp` and applies it, so the committed manifest is never rewritten — re-apply
the file from Practise 1 if the live object ever drifts from git.

**Math to recite (Qwen3-8B GQA: 36 layers × 8 KV heads × 128 dim, BF16):**
~144 KiB per token of KV → 8192 ctx × 8 seqs ≈ 9.4 GiB KV + 16 GiB weights ≈ over budget → vLLM refuses or evicts. That refusal *is* the lesson: KV cache, not weights, is the capacity lever; `PagedAttention` (vLLM's block manager) raises throughput by packing that fixed budget.

Then compare prefix-cache behavior with the matrix's built-in switch: one run with
`--shared-prompt` (identical prompt every request — prefix-cache-friendly, optimistic
TTFT) vs default (per-request randomized prompts — cache-busting). Say: "prefix hits
skip prefill — TTFT drops on repeated system prompts; that's the EPP scorer's
cache-awareness when we scale to 2+ replicas."

## Practise 4 — Reproducibility mini-lab (30 min)

```bash
# Fixed seed + greedy decoding, same prompt 5× through the gateway:
bash 03_repeatability_check.sh https://llm.yacodata.com "Qwen/Qwen3-8B" \
  "Explain thermal throttling in one sentence." 5
# Expect: identical (or near-identical) outputs.
```

**Say it in the interview:** "Greedy + fixed `--seed` gives *statistical* reproducibility for this serving path. *Bitwise* run-to-run needs the training-side controls — `torch.use_deterministic_algorithms(True)`, `CUBLAS_WORKSPACE_CONFIG=:4096:8`, deterministic NCCL, pinned image/driver/CUDA/toolkit, fixed seeds — and even then vLLM's continuous batching (batch composition changes arrival-order) plus tensor-parallel reduction order can break bitwise equality. First question back to the team: do you need bitwise or statistical? Without *that*, you can't attribute a tokens/sec drop to hardware vs software jitter."

## Stretch — BF16 vs FP8 A/B (if time remains)

```bash
# Swap model config to hf://Qwen/Qwen3-8B-FP8, workload --model Qwen/Qwen3-8B-FP8,
# re-add "--quantization" "fp8", gateway header + test.sh to match, re-apply.
# Re-run practises 2 (TTFT, tok/s, VRAM) and compare against the BF16 numbers.
```

Expected story: weights ~16 → ~8 GiB, KV headroom doubles, decode (bandwidth-bound) gets faster; prefill barely moves. That is the Blackwell-native quantization answer.

## Scorecard (fill in live)

| Metric (BF16) | Value |
|---|---|
| Cold start (empty cache) | |
| VRAM used @ idle (`FB_USED`) | |
| TTFT, 1 req | |
| tokens/sec, 1 req / saturated | |
| Max ctx×seqs that schedules | |
| 5× repeat identical? (y/n) | |
| NVML CSV matches DCGM panel? (y/n, stretch) | |

| Metric (FP8, stretch) | Value |
|---|---|
| VRAM used @ idle | |
| TTFT, 1 req | |
| tokens/sec saturated | |
