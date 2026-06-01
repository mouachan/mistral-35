# Mistral Medium 3.5 128B on OpenShift AI

Helm chart for deploying [Mistral Medium 3.5 128B](https://huggingface.co/mistralai/Mistral-Medium-3.5-128B) on Red Hat OpenShift AI (RHOAI 3.4+) using vLLM as the inference engine.

This chart packages all the Kubernetes resources needed to download, serve, and observe the model end-to-end. It is designed for GitOps workflows (ArgoCD / OpenShift GitOps).

## Architecture Overview

```
+---------------------+      +---------------------+      +-------------------+
|  HuggingFace Hub    | ---> |  Download Job        | ---> |  PVC (300 Gi)     |
|  (gated model)      |      |  (huggingface-cli)   |      |  Model weights    |
+---------------------+      +---------------------+      +--------+----------+
                                                                    |
                              +---------------------+               |
                              |  ServingRuntime      |               |
                              |  (vLLM + custom log) | <-------------+
                              +--------+------------+
                                       |
                              +--------v------------+
                              |  InferenceService    |
                              |  OpenAI-compatible   |
                              |  /v1/chat/completions|
                              +---------------------+
```

## What Gets Deployed

| Resource | Template | Description |
|----------|----------|-------------|
| **Secret** | `secret-hf-token.yaml` | HuggingFace access token for downloading the gated model |
| **PersistentVolumeClaim** | `pvc.yaml` | Storage for model weights (~256 GB for BF16) |
| **Job** | `job-download.yaml` | One-shot job that downloads model weights from HuggingFace to the PVC |
| **HardwareProfile** | `hardwareprofile.yaml` | RHOAI resource profile visible in the OpenShift AI dashboard |
| **ConfigMap** | `configmap-logging.yaml` | vLLM logging configuration (JSON formatter for EFK/Kibana) |
| **ServingRuntime** | `servingruntime.yaml` | KServe ServingRuntime with vLLM, custom args, and logging |
| **InferenceService** | `inferenceservice.yaml` | KServe InferenceService exposing the model as an OpenAI-compatible API |

## Prerequisites

- OpenShift 4.x cluster with RHOAI 3.4+ operator installed
- NVIDIA GPU operator installed and configured
- GPU nodes available (see [GPU Requirements](#gpu-requirements))
- A HuggingFace account with access granted to [mistralai/Mistral-Medium-3.5-128B](https://huggingface.co/mistralai/Mistral-Medium-3.5-128B) (gated model, requires license acceptance)
- A HuggingFace [User Access Token](https://huggingface.co/settings/tokens)
- Helm 3.x

## GPU Requirements

Mistral Medium 3.5 is a **128B parameter dense multimodal model** (text + vision). It includes a vision encoder trained from scratch. The full model weights are available in BF16 and FP8 formats.

| Precision | Model Size | Minimum Hardware | Example Instance |
|-----------|-----------|-----------------|-----------------|
| **BF16** | ~256 GB | 4x A100 80GB or 8x A100 40GB | AWS `p4d.24xlarge` (8x A100 40GB) |
| **FP8** | ~128 GB | 2x A100 80GB or 4x A100 40GB | AWS `p4d.24xlarge` (8x A100 40GB) |

The default configuration targets **8x NVIDIA A100 40GB** (AWS `p4d.24xlarge`):
- 96 vCPU, 1152 GiB RAM, 8x A100 40GB (320 GB total VRAM)
- `tensor-parallel-size=8` distributes the model across all 8 GPUs
- `gpu-memory-utilization=0.90` reserves 10% headroom for CUDA overhead

## Quick Start

```bash
# Create the namespace
oc new-project mistral35

# Install the chart
helm install mistral-medium . \
  --namespace mistral35 \
  --set secret.hfToken=<your-hf-token> \
  --wait=false
```

> **Note:** `--wait=false` is important because the download job takes 30-60 minutes to complete. The predictor pod will restart (CrashLoopBackOff) until the model weights are fully downloaded to the PVC.

## Configuration Reference

### Model

| Parameter | Default | Description |
|-----------|---------|-------------|
| `model.name` | `mistral-medium-3-5-128b` | Model identifier used in served model name |
| `model.displayName` | `Mistral-Medium-3.5-128B` | Human-readable name for RHOAI dashboard |
| `model.huggingfaceRepo` | `mistralai/Mistral-Medium-3.5-128B` | HuggingFace repository to download from |
| `model.localDir` | `Mistral-Medium-3.5-128B` | Directory name inside the PVC |

### Storage

| Parameter | Default | Description |
|-----------|---------|-------------|
| `storage.pvc.name` | `mistral-medium-3-5-pvc` | PVC name for model weights |
| `storage.pvc.size` | `300Gi` | PVC size (must be > 2x model size for download temp files) |
| `storage.pvc.storageClass` | `gp3-csi` | Kubernetes StorageClass |
| `storage.pvc.accessMode` | `ReadWriteOnce` | PVC access mode |

### Download Job

| Parameter | Default | Description |
|-----------|---------|-------------|
| `download.enabled` | `true` | Enable/disable the model download job |
| `download.image` | `registry.access.redhat.com/ubi9/python-311:latest` | Container image for the download job |

### HuggingFace Secret

| Parameter | Default | Description |
|-----------|---------|-------------|
| `secret.hfToken` | `REPLACE_WITH_YOUR_HF_TOKEN` | HuggingFace access token. **Pass via `--set` at install time, never commit real tokens.** |

### Hardware Profile

| Parameter | Default | Description |
|-----------|---------|-------------|
| `hardwareProfile.name` | `nvidia-a100-8gpu` | Profile name in RHOAI dashboard |
| `hardwareProfile.gpu.count` | `8` | Default GPU count |
| `hardwareProfile.cpu.count` | `90` | Default CPU allocation |
| `hardwareProfile.memory.count` | `1100Gi` | Default memory allocation |

### vLLM Inference Arguments

| Parameter | Default | Description |
|-----------|---------|-------------|
| `inference.vllm.tensorParallelSize` | `8` | Number of GPUs for tensor parallelism |
| `inference.vllm.maxModelLen` | `32768` | Maximum sequence length (model supports up to 256k) |
| `inference.vllm.gpuMemoryUtilization` | `0.90` | Fraction of GPU memory allocated to model + KV cache |
| `inference.vllm.enforceEager` | `false` | Disable CUDA graphs (saves memory, slower inference) |
| `inference.vllm.enablePrefixCaching` | `true` | Enable KV cache prefix sharing across requests |
| `inference.vllm.dtype` | `auto` | Model data type (auto-detected from weights) |
| `inference.vllm.enableAutoToolChoice` | `true` | Enable native function/tool calling |
| `inference.vllm.toolCallParser` | `mistral` | Tool call parser (use `mistral` for Mistral models) |
| `inference.vllm.maxNumBatchedTokens` | `16384` | Maximum tokens processed in a single batch |

### Deployment Strategy

| Parameter | Default | Description |
|-----------|---------|-------------|
| `inference.strategy` | `RollingUpdate` | `RollingUpdate` or `Recreate` |

```bash
# Rolling update (default) - requires 2x GPU capacity during rollout
helm install mistral-medium . --set inference.strategy=RollingUpdate

# Recreate - zero downtime not guaranteed, but no extra GPU needed
helm install mistral-medium . --set inference.strategy=Recreate
```

### Runtime Selection

The chart supports two vLLM runtimes:

```bash
# Red Hat certified vLLM runtime (default)
helm install mistral-medium . --set servingRuntime.useRedHatRuntime=true

# Custom vLLM image (e.g., with additional Python packages for logging)
helm install mistral-medium . \
  --set servingRuntime.useRedHatRuntime=false \
  --set servingRuntime.custom.image=quay.io/your-org/vllm-custom:latest
```

Use a custom runtime when you need:
- Additional Python packages (e.g., `python-json-logger` for JSON log formatting)
- Custom middleware or request preprocessing
- Patched vLLM version

## Custom Logging

vLLM logging is fully configurable via a JSON configuration file mounted as a ConfigMap. This enables structured logging for ingestion into **Kibana / EFK / OpenShift Logging**.

### How It Works

1. The `configmap-logging.yaml` template renders the `logging.config` values into a `logging_config.json` file
2. The ConfigMap is mounted at `/etc/vllm/logging_config.json` inside the vLLM container
3. The environment variable `VLLM_LOGGING_CONFIG_PATH` points vLLM to this config file
4. vLLM uses Python's `logging.config.dictConfig()` to apply the configuration at startup

### Default Configuration (JSON format)

```json
{
  "version": 1,
  "formatters": {
    "json": {
      "class": "pythonjsonlogger.jsonlogger.JsonFormatter",
      "format": "%(asctime)s %(name)s %(levelname)s %(message)s %(pathname)s %(lineno)d"
    }
  },
  "handlers": {
    "console": {
      "class": "logging.StreamHandler",
      "formatter": "json",
      "level": "INFO",
      "stream": "ext://sys.stdout"
    }
  },
  "loggers": {
    "vllm": {
      "handlers": ["console"],
      "level": "INFO",
      "propagate": false
    }
  }
}
```

### Customizing Log Format

Override the logging config in your `values.yaml` or via `--set`:

```bash
# Change log level to DEBUG
helm install mistral-medium . --set logging.config.loggers.vllm.level=DEBUG

# Disable custom logging entirely (use vLLM defaults)
helm install mistral-medium . --set logging.enabled=false
```

To use the **plain text** formatter instead of JSON:

```yaml
logging:
  config:
    handlers:
      console:
        formatter: plain  # instead of "json"
```

### Access Log Filtering

Health check and metrics endpoints are excluded from access logs by default to reduce noise:

```
/health, /metrics, /ping
```

This is controlled by `logging.disableAccessLogEndpoints`.

### Important: python-json-logger Dependency

The JSON formatter (`pythonjsonlogger.jsonlogger.JsonFormatter`) requires the `python-json-logger` package. If it is **not pre-installed** in the vLLM image:

- The Red Hat vLLM image may not include it. In that case, vLLM will fall back to the default formatter or crash.
- **Solution**: Either build a custom vLLM image with the package, or switch to the `plain` formatter which has no extra dependencies.

```dockerfile
# Example custom vLLM Dockerfile
FROM registry.redhat.io/rhaii/vllm-cuda-rhel9@sha256:ad06abf3bb...
RUN pip install --no-cache-dir python-json-logger
```

Then deploy with:
```bash
helm install mistral-medium . \
  --set servingRuntime.useRedHatRuntime=false \
  --set servingRuntime.custom.image=quay.io/your-org/vllm-custom:latest
```

## GitOps Usage

This chart is designed for ArgoCD / OpenShift GitOps. Create per-environment values files:

```
values.yaml              # Defaults
values-dev.yaml          # Dev overrides (smaller model len, fewer GPUs)
values-staging.yaml      # Staging
values-prod.yaml         # Production (full config)
```

Example ArgoCD Application:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: mistral-medium
  namespace: openshift-gitops
spec:
  project: default
  source:
    repoURL: https://github.com/mouachan/mistral-35
    targetRevision: main
    helm:
      valueFiles:
        - values-prod.yaml
      parameters:
        - name: secret.hfToken
          value: $HF_TOKEN  # injected from ArgoCD secret
  destination:
    server: https://kubernetes.default.svc
    namespace: mistral35
```

## Testing the Deployment

Once the download job completes and the predictor pod is `Running` and `Ready`:

```bash
# Port-forward to the inference service
oc port-forward svc/mistral-medium-3-5-128b-predictor 8000:80 -n mistral35

# Send a chat completion request
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "mistral-medium-3-5-128b",
    "messages": [{"role": "user", "content": "Hello, who are you?"}],
    "max_tokens": 100
  }'
```

## Validated Test Results

The following tests were run against the deployed model on an 8x A100 40GB cluster (p4d.24xlarge) with `tensor-parallel-size=8` and `max-model-len=32768`.

### Test 1 — General Knowledge

```bash
curl -s http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "mistral-medium-3-5-128b",
    "messages": [{"role": "user", "content": "Explain quantum computing in 2 sentences."}],
    "max_tokens": 100
  }'
```

**Result:** Coherent 2-sentence explanation covering qubits, superposition, and entanglement. 78 completion tokens.

### Test 2 — Code Generation

```bash
curl -s http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "mistral-medium-3-5-128b",
    "messages": [{"role": "user", "content": "Write a Python function that checks if a number is prime. Include examples."}],
    "max_tokens": 500
  }'
```

**Result:** Complete `is_prime()` function with edge-case handling and usage examples. 200 completion tokens.

### Test 3 — Structured JSON Output

```bash
curl -s http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "mistral-medium-3-5-128b",
    "messages": [
      {"role": "system", "content": "You are a helpful assistant that responds in JSON format."},
      {"role": "user", "content": "List the 3 largest countries by area with their capital and population."}
    ],
    "max_tokens": 300
  }'
```

**Result:** Well-formed JSON array with Russia, Canada, and China including area (km2), capital, and population. 203 completion tokens.

### Test 4 — Translation

```bash
curl -s http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "mistral-medium-3-5-128b",
    "messages": [{"role": "user", "content": "Translate to Japanese: The weather is beautiful today."}],
    "max_tokens": 100
  }'
```

**Result:** Correct translation with romanization. 27 completion tokens.

### Test 5 — Tool / Function Calling

```bash
curl -s http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "mistral-medium-3-5-128b",
    "messages": [{"role": "user", "content": "What is the weather in Paris?"}],
    "tools": [{
      "type": "function",
      "function": {
        "name": "get_weather",
        "description": "Get current weather for a location",
        "parameters": {
          "type": "object",
          "properties": {
            "location": {"type": "string", "description": "City name"}
          },
          "required": ["location"]
        }
      }
    }],
    "max_tokens": 100
  }'
```

**Result:** Model correctly identified the available tool. Tool calling via `--tool-call-parser mistral` confirmed working. 50 completion tokens.

### Summary

| Test | Category | Status | Tokens |
|------|----------|--------|--------|
| 1 | General Knowledge | Passed | 78 |
| 2 | Code Generation | Passed | 200 |
| 3 | Structured JSON | Passed | 203 |
| 4 | Translation | Passed | 27 |
| 5 | Tool Calling | Passed | 50 |

All tests passed on the **Red Hat certified vLLM runtime** (`registry.redhat.io/rhaii/vllm-cuda-rhel9`) with BF16 precision and FP8 weight loading via Marlin kernels.

## Troubleshooting

### Download job fails with "No space left on device"
Increase `storage.pvc.size`. The download process uses temporary files, so the PVC must be at least **2x the model size**.

### Predictor pod stuck in CrashLoopBackOff
This is expected while the download job is still running. The predictor pod tries to load the model from the PVC, fails because the files are incomplete, and restarts. It will stabilize once the download finishes.

### "CUDA out of memory" during model loading
- Increase `inference.vllm.tensorParallelSize` to use more GPUs
- Decrease `inference.vllm.maxModelLen` to reduce KV cache memory
- Set `inference.vllm.enforceEager=true` to disable CUDA graphs (saves ~1-2 GB per GPU)

### Image pull errors (unauthorized)
Ensure the cluster has a valid pull secret for `registry.redhat.io`. The Red Hat vLLM image requires an active Red Hat subscription.

### Pod not scheduling (Insufficient cpu/memory)
The HardwareProfile injects resource requests. Ensure the GPU node has enough allocatable resources after system pods. Check with:
```bash
oc describe node <gpu-node> | grep -A 5 "Allocated resources"
```
