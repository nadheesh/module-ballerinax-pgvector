import ballerina/log;
import ballerina/sql;
import ballerinax/postgresql;
import ballerinax/postgresql.driver as _;

# Represents similarity search types for vector comparisons
#
# + EUCLIDEAN_DISTANCE - L2 distance (Euclidean distance)
# + COSINE_DISTANCE - Cosine distance (1 - cosine similarity)
# + NEGATIVE_INNER_PRODUCT - Negative inner product
public enum SimilarityType {
    EUCLIDEAN_DISTANCE = "<->",
    COSINE_DISTANCE = "<=>",
    NEGATIVE_INNER_PRODUCT = "<#>"
}

# Represents vector data without ID
#
# + embedding - Vector embedding array
# + document - Document text
# + metadata - Optional metadata
public type VectorData record {|
    float[] embedding;
    string document;
    map<json> metadata?;
|};

# Represents vector data with ID
#
# + id - Unique identifier
public type VectorDataWithId record {|
    int id;
    *VectorData;
|};

# Represents vector data with the distance score
#
# + distance - Distance score
public type VectorDataWithDistance record {|
    *VectorDataWithId;
    float distance;
|};

# Represent output record from vector store
#
# + id - Unique identifier
# + collection_name - Collection name
# + embedding - Vector embedding array
# + document - Document text
# + metadata - Optional metadata
# + distance - Optional distance
type VectorStoreOutput record {|
    int id;
    string collection_name;
    string embedding;
    string document;
    string metadata?;
    float distance?;
|};

# Search configuration for vector queries
#
# + similarityType - Type of similarity measure to use
# + limit - Maximum number of results to return
# + threshold - Optional similarity threshold
# + metadata - Optional metadata filters
public type SearchConfig record {|
    SimilarityType similarityType = COSINE_DISTANCE;
    int 'limit = 10;
    float? threshold = ();
    map<sql:Value> metadata = {};
|};

# Connection configuration for the vector store
#
# + host - Database host
# + user - Database username
# + password - Database password
# + database - Database name
# + port - Database port
public type ConnectionConfig record {|
    string host;
    string user;
    string password;
    string database;
    int port = 5432;
|};

public isolated class VectorStore {
    final postgresql:Client dbClient;
    private final int vectorDimension;

    public isolated function init(ConnectionConfig connectionConfigs, int vectorDimension = 1536, postgresql:Options options = {
                connectTimeout: 10,
                ssl: {
                    mode: postgresql:REQUIRE
                }
            }, sql:ConnectionPool connectionPool = {}) returns error? {

        // Initialize database client
        self.dbClient = check new (
            host = connectionConfigs.host,
            username = connectionConfigs.user,
            password = connectionConfigs.password,
            database = connectionConfigs.database,
            port = connectionConfigs.port,
            options = options,
            connectionPool = connectionPool
        );
        self.vectorDimension = vectorDimension;

        // Initialize vector extension and create table
        error? initError = self.initializeDatabase();

        // If fails we will log and move forward. 
        // This could be due to access issues.
        if initError is error {
            log:printWarn("Error during the initializing database.", initError);
        }
    }

    private isolated function initializeDatabase() returns error? {
        // Enable pgvector extension if not exists
        _ = check self.dbClient->execute(`CREATE EXTENSION IF NOT EXISTS vector`);

        // Query creation with dynamic vector dimension size
        // Cannot use ParameterizedQuery because it doesn't allow parameters with type definitions 
        string queryString = string `
            CREATE TABLE IF NOT EXISTS vector_store (
                id SERIAL PRIMARY KEY,
                collection_name VARCHAR NOT NULL,
                embedding vector(${self.vectorDimension}),
                document VARCHAR NOT NULL,
                metadata JSONB,
                created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
                updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
            )`;

        sql:ParameterizedQuery query = ``;
        query.strings = [queryString];

        // Create table with vector support
        sql:ExecutionResult result = check self.dbClient->execute(query);
        log:printDebug("Table created successfully" + result.toJsonString());

        // Create collection index
        _ = check self.dbClient->execute(`
            CREATE INDEX IF NOT EXISTS ix_vector_store_collection 
            ON vector_store(collection_name);
        `);

        // Create metadata index
        _ = check self.dbClient->execute(`
            CREATE INDEX IF NOT EXISTS ix_vector_store_metadata_gin 
            ON vector_store USING gin (metadata jsonb_path_ops);
        `);

        // Create index for vector similarity search
        _ = check self.dbClient->execute(`
            CREATE INDEX IF NOT EXISTS vector_store_embedding_idx
            ON vector_store
            USING hnsw(embedding vector_cosine_ops)
            WITH (m = 24, ef_construction = 100);
        `);
    }

    # Add data to vector store
    #
    # + data - Data to added to vector storage
    # + collectionName - Collection name
    # + return - Data with ID if succesfull or an error
    public isolated function addVector(VectorData data, string collectionName) returns VectorDataWithId|error {
        postgresql:JsonBinaryValue metadata = new (data?.metadata);

        sql:ParameterizedQuery query = `
        INSERT INTO vector_store (
            collection_name,
            embedding, 
            document, 
            metadata) 
        VALUES (
            ${collectionName},
            ${data.embedding},
            ${data.document},
            ${metadata})
        RETURNING id, collection_name, embedding, document, metadata`;

        VectorStoreOutput result = check self.dbClient->queryRow(query);
        return check getVectorDataWithId(result);
    }

    # Performs vector similarity search
    #
    # + queryVector - Query vector for similarity search
    # + collectionName - Collection name
    # + config - Search configuration
    # + return - List of vector data results or error
    public isolated function searchVector(float[] queryVector, string collectionName, SearchConfig config = {}) returns VectorDataWithDistance[]|error {
        // Build the base query
        string[] queryParts = [];
        sql:Value[] insertions = [];

        // Base SELECT with collection filter
        queryParts.push(string `WITH scored_vectors AS (
            SELECT id, 
                   collection_name, 
                   embedding, 
                   document, 
                   metadata, 
                   embedding ${config.similarityType} `, "::vector AS distance FROM vector_store WHERE collection_name = ");
        insertions.push(queryVector, collectionName);

        queryParts.push(" ) SELECT * FROM scored_vectors WHERE 1 = ");
        insertions.push(1);

        // Add threshold condition if specified
        if config.threshold is float {
            queryParts.push(" AND distance <= ");
            insertions.push(config.threshold);
        }

        // Add metadata filters if specified
        if config.metadata.length() > 0 {
            map<sql:Value> metadata = config.metadata;
            foreach [string, sql:Value] [key, value] in metadata.entries() {
                if value != "" {
                    queryParts.push(string ` AND metadata->>'${key}' = `);
                    insertions.push(value);
                }
            }
        }

        // Add ORDER BY and LIMIT
        queryParts.push(" ORDER BY distance LIMIT ", "");
        insertions.push(config.'limit);

        // Construct final query
        sql:ParameterizedQuery query = ``;
        query.strings = queryParts.cloneReadOnly();
        query.insertions = insertions;

        // Execute query
        stream<VectorStoreOutput, sql:Error?> resultStream = self.dbClient->query(query);
        VectorDataWithDistance[] results = [];

        check from VectorStoreOutput result in resultStream
            do {
                results.push(check getVectorDataWithDistance(result));
            };
        return results;
    }

    # Fetch data by metadata filters
    #
    # + metadata - Metadata filters. If empty, fetches all data.
    # + collectionName - Collection name
    # + return - List of vector data results or error
    public isolated function fetchVectorByMetadata(map<sql:Value> metadata, string collectionName) returns VectorDataWithId[]|error {
        // Build the base query
        string[] queryParts = [];
        sql:Value[] insertions = [];

        // Base SELECT with collection filter
        queryParts.push("SELECT id, collection_name, embedding, document, metadata FROM vector_store WHERE collection_name = ");
        insertions.push(collectionName);

        // Add metadata filters if specified
        if metadata.length() > 0 {
            foreach [string, sql:Value] [key, value] in metadata.entries() {
                if value != "" {
                    queryParts.push(string ` AND metadata->>'${key}' = `);
                    insertions.push(value);
                }
            }
        }
        queryParts.push(""); // needed for last injection

        // Construct final query
        sql:ParameterizedQuery query = ``;
        query.strings = queryParts.cloneReadOnly();
        query.insertions = insertions;

        // Execute query
        stream<VectorStoreOutput, sql:Error?> resultStream = self.dbClient->query(query);
        VectorDataWithId[] results = [];

        check from VectorStoreOutput result in resultStream
            do {
                results.push(check getVectorDataWithId(result));
            };
        return results;
    }

    # Check if data exists based on metadata criteria
    #
    # + metadata - Metadata to check against
    # + collectionName - Collection name
    # + return - Returns true if matching data exists, false otherwise, or error
    public isolated function existsByMetadata(map<sql:Value> metadata, string collectionName) returns boolean|error {
        string[] queryParts = ["SELECT EXISTS ( SELECT 1 FROM vector_store WHERE collection_name = "];
        sql:Value[] insertions = [collectionName];

        // Add metadata filters if specified
        if metadata.length() > 0 {
            foreach [string, sql:Value] [key, value] in metadata.entries() {
                if value != "" {
                    queryParts.push(string ` AND metadata->>'${key}' = `);
                    insertions.push(value);
                }
            }
        }
        queryParts.push(")");

        // Construct final query
        sql:ParameterizedQuery query = ``;
        query.strings = queryParts.cloneReadOnly();
        query.insertions = insertions;

        stream<record {|boolean exists;|}, sql:Error?> result = self.dbClient->query(query);
        record {|record {|boolean exists;|} value;|}? next = check result.next();
        check result.close();

        // Return the result
        if next !is () {
            return next.value.exists;
        }
        return false;
    }

    # Execute a SQL query
    #
    # + query - Parameterized query
    # + return - Execution result or error
    public isolated function execute(sql:ParameterizedQuery query) returns sql:ExecutionResult|error {
        return self.dbClient->execute(query);
    }

    # Close the database connection
    #
    # + return - Error if closing fails
    public isolated function close() returns error? {
        check self.dbClient.close();
    }

    # Delete vectors based on metadata criteria
    #
    # + metadata - Metadata criteria for deletion
    # + collectionName - Collection name
    # + return - Number of rows deleted or error
    public isolated function deleteVectorsByMetadata(map<sql:Value> metadata, string collectionName) returns int|error {
        string[] queryParts = ["DELETE FROM vector_store WHERE collection_name = "];
        sql:Value[] insertions = [collectionName];

        // Add metadata filters if specified
        if metadata.length() > 0 {
            foreach [string, sql:Value] [key, value] in metadata.entries() {
                if value != "" {
                    queryParts.push(string ` AND metadata->>'${key}' = `);
                    insertions.push(value);
                }
            }
        }
        queryParts.push(" RETURNING id");

        // Construct final query
        sql:ParameterizedQuery query = ``;
        query.strings = queryParts.cloneReadOnly();
        query.insertions = insertions;

        sql:ExecutionResult result = check self.dbClient->execute(query);
        int? deletedCount = result.affectedRowCount;
        return deletedCount is () ? 0 : deletedCount;
    }

    # Update or add a field in metadata of vectors matching criteria.
    # Updates existing field or adds new field while preserving other metadata.
    #
    # + metadata - Metadata criteria to find vectors to update
    # + fieldName - The field name in the metadata to update
    # + fieldValue - The new value for the field
    # + collectionName - Collection name
    # + return - Updated vector data or error
    public isolated function updateMetadataField(map<sql:Value> metadata, string fieldName, string fieldValue, string collectionName) returns VectorDataWithId[]|error {
        // First fetch all vectors matching the metadata criteria
        VectorDataWithId[] matchingVectors = check self.fetchVectorByMetadata(metadata, collectionName);
        VectorDataWithId[] updatedVectors = [];

        foreach VectorDataWithId vector in matchingVectors {
            sql:ParameterizedQuery query = `
                UPDATE vector_store 
                SET metadata = jsonb_set(COALESCE(metadata, '{}'::jsonb), ARRAY[${fieldName}], to_jsonb(${fieldValue})) 
                WHERE id = ${vector.id} AND collection_name = ${collectionName}
                RETURNING id, collection_name, embedding, document, metadata
            `;

            // Execute the query and get the updated row
            VectorStoreOutput result = check self.dbClient->queryRow(query);

            // Add the updated vector to our results array
            updatedVectors.push(check getVectorDataWithId(result));
        }

        return updatedVectors;
    }

    # Get the underlying database client
    #
    # + return - Postgres client
    public function getClient() returns postgresql:Client {
        return self.dbClient;
    }
}

isolated function getVectorDataWithId(VectorStoreOutput result) returns VectorDataWithId|error {
    string? metadata = result.metadata;
    return {
        id: result.id,
        metadata: metadata is () ? {} : check metadata.fromJsonStringWithType(),
        document: result.document,
        embedding: check result.embedding.fromJsonStringWithType()
    };
}

isolated function getVectorDataWithDistance(VectorStoreOutput result) returns VectorDataWithDistance|error {
    return {
        ...check getVectorDataWithId(result),
        distance: result.distance ?: 0
    };
}
