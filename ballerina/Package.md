# PgVector - PostgreSQL Vector Database Client for Ballerina

## Overview
This module provides functionality to interact with PostgreSQL using the `pgvector` extension, enabling vector similarity search capabilities in Ballerina applications. It supports storing and searching high-dimensional vectors alongside metadata with collection-based organization, making it ideal for AI/ML applications, semantic search, and recommendation systems.

## Prerequisites

Before using this module, ensure you have:

1. PostgreSQL server with the `pgvector` extension installed.
2. PostgreSQL database credentials.
3. Knowledge of vector dimensions for your use case (e.g., 1536 for OpenAI embeddings).

To install the `pgvector` extension in PostgreSQL:

```sql
CREATE EXTENSION vector;
```

## Features

- Collection-based vector organization
- Vector storage with metadata
- Multiple similarity search types (Cosine Distance, Euclidean Distance, Negative Inner Product)
- Metadata filtering and updates
- Automatic index creation for performance
- HNSW indexing support
- Type-safe operations
- Distance scoring in search results

## Quick Start

### 1. Import the Module

```ballerina
import wso2/pgvector;
```

### 2. Initialize Vector Store

```ballerina
// Configure connection
ConnectionConfig connectionConfig = {
    host: "localhost",
    user: "postgres",
    password: "password",
    database: "vectordb",
    port: 5432
};

// Initialize vector store
VectorStore vectorStore = check new(
    connectionConfig,
    vectorDimension = 1536  // dimension size of your vectors
);
```

### 3. Add Vectors

```ballerina
// Create vector data
VectorData data = {
    embedding: [0.1, 0.2, 0.3], // your vector embedding
    document: "Sample document text",
    metadata: {
        "name": "Example",
        "category": "test"
    }
};

// Add to vector store with collection name
VectorDataWithId result = check vectorStore.addVector(data, "my_collection");
```

### 4. Search Vectors

```ballerina
// Define search configuration
SearchConfig config = {
    similarityType: COSINE_DISTANCE,  // COSINE_DISTANCE, EUCLIDEAN_DISTANCE, or NEGATIVE_INNER_PRODUCT
    'limit: 10,
    threshold: 0.8,
    metadata: {
        "category": "test"
    }
};

// Perform similarity search
float[] queryVector = [0.1, 0.2, 0.3];
VectorDataWithDistance[] results = check vectorStore.searchVector(queryVector, "my_collection", config);

// Access results with distance scores
foreach VectorDataWithDistance result in results {
    log:printInfo(string `Document: ${result.document}, Distance: ${result.distance}`);
}
```

## Types and Enums

### SimilarityType
Defines the type of similarity measure to use:

```ballerina
public enum SimilarityType {
    EUCLIDEAN_DISTANCE = "<->",    // L2 distance
    COSINE_DISTANCE = "<=>",       // Cosine distance  
    NEGATIVE_INNER_PRODUCT = "<#>" // Negative inner product
}
```

### VectorData
Structure for vector data without an ID:

```ballerina
public type VectorData record {|
    float[] embedding;    // Vector embedding
    string document;      // Associated document text
    map<json> metadata?;  // Optional metadata
|};
```

### VectorDataWithId
Structure for vector data with an ID:

```ballerina
public type VectorDataWithId record {|
    int id;
    *VectorData;
|};
```

### VectorDataWithDistance
Structure for vector data with distance score:

```ballerina
public type VectorDataWithDistance record {|
    *VectorDataWithId;
    float distance;  // Distance score from similarity search
|};
```

### SearchConfig
Configuration for vector search:

```ballerina
public type SearchConfig record {|
    SimilarityType similarityType = COSINE_DISTANCE;
    int 'limit = 10;
    float? threshold = ();  // Optional threshold
    map<sql:Value> metadata = {};
|};
```

### ConnectionConfig
Configuration for database connection:

```ballerina
public type ConnectionConfig record {|
    string host;
    string user;
    string password;
    string database;
    int port = 5432;
|};
```

## Advanced Usage

### 1. Collection Management
Organize vectors into collections for better data management:

```ballerina
// Add vectors to different collections
VectorDataWithId userVector = check vectorStore.addVector(userData, "users");
VectorDataWithId productVector = check vectorStore.addVector(productData, "products");

// Search within specific collections
VectorDataWithDistance[] userResults = check vectorStore.searchVector(queryVector, "users");
VectorDataWithDistance[] productResults = check vectorStore.searchVector(queryVector, "products");
```

### 2. Metadata Operations

#### Filtering by Metadata
```ballerina
// Search with metadata filters
map<sql:Value> metadata = {
    "category": "technology",
    "author": "John Doe"
};

VectorDataWithId[] results = check vectorStore.fetchVectorByMetadata(metadata, "documents");
```

#### Checking Existence
```ballerina
// Check if vectors with specific metadata exist
boolean exists = check vectorStore.existsByMetadata({"category": "tech"}, "documents");
```

#### Updating Metadata
```ballerina
// Update a specific field in metadata for matching vectors
VectorDataWithId[] updated = check vectorStore.updateMetadataField(
    {"category": "tech"}, 
    "processed", 
    "true", 
    "documents"
);
```

#### Deleting Vectors
```ballerina
// Delete vectors based on metadata criteria
int deletedCount = check vectorStore.deleteVectorsByMetadata(
    {"status": "obsolete"}, 
    "documents"
);
```

### 3. Advanced Search with Distance Scoring

```ballerina
SearchConfig config = {
    similarityType: COSINE_DISTANCE,
    'limit: 5,
    threshold: 0.7,
    metadata: {
        "category": "technology"
    }
};

VectorDataWithDistance[] results = check vectorStore.searchVector(queryVector, "documents", config);

// Process results with distance information
foreach VectorDataWithDistance result in results {
    if result.distance < 0.5 {
        log:printInfo("High similarity match: " + result.document);
    }
}
```

### 4. Direct Database Access

```ballerina
// Get the underlying PostgreSQL client for custom operations
postgresql:Client dbClient = vectorStore.getClient();

// Execute custom queries
sql:ExecutionResult result = check vectorStore.execute(`
    UPDATE vector_store 
    SET updated_at = CURRENT_TIMESTAMP 
    WHERE collection_name = 'documents'
`);
```

## Error Handling

The module provides comprehensive error handling:

```ballerina
do {
    VectorDataWithDistance[] results = check vectorStore.searchVector(queryVector, "my_collection");
    // Process results
} on fail var e {
    // Handle errors
    log:printError("Error during vector search", e);
}
```

## Best Practices

- **Close connections properly:**
  
  ```ballerina
  check vectorStore.close();
  ```

- **Use appropriate vector dimensions:**
  - E.g.g OpenAI `text-embedding-3-small`: 1536
  - Should be selected as per your model

- **Choose appropriate similarity measures:**
  - **COSINE_DISTANCE**: Normalized similarity (recommended for most cases)
  - **EUCLIDEAN_DISTANCE**: Distance-based similarity
  - **NEGATIVE_INNER_PRODUCT**: Dot product similarity

- **Organize data with collections:**
  - Use meaningful collection names
  - Group related vectors together
  - Separate different data types into different collections

- **Metadata design:**
  - Use consistent metadata schemas within collections
  - Index frequently queried metadata fields
  - Keep metadata lightweight for better performance

## Examples

### Complete Example with Collections

```ballerina
import wso2/pgvector;
import ballerina/log;

public function main() returns error? {
    // Initialize store
    ConnectionConfig config = {
        host: "localhost",
        user: "postgres",
        password: "password",
        database: "vectordb"
    };
    
    VectorStore store = check new(config, vectorDimension = 1536);

    // Add vectors to different collections
    VectorData documentData = {
        embedding: [0.1, 0.2, 0.3],
        document: "Technical documentation about APIs",
        metadata: {
            "category": "documentation",
            "type": "technical"
        }
    };
    
    VectorData blogData = {
        embedding: [0.4, 0.5, 0.6],
        document: "Blog post about machine learning",
        metadata: {
            "category": "blog",
            "author": "Jane Doe"
        }
    };

    VectorDataWithId docResult = check store.addVector(documentData, "documents");
    VectorDataWithId blogResult = check store.addVector(blogData, "blogs");

    // Search within specific collection
    SearchConfig searchConfig = {
        similarityType: COSINE_DISTANCE,
        'limit: 10,
        metadata: {
            "category": "documentation"
        }
    };
    
    VectorDataWithDistance[] results = check store.searchVector(
        [0.1, 0.2, 0.3], 
        "documents", 
        searchConfig
    );

    // Process results with distance scores
    foreach VectorDataWithDistance result in results {
        log:printInfo(string `Found: ${result.document} (Distance: ${result.distance})`);
    }

    // Update metadata
    VectorDataWithId[] updated = check store.updateMetadataField(
        {"category": "documentation"}, 
        "reviewed", 
        "true", 
        "documents"
    );

    // Check existence
    boolean hasBlogs = check store.existsByMetadata(
        {"category": "blog"}, 
        "blogs"
    );

    // Close connection
    check store.close();
}
```

### Search with Distance Threshold

```ballerina
// Find only very similar vectors
SearchConfig strictConfig = {
    similarityType: COSINE_DISTANCE,
    'limit: 5,
    threshold: 0.2  // Only return results with distance <= 0.2
};

VectorDataWithDistance[] similarResults = check store.searchVector(
    queryVector, 
    "embeddings", 
    strictConfig
);
```

## Use Cases

This module is ideal for:

- **Semantic search applications** with collection-based organization
- **AI/ML applications requiring vector similarity search**
- **Recommendation systems** with user and item collections
- **Document similarity analysis** with metadata filtering
- **Image similarity search** using image embeddings
- **Multi-tenant applications** using collections as tenant isolation
- **Content management systems** with categorized vector storage

## Database Schema

The module automatically creates the following table structure:

```sql
CREATE TABLE vector_store (
    id SERIAL PRIMARY KEY,
    collection_name VARCHAR NOT NULL,
    embedding vector(1536),  -- Configurable dimension
    document VARCHAR NOT NULL,
    metadata JSONB,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Indexes for performance
CREATE INDEX ix_vector_store_collection ON vector_store(collection_name);
CREATE INDEX ix_vector_store_metadata_gin ON vector_store USING gin (metadata jsonb_path_ops);
CREATE INDEX vector_store_embedding_idx ON vector_store USING hnsw(embedding vector_cosine_ops);
```