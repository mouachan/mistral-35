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

### Log Output Examples

**Default vLLM logs (without custom logging):**

```
INFO 06-01 14:32:10 api_server.py:234] vLLM API server started on port 8000
INFO 06-01 14:32:15 engine.py:112] Loading model mistral-medium-3-5-128b...
INFO 06-01 14:32:45 metrics.py:89] Avg prompt throughput: 1024.0 tokens/s, Avg generation throughput: 45.2 tokens/s
```

Plain text logs are human-readable but difficult to parse, filter, and aggregate in centralized logging systems (EFK, Kibana, Splunk).

**With custom JSON logging enabled (default in this chart):**

```json
{"asctime": "2026-06-01 14:32:10,234", "name": "vllm.entrypoints.openai.api_server", "levelname": "INFO", "message": "vLLM API server started on port 8000", "pathname": "/opt/vllm/vllm/entrypoints/openai/api_server.py", "lineno": 234}
{"asctime": "2026-06-01 14:32:15,891", "name": "vllm.engine.async_llm_engine", "levelname": "INFO", "message": "Loading model mistral-medium-3-5-128b...", "pathname": "/opt/vllm/vllm/engine.py", "lineno": 112}
{"asctime": "2026-06-01 14:32:45,567", "name": "vllm.engine.metrics", "levelname": "INFO", "message": "Avg prompt throughput: 1024.0 tokens/s, Avg generation throughput: 45.2 tokens/s", "pathname": "/opt/vllm/vllm/engine/metrics.py", "lineno": 89}
```

Structured JSON logs enable:
- **Filtering** by log level, logger name, or source file in Kibana/EFK
- **Alerting** on specific patterns (e.g., `levelname: "ERROR"`)
- **Correlation** with request tracing via timestamps and source locations
- **Noise reduction** via `disableAccessLogEndpoints` which excludes `/health`, `/metrics`, and `/ping` from access logs

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

## RHOAI Dashboard

### Model Deployments

The model appears as **Ready** in the RHOAI Models > Deployments view, with the correct hardware profile (NVIDIA A100 8x GPU) and serving runtime (vLLM NVIDIA GPU ServingRuntime for KServe).

![Model Deployments](docs/model-deployments.png)

## MaaS Integration (Models as a Service)

Once deployed, the model appears in the RHOAI **AI asset endpoints** dashboard and can be added to a **Playground** for interactive testing.

### AI Asset Endpoints

![MaaS Endpoint](docs/maas-endpoint.png)

### Configure Playground

Set **Max tokens** to `32768` (matching the `max-model-len` configured in vLLM).

![Playground Configuration](docs/playground-config.png)

### Playground in Action

**Question:** "comment installer openshift ai soit concis"

![Playground Question](docs/playground-question.png)

**Response:** Complete step-by-step guide with CLI commands and YAML examples.

![Playground Response](docs/playground-response.png)

**Performance metrics:** 8.80s total | 492 tokens | TTFT: 125ms

## Observability Dashboard (Tech Preview)

The RHOAI built-in **Observe & monitor > Dashboard** provides real-time visibility into GPU, CPU, memory, and network usage at both cluster and project level.

![Observability Dashboard](docs/observability-dashboard.png)

Key metrics displayed:
- **Overview** — System health (100%), deployed models count, GPU utilization (12.5%), request success rate
- **Cluster resource overview** — GPU utilization, memory allocated, CPU utilization, inbound traffic over time
- **Project resource usage** — Per-namespace breakdown (GPU, CPU, memory) with the `mistral35` project highlighted

> **Note:** GPU metrics require a `ServiceMonitor` for the NVIDIA DCGM exporter. If GPU utilization shows "No data", create one in the `nvidia-gpu-operator` namespace targeting `app: nvidia-dcgm-exporter` on port `gpu-metrics`.

## Grafana Dashboard

The Helm chart includes an optional Grafana deployment (via the [Grafana Operator](https://github.com/grafana/grafana-operator)) with a pre-configured dashboard for deep observability beyond the RHOAI built-in dashboard.

When `grafana.enabled=true`, the chart deploys:
- A **Grafana instance** with an OpenShift Route (HTTPS)
- A **ServiceAccount** with `cluster-monitoring-view` permissions to query Prometheus/Thanos
- A **GrafanaDatasource** pointing to the OpenShift Thanos Querier
- A **GrafanaDashboard** loaded from [`grafana/mistral-medium-dashboard.json`](grafana/mistral-medium-dashboard.json)

### Prerequisites

The Grafana Operator must be installed on the cluster before enabling this feature:

```bash
# Install the Grafana Operator from OperatorHub (AllNamespaces mode)
# Or via CLI:
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: grafana-operator
  namespace: openshift-operators
spec:
  channel: v5
  name: grafana-operator
  source: community-operators
  sourceNamespace: openshift-marketplace
EOF
```

### Deployment

```bash
# Create a ServiceAccount token for Prometheus access
oc create sa grafana-prometheus -n mistral35
oc adm policy add-cluster-role-to-user cluster-monitoring-view -z grafana-prometheus -n mistral35
SA_TOKEN=$(oc create token grafana-prometheus -n mistral35 --duration=87600h)

# Install/upgrade with Grafana enabled
helm upgrade --install mistral-medium . \
  --namespace mistral35 \
  --set secret.hfToken=<your-hf-token> \
  --set grafana.enabled=true \
  --set grafana.datasource.token=$SA_TOKEN
```

### Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| `grafana.enabled` | `true` | Enable/disable Grafana deployment |
| `grafana.adminUser` | `admin` | Grafana admin username |
| `grafana.adminPassword` | `admin` | Grafana admin password. **Change in production.** |
| `grafana.datasource.url` | `https://thanos-querier.openshift-monitoring.svc.cluster.local:9091` | Prometheus/Thanos endpoint |
| `grafana.datasource.token` | `REPLACE_WITH_SA_TOKEN` | ServiceAccount bearer token. **Pass via `--set` at install time.** |

### Dashboard Sections

The dashboard is organized into 6 sections covering both vLLM application metrics and NVIDIA GPU hardware metrics:

![Grafana — Overview + GPU](docs/grafana-overview-gpu.png)

**Overview** — KPIs at a glance: total requests (8), prompt tokens (277), generation tokens (3016), requests running/waiting, and KV cache usage percentage.

**GPU — NVIDIA DCGM Metrics** — Per-GPU hardware monitoring sourced from the DCGM exporter:
- GPU utilization (%) with spike visualization during inference
- GPU memory used (~20.9 GB per GPU for the 128B model in BF16)
- GPU temperature (50-54 C under load)
- Power usage (~35 W idle per A100)
- Tensor core activity (SM Active + Tensor Active)

![Grafana — Latency + Tokens](docs/grafana-latency-tokens.png)

**Latency & Performance** — Real-time latency tracking:
- Time to First Token: P50 = 87.5 ms, P99 = 99.8 ms
- Inter-Token Latency: P50 = 17.5 ms (~57 tokens/s generation speed)
- E2E Latency: P50 = 12.5 s (for 500-token responses)
- Latency distribution with P50/P99 trendlines (dashed = P99)
- Request phase breakdown: Queue (150 ms), Prefill (187 ms), Decode (7.04 s)

**Token Throughput** — Token generation analytics:
- Real-time tokens/s (prompt: 2.10 peak, generation: 28.2 peak)
- Requests by finish reason: stop (natural end) vs length (max_tokens reached) vs error/abort
- Cumulative tokens over time (prompt: 277, generation: 3.02K)
- Finish reason distribution (donut): 63% length, 38% stop
- Prompt tokens by source (donut): 53% local_compute, 47% local_cache_hit (prefix caching working)

![Grafana — Cache + Interconnect](docs/grafana-cache-interconnect.png)

**Cache & Memory** — KV cache and prefix cache monitoring:
- KV cache usage gauge (0% when idle, watch for saturation > 90%)
- KV cache usage over time (mean: 0.005%, max: 0.86% — healthy headroom)
- Prefix cache hit rate (1.51% mean — increases with repeated prompts)

**GPU Interconnect & PCIe** — Inter-GPU communication for tensor parallelism:
- NVLink bandwidth (GPU-to-GPU, ~210 B/s idle, 4.25 kB/s peak)
- PCIe throughput TX/RX (~4 kB/s during inference)
- DRAM activity and memory copy utilization per GPU

### Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `DS_PROMETHEUS` | Prometheus datasource | Auto-detected |
| `model` | vLLM model name (auto-populated from Prometheus) | `mistral-medium-3-5-128b` |
| `namespace` | Namespace for DCGM GPU metrics | `nvidia-gpu-operator` |

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
