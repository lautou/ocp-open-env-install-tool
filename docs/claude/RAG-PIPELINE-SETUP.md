# RAG Pipeline Setup Summary

Complete documentation for the RAG (Retrieval-Augmented Generation) pipeline infrastructure.

## Quick Links

- **Pipeline Run Guide**: [rag-pipeline-run-guide.md](rag-pipeline-run-guide.md) - Step-by-step instructions
- **Retrieval Guide**: [rag-retrieval-guide.md](rag-retrieval-guide.md) - Semantic search and LLM integration
- **Component Details**: [components.md](components.md) - Infrastructure configuration (AI Embedding Service, UC AI Generation LLM RAG sections)

## Overview

Two-stage RAG pipeline for document processing and semantic search:

1. **Stage 1: chunk-data** - Convert PDFs to semantic chunks using Docling
2. **Stage 2: convert-store-embeddings** - Generate embeddings and store in PostgreSQL + pgvector

## Infrastructure

### AI Embedding Service
- **Model**: granite-embedding-english-r2 (768 dimensions)
- **Hardware**: 1 Tesla T4 GPU (shared service)
- **Endpoint**: `https://granite-embedding-predictor.ai-models-service.svc.cluster.local:8443`
- **Pattern**: Shared service architecture (one GPU serves multiple consumers)

### UC AI Generation LLM RAG
- **Namespaces**: 
  - `ai-generation-llm-rag` - DSPA and pipeline execution
  - `external-db-generation-llm-rag` - External databases (MariaDB, PostgreSQL)
- **Storage**: ODF ObjectBucketClaim (`pipeline-artifacts` → `ai-generation-llm-rag-pipelines`)
- **Database**: PostgreSQL 16 + pgvector 0.8.2 (HNSW indexing)

## Pipelines

### chunk-data Pipeline
- **Source**: opendatahub-io/data-processing (upstream)
- **Fix Applied**: HF_HOME environment variable for OpenShift compatibility (commit `62cb253`)
- **Input**: PDF URLs or S3 paths
- **Output**: Semantic chunks in ODF storage
- **Duration**: 10-20 minutes

### convert-store-embeddings Pipeline
- **Source**: Custom (project-specific)
- **Input**: Chunks from Stage 1
- **Output**: 768-dim embeddings in PostgreSQL `document_chunks` table
- **Duration**: 5-15 minutes

## Key Features

- ✅ Production-ready ODF storage (no embedded Minio)
- ✅ Shared GPU embedding service (resource efficient)
- ✅ PostgreSQL + pgvector with HNSW indexing (fast semantic search)
- ✅ GitOps deployment with ArgoCD
- ✅ Pipeline upload automation via PostSync Jobs

## Getting Started

1. **Prerequisites**: Verify infrastructure (see [rag-pipeline-run-guide.md](rag-pipeline-run-guide.md#prerequisites-checklist))
2. **Access Dashboard**: RHOAI Dashboard → Develop & train → Pipelines
3. **Run Stage 1**: chunk-data pipeline (convert PDFs to chunks)
4. **Run Stage 2**: convert-store-embeddings pipeline (generate embeddings)
5. **Test Search**: See [rag-retrieval-guide.md](rag-retrieval-guide.md) for examples

## Known Issues

### HuggingFace Cache Permission Error (FIXED)

**Problem**: Pipeline failed with `PermissionError: /tmp/hub/models--sentence-transformers--all-MiniLM-L6-v2`

**Root Cause**: Red Hat Docling image sets `HF_HOME=/tmp/`, but OpenShift restricts `/tmp/` write access for non-root pods.

**Fix Applied** (2 parts):

1. **Container spec location** (commit `04cde66`):
   - RHOAI KFP v2 requires env variables in executor container spec, not platform spec
   - Moved `HF_HOME` from `platforms.kubernetes.deploymentSpec.executors` to `executors.exec-docling-chunk.container`
   - Error without fix: `failed to unmarshal kubernetes config: proto: unknown field "env"`

2. **Correct cache path** (commit `d254ba6`):
   - Changed `HF_HOME` from `/mainctrfs/.cache` to `/.cache`
   - DSPA mounts `dot-cache-scratch` volume at `/.cache` (not `/mainctrfs/.cache`)
   - Error without fix: `PermissionError: [Errno 13] Permission denied: '/mainctrfs'`

**Status**: ✅ Fixed and tested successfully (2026-04-10)
- Pipeline run: chunk-data-6ckcz
- Duration: 5 minutes 24 seconds
- All 8 test PDFs converted and chunked successfully

## Testing

### Infrastructure Tests
Infrastructure test script: `/tmp/test-complete-rag-infrastructure.py`
- Test 1: Embedding service validation ✅
- Test 2: PostgreSQL + pgvector validation ✅
- Test 3: End-to-end RAG workflow ✅

All tests passed with semantic search achieving 0.86+ similarity scores.

### Pipeline Execution Tests

**chunk-data Pipeline** (Stage 1: PDF to chunks):
- Run ID: chunk-data-6ckcz
- Status: ✅ Succeeded
- Duration: 5 minutes 24 seconds
- Processed: 8 test PDFs
- Output: 8 JSONL files with 161 semantic chunks
- Test Date: 2026-04-10

**Key Validation**:
- ✅ PDF download from GitHub
- ✅ Docling model downloads (CodeFormulaV2, etc.)
- ✅ PDF to JSON conversion with OCR (3 parallel tasks)
- ✅ Semantic chunking with HuggingFace tokenizer (3 parallel tasks)
- ✅ HF_HOME cache fix working correctly
- ✅ Output stored in ODF (s3://ai-generation-llm-rag-pipelines)

**convert-store-embeddings Pipeline** (Stage 2: Embeddings to vector database):
- Run ID: convert-store-embeddings-8fg6z
- Status: ✅ Succeeded
- Duration: 4 minutes 16 seconds
- Input: 161 chunks from chunk-data-6ckcz
- Output: 161 rows with 768-dim embeddings in PostgreSQL
- Test Date: 2026-04-10

**Key Validation**:
- ✅ Stage 1 (collect-chunks): Merged 161 chunks from 8 JSONL files
- ✅ Stage 2 (generate-embeddings): Generated 768-dim embeddings via granite-embedding-english-r2
- ✅ RBAC fix working: pipeline-runner-pipelines SA has access to ai-models-service
- ✅ Stage 3 (store-in-pgvector): Inserted 161 rows into document_chunks table
- ✅ PostgreSQL + pgvector: Table with HNSW index, 768-dim vectors
- ✅ End-to-end semantic search: 0.89-0.90 similarity scores for relevant queries

**Database Verification**:
```sql
-- Total chunks: 161
-- Embedding dimensions: 768
-- Table size: 1608 kB
-- HNSW index: document_chunks_embedding_idx (cosine similarity)
```

**Semantic Search Test**:
- Query: "What is table detection?"
- Top result similarity: 0.9007 (chunk about table structure recognition)
- Results span 2 source documents (2203.01017v2.json, 2305.03393v1.json)
- All results semantically relevant to table detection/recognition

## Documentation Updates

**2026-04-10**:
- Fixed chunk-data pipeline HuggingFace cache permissions (2 critical fixes)
- RHOAI KFP v2 compatibility: env in container spec (not platform spec)
- Correct DSPA cache path: HF_HOME=/.cache (not /mainctrfs/.cache)
- Fixed RBAC for ai-models-service: Added pipeline-runner-pipelines ServiceAccount
- Successfully tested complete end-to-end RAG pipeline (both stages)
- chunk-data pipeline: 5m24s, 161 chunks generated
- convert-store-embeddings pipeline: 4m16s, 161 embeddings stored in PostgreSQL
- Verified semantic search with 0.90 similarity scores
- Updated to RHOAI 3 navigation (Develop & train → Pipelines)
- Documented ODF OBC storage (vs embedded Minio)
- Configured shared AI Embedding Service in LlamaStack
- Created comprehensive pipeline run guide

## Commits

- `eae505d` - Fix RBAC: Add pipeline-runner-pipelines SA to ai-models-service access
- `d254ba6` - Fix HF_HOME path to use actual DSPA cache mount location (/.cache)
- `04cde66` - Fix chunk-data pipeline HF_HOME env for RHOAI KFP v2 compatibility
- `62cb253` - Fix chunk-data pipeline HuggingFace cache permissions (initial attempt)
- `5e3bc6c` - Document ODF OBC storage for RAG pipelines
- `c38a634` - Use shared AI Embedding Service in LlamaStack
- `23d4d3a` - Fix pipeline upload script for multi-document YAML

---

**Status**: ✅ All infrastructure deployed and tested
**Pipelines**: ✅ Ready for production use
**Documentation**: ✅ Complete
