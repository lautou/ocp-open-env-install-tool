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
- **Endpoint**: `https://granite-embedding-predictor.ai-embedding-service.svc.cluster.local:8443`
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

**Fix**: Added `HF_HOME=/mainctrfs/.cache` environment variable to use DSPA-provided writable cache volume.

**Status**: ✅ Fixed in commit `62cb253` - Pipeline tested and working

## Testing

Infrastructure test script: `/tmp/test-complete-rag-infrastructure.py`
- Test 1: Embedding service validation
- Test 2: PostgreSQL + pgvector validation
- Test 3: End-to-end RAG workflow

All tests passed with semantic search achieving 0.86+ similarity scores.

## Documentation Updates

**2026-04-10**:
- Fixed chunk-data pipeline HuggingFace cache permissions
- Updated to RHOAI 3 navigation (Develop & train → Pipelines)
- Documented ODF OBC storage (vs embedded Minio)
- Configured shared AI Embedding Service in LlamaStack
- Created comprehensive pipeline run guide

## Commits

- `62cb253` - Fix chunk-data pipeline HuggingFace cache permissions
- `5e3bc6c` - Document ODF OBC storage for RAG pipelines
- `c38a634` - Use shared AI Embedding Service in LlamaStack
- `23d4d3a` - Fix pipeline upload script for multi-document YAML

---

**Status**: ✅ All infrastructure deployed and tested
**Pipelines**: ✅ Ready for production use
**Documentation**: ✅ Complete
