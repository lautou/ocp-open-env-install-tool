# RAG Retrieval Guide

**Purpose**: Complete guide for implementing Retrieval-Augmented Generation (RAG) using the chunk-data and convert-store-embeddings pipelines with granite-embedding and pgvector.

**Related Documentation**:
- `components.md` - Infrastructure setup (AI Embedding Service, UC AI Generation LLM RAG)
- `AUDIT.md` - Complete project structure and architecture

---

## Overview

**RAG Architecture**: Two-stage pipeline + semantic search retrieval.

```
┌─────────────────────────────────────────────────────────────────────┐
│ Stage 1: chunk-data Pipeline                                        │
│ PDFs → Docling Conversion → Semantic Chunking → JSONL Files        │
└──────────────────────────┬──────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Stage 2: convert-store-embeddings Pipeline                          │
│ JSONL Files → granite-embedding (768-dim) → PostgreSQL + pgvector   │
└──────────────────────────┬──────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Retrieval: Semantic Search                                          │
│ User Query → Embedding → Cosine Similarity → Top-K Documents        │
└──────────────────────────┬──────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Generation: LLM with Context                                        │
│ Retrieved Docs + Query → LLM → Grounded Answer                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Running the Pipelines

### Prerequisites

1. ✅ AI Embedding Service deployed and ready
2. ✅ PostgreSQL + pgvector database running
3. ✅ DSPA (Data Science Pipelines Application) deployed
4. ✅ Both pipelines uploaded to DSPA

**Verification**:
```bash
# Check embedding service
oc get inferenceservice granite-embedding -n ai-models-service

# Check PostgreSQL
oc get deployment rag-postgresql -n external-db-generation-llm-rag

# Check DSPA
oc get dspa pipelines -n ai-generation-llm-rag

# Check pipelines (via RHOAI UI or API)
# Navigate to: RHOAI Dashboard → Data Science Pipelines → ai-generation-llm-rag
```

### Stage 1: chunk-data Pipeline

**Purpose**: Convert PDFs to semantic chunks.

#### Via RHOAI Dashboard

1. Navigate to **Data Science Pipelines** → `ai-generation-llm-rag` project
2. Click **Pipelines** tab → Find `chunk-data` pipeline
3. Click **Create run**
4. Configure parameters:

```yaml
# Required Parameters
pdf_filenames: "your-document.pdf,another-doc.pdf"  # Comma-separated list
pdf_base_url: "https://your-storage.com/pdfs"  # Base URL for PDF downloads

# Chunking (REQUIRED for RAG)
docling_chunk_enabled: true  # MUST be true
docling_chunk_max_tokens: 512  # Chunk size (adjust based on LLM context)
docling_chunk_merge_peers: true  # Merge small adjacent chunks

# Processing
num_splits: 3  # Parallel splits (faster for large PDF sets)

# Optional: Docling settings
docling_pdf_backend: "dlparse_v4"  # Default
docling_table_mode: "accurate"  # Extract tables accurately
docling_ocr: true  # Enable OCR for scanned PDFs
docling_num_threads: 4  # Threads per document
```

5. Click **Create** to start the run
6. Monitor progress in **Runs** tab
7. Wait for Status: **Succeeded** (typically 5-15 minutes depending on PDF count/size)

#### Via Python SDK

```python
import kfp

# Connect to DSPA
client = kfp.Client(
    host="https://ds-pipeline-pipelines.ai-generation-llm-rag.svc:8443",
    verify_ssl=False,
    existing_token=open('/var/run/secrets/kubernetes.io/serviceaccount/token').read()
)

# Get pipeline ID
pipeline_id = client.get_pipeline_id("chunk-data")

# Create experiment
experiment = client.create_experiment("rag-experiments")

# Submit run
run = client.run_pipeline(
    experiment_id=experiment.experiment_id,
    job_name=f"chunk-pdfs-{int(time.time())}",
    pipeline_id=pipeline_id,
    params={
        'pdf_filenames': '2203.01017v2.pdf',
        'pdf_base_url': 'https://github.com/docling-project/docling/raw/v2.43.0/tests/data/pdf',
        'docling_chunk_enabled': True,
        'docling_chunk_max_tokens': 512,
        'num_splits': 1,
    }
)

print(f"Run ID: {run.run_id}")
print(f"Monitor at: https://rhoai-dashboard.../pipelines/runs/details/{run.run_id}")
```

#### Extracting Chunk Output Path

**Method 1: Via RHOAI UI**
1. Open the completed run
2. Navigate to **Artifacts** tab
3. Find the `docling-chunk` task output
4. Copy the artifact URI (format: `minio://mlpipeline/v2/artifacts/{run_id}/...`)

**Method 2: Via Python SDK**
```python
# Get run details
run_detail = client.get_run(run.run_id)

# Extract artifact path (simplified - actual path in run metadata)
# For Stage 2, you can use the run output directory
chunks_directory = f"minio://mlpipeline/v2/artifacts/{run.run_id}/for-loop-1/"
```

**Method 3: Manual Minio Access** (if configured)
```bash
# Access Minio console or CLI
mc ls minio/mlpipeline/v2/artifacts/{run_id}/
```

---

### Stage 2: convert-store-embeddings Pipeline

**Purpose**: Generate embeddings and store in pgvector.

#### Via RHOAI Dashboard

1. Navigate to **Data Science Pipelines** → `ai-generation-llm-rag` project
2. Click **Pipelines** tab → Find `convert-store-embeddings` pipeline
3. Click **Create run**
4. Configure parameters:

```yaml
# Required: Input from Stage 1
chunks_directory: "minio://mlpipeline/v2/artifacts/{stage1_run_id}/for-loop-1/"

# Embedding Configuration
embedding_endpoint: "https://granite-embedding-predictor.ai-models-service.svc.cluster.local:8443"
embedding_batch_size: 32  # Optimize for GPU (16-64 recommended)

# PostgreSQL Configuration (from Secret)
postgres_host: "rag-postgresql.external-db-generation-llm-rag.svc.cluster.local"
postgres_port: 5432
postgres_database: "ragdb"
postgres_user: "raguser"
postgres_password: "changeme-demo-only"  # From Secret in production
postgres_table_name: "document_chunks"
```

5. Click **Create** to start the run
6. Monitor progress (typically 2-10 minutes depending on chunk count)
7. Wait for Status: **Succeeded**

#### Via Python SDK

```python
# Submit Stage 2 run
run2 = client.run_pipeline(
    experiment_id=experiment.experiment_id,
    job_name=f"embed-store-{int(time.time())}",
    pipeline_id=client.get_pipeline_id("convert-store-embeddings"),
    params={
        'chunks_directory': chunks_directory,  # From Stage 1
        'embedding_endpoint': 'https://granite-embedding-predictor.ai-models-service.svc.cluster.local:8443',
        'embedding_batch_size': 32,
        'postgres_host': 'rag-postgresql.external-db-generation-llm-rag.svc.cluster.local',
        'postgres_port': 5432,
        'postgres_database': 'ragdb',
        'postgres_user': 'raguser',
        'postgres_password': 'changeme-demo-only',
    }
)

print(f"Run ID: {run2.run_id}")
```

#### Verification

```bash
# Check embeddings were stored
oc exec -n external-db-generation-llm-rag deployment/rag-postgresql -- \
  psql -U raguser -d ragdb -c \
  "SELECT COUNT(*), AVG(ARRAY_LENGTH(embedding::real[], 1)) AS avg_dim FROM document_chunks;"

# Expected output:
#  count | avg_dim
# -------+---------
#    150 |     768
```

---

## Semantic Search Retrieval

### Basic Retrieval Flow

```python
#!/usr/bin/env python3
"""
RAG Retrieval Example: Semantic search with granite-embedding + pgvector
"""

import requests
import psycopg2
from pgvector.psycopg2 import register_vector

# Configuration
EMBEDDING_ENDPOINT = "https://granite-embedding-predictor.ai-models-service.svc.cluster.local:8443"
POSTGRES_HOST = "rag-postgresql.external-db-generation-llm-rag.svc.cluster.local"
POSTGRES_PORT = 5432
POSTGRES_DB = "ragdb"
POSTGRES_USER = "raguser"
POSTGRES_PASSWORD = "changeme-demo-only"

# Read ServiceAccount token (when running in cluster)
with open('/var/run/secrets/kubernetes.io/serviceaccount/token', 'r') as f:
    token = f.read().strip()

def retrieve_documents(query: str, top_k: int = 5, similarity_threshold: float = 0.7):
    """
    Retrieve top-K documents semantically similar to query.
    
    Args:
        query: User query text
        top_k: Number of results to return
        similarity_threshold: Minimum cosine similarity (0-1)
    
    Returns:
        List of (text, source, similarity) tuples
    """
    # Step 1: Generate query embedding
    print(f"Generating embedding for query: '{query}'")
    
    response = requests.post(
        f"{EMBEDDING_ENDPOINT}/v1/embeddings",
        headers={"Authorization": f"Bearer {token}"},
        json={"input": [query], "model": "granite-embedding"},
        verify=False  # Self-signed cert
    )
    response.raise_for_status()
    
    query_embedding = response.json()['data'][0]['embedding']
    print(f"✓ Embedding generated (dimension: {len(query_embedding)})")
    
    # Step 2: Semantic search in pgvector
    conn = psycopg2.connect(
        host=POSTGRES_HOST,
        port=POSTGRES_PORT,
        database=POSTGRES_DB,
        user=POSTGRES_USER,
        password=POSTGRES_PASSWORD
    )
    register_vector(conn)
    cursor = conn.cursor()
    
    # Cosine similarity search with HNSW index
    cursor.execute("""
        SELECT 
            text,
            source,
            chunk_index,
            1 - (embedding <=> %s::vector) AS similarity
        FROM document_chunks
        WHERE 1 - (embedding <=> %s::vector) > %s
        ORDER BY embedding <=> %s::vector
        LIMIT %s
    """, (query_embedding, query_embedding, similarity_threshold, query_embedding, top_k))
    
    results = cursor.fetchall()
    cursor.close()
    conn.close()
    
    print(f"✓ Found {len(results)} documents (similarity > {similarity_threshold})")
    return results

# Example usage
if __name__ == "__main__":
    query = "How do I deploy machine learning models in OpenShift AI?"
    
    results = retrieve_documents(query, top_k=5, similarity_threshold=0.7)
    
    print("\nTop Results:")
    for i, (text, source, chunk_idx, similarity) in enumerate(results, 1):
        print(f"\n{i}. Similarity: {similarity:.4f}")
        print(f"   Source: {source} (chunk {chunk_idx})")
        print(f"   Text: {text[:200]}...")  # First 200 chars
```

### Advanced: Filtered Retrieval

```python
def retrieve_with_metadata_filter(query: str, source_filter: str = None, top_k: int = 5):
    """
    Retrieve documents with metadata filtering.
    
    Example: Only retrieve from specific document sources
    """
    # Generate query embedding (same as above)
    # ...
    
    # Semantic search with source filter
    if source_filter:
        cursor.execute("""
            SELECT text, source, 1 - (embedding <=> %s::vector) AS similarity
            FROM document_chunks
            WHERE source LIKE %s
              AND 1 - (embedding <=> %s::vector) > 0.7
            ORDER BY embedding <=> %s::vector
            LIMIT %s
        """, (query_embedding, f"%{source_filter}%", query_embedding, query_embedding, top_k))
    else:
        # No filter (same as basic retrieval)
        pass
    
    return cursor.fetchall()

# Example: Only retrieve from "deployment_guide.pdf"
results = retrieve_with_metadata_filter(
    query="How to configure GPU resources?",
    source_filter="deployment_guide.pdf",
    top_k=3
)
```

### Advanced: Hybrid Search (Semantic + Keyword)

```python
def hybrid_search(query: str, keywords: list, top_k: int = 10):
    """
    Combine semantic similarity with keyword matching.
    
    Useful for technical queries where exact terms matter.
    """
    # Generate query embedding
    # ...
    
    # Hybrid query: Semantic + Full-Text Search
    cursor.execute("""
        SELECT 
            text,
            source,
            1 - (embedding <=> %s::vector) AS semantic_similarity,
            ts_rank(to_tsvector('english', text), to_tsquery('english', %s)) AS keyword_rank
        FROM document_chunks
        WHERE 
            to_tsvector('english', text) @@ to_tsquery('english', %s)
            OR 1 - (embedding <=> %s::vector) > 0.6
        ORDER BY 
            (0.7 * (1 - (embedding <=> %s::vector))) + 
            (0.3 * ts_rank(to_tsvector('english', text), to_tsquery('english', %s)))
            DESC
        LIMIT %s
    """, (
        query_embedding, 
        ' & '.join(keywords),  # Keyword query
        ' & '.join(keywords),
        query_embedding,
        query_embedding,
        ' & '.join(keywords),
        top_k
    ))
    
    return cursor.fetchall()

# Example: Find GPU configuration docs
results = hybrid_search(
    query="GPU configuration for model deployment",
    keywords=["GPU", "nvidia", "deployment"],
    top_k=5
)
```

---

## LLM Integration

### Complete RAG Flow with LLM

```python
def rag_query(user_question: str, llm_endpoint: str, top_k: int = 3):
    """
    Complete RAG: Retrieve documents + Generate answer with LLM.
    """
    # Step 1: Retrieve relevant documents
    print(f"User Question: {user_question}\n")
    print("Step 1: Retrieving relevant documents...")
    
    results = retrieve_documents(user_question, top_k=top_k, similarity_threshold=0.7)
    
    if not results:
        return "No relevant documents found. Please rephrase your question."
    
    # Step 2: Build context from retrieved documents
    context_parts = []
    for i, (text, source, chunk_idx, similarity) in enumerate(results, 1):
        context_parts.append(f"[Document {i}] (Source: {source}, Similarity: {similarity:.2f})\n{text}\n")
    
    context = "\n".join(context_parts)
    
    print(f"✓ Retrieved {len(results)} documents")
    print(f"\nStep 2: Generating answer with LLM...")
    
    # Step 3: Create LLM prompt with context
    prompt = f"""You are a helpful AI assistant. Answer the user's question based on the provided context.

Context:
{context}

User Question: {user_question}

Instructions:
- Answer based ONLY on the provided context
- If the context doesn't contain enough information, say so
- Cite the document number when referencing information (e.g., "According to Document 1...")
- Be concise and factual

Answer:"""
    
    # Step 4: Call LLM (example with OpenAI-compatible API)
    response = requests.post(
        f"{llm_endpoint}/v1/chat/completions",
        headers={"Authorization": f"Bearer {token}"},
        json={
            "model": "granite-7b-instruct",  # Or your model
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": 512,
            "temperature": 0.3,  # Lower temperature for factual answers
        },
        verify=False
    )
    response.raise_for_status()
    
    answer = response.json()['choices'][0]['message']['content']
    
    print(f"✓ Answer generated\n")
    return answer, results

# Example usage
question = "What GPU types are supported for model serving in OpenShift AI?"

answer, sources = rag_query(
    user_question=question,
    llm_endpoint="https://granite-7b-predictor.ai-models.svc.cluster.local:8443",
    top_k=3
)

print("=" * 80)
print("ANSWER:")
print(answer)
print("\n" + "=" * 80)
print("SOURCES:")
for i, (text, source, chunk_idx, sim) in enumerate(sources, 1):
    print(f"\n{i}. {source} (chunk {chunk_idx}) - Similarity: {sim:.4f}")
    print(f"   {text[:150]}...")
```

### Streaming LLM Response

```python
def rag_query_streaming(user_question: str, llm_endpoint: str, top_k: int = 3):
    """
    RAG with streaming LLM response (better UX for long answers).
    """
    # Retrieve documents (same as above)
    results = retrieve_documents(user_question, top_k=top_k)
    context = build_context(results)
    prompt = create_rag_prompt(context, user_question)
    
    # Stream LLM response
    response = requests.post(
        f"{llm_endpoint}/v1/chat/completions",
        headers={"Authorization": f"Bearer {token}"},
        json={
            "model": "granite-7b-instruct",
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": 512,
            "temperature": 0.3,
            "stream": True,  # Enable streaming
        },
        verify=False,
        stream=True
    )
    
    print("Answer: ", end="", flush=True)
    for line in response.iter_lines():
        if line:
            data = json.loads(line.decode('utf-8').removeprefix('data: '))
            if 'choices' in data and len(data['choices']) > 0:
                delta = data['choices'][0].get('delta', {})
                if 'content' in delta:
                    print(delta['content'], end="", flush=True)
    
    print()  # Newline after streaming complete
```

---

## Performance Optimization

### Embedding Batch Size

**Recommendation**: Batch 16-64 chunks per request for optimal GPU utilization.

```python
# ❌ Bad: One request per chunk (slow)
for chunk in chunks:
    embedding = generate_embedding([chunk])

# ✅ Good: Batch requests
batch_size = 32
for i in range(0, len(chunks), batch_size):
    batch = chunks[i:i + batch_size]
    embeddings = generate_embedding(batch)
```

### HNSW Index Tuning

**Default**: Good for most use cases (<100K vectors).

**Large Datasets** (>100K vectors):
```sql
-- Rebuild index with custom parameters
DROP INDEX document_chunks_embedding_idx;

CREATE INDEX document_chunks_embedding_idx
ON document_chunks 
USING hnsw (embedding vector_cosine_ops)
WITH (m = 16, ef_construction = 64);

-- m: Max connections per node (higher = better recall, more memory)
-- ef_construction: Search effort during index build (higher = better quality, slower build)
```

**Query-Time Parameters**:
```sql
-- Increase search accuracy (slower but better results)
SET hnsw.ef_search = 100;  -- Default: 40

-- Then run your search query
SELECT ... WHERE 1 - (embedding <=> query_emb) > 0.7 ...
```

### Caching Query Embeddings

```python
from functools import lru_cache

@lru_cache(maxsize=1000)
def get_query_embedding(query: str):
    """Cache query embeddings for repeated searches."""
    # Generate embedding (same as above)
    return embedding

# Subsequent calls with same query use cached embedding
emb1 = get_query_embedding("How to deploy models?")  # API call
emb2 = get_query_embedding("How to deploy models?")  # Cached (no API call)
```

---

## Production Considerations

### Security

**Authentication**:
- ✅ ServiceAccount tokens for service-to-service (granite-embedding)
- ✅ PostgreSQL password from Secret (not hardcoded)
- ❌ **Never commit credentials to Git** (use AWS Secrets Manager or Vault)

**Network**:
- ✅ Internal service endpoints only (no public exposure)
- ✅ mTLS via KServe service mesh
- ✅ Network policies for namespace isolation (if enabled)

### Monitoring

**Metrics to Track**:
- Embedding service latency (p50, p95, p99)
- PostgreSQL query latency
- Semantic search result relevance (via user feedback)
- LLM response time
- Cache hit rate (if caching query embeddings)

**Example Prometheus Queries**:
```promql
# Embedding service request rate
rate(vllm_request_success_total{model="granite-embedding"}[5m])

# PostgreSQL active connections
pg_stat_activity_count{namespace="external-db-generation-llm-rag"}

# Semantic search latency (custom metric)
histogram_quantile(0.95, rate(rag_search_duration_seconds_bucket[5m]))
```

### Scalability

**Embedding Service**:
- Horizontal scaling: Add HPA based on GPU utilization
- Vertical scaling: Larger GPU for bigger batches

**PostgreSQL**:
- Read replicas for query scaling
- Connection pooling (PgBouncer)
- Partitioning by source/date for large datasets (>1M vectors)

**HNSW Index**:
- Rebuilds recommended after 10-20% data growth
- Consider IVFFlat for datasets >10M vectors (different trade-offs)

### Data Refresh

**Incremental Updates**:
```python
def update_document(document_id: str, new_text: str):
    """Update a single document's embedding."""
    # Generate new embedding
    new_embedding = generate_embedding([new_text])[0]
    
    # Update in database
    cursor.execute("""
        UPDATE document_chunks
        SET text = %s, embedding = %s, updated_at = NOW()
        WHERE id = %s
    """, (new_text, new_embedding, document_id))
    
    conn.commit()
```

**Batch Reindexing**:
- Re-run chunk-data + convert-store-embeddings pipelines
- Use `TRUNCATE document_chunks` before Stage 2 for full refresh
- Or use upsert logic with `ON CONFLICT` for incremental updates

---

## Troubleshooting

### No Results Returned

**Cause**: Similarity threshold too high or query embedding mismatch.

**Solution**:
```python
# Debug: Check raw similarities without threshold
cursor.execute("""
    SELECT text, 1 - (embedding <=> %s::vector) AS similarity
    FROM document_chunks
    ORDER BY embedding <=> %s::vector
    LIMIT 10
""", (query_embedding, query_embedding))

# Expected: Top results should have similarity > 0.5
# If all results < 0.3, check:
# 1. Query phrasing (try rephrasing)
# 2. Embedding service (verify 768-dim vectors)
# 3. Data quality (chunks too short/long?)
```

### Slow Semantic Search

**Cause**: HNSW index not used or table scan.

**Solution**:
```sql
-- Verify index exists
\d+ document_chunks

-- Force index usage
SET enable_seqscan = off;

-- Check query plan
EXPLAIN ANALYZE
SELECT ...
FROM document_chunks
WHERE 1 - (embedding <=> query_emb) > 0.7
LIMIT 10;

-- Expected: "Index Scan using document_chunks_embedding_idx"
```

### Embedding Service Timeouts

**Cause**: Batch size too large or service overloaded.

**Solution**:
```python
# Reduce batch size
embedding_batch_size = 16  # Instead of 32

# Add timeout and retry logic
import time

max_retries = 3
for attempt in range(max_retries):
    try:
        response = requests.post(..., timeout=60)
        break
    except requests.Timeout:
        if attempt == max_retries - 1:
            raise
        time.sleep(2 ** attempt)  # Exponential backoff
```

---

## Example Applications

### Document Q&A Service

```python
from flask import Flask, request, jsonify

app = Flask(__name__)

@app.route('/api/ask', methods=['POST'])
def ask():
    """API endpoint for document Q&A."""
    question = request.json['question']
    
    # RAG query
    answer, sources = rag_query(question, llm_endpoint=LLM_ENDPOINT, top_k=3)
    
    return jsonify({
        'answer': answer,
        'sources': [
            {'text': text, 'source': source, 'similarity': float(sim)}
            for text, source, _, sim in sources
        ]
    })

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080)
```

### Chatbot with Conversation History

```python
def chatbot_rag(user_message: str, conversation_history: list):
    """
    RAG chatbot that maintains conversation context.
    """
    # Retrieve relevant documents for current message
    results = retrieve_documents(user_message, top_k=3)
    context = build_context(results)
    
    # Build messages with history
    messages = conversation_history + [
        {"role": "system", "content": f"Context:\n{context}"},
        {"role": "user", "content": user_message}
    ]
    
    # Call LLM
    response = requests.post(
        f"{LLM_ENDPOINT}/v1/chat/completions",
        json={"model": "granite-7b-instruct", "messages": messages}
    )
    
    assistant_message = response.json()['choices'][0]['message']['content']
    
    # Update conversation history
    conversation_history.append({"role": "user", "content": user_message})
    conversation_history.append({"role": "assistant", "content": assistant_message})
    
    return assistant_message, conversation_history

# Usage
history = []
response1, history = chatbot_rag("What is OpenShift AI?", history)
response2, history = chatbot_rag("How do I deploy models in it?", history)  # "it" refers to OpenShift AI from context
```

---

## Additional Resources

**Related Documentation**:
- `components.md` - AI Embedding Service and UC AI Generation LLM RAG infrastructure
- `jobs.md` - Pipeline upload Jobs and ArgoCD hooks
- `AUDIT.md` - Complete project architecture

**External Links**:
- [granite-embedding Model](https://huggingface.co/ibm-granite/granite-embedding-english-r2) - Model details
- [pgvector Documentation](https://github.com/pgvector/pgvector) - Vector extension for PostgreSQL
- [Docling Project](https://github.com/docling-project/docling) - Document processing library
- [KFP v2 Documentation](https://www.kubeflow.org/docs/components/pipelines/v2/) - Kubeflow Pipelines v2

**Testing**:
- End-to-end test suite: `/tmp/test-complete-rag-infrastructure.py`
- Test results: `/tmp/RAG-PIPELINE-E2E-TEST-RESULTS.md`
