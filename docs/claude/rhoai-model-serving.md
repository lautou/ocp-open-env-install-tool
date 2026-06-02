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
