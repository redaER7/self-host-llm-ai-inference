#!/usr/bin/env bash
set -euo pipefail

# Build and push the model image to the private registry.
# Run this on the GPU node (or any machine with Docker access).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Logging in to registry..."
echo "${REGISTRY_PASS}" | docker login docker-registry.yacodata.com \
  -u "${REGISTRY_USER}" --password-stdin

echo "Building model image..."
bash "${SCRIPT_DIR}/../model-image/build.sh" \
  --base vllm/vllm-openai:latest \
  --model Qwen/Qwen2.5-7B-Instruct \
  --tag docker-registry.yacodata.com/kserve-vllm-qwen:0.1

echo "Pushing to registry..."
docker push docker-registry.yacodata.com/kserve-vllm-qwen:0.1

echo "Done."
