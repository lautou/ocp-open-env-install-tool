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

### `serving.kserve.io/deploymentMode` — Omit It, Let KServe Inject the Default

RHOAI 3.5 has no Knative Serverless component at all (dropped for Gateway API/llm-d compatibility) — `Standard` (KServe's RawDeployment mode) is the only functional value, sourced from `inferenceservice-config`'s `deploy.defaultDeploymentMode: RawDeployment`.

**Omit the annotation from the manifest.** `oc apply --dry-run=server` against a manifest without it predicts the exact same live result as today (`deploymentMode: Standard`) — confirmed on both `ai-project-a` (`default-profile`) and `ai-project-b` (`gpus`). KServe's `inferenceservice.kserve-webhook-server.defaulter` mutating webhook re-applies this on every CREATE/UPDATE regardless of what's requested, so declaring it adds nothing and only risks a stale/legacy value (`RawDeployment`, KServe's deprecated alias for `Standard`) drifting from what's actually live. This is the same "omit the field entirely so ArgoCD never manages it" pattern documented for `spec.replicas` in the root `CLAUDE.md`'s ignoreDifferences section.

### HardwareProfile `tolerations` — Omit It, Injection Verified Safe Against Real Writes

GPU nodes on this cluster carry a taint (`nvidia.com/gpu=present:NoSchedule`), so this field is operationally load-bearing — if the toleration ever failed to reach the actual Pod (not just the `InferenceService` CR), the model Pod would get stuck `Pending` forever. A plain `dry-run=server` test isn't strong enough evidence for a field this sensitive: the actual injection is done by a separate `odh-model-controller` mutating webhook (`minferenceservice-v1beta1.odh-model-controller.opendatahub.io`, not the plain KServe defaulter), flagged `sideEffects: NoneOnDryRun` — exactly the class of webhook that can legally special-case dry-run requests.

**Verified directly, not by dry-run**: two hand-built `AdmissionReview` v1 requests (identical `InferenceService` payload, tolerations omitted; one `dryRun: false`, one `dryRun: true`) were POSTed straight to the webhook service, bypassing the API server's dry-run path entirely. Both returned the byte-identical JSONPatch injecting `[{key: nvidia.com/gpu, operator: Exists}]` — no dry-run branching exists in this webhook. The live Pod backing `granite-3-3-2b-instruct` was also confirmed to carry the toleration in its actual `spec.tolerations`, not just the CR. Given real writes get the same injection as dry-run, `spec.predictor.tolerations` is safe to omit for any `InferenceService` referencing a HardwareProfile with `scheduling.node.tolerations` set — the HardwareProfile CR is the single source of truth; changing it re-propagates to every referencing `InferenceService` automatically.

### `automountServiceAccountToken` and `minReplicas`/`maxReplicas` — Omit, Confirmed Safe by Live Testing

RHOAI overrides KServe's own upstream default (`true`) via `inferenceservice-config`'s `security.autoMountServiceAccountToken: false` — so `spec.predictor.automountServiceAccountToken: false` is redundant to declare.

`minReplicas`/`maxReplicas` default to `1`/`1` (KServe's documented autoscaling default) when omitted. Verified with a **real apply** (not just dry-run, since the HPA that KServe creates is a controller-reconcile side effect invisible to admission-time dry-run) against `ai-project-a`'s `qwen3-06b-100`: omitting both fields still produced `HPA minPods=1/maxPods=1`, `Deployment replicas=1`, and the CR's own spec settling back to `1`/`1` — identical to declaring them. Contrast with `timeout`, whose real KServe default (60s) *differs* from this repo's declared `30` — that one must stay explicit.

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

### vllm-cpu-x86-runtime CrashLoopBackOff — Two Real Causes, One Misleading Symptom

`qwen3-06b-100` (`ai-project-a`, RHOAI 3.5.1, `vllm-cpu-x86-runtime`) crash-looped with a generic, unhelpful error on every attempt: `RuntimeError: Engine core initialization failed. See root cause above. Failed core proc(s): {}`. The captured container log was consistently only ~20-30 lines — too short to contain the actual root cause, which vLLM normally prints just above that line. **Two independent, stacked bugs**, both required to get a working deployment:

**1. `/dev/shm` too small (the actual cause of the truncated, uninformative log).** The pod had no dedicated shared-memory volume, so it used CRI-O's 64Mi default — too small for vLLM's multiprocess CPU executor (API server + EngineCore run as separate processes communicating over shared memory). Fix: add a `Memory`-medium `emptyDir` at `/dev/shm`:
```yaml
spec:
  predictor:
    model:
      volumeMounts:
      - mountPath: /dev/shm
        name: dshm
    volumes:
    - emptyDir:
        medium: Memory
        sizeLimit: 2Gi
      name: dshm
```
Once this is in place, the log gets far enough to print the *real* error — don't stop investigating just because a short, generic-looking log matches this symptom; fix `/dev/shm` first and re-check the logs before concluding anything else.

**2. `--gpu-memory-utilization` is NOT GPU-only on Red Hat's vLLM CPU backend — despite the name, it controls CPU memory reservation.** This is a Red Hat AI Inference Server (`rhaiv`) build-specific behavior, not documented in upstream vLLM's CPU docs, and not discoverable without hitting the actual error text. **Do not remove this arg from a CPU `InferenceService` just because the flag name says "gpu"** — confirmed via the real error surfaced only after fixing `/dev/shm` above:
```
ValueError: Available memory on node 0 (6.11/8.0 GiB) on startup is less than desired CPU memory
utilization (0.92, 7.36 GiB). On the CPU backend, the `--gpu-memory-utilization` flag controls the
fraction of CPU memory reserved (despite its name). To resolve: decrease `--gpu-memory-utilization`
(e.g. `--gpu-memory-utilization 0.5`) or reduce CPU memory used by other processes.
```
`gpu_memory_utilization` defaults to ~0.9 of the container's memory limit when omitted — on an 8Gi limit that leaves too little headroom once the model, Python/PyTorch runtime, and framework overhead are already resident. Set it explicitly (e.g. `0.5`) to leave real headroom; don't just delete it.

**Rule**: on this vLLM CPU image, treat `--gpu-memory-utilization` as a required CPU memory-budget arg, not a leftover GPU flag — verify against the actual crash log (after fixing `/dev/shm` if the log looks suspiciously short) before assuming a "gpu"-named flag is safe to drop on a CPU runtime.

**Documentation gap filed upstream** (2026-09-29): neither issue is documented for the KServe/`InferenceService` deployment path in RHOAI 3.5's own docs — filed as [RHOAIENG-97011](https://redhat.atlassian.net/browse/RHOAIENG-97011) (`/dev/shm` sizing) and [RHOAIENG-97012](https://redhat.atlassian.net/browse/RHOAIENG-97012) (`--gpu-memory-utilization` CPU semantics).

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

## NooBaa/MCG-Backed Data Connections — Use the Internal S3 Endpoint, HTTPS Is Also an Option

For an S3-type Data Connection (or a ModelRegistry's object storage) backed by an `ObjectBucketClaim`, point `AWS_S3_ENDPOINT` at NooBaa's in-cluster gateway service — `s3.openshift-storage.svc` — never the external Route. The Route is signed by the cluster's self-signed default ingress cert, which fails TLS verification for S3 clients (boto3, DSPA, etc.) connecting from inside the cluster.

**The internal Service itself supports real, verifiable TLS on port 443** — its cert (`CN=s3.openshift-storage.svc`) is signed by the cluster's own service-ca signer, same as every other service-ca cert cluster-wide. Confirmed live: `curl --cacert <(oc get cm odh-kserve-custom-ca-bundle -o jsonpath='{.data.cabundle\.crt}') https://s3.openshift-storage.svc` returns `SSL certificate verify ok`. `odh-kserve-custom-ca-bundle` (and the combined `odh-trusted-ca-bundle`'s `odh-ca-bundle.crt` key) are auto-propagated to every namespace cluster-wide, so any consumer that trusts the cluster's service-ca signer — explicitly via a mounted CA bundle (MLflow's CR `caBundleConfigMap` field), or implicitly via RHOAI's standard Workbench/Pipeline trusted-CA injection — gets a genuinely verified connection with `https://s3.openshift-storage.svc`, not just an encrypted-but-unverified one.

**Plain `http://` is still the simplest, lowest-risk default** for a generic Data Connection Secret with no single fixed consumer (the RHOAI dashboard's S3 connection type has no CA-bundle field, so there's no way to wire explicit trust into the Secret itself — a consumer has to already trust the service-ca signer on its own, which dashboard-created Workbenches generally do but arbitrary user code might not). Use `https://` when there's a specific, verifiable consumer to confirm against (as done for MLflow); default to `http://` otherwise, matching `create-secret-logging-loki-s3`/`create-secret-netobserv-loki-s3`.

### A Large Upload Can Silently Fail on a Just-Created OBC Bucket, While Small Files Succeed

Immediately after an `ObjectBucketClaim` is created (e.g. right after a namespace recreation), a model-ingest script's `wait_for_bucket()`-style readiness check can pass and small file uploads (`config.json`, tokenizer files) can succeed via `boto3.upload_file()`, while a large file (a multi-hundred-MB/GB `.safetensors` weight file, uploaded as a multipart transfer) silently fails with no exception raised and no error in the Job log — the script reports `✅ SUCCESS` even though the weight file never lands in the bucket. The only symptom shows up downstream: KServe's storage-initializer lists fewer S3 objects than expected, and vLLM fails to load with a generic, unhelpful `Engine core initialization failed` error (same misleading-short-log symptom as the `vllm-cpu-x86-runtime` entry above, but with a different root cause).

**Diagnosis:** check the storage-initializer's own log for `Found S3 object: ...` lines and confirm the weight file is actually listed with its real size — don't assume the ingest Job's own `SUCCESS` message proves the upload is complete.

**Fix:** re-run the ingest Job once (`oc create -f` a copy of the completed Job's spec under a new name, or delete+let GitOps/Force=true recreate it) — a retry against the now-fully-provisioned bucket succeeds reliably. **Confirmed reproducible, not a one-off:** hit twice in a row during the same renaming session (2026-10-12) — `ai-model-registry-governance` (`model-registry-lab` rename) dropped the single 1.5GB `model.safetensors`; `ai-single-pod-llm-serving` (`model-deploy-lab` rename) dropped both sharded `model-0000X-of-00002.safetensors` files (~5GB total) the very next time a fresh OBC was created. Treat the first ingest run after any namespace recreation as untrusted by default — check the storage-initializer log before assuming the model loaded correctly.

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

**Workaround (EBS RWO):** Force co-location via `podAffinity` in `router.scheduler.template`. Requires providing full container specs because the controller uses the template as-is without merging with defaults (bug — see "Full Working YAML — EBS RWO Co-location Workaround" below).

**Clean solution:** Use RWX storage (EFS on AWS, CephFS with ODF). Standard LLMInferenceService spec then works without modification. EFS Standard is 2-3x slower at model load vs EBS gp3, but runtime inference is unaffected (model in GPU VRAM).

**Recommended storage for llm-d in production:** S3 or `hf://` URI — no volume mounts, pods schedule freely on any node.

### S3 Storage with an MCG/NooBaa `ObjectBucketClaim` — URI Must Be Re-synced After Namespace Recreation

`spec.model.uri` for an S3-backed `LLMInferenceService` is a static, git-committed string
(`s3://<bucket>/<path>`), but an `ObjectBucketClaim` using `generateBucketName` gets a brand-new
random bucket name (e.g. `models--79cb8c90-...`) every time it's created — including when a
namespace is deleted and recreated (a GitOps rename, a profile switch). The old bucket and its
contents are gone with the old namespace; the new OBC creates an empty bucket under a different
name that the hardcoded `model.uri` doesn't match, so the storage-initializer fails with `404
HeadBucket ... Not Found`, even though the model-loading Job (e.g. `fasttracker`) completes
successfully into the *new* bucket.

**Fix after any namespace recreation:** read the new bucket name (`oc get obc <name> -n <ns> -o
jsonpath='{.spec.bucketName}'`) and update `model.uri` in the component's
`*-llminferenceservice-*.yaml` to match, then commit/push — a live-only patch won't survive
ArgoCD `selfHeal`. Seen in `ai-distributed-llm-serving` (`llmd-deploy-lab` rename, 2026-10-12).

### `router.scheduler.template` — Controller Behavior

When `spec.router.scheduler.template` is provided, the controller uses it **as-is without merging with defaults**. This means:

- ✅ `affinity`, `tolerations`, `nodeSelector` work
- ❌ If `containers` is absent → Deployment creation fails: `spec.template.spec.containers: Required value`

To use `affinity` in the scheduler template, you must also provide the full container specs — see "Full Working YAML — EBS RWO Co-location Workaround" below.

### Full Working YAML — EBS RWO Co-location Workaround

Deploying LLMInferenceService with PVC RWO storage on a GPU-tainted node (e.g. `p4d.24xlarge`) requires two non-standard sections beyond the basic spec, because EBS gp3 is RWO (one node at a time) and the llm-d controller mounts the PVC on every pod it creates — both vLLM and the router-scheduler's `tokenizer` container must land on the same node.

```yaml
apiVersion: serving.kserve.io/v1alpha1
kind: LLMInferenceService
metadata:
  annotations:
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
    opendatahub.io/genai-use-case: chat
    opendatahub.io/model-type: generative
    openshift.io/display-name: mistral-medium-3-5-llmd
    security.opendatahub.io/enable-auth: "false"
  labels:
    opendatahub.io/dashboard: "true"
    opendatahub.io/genai-asset: "true"
  name: mistral-medium-3-5-llmd
  namespace: demo-ei
spec:
  model:
    name: mistral-medium-3-5-llmd
    uri: pvc://mistral-medium-3-5-bf16/mistral-medium-3-5
  replicas: 1
  router:
    gateway:
      refs:
      - name: openshift-ai-inference
        namespace: openshift-ingress
    route: {}
    scheduler:
      template:
        # NON-STANDARD: podAffinity to co-locate router-scheduler with vLLM pod (same RWO node)
        affinity:
          podAffinity:
            requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels:
                  app.kubernetes.io/name: mistral-medium-3-5-llmd
                  kserve.io/component: workload
              topologyKey: kubernetes.io/hostname
        # NON-STANDARD: toleration needed since p4d has nvidia.com/gpu:NoSchedule taint
        tolerations:
        - effect: NoSchedule
          key: nvidia.com/gpu
          operator: Exists
        # NON-STANDARD: full containers required — controller does NOT merge with defaults
        containers:
        - name: main
          command:
          - /app/epp
          - --pool-name
          - mistral-medium-3-5-llmd-inference-pool
          - --pool-namespace
          - demo-ei
          - --zap-encoder
          - json
          - --grpc-port
          - "9002"
          - --grpc-health-port
          - "9003"
          - --enable-cert-reload=true
          - --secure-serving=true
          - --model-server-metrics-scheme=https
          - --cert-path=/var/run/kserve/tls
          args:
          - --config-text
          - |
            apiVersion: inference.networking.x-k8s.io/v1alpha1
            kind: EndpointPickerConfig
            plugins:
            - type: single-profile-handler
            - type: queue-scorer
            - type: prefix-cache-scorer
            - type: max-score-picker
            schedulingProfiles:
            - name: default
              plugins:
              - pluginRef: queue-scorer
                weight: 2
              - pluginRef: prefix-cache-scorer
                weight: 3
              - pluginRef: max-score-picker
          env:
          - name: SSL_CERT_DIR
            value: /var/run/kserve/tls:/var/run/secrets/kubernetes.io/serviceaccount:/etc/pki/tls/certs
          image: registry.redhat.io/rhoai/odh-llm-d-inference-scheduler-rhel9@sha256:bddf686d6eaf1a607e1c697f58165d685944607cb4629648f27e56b2884e3de0
          resources:
            requests:
              cpu: 256m
              memory: 500Mi
          volumeMounts:
          - mountPath: /var/run/kserve/tls
            name: tls-certs
            readOnly: true
          - mountPath: /tmp/tokenizer
            name: tokenizer-uds
        - name: tokenizer
          image: registry.redhat.io/rhoai/odh-llm-d-kv-cache-rhel9@sha256:db4b79a17194574aeae3e702eb2740485c95f160166d2ea7b6cbab0a40cfe9e9
          env:
          - name: TOKENIZERS_DIR
            value: /mnt/models
          workingDir: /mnt/models
          resources:
            requests:
              cpu: 256m
              memory: 500Mi
          volumeMounts:
          - mountPath: /tmp
            name: tokenizer-tmp
          - mountPath: /.cache
            name: tokenizer-cache
          - mountPath: /tmp/tokenizer
            name: tokenizer-uds
          - mountPath: /mnt/models/base
            name: kserve-pvc-source
            readOnly: true
            subPath: mistral-medium-3-5
        volumes:
        - name: tls-certs
          secret:
            secretName: mistral-medium-3-5-llmd-kserve-self-signed-certs
        - name: tokenizer-uds
          emptyDir: {}
        - name: tokenizer-tmp
          emptyDir: {}
        - name: tokenizer-cache
          emptyDir: {}
        - name: kserve-pvc-source
          persistentVolumeClaim:
            claimName: mistral-medium-3-5-bf16
  template:
    containers:
    - env:
      - name: VLLM_ADDITIONAL_ARGS
        value: --tensor-parallel-size 8
      name: main
      resources:
        limits:
          cpu: "48"
          memory: 320Gi
          nvidia.com/gpu: "8"
        requests:
          cpu: "48"
          memory: 320Gi
          nvidia.com/gpu: "8"
    # NON-STANDARD: toleration required for vLLM pod on GPU-tainted p4d node
    tolerations:
    - effect: NoSchedule
      key: nvidia.com/gpu
      operator: Exists
```

**Key facts:**
- TLS secret name: `<llmisvc-name>-kserve-self-signed-certs` (auto-created by controller)
- Pool name: `<llmisvc-name>-inference-pool` (hardcoded in EPP args)
- Tokenizer container mounts the PVC at `/mnt/models/base` with `subPath=<model-subfolder>`
- Image digests above are for RHOAI 3.4 — re-verify against the current release before reusing

For PVC RWX (e.g. EFS), none of these workarounds are needed — the standard spec works as-is. AWS EFS supports ReadWriteMany, eliminating the co-location requirement entirely: EFS Standard runs 100-300 MB/s (2-3x slower model load than EBS gp3), EFS Performance up to 3 GB/s (comparable to EBS, more expensive). Runtime inference is unaffected either way since the model loads into GPU VRAM — the only cost is cold-start time.

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

| Pod requests `nvidia.com/gpu` | T4 (1 GPU/node, g4dn.xlarge, maxReplicas=1) | A100 (8 GPU/node, p4d.24xlarge) | Triggered |
|---|---|---|---|
| 1 | ✅ can satisfy | ✅ can too | T4 (cheaper) |
| 2–8 | ❌ insufficient (single GPU per node, only 1 replica max) | ✅ can satisfy | A100 only |

**Prerequisite:** A `MachineAutoscaler` must exist for the target MachineSet **in the correct AZ**. If the AZ has no MachineAutoscaler, manual scaling is required (`oc scale machineset`).

**AZ caveat:** p4d.24xlarge capacity is AZ-specific on AWS. Always verify which AZ has capacity before creating MachineSets — `InsufficientInstanceCapacity` errors will tell you which AZ to use instead.
