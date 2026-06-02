# RHOAI 3.x Model Serving — Patterns and Lessons Learned

Complements the LlamaStack RAG section in `components.md`. Covers model deployment patterns, Gen AI Studio, llm-d, and storage considerations.

---

## KServe InferenceService — GitOps Patterns

### Required Labels and Annotations

**To appear in RHOAI Dashboard (Deployments tab):**
```yaml
labels:
  opendatahub.io/dashboard: "true"
```

**To appear as AI asset endpoint in Gen AI Studio → AI asset endpoints:**
```yaml
labels:
  opendatahub.io/genai-asset: "true"
annotations:
  opendatahub.io/genai-use-case: chat  # descriptive only, not functional
  opendatahub.io/model-type: generative
```

**`opendatahub.io/genai-asset: "true"` is the single label** that makes a model visible in the Playground. The `genai-use-case` annotation is purely informational — it does not control which UI is shown.

### PVC Cluster Storage Visibility

A PVC must have `opendatahub.io/dashboard: "true"` to appear in:
- RHOAI Dashboard → Project → Cluster storage tab
- The "Existing cluster storage" option in the Deploy model wizard

Without this label, the PVC is invisible to the dashboard even if it exists in the namespace. Add it with:
```bash
oc label pvc <name> -n <namespace> opendatahub.io/dashboard=true
```

### vLLM Serving Runtime — Mistral Models

For Mistral models in **HuggingFace format** (model-XXXXX.safetensors + config.json):
- **`--tensor-parallel-size N`** — required for multi-GPU (N = number of GPUs)
- **`--tokenizer-mode mistral`** — required per Red Hat AI docs: *"AI Inference does not auto-detect the Mistral tokenizer"* (Tekken tokenizer)
- **`--load-format mistral`** — only for native Mistral consolidated format; **do NOT use for HF format** (breaks loading)
- **`--config-format mistral`** — only for native Mistral params.json; **do NOT use for HF format**

The Red Hat AI Inference Server 3.4 docs show all four args together for the `RedHatAI/Mistral-*-NVFP4` model (native Mistral format). For standard HF-format Mistral models, only the first two apply.

### HuggingFace CLI

`huggingface-cli` is deprecated in newer `huggingface_hub` versions. Use `hf` instead:
```bash
# ❌ deprecated
huggingface-cli download model-name --local-dir /path

# ✅ current
hf download model-name --local-dir /path
```

Set `TMPDIR` to a writable path and mount an `emptyDir` at `/tmp` to avoid permission errors on temp files in containers.

---

## Gen AI Studio — Playground

### Prerequisites (Cluster Admin)

Per RHOAI 3.4 doc (section "Playground prerequisites"):

1. `spec.dashboardConfig.genAiStudio: true` in `OdhDashboardConfig`
2. **LlamaStack Operator enabled** in DataScienceCluster:
   ```yaml
   spec:
     components:
       llamastackoperator:
         managementState: Managed
   ```
3. Model deployed with `opendatahub.io/genai-asset: "true"` label

**LlamaStack is the backend of the Playground** — one pod per project, auto-created when user configures a playground instance. It connects to all AI asset endpoints in the project.

### LlamaStack vs AI Asset Endpoints vs MaaS

| Feature | Requires LlamaStack | Requires Kuadrant/RHCL |
|---|---|---|
| AI asset endpoints (listing) | No | No |
| Playground | **Yes** | No |
| MaaS | No | **Yes** |
| llm-d (LLMInferenceService) | No | **Yes** (AuthPolicy auto-created) |

---

## Distributed Inference with llm-d (LLMInferenceService)

### Enabling Gateway Discovery in the Wizard

To see the "Gateway Selection" field in the Deploy model wizard Advanced Settings:
```bash
oc patch odhdashboardconfig odh-dashboard-config \
  -n redhat-ods-applications \
  --type merge \
  -p '{"spec":{"dashboardConfig":{"llmGatewayField":true}}}'
```

Without this, the wizard never shows the Gateway field and always creates a standard `InferenceService`.

### Gateway `openshift-ai-inference` — Required for llm-d

The `odh-model-controller` (`gateway-auth-bootstrap` controller) is **hardcoded** to watch for a Gateway named exactly `openshift-ai-inference` in namespace `openshift-ingress`. It automatically creates an `AuthPolicy` on this Gateway for llm-d authentication.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: openshift-ai-inference  # exact name required
  namespace: openshift-ingress  # exact namespace required
spec:
  gatewayClassName: data-science-gateway-class  # reuse existing class
  listeners:
  - allowedRoutes:
      namespaces:
        from: All  # shared gateway across namespaces
    hostname: llm-d.CMP_PLACEHOLDER_OCP_APPS_DOMAIN
    name: https
    port: 443
    protocol: HTTPS
    tls:
      certificateRefs:
      - group: ""
        kind: Secret
        name: ingress-certificates
      mode: Terminate
```

**Note:** The wizard says "Gateway selection does not support MaaS Gateways" — `maas-default-gateway` cannot be used for llm-d.

### InferenceService vs LLMInferenceService

| | `InferenceService` | `LLMInferenceService` |
|---|---|---|
| **CRD** | `serving.kserve.io/v1beta1` | `serving.kserve.io/v1alpha1` |
| **Runtime** | ServingRuntime (vLLM NVIDIA GPU) | Embedded in spec.template.containers |
| **Router** | KServe standard | Endpoint Picker (KV-cache aware) |
| **Gateway** | Not required | Required (`openshift-ai-inference`) |
| **AuthPolicy** | Not auto-created | Auto-created by `odh-model-controller` |
| **Multi-pod** | 1 pod (vLLM) | 2 pods: vLLM + router-scheduler (EPP + tokenizer) |
| **Wizard trigger** | Default (no Gateway selected) | Gateway selected in Advanced Settings |

### PVC Storage with LLMInferenceService — Important Limitation

**The llm-d controller mounts the PVC on ALL pods it creates**, including the router-scheduler. This is intentional: the `tokenizer` container in the router-scheduler reads tokenizer files (`tekken.json`, `tokenizer.json`) from the model directory for KV-cache routing decisions.

**Consequence with EBS RWO (ReadWriteOnce):**
- vLLM pod and router-scheduler pod both need the PVC
- EBS RWO = one node at a time
- If pods land on different nodes → **Multi-Attach error** → router-scheduler stuck `ContainerCreating`

**Workaround (EBS RWO):** Force co-location via `podAffinity` in `router.scheduler.template`. Requires providing full container specs because the controller uses the template as-is without merging with defaults (bug — see YAML in memory `project_llmisvc_pvc_workaround`).

**Clean solution:** Use RWX storage (EFS on AWS, CephFS with ODF). Standard LLMInferenceService spec then works without modification. EFS Standard is 2-3x slower at model load vs EBS gp3, but runtime inference is unaffected (model in GPU VRAM).

**Recommended storage for llm-d in production:** S3 or `hf://` URI — no volume mounts, pods schedule freely on any node.

### `router.scheduler.template` — Controller Behavior

When `spec.router.scheduler.template` is provided, the controller uses it **as-is without merging with defaults**. This means:

- ✅ `affinity`, `tolerations`, `nodeSelector` work
- ❌ If `containers` is absent → Deployment creation fails: `spec.template.spec.containers: Required value`

To use `affinity` in the scheduler template, you must also provide the full container specs. See memory entry `project_llmisvc_pvc_workaround` for the complete YAML.

---

## AWS GPU Instance Availability

**`InsufficientInstanceCapacity`** is common for specialized GPU instances (p4d, p4de, p5):

- Capacity is AZ-specific — an instance type "available" in eu-central-1a per the API may have no actual capacity
- Always try **all 3 AZs** before concluding an instance type is unavailable
- Create separate MachineSets per AZ and test sequentially
- The error message specifies which AZs currently have capacity — use that information

**EBS PVC and AZ:** EBS volumes are AZ-bound. If the GPU node ends up in a different AZ than the PVC, the pod cannot mount it. Plan accordingly:
- Let the download job run first to bind the PVC to an AZ
- Use the same AZ for the MachineSet
- Or use EFS/S3 to avoid the AZ constraint entirely

**EBS snapshot cross-AZ migration:** Very slow for large volumes (300 Gi = hours). Re-downloading from HuggingFace is faster (~34 min for 249 Go in a lab environment).

---

## LokiStack Rate Limits with GPU/AI Workloads

Large AI workloads (vLLM, llm-d pods) generate very verbose logs that can exceed the default LokiStack ingestion rate for `1x.pico` deployments (2 MB/s).

**Symptom:** `LokiTenantRateLimit` alert + 429 errors in Loki distributor logs:
```
ingestion rate limit exceeded for user infrastructure (limit: 2097152 bytes/sec)
```

**Fix:** Increase `ingestionRate` in the LokiStack spec (not a size upgrade):
```yaml
spec:
  limits:
    global:
      ingestion:
        ingestionRate: 10   # MB/s (default 2 for 1x.pico)
        ingestionBurstSize: 20
```

Location: `components/openshift-logging/base/openshift-logging-lokistack-logging-loki.yaml`

---

## vLLM Logging Configuration

### Structured JSON Logging

The `registry.redhat.io/rhaii/vllm-cuda-rhel9` image includes `pythonjsonlogger` as a **transitive dependency** of `opentelemetry-sdk` (a direct vLLM dependency). This is not documented or guaranteed by Red Hat — verify after each image upgrade.

Configure JSON logging via `VLLM_LOGGING_CONFIG_PATH` pointing to a mounted ConfigMap:

```yaml
# ConfigMap (standard Python logging.config.dictConfig format)
data:
  logging_config.json: |
    {
      "version": 1,
      "disable_existing_loggers": false,
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
        "vllm": {"handlers": ["console"], "level": "INFO", "propagate": false},
        "uvicorn.access": {"handlers": ["console"], "level": "WARNING", "propagate": false}
      },
      "root": {"handlers": ["console"], "level": "WARNING"}
    }
```

### ⚠️ VLLM_LOGGING_CONFIG_PATH and --disable-access-log-for-endpoints are mutually exclusive

vLLM's `get_uvicorn_log_config_dict()` returns immediately when `log_config_file` is set — the `--disable-access-log-for-endpoints` code path is never reached:

```python
if log_config is not None:
    return log_config   # exits here — disable-access-log-for-endpoints never applied

if args.disable_access_log_for_endpoints:
    ...  # never reached
```

**Use `--disable-uvicorn-access-log` instead** — it works independently of `log_config`:

```
# ❌ Has no effect when VLLM_LOGGING_CONFIG_PATH is set
--disable-access-log-for-endpoints /health,/metrics,/ping

# ✅ Works regardless of log config
--disable-uvicorn-access-log
```

### InferenceService vs LLMInferenceService — Protocol Difference

| | `InferenceService` | `LLMInferenceService` |
|---|---|---|
| **Protocol** | HTTP | HTTPS (TLS, self-signed) |
| **Port** | 8080 | 8000 |
| **curl test** | `curl http://localhost:8080/v1/models` | `curl -sk https://localhost:8000/v1/models` |

---

## Tool Calling (Function Calling)

### Always Use Both Args Together

For Mistral models, tool calling requires **both** args — neither alone is sufficient:

```
--enable-auto-tool-choice   # activates tool call detection
--tool-call-parser mistral  # parses Mistral's [TOOL_CALLS] token format
```

**`--enable-auto-tool-choice` alone** → vLLM detects tool intent but cannot parse → malformed responses

**`--tool-call-parser mistral` alone** → parser configured but tool detection inactive → tools ignored

**Validation test:**
```bash
curl -s http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"<name>","messages":[{"role":"user","content":"Calculate 7*8, use calculator tool"}],
       "tools":[{"type":"function","function":{"name":"calculator","description":"Math",
       "parameters":{"type":"object","properties":{"expression":{"type":"string"}},"required":["expression"]}}}],
       "tool_choice":"auto","max_tokens":100}'
# Expected: finish_reason: tool_calls, tool_calls[0].function.name: "calculator"
```

---

## LLMInferenceService — Stop/Start Lifecycle

**Stop (frees GPUs immediately, preserves config):**
```bash
oc annotate llminferenceservice <name> -n <ns> serving.kserve.io/stop=true --overwrite
```

**Start (removes stop annotation):**
```bash
oc annotate llminferenceservice <name> -n <ns> serving.kserve.io/stop- --overwrite
```

**Why not scale replicas to 0?** Use the stop annotation — it's the official mechanism. Setting `replicas: 0` in the manifest causes ArgoCD selfHeal conflicts (see ArgoCD patterns in CLAUDE.md).

**Known side effect:** While stopped, `odh-model-controller` logs continuous reconciliation errors (AuthPolicy targets deleted HTTPRoute). This is cosmetic only — [RHOAIENG-56131](https://redhat.atlassian.net/browse/RHOAIENG-56131), In Review.

---

## GPU MachineSet Autoscaling — Which One Triggers?

The cluster autoscaler selects a MachineSet based on GPU count per node vs pod request:

| Pod requests `nvidia.com/gpu` | T4 (4 GPU/node, g4dn.12xlarge) | A100 (8 GPU/node, p4d.24xlarge) | Triggered |
|---|---|---|---|
| 1–4 | ✅ can satisfy | ✅ can too | T4 (cheaper) |
| 5–8 | ❌ insufficient | ✅ can satisfy | A100 only |

**Prerequisite:** A `MachineAutoscaler` must exist for the target MachineSet **in the correct AZ**. If the AZ has no MachineAutoscaler, manual scaling is required (`oc scale machineset`).

**AZ caveat:** p4d.24xlarge capacity is AZ-specific on AWS. Always verify which AZ has capacity before creating MachineSets — `InsufficientInstanceCapacity` errors will tell you which AZ to use instead.
