#!/bin/bash

export DOCKER_BUILDKIT=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY=docker-registry.yacodata.com
REPOSITORY=kserve-vllm-qwen
TAG=0.11

echo "Logging in to registry..."
echo "${REGISTRY_PASS}" | docker login docker-registry.yacodata.com \
    -u "${REGISTRY_USER}" --password-stdin

echo "Building model image..."
docker build \
    --build-arg BASE_IMAGE=vllm/vllm-openai:latest \
    --build-arg MODEL_NAME=Qwen/Qwen2.5-7B-Instruct \
    --build-arg HF_TOKEN="${HF_TOKEN}" \
    -t ${REGISTRY}/${REPOSITORY}:${TAG} \
    -f "${SCRIPT_DIR}/../model-image/Dockerfile" \
    "${SCRIPT_DIR}/.."

if [ $? -ne 0 ]; then
    echo "Build failed!"
    exit 1
fi

echo "Pushing to registry..."
docker tag ${REGISTRY}/${REPOSITORY}:${TAG} ${REGISTRY}/${REPOSITORY}:latest
docker push ${REGISTRY}/${REPOSITORY}:${TAG}
docker push ${REGISTRY}/${REPOSITORY}:latest

echo "Done."
echo "Token: ${HF_TOKEN:0:10}..." # Show only first 10 chars for security