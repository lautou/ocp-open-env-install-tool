# RAG Pipeline Run Instructions

**Quick Reference**: How to run the two-stage RAG pipeline (chunk-data → convert-store-embeddings).

---

## Prerequisites Checklist

Before running the pipelines, verify all infrastructure is ready:

```bash
# 1. Check AI Embedding Service
oc get inferenceservice granite-embedding -n ai-embedding-service
# Expected: READY=True, URL shows predictor endpoint

# 2. Check PostgreSQL + pgvector
oc get deployment rag-postgresql -n external-db-generation-llm-rag
# Expected: READY=1/1

oc exec -n external-db-generation-llm-rag deployment/rag-postgresql -- \
  psql -U raguser -d ragdb -c "\dx vector"
# Expected: vector extension v0.8.2 listed

# 3. Check DSPA
oc get dspa pipelines -n ai-generation-llm-rag
# Expected: Phase=Ready

# 4. Check pipelines uploaded
oc get job -n openshift-gitops | grep upload-pipeline
# Expected: upload-pipeline-chunk-data (Complete 1/1)
#           upload-pipeline-convert-store-embeddings (Complete 1/1)

# 5. Check applications synced
oc get application.argoproj.io -n openshift-gitops | grep -E "ai-embedding|ai-generation"
# Expected: ai-embedding-service (Synced/Healthy)
#           uc-ai-generation-llm-rag (Synced/Healthy)
```

✅ **All checks passed?** Proceed to running the pipelines.

---

## Access RHOAI Dashboard

### Find Dashboard URL

```bash
# Get RHOAI dashboard route (in openshift-ingress namespace)
oc get route -A | grep data-science-gateway
# Or check the ConsoleLink
oc get consolelink rhodslink -o jsonpath='{.spec.href}'
```

**Example output**: `https://data-science-gateway.apps.myocp.sandbox226.opentlc.com/`

### Login

1. Open browser to dashboard URL
2. Login with OpenShift credentials (same as `oc login`)
3. Navigate to **Develop & train** → **Pipelines** in left menu
4. Under **Pipeline definitions**, select **ai-generation-llm-rag** project from dropdown

---

## Stage 1: chunk-data Pipeline

### Purpose
Convert PDF documents to semantic chunks using Docling.

### Via RHOAI UI

#### Step 1: Navigate to Pipeline

1. In RHOAI Dashboard → **Develop & train** → **Pipelines**
2. Under **Pipeline definitions**, select project: **ai-generation-llm-rag**
3. Find pipeline: **chunk-data** in the list
4. Click the pipeline name to view details

#### Step 2: Create Run

1. Click **Create run** button
2. **Run details**:
   - **Name**: `chunk-pdfs-{your-name}-{date}` (e.g., `chunk-pdfs-test-2026-04-10`)
   - **Description**: (Optional) "Processing technical documentation for RAG"
   - **Experiment**: Select existing or create new (e.g., "rag-experiments")

#### Step 3: Configure Parameters

**Required Parameters:**

| Parameter | Value | Description |
|-----------|-------|-------------|
| `pdf_filenames` | `"doc1.pdf,doc2.pdf"` | Comma-separated PDF filenames (no spaces) |
| `pdf_base_url` | `"https://example.com/pdfs"` | Base URL where PDFs are located |
| `docling_chunk_enabled` | `true` | **MUST BE TRUE** for RAG pipeline |
| `docling_chunk_max_tokens` | `512` | Chunk size (adjust based on use case) |

**Example Values for Testing:**
```yaml
pdf_filenames: "2203.01017v2.pdf"
pdf_base_url: "https://github.com/docling-project/docling/raw/v2.43.0/tests/data/pdf"
docling_chunk_enabled: true
docling_chunk_max_tokens: 512
docling_chunk_merge_peers: true
num_splits: 1
```

**Optional Parameters** (use defaults unless you need customization):

| Parameter | Default | When to Change |
|-----------|---------|----------------|
| `num_splits` | `3` | Increase for large PDF sets (faster parallel processing) |
| `docling_pdf_backend` | `"dlparse_v4"` | Only change if advised by Docling docs |
| `docling_table_mode` | `"accurate"` | Set to `"fast"` for speed over accuracy |
| `docling_ocr` | `true` | Set to `false` if PDFs are text-based (no scans) |
| `docling_num_threads` | `4` | Increase for larger machines |

#### Step 4: Launch Run

1. Review all parameters
2. Click **Create** button
3. You'll be redirected to the run details page

#### Step 5: Monitor Progress

**UI Monitoring:**
1. **Runs** tab shows all pipeline runs
2. Click on your run to see details
3. Watch the **Graph** tab for task progress
4. Typical stages:
   - `import-pdfs` (2-5 min)
   - `download-docling-models` (parallel with import, 2-3 min)
   - `create-pdf-splits` (< 1 min)
   - `for-loop-1` → `docling-convert-standard` → `docling-chunk` (5-15 min per split)

**Expected Duration**: 10-20 minutes (depends on PDF count and size)

**Status Indicators:**
- ⏳ **Running**: Task in progress
- ✅ **Succeeded**: Task completed successfully
- ❌ **Failed**: Task failed (click for logs)
- ⏸️ **Skipped**: Task skipped (e.g., `docling-chunk` if `docling_chunk_enabled=false`)

#### Step 6: Extract Chunk Artifact Path

**After run succeeds:**

1. Go to run details page
2. Click **Artifacts** tab (or **Output** depending on UI version)
3. Find the `docling-chunk` task output
4. Copy the artifact URI

**Format**: `minio://mlpipeline/v2/artifacts/{run_id}/for-loop-1/docling-chunk/output_path`

**Simplified path for Stage 2** (works in most cases):
```
minio://mlpipeline/v2/artifacts/{run_id}/for-loop-1/
```

**Example**:
```
minio://mlpipeline/v2/artifacts/12345678-abcd-1234-abcd-123456789abc/for-loop-1/
```

**Note**: The `minio://` prefix is KFP v2's protocol scheme. The actual storage backend is **ODF NooBaa** (ObjectBucketClaim `pipeline-artifacts` → bucket `ai-generation-llm-rag-pipelines` on `s3.openshift-storage.svc`).

📋 **Copy this path** - you'll need it for Stage 2!

---

## Stage 2: convert-store-embeddings Pipeline

### Purpose
Generate embeddings using granite-embedding and store in PostgreSQL + pgvector.

### Via RHOAI UI

#### Step 1: Navigate to Pipeline

1. In RHOAI Dashboard → **Develop & train** → **Pipelines**
2. Under **Pipeline definitions**, select project: **ai-generation-llm-rag**
3. Find pipeline: **convert-store-embeddings** in the list
4. Click the pipeline name to view details

#### Step 2: Create Run

1. Click **Create run** button
2. **Run details**:
   - **Name**: `embed-store-{your-name}-{date}` (e.g., `embed-store-test-2026-04-10`)
   - **Description**: (Optional) "Generating embeddings for technical docs"
   - **Experiment**: Select same experiment as Stage 1 (e.g., "rag-experiments")

#### Step 3: Configure Parameters

**Required Parameters:**

| Parameter | Value | Description |
|-----------|-------|-------------|
| `chunks_directory` | `minio://mlpipeline/v2/artifacts/{run_id}/for-loop-1/` | **FROM STAGE 1 OUTPUT** |
| `embedding_endpoint` | `https://granite-embedding-predictor.ai-embedding-service.svc.cluster.local:8443` | Default (don't change) |
| `postgres_host` | `rag-postgresql.external-db-generation-llm-rag.svc.cluster.local` | Default (don't change) |
| `postgres_port` | `5432` | Default (don't change) |
| `postgres_database` | `ragdb` | Default (don't change) |
| `postgres_user` | `raguser` | Default (don't change) |
| `postgres_password` | (from Secret) | Use value from Secret or default |

**Example Values:**
```yaml
chunks_directory: "minio://mlpipeline/v2/artifacts/12345678-abcd-1234-abcd-123456789abc/for-loop-1/"
embedding_endpoint: "https://granite-embedding-predictor.ai-embedding-service.svc.cluster.local:8443"
embedding_batch_size: 32
postgres_host: "rag-postgresql.external-db-generation-llm-rag.svc.cluster.local"
postgres_port: 5432
postgres_database: "ragdb"
postgres_user: "raguser"
postgres_password: "changeme-demo-only"
postgres_table_name: "document_chunks"
```

**Get Secret Values** (if needed):
```bash
oc get secret rag-postgresql-credentials -n ai-generation-llm-rag -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d && echo
# Output: changeme-demo-only (or your custom password)
```

**Optional Parameters** (advanced):

| Parameter | Default | When to Change |
|-----------|---------|----------------|
| `embedding_batch_size` | `32` | Increase to 64 for faster processing (more GPU memory) |
| `postgres_table_name` | `"document_chunks"` | Change for multiple document sets |

#### Step 4: Launch Run

1. **VERIFY** `chunks_directory` path is correct (from Stage 1)
2. Click **Create** button
3. You'll be redirected to the run details page

#### Step 5: Monitor Progress

**Typical stages:**
1. `collect-chunks` (1-2 min) - Merges all chunk files
2. `generate-embeddings` (2-10 min) - Calls granite-embedding service
3. `store-in-pgvector` (1-3 min) - Inserts into PostgreSQL

**Expected Duration**: 5-15 minutes (depends on chunk count)

**Watch for:**
- ✅ `collect-chunks` outputs total chunk count
- ✅ `generate-embeddings` outputs embedding dimension (should be 768)
- ✅ `store-in-pgvector` outputs number of rows inserted

#### Step 6: Verify Embeddings Stored

**After run succeeds:**

```bash
# Check count and dimensions
oc exec -n external-db-generation-llm-rag deployment/rag-postgresql -- \
  psql -U raguser -d ragdb -c \
  "SELECT 
     COUNT(*) AS total_chunks,
     AVG(ARRAY_LENGTH(embedding::real[], 1)) AS avg_embedding_dim
   FROM document_chunks;"

# Expected output:
#  total_chunks | avg_embedding_dim
# --------------+-------------------
#           150 |               768
```

**Test Semantic Search:**

```bash
# Simple test query (see docs/claude/rag-retrieval-guide.md for full examples)
oc exec -n external-db-generation-llm-rag deployment/rag-postgresql -- \
  psql -U raguser -d ragdb -c \
  "SELECT text, source, chunk_index 
   FROM document_chunks 
   LIMIT 3;"
```

---

## Via Python SDK (Advanced)

### Prerequisites

```python
pip install kfp==2.14.6
```

### Complete Two-Stage Run

```python
#!/usr/bin/env python3
"""
Automated two-stage RAG pipeline execution
"""

import kfp
import time

# Configuration
DSPA_HOST = "https://ds-pipeline-pipelines.ai-generation-llm-rag.svc:8443"
TOKEN = open('/var/run/secrets/kubernetes.io/serviceaccount/token').read().strip()

# Create client
client = kfp.Client(host=DSPA_HOST, verify_ssl=False, existing_token=TOKEN)

# Create experiment
try:
    experiment = client.get_experiment(experiment_name="rag-automated")
except:
    experiment = client.create_experiment("rag-automated")

print("=" * 80)
print("STAGE 1: chunk-data Pipeline")
print("=" * 80)

# Stage 1: chunk-data
stage1_run = client.run_pipeline(
    experiment_id=experiment.experiment_id,
    job_name=f"chunk-data-{int(time.time())}",
    pipeline_id=client.get_pipeline_id("chunk-data"),
    params={
        'pdf_filenames': '2203.01017v2.pdf',
        'pdf_base_url': 'https://github.com/docling-project/docling/raw/v2.43.0/tests/data/pdf',
        'docling_chunk_enabled': True,
        'docling_chunk_max_tokens': 512,
        'docling_chunk_merge_peers': True,
        'num_splits': 1,
    }
)

print(f"Stage 1 Run ID: {stage1_run.run_id}")
print("Waiting for Stage 1 to complete...")

# Wait for Stage 1
start_time = time.time()
while True:
    run_detail = client.get_run(stage1_run.run_id)
    status = run_detail.run.status
    
    elapsed = int(time.time() - start_time)
    print(f"  [{elapsed}s] Status: {status}", end='\r')
    
    if status == 'Succeeded':
        print(f"\n✅ Stage 1 completed in {elapsed} seconds")
        break
    elif status in ['Failed', 'Error']:
        print(f"\n❌ Stage 1 failed with status: {status}")
        exit(1)
    
    time.sleep(10)

# Extract chunk artifact path
chunks_directory = f"minio://mlpipeline/v2/artifacts/{stage1_run.run_id}/for-loop-1/"

print("\n" + "=" * 80)
print("STAGE 2: convert-store-embeddings Pipeline")
print("=" * 80)
print(f"Chunks directory: {chunks_directory}")

# Stage 2: convert-store-embeddings
stage2_run = client.run_pipeline(
    experiment_id=experiment.experiment_id,
    job_name=f"convert-store-{int(time.time())}",
    pipeline_id=client.get_pipeline_id("convert-store-embeddings"),
    params={
        'chunks_directory': chunks_directory,
        'embedding_endpoint': 'https://granite-embedding-predictor.ai-embedding-service.svc.cluster.local:8443',
        'embedding_batch_size': 32,
        'postgres_host': 'rag-postgresql.external-db-generation-llm-rag.svc.cluster.local',
        'postgres_port': 5432,
        'postgres_database': 'ragdb',
        'postgres_user': 'raguser',
        'postgres_password': 'changeme-demo-only',
    }
)

print(f"Stage 2 Run ID: {stage2_run.run_id}")
print("Waiting for Stage 2 to complete...")

# Wait for Stage 2
start_time = time.time()
while True:
    run_detail = client.get_run(stage2_run.run_id)
    status = run_detail.run.status
    
    elapsed = int(time.time() - start_time)
    print(f"  [{elapsed}s] Status: {status}", end='\r')
    
    if status == 'Succeeded':
        print(f"\n✅ Stage 2 completed in {elapsed} seconds")
        break
    elif status in ['Failed', 'Error']:
        print(f"\n❌ Stage 2 failed with status: {status}")
        exit(1)
    
    time.sleep(10)

print("\n" + "=" * 80)
print("✅ TWO-STAGE RAG PIPELINE COMPLETED SUCCESSFULLY")
print("=" * 80)
print(f"\nStage 1 Run: {stage1_run.run_id}")
print(f"Stage 2 Run: {stage2_run.run_id}")
print(f"\nNext: Test semantic search (see docs/claude/rag-retrieval-guide.md)")
```

---

## Troubleshooting

### Stage 1: chunk-data

**Error: "Could not download PDF"**
- Check `pdf_base_url` is accessible
- Verify `pdf_filenames` match exactly (case-sensitive)
- For S3: Set `pdf_from_s3: true` and create Secret `data-processing-docling-pipeline`

**Error: "Docling conversion failed"**
- Check pod logs in `docling-convert-standard` task
- Try with `docling_pdf_backend: "pypdfium2"` (simpler backend)
- Verify PDF is not corrupted

**No chunks generated**
- Verify `docling_chunk_enabled: true` (CRITICAL!)
- Check `docling-chunk` task wasn't skipped
- Review task logs

### Stage 2: convert-store-embeddings

**Error: "Chunks directory not found"**
- Verify `chunks_directory` path from Stage 1 output
- Format should be: `minio://mlpipeline/v2/artifacts/{run_id}/for-loop-1/`
- Check ODF storage: `oc get obc pipeline-artifacts -n ai-generation-llm-rag` (should be Bound)
- Verify S3 endpoint: `oc get configmap pipeline-artifacts -n ai-generation-llm-rag -o jsonpath='{.data.BUCKET_HOST}'` (should be s3.openshift-storage.svc)

**Error: "Embedding service timeout"**
- Check embedding service: `oc get inferenceservice granite-embedding -n ai-embedding-service`
- Reduce `embedding_batch_size` to 16
- Check service logs: `oc logs -n ai-embedding-service <predictor-pod>`

**Error: "PostgreSQL connection failed"**
- Check PostgreSQL: `oc get deployment rag-postgresql -n external-db-generation-llm-rag`
- Verify credentials in Secret match parameters
- Check network connectivity: `oc exec -n ai-generation-llm-rag <pod> -- ping rag-postgresql.external-db-generation-llm-rag.svc`

**No data in database after successful run**
- Check task logs: `store-in-pgvector` task
- Verify table name matches parameter
- Query database directly: `SELECT COUNT(*) FROM document_chunks;`

---

## Next Steps

After successfully running both pipelines:

1. **Test Semantic Search**: See `docs/claude/rag-retrieval-guide.md`
2. **Integrate with LLM**: Build RAG application (examples in guide)
3. **Optimize Performance**: Tune batch sizes, HNSW index parameters
4. **Production Hardening**: Replace demo credentials, add monitoring

**Documentation**:
- `docs/claude/rag-retrieval-guide.md` - Semantic search and LLM integration
- `docs/claude/components.md` - Infrastructure details (AI Embedding Service, UC AI Generation LLM RAG)

**Support**:
- Check pipeline logs in RHOAI UI for detailed error messages
- Review ArgoCD application status: `oc get application.argoproj.io -n openshift-gitops`
- Test infrastructure: Use `/tmp/test-complete-rag-infrastructure.py` script
