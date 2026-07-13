# EPP Scheduler Configuration
#
# Integrated into LLMInferenceServiceConfig as the scheduler spec.
# See: ../kserve/llm-inferenceservice-config.yaml
#
# Scorer weights for the endpoint picker:
#   prefix-cache-scorer:  2.0  — routes to pods with matching KV cache blocks
#   load-aware-scorer:    1.0  — routes to pods with shortest queue
#   picker policy: max-score  — selects the pod with the highest combined score
#
# This file is a reference only — the actual config is embedded in the
# LLMInferenceServiceConfig CRD:
#   case_beta/kserve/llm-inferenceservice-config.yaml
