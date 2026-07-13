# Model Images for Case γ (gamma)

Uses the shared [model-image/build.sh](../../model-image/build.sh) to bake two model images.

## Qwen 2.5 7B (MIG 1g.10gb)

```bash
bash ../../model-image/build.sh \
  --base quay.io/kserve/vllm:latest \
  --model Qwen/Qwen2.5-7B-Instruct-AWQ \
  --tag qwen-with-weights:latest
```

## Llama 3 70B (MIG 3g.40gb)

```bash
bash ../../model-image/build.sh \
  --base quay.io/kserve/vllm:latest \
  --model meta-llama/Llama-3-70B-Instruct-AWQ \
  --tag llama-with-weights:latest
```

> **Note**: Llama 3 70B is gated — you need a Hugging Face token to download. Pass it at build time:
> ```bash
> docker build --build-arg HF_TOKEN=<token> ...
> ```
