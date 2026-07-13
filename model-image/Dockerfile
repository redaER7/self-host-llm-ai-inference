ARG BASE_IMAGE=vllm/vllm-openai:latest
FROM $BASE_IMAGE

ARG MODEL_NAME=deepseek-ai/DeepSeek-Coder-33B-Instruct-AWQ

RUN pip install --no-cache-dir huggingface-hub

RUN python3 -c "
from huggingface_hub import snapshot_download
snapshot_download('$MODEL_NAME')
"
