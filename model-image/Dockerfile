ARG BASE_IMAGE=vllm/vllm-openai:latest
FROM $BASE_IMAGE

ARG MODEL_NAME=Qwen/Qwen2.5-7B-Instruct
ENV MODEL_NAME=${MODEL_NAME}

# Install huggingface-hub
RUN pip install --no-cache-dir huggingface-hub

# Download the model using the secret token
RUN --mount=type=secret,id=hf_token \
    export HF_TOKEN=$(cat /run/secrets/hf_token) && \
    python3 -c "import os; from huggingface_hub import snapshot_download; snapshot_download(os.environ['MODEL_NAME'])"

# Set the model path for vLLM
ENV HF_HOME=/root/.cache/huggingface
ENV MODEL_PATH=/root/.cache/huggingface/hub/models--${MODEL_NAME//\//--}