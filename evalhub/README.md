# EvalHub on RHOAI 3.4

One-time cluster setup for the EvalHub evaluation orchestration service. EvalHub is deployed centrally in `redhat-ods-applications` and runs benchmark jobs in tenant namespaces.

## Prerequisites

- RHOAI 3.4+ with TrustyAI operator installed
- MLflow deployed on the cluster (managed by RHOAI)
- `oc` CLI with cluster-admin access

## Architecture

```
redhat-ods-applications          evalhub (namespace)         mistral35 (tenant)
+------------------+            +------------------+        +------------------+
| EvalHub CR       |            | PostgreSQL       |        | Benchmark pods   |
| EvalHub pod      |----------->| (evalhub-db)     |        | (created by      |
| EvalHub route    |            +------------------+        |  EvalHub)        |
+------------------+                                        | Model predictor  |
        |                                                   +------------------+
        +----> MLflow (redhat-ods-applications)
```

## Deployment

### Step 1: Enable the EvalHub controller

On RHOAI 3.4, the TrustyAI operator does not enable the EvalHub controller by default. Patch it manually:

```bash
# Scale down rhods-operator to prevent it from reverting the patch
oc scale deployment rhods-operator -n redhat-ods-operator --replicas=0

# Add EVALHUB to --enable-services
oc patch deployment trustyai-service-operator-controller-manager \
  -n redhat-ods-applications --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/containers/0/args",
       "value":["--leader-elect","--enable-services","NEMO_GUARDRAILS,EVALHUB"]}]'

# Prevent rhods-operator from reverting the patch
oc annotate deployment trustyai-service-operator-controller-manager \
  -n redhat-ods-applications opendatahub.io/managed='false'

# Scale rhods-operator back up
oc scale deployment rhods-operator -n redhat-ods-operator --replicas=3
```

### Step 2: Deploy PostgreSQL

```bash
oc apply -f namespace.yaml
oc apply -f db-secret.yaml        # edit password first!
oc apply -f postgresql.yaml
oc wait --for=condition=Available deployment/evalhub-db -n evalhub --timeout=120s
```

### Step 3: Create the DB secret in redhat-ods-applications

The EvalHub pod runs in `redhat-ods-applications` but connects to PostgreSQL in `evalhub`:

```bash
oc apply -f db-secret.yaml
```

### Step 4: Apply RBAC

```bash
oc apply -f rbac.yaml
```

This creates all the ClusterRoles and bindings that the TrustyAI operator would normally create on RHOAI 3.5+.

### Step 5: Deploy EvalHub

```bash
oc apply -f evalhub-cr.yaml
oc wait --for=condition=Available deployment/evalhub -n redhat-ods-applications --timeout=300s
```

### Step 6: Register a tenant namespace

For each namespace containing a model to benchmark:

```bash
# Label the namespace
oc label namespace mistral35 \
  evalhub.trustyai.opendatahub.io/tenant="true" \
  opendatahub.io/dashboard="true"

# Apply tenant RBAC (edit TENANT_NAMESPACE in the file first)
sed 's/TENANT_NAMESPACE/mistral35/g' tenant-rbac.yaml | oc apply -f -
```

## Submit a benchmark

### Available GuideLLM benchmark IDs

| ID | Description |
|----|-------------|
| `sweep` | Auto-discover optimal load (10 strategies, recommended) |
| `quick_perf_test` | Fast sweep with limited samples |
| `throughput` | Maximum throughput discovery |
| `concurrent` | Fixed concurrency stress test |
| `constant` | Steady-state load test |
| `poisson` | Realistic traffic simulation (Poisson arrivals) |
| `comprehensive_perf_test` | Full performance characterization |

### Via curl

```bash
TOKEN=$(oc whoami -t)
EVALHUB_ROUTE=$(oc get route evalhub -n redhat-ods-applications -o jsonpath='{.spec.host}')

curl -sk -X POST "https://${EVALHUB_ROUTE}/api/v1/evaluations/jobs" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "X-Tenant: mistral35" \
  -d '{
    "name": "bench-mistral-sweep",
    "model": {
      "url": "http://mistral-medium-3-5-128b-predictor.mistral35.svc.cluster.local:8000/v1",
      "name": "mistral-medium-3-5-128b"
    },
    "benchmarks": [
      {"id": "sweep", "provider_id": "guidellm"}
    ],
    "experiment": {
      "name": "benchmark-mistral-3.5"
    }
  }'
```

### Via Helm chart

```bash
helm upgrade --install mistral-medium . \
  --namespace mistral35 \
  --set benchmark.enabled=true \
  --set benchmark.benchmarkId=sweep
```

### Via RHOAI Dashboard

Navigate to **Evaluations** > **New evaluation** in the RHOAI dashboard (project: `mistral35`).

## Check status

```bash
TOKEN=$(oc whoami -t)
EVALHUB_ROUTE=$(oc get route evalhub -n redhat-ods-applications -o jsonpath='{.spec.host}')

# List all evaluations
curl -sk -H "Authorization: Bearer $TOKEN" \
  -H "X-Tenant: mistral35" \
  "https://${EVALHUB_ROUTE}/api/v1/evaluations/jobs"

# Get specific job status
curl -sk -H "Authorization: Bearer $TOKEN" \
  -H "X-Tenant: mistral35" \
  "https://${EVALHUB_ROUTE}/api/v1/evaluations/jobs/<job-id>"
```

## View results

Results are automatically exported to MLflow:

1. **RHOAI Dashboard**: Experiments (MLflow) > workspace `mistral35` > experiment `benchmark-mistral-3.5`
2. **RHOAI Dashboard**: Evaluations page (project: `mistral35`)

## Important notes

- **Model URL**: Use the predictor service with explicit port 8000: `http://<model>-predictor.<namespace>.svc.cluster.local:8000/v1`. The predictor service is headless (ClusterIP None), so the default port 80 does not work.
- **API field**: Use `"id"` (not `"benchmark_id"`) in the benchmarks array when calling the API.
- **Namespace**: The EvalHub CR must be in `redhat-ods-applications`, not in a separate namespace.
- **RHOAI 3.5+**: The RBAC and `--enable-services` patch are not needed — the operator handles everything automatically.
