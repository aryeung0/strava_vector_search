-- =====================================================
-- STRAVA WORKOUT VECTOR SEARCH - MANUAL VECTOR EMBEDDING
-- =====================================================
-- This demo implements vector search using manual embedding generation and direct similarity search
-- Use Case: Semantic caching for workout generation system
-- Target: ~10,000 workouts, peak load 1000 req/sec, 300ms latency
-- 
-- WHY THIS APPROACH:
-- Cortex Search may have concurrency limits that cannot handle 1000 requests/sec
-- This approach uses direct VECTOR data type with cosine similarity search
-- Provides more control over concurrency and can leverage warehouse parallelism
-- Prerequisite: Load 00_sample_workout_data.csv into Snowflake first
-- =====================================================

-- =====================================================
-- STEP 1: WAREHOUSE AND ROLE SETUP
-- =====================================================

USE ROLE ACCOUNTADMIN;

-- Create warehouse for demo (if not already created from 01 script)
CREATE WAREHOUSE IF NOT EXISTS STRAVA_DEMO_WH
    WAREHOUSE_SIZE = XSMALL
    AUTO_SUSPEND = 300
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = FALSE
    COMMENT = 'Warehouse for Strava demo activities';

-- Create role for demo (if not already created from 01 script)
CREATE ROLE IF NOT EXISTS STRAVA_DEMO_ADMIN
    COMMENT = 'Role for Strava Vector Search demo';

-- Grant role to ACCOUNTADMIN
GRANT ROLE STRAVA_DEMO_ADMIN TO ROLE ACCOUNTADMIN;

-- Grant warehouse usage to role
GRANT USAGE ON WAREHOUSE STRAVA_DEMO_WH TO ROLE STRAVA_DEMO_ADMIN;
GRANT OPERATE ON WAREHOUSE STRAVA_DEMO_WH TO ROLE STRAVA_DEMO_ADMIN;
GRANT MONITOR ON WAREHOUSE STRAVA_DEMO_WH TO ROLE STRAVA_DEMO_ADMIN;

-- Switch to demo role
USE ROLE STRAVA_DEMO_ADMIN;
USE WAREHOUSE STRAVA_DEMO_WH;

-- =====================================================
-- STEP 2: DATABASE AND SCHEMA SETUP
-- =====================================================

-- Grant necessary privileges to create database (if needed)
USE ROLE ACCOUNTADMIN;
GRANT CREATE DATABASE ON ACCOUNT TO ROLE STRAVA_DEMO_ADMIN;

USE ROLE STRAVA_DEMO_ADMIN;

-- Create database if it doesn't exist
CREATE DATABASE IF NOT EXISTS STRAVA_DEMO_SAMPLE;

-- Grant ownership to demo role
USE ROLE ACCOUNTADMIN;
GRANT OWNERSHIP ON DATABASE STRAVA_DEMO_SAMPLE TO ROLE STRAVA_DEMO_ADMIN COPY CURRENT GRANTS;
GRANT ALL ON DATABASE STRAVA_DEMO_SAMPLE TO ROLE STRAVA_DEMO_ADMIN;

USE ROLE STRAVA_DEMO_ADMIN;

-- Create schema for vector embedding demo
CREATE SCHEMA IF NOT EXISTS STRAVA_DEMO_SAMPLE.VECTOR_EMBEDDING_DEMO;

-- Set context
USE DATABASE STRAVA_DEMO_SAMPLE;
USE SCHEMA VECTOR_EMBEDDING_DEMO;

-- =====================================================
-- STEP 3: CREATE WORKOUT TABLE WITH VECTOR COLUMN
-- =====================================================
-- Table stores workout metadata, searchable descriptions, and pre-computed embeddings
-- The EMBEDDING column stores vector embeddings as VECTOR data type

DROP TABLE IF EXISTS WORKOUTS_WITH_VECTORS;

CREATE TABLE WORKOUTS_WITH_VECTORS (
    -- Primary identifier
    ID VARCHAR(50) PRIMARY KEY,
    
    -- Searchable text fields (to be embedded)
    EMBED_STR VARCHAR(16777216),  -- Workout instructions/description
    
    -- Pre-computed vector embedding (768 dimensions for e5-base-v2 model)
    EMBEDDING VECTOR(FLOAT, 768),
    
    -- Metadata for filtering (used alongside vector search)
    SPORT_TYPE VARCHAR(50),               -- 'run', 'ride', 'swim', 'trail_run', etc.
    DIFFICULTY VARCHAR(20),               -- 'easy', 'moderate', 'hard', 'very_hard'
    MOVING_TIME_SECONDS INTEGER,          -- Duration in seconds
    DISTANCE_METERS INTEGER,              -- Distance in meters
    
    -- System fields
    GENERATION_MODEL VARCHAR(100),
    WORKOUT_SOURCE VARCHAR(50),
    STORE_VERSION VARCHAR(10),
    
    -- Full workout content (JSON format, retrieved via JOIN)
    RAW_JSON_STR VARIANT,
    
    CREATED_AT TIMESTAMP_NTZ
);

-- =====================================================
-- STEP 4: LOAD DATA FROM CSV
-- =====================================================

-- Load data from the stage created in 01_cortex_search_setup.sql
-- Note: This reuses the same stage and CSV file uploaded in script 01
-- If you haven't run script 01 yet, create the stage first:
-- CREATE OR REPLACE STAGE STRAVA_DEMO_SAMPLE.VECTOR_SEARCH_DEMO.WORKOUT_STAGE;
-- Then upload: PUT file:///path/to/00_sample_workout_data.csv @STRAVA_DEMO_SAMPLE.VECTOR_SEARCH_DEMO.WORKOUT_STAGE

-- Load data with transformation for empty numeric values
-- CSV columns: ID,EMBED_STR,SPORT_TYPE,DIFFICULTY,MOVING_TIME_SECONDS,DISTANCE_METERS,
--              GENERATION_MODEL,WORKOUT_SOURCE,STORE_VERSION,RAW_JSON_STR,CREATED_AT
COPY INTO WORKOUTS_WITH_VECTORS (ID, EMBED_STR, SPORT_TYPE, DIFFICULTY, MOVING_TIME_SECONDS, 
                                  DISTANCE_METERS, GENERATION_MODEL, WORKOUT_SOURCE, STORE_VERSION,
                                  RAW_JSON_STR, CREATED_AT)
FROM (
    SELECT 
        $1::VARCHAR,                                        -- ID
        $2::VARCHAR,                                        -- EMBED_STR
        $3::VARCHAR,                                        -- SPORT_TYPE
        $4::VARCHAR,                                        -- DIFFICULTY
        NULLIF($5, '')::INTEGER,                           -- MOVING_TIME_SECONDS (convert empty to NULL)
        NULLIF($6, '')::INTEGER,                           -- DISTANCE_METERS (convert empty to NULL)
        $7::VARCHAR,                                        -- GENERATION_MODEL
        $8::VARCHAR,                                        -- WORKOUT_SOURCE
        $9::VARCHAR,                                        -- STORE_VERSION
        PARSE_JSON($10),                                    -- RAW_JSON_STR
        $11::TIMESTAMP_NTZ                                  -- CREATED_AT
    FROM @STRAVA_DEMO_SAMPLE.VECTOR_SEARCH_DEMO.WORKOUT_STAGE/00_sample_workout_data.csv
)
FILE_FORMAT = (
    TYPE = 'CSV'
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    SKIP_HEADER = 1
    ESCAPE_UNENCLOSED_FIELD = NONE
    FIELD_DELIMITER = ','
    RECORD_DELIMITER = '\n'
    TRIM_SPACE = FALSE
    ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE
    ENCODING = 'UTF8'
    DATE_FORMAT = 'AUTO'
    TIMESTAMP_FORMAT = 'AUTO'
)
ON_ERROR = 'CONTINUE';

-- Verify the data was loaded
SELECT 
    SPORT_TYPE,
    DIFFICULTY,
    COUNT(*) AS workout_count,
    ROUND(AVG(DISTANCE_METERS)/1000.0, 1) AS avg_distance_km,
    ROUND(AVG(MOVING_TIME_SECONDS/60.0), 0) AS avg_duration_min
FROM WORKOUTS_WITH_VECTORS
GROUP BY SPORT_TYPE, DIFFICULTY
ORDER BY SPORT_TYPE, DIFFICULTY;

-- =====================================================
-- STEP 5: GENERATE VECTOR EMBEDDINGS FOR ALL WORKOUTS
-- =====================================================
-- Use Snowflake Cortex EMBED_TEXT function to generate embeddings
-- The e5-base-v2 model creates 768-dimensional embeddings

UPDATE WORKOUTS_WITH_VECTORS
SET EMBEDDING = SNOWFLAKE.CORTEX.EMBED_TEXT_768('e5-base-v2', EMBED_STR)
WHERE EMBED_STR IS NOT NULL;

-- Verify embeddings were generated
SELECT 
    ID,
    LEFT(EMBED_STR, 50) AS WORKOUT_PREVIEW,
    CASE 
        WHEN EMBEDDING IS NOT NULL THEN 'Embedded'
        ELSE 'Missing'
    END AS embedding_status
FROM WORKOUTS_WITH_VECTORS
LIMIT 10;

-- Check embedding statistics
SELECT 
    COUNT(*) AS total_workouts,
    SUM(CASE WHEN EMBEDDING IS NOT NULL THEN 1 ELSE 0 END) AS workouts_with_embeddings,
    ROUND(100.0 * SUM(CASE WHEN EMBEDDING IS NOT NULL THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_embedded
FROM WORKOUTS_WITH_VECTORS;

-- =====================================================
-- STEP 6: VECTOR SIMILARITY SEARCH QUERIES
-- =====================================================
-- Note: SQL UDFs have limitations with complex queries and LIMIT clauses
-- We'll use inline queries instead for better compatibility and performance
-- This approach gives you full control and avoids UDF syntax restrictions

-- =====================================================
-- STEP 7: PERFORM SEMANTIC SEARCH QUERIES
-- =====================================================
-- Simulate user requests for workout recommendations using vector search

-- Example Query 1: Find 5K interval run workouts
-- User request: "I want a 5k interval run workout"
WITH query_embedding AS (
    SELECT SNOWFLAKE.CORTEX.EMBED_TEXT_768('e5-base-v2', '5k interval run workout with speed training') AS embedding
)
SELECT 
    w.ID,
    LEFT(w.EMBED_STR, 100) AS EMBED_STR_PREVIEW,
    VECTOR_COSINE_SIMILARITY(w.EMBEDDING, qe.embedding) AS SIMILARITY_SCORE,
    w.SPORT_TYPE,
    w.DIFFICULTY,
    w.DISTANCE_METERS,
    w.MOVING_TIME_SECONDS,
    ROUND(w.DISTANCE_METERS / 1000.0, 1) AS DISTANCE_KM,
    ROUND(w.MOVING_TIME_SECONDS / 60.0, 1) AS DURATION_MIN
FROM WORKOUTS_WITH_VECTORS w
CROSS JOIN query_embedding qe
WHERE 
    w.SPORT_TYPE = 'run'
    AND w.DISTANCE_METERS >= 4500
    AND w.DISTANCE_METERS <= 6000
    AND w.EMBEDDING IS NOT NULL
ORDER BY SIMILARITY_SCORE DESC
LIMIT 5;

-- Example Query 2: Find moderate difficulty cycling workouts
-- User request: "moderate difficulty cycling workout"
WITH query_embedding AS (
    SELECT SNOWFLAKE.CORTEX.EMBED_TEXT_768('e5-base-v2', 'moderate cycling endurance ride') AS embedding
)
SELECT 
    w.ID,
    LEFT(w.EMBED_STR, 100) AS EMBED_STR_PREVIEW,
    VECTOR_COSINE_SIMILARITY(w.EMBEDDING, qe.embedding) AS SIMILARITY_SCORE,
    w.SPORT_TYPE,
    w.DIFFICULTY,
    w.DISTANCE_METERS,
    w.MOVING_TIME_SECONDS,
    ROUND(w.DISTANCE_METERS / 1000.0, 1) AS DISTANCE_KM,
    ROUND(w.MOVING_TIME_SECONDS / 60.0, 1) AS DURATION_MIN
FROM WORKOUTS_WITH_VECTORS w
CROSS JOIN query_embedding qe
WHERE 
    w.SPORT_TYPE = 'ride'
    AND w.DIFFICULTY = 'moderate'
    AND w.EMBEDDING IS NOT NULL
ORDER BY SIMILARITY_SCORE DESC
LIMIT 5;

-- Example Query 3: Find easy recovery runs
-- User request: "easy recovery run"
WITH query_embedding AS (
    SELECT SNOWFLAKE.CORTEX.EMBED_TEXT_768('e5-base-v2', 'easy recovery jog gentle pace') AS embedding
)
SELECT 
    w.ID,
    LEFT(w.EMBED_STR, 100) AS EMBED_STR_PREVIEW,
    VECTOR_COSINE_SIMILARITY(w.EMBEDDING, qe.embedding) AS SIMILARITY_SCORE,
    w.SPORT_TYPE,
    w.DIFFICULTY,
    w.DISTANCE_METERS,
    w.MOVING_TIME_SECONDS,
    ROUND(w.DISTANCE_METERS / 1000.0, 1) AS DISTANCE_KM,
    ROUND(w.MOVING_TIME_SECONDS / 60.0, 1) AS DURATION_MIN
FROM WORKOUTS_WITH_VECTORS w
CROSS JOIN query_embedding qe
WHERE 
    w.SPORT_TYPE = 'run'
    AND w.DIFFICULTY = 'easy'
    AND w.EMBEDDING IS NOT NULL
ORDER BY SIMILARITY_SCORE DESC
LIMIT 5;

-- =====================================================
-- STEP 8: DIRECT VECTOR SIMILARITY SEARCH (INLINE)
-- =====================================================
-- For maximum performance and control, query directly without UDF

-- Example: Find similar workouts to "trail running with hills"
WITH query_embedding AS (
    SELECT SNOWFLAKE.CORTEX.EMBED_TEXT_768('e5-base-v2', 'trail running with elevation gain hills') AS embedding
),
ranked_workouts AS (
    SELECT 
        w.ID,
        LEFT(w.EMBED_STR, 100) AS WORKOUT_PREVIEW,
        w.SPORT_TYPE,
        w.DIFFICULTY,
        ROUND(w.DISTANCE_METERS / 1000.0, 1) AS DISTANCE_KM,
        ROUND(w.MOVING_TIME_SECONDS / 60.0, 1) AS DURATION_MIN,
        VECTOR_COSINE_SIMILARITY(w.EMBEDDING, qe.embedding) AS SIMILARITY_SCORE
    FROM WORKOUTS_WITH_VECTORS w
    CROSS JOIN query_embedding qe
    WHERE 
        w.SPORT_TYPE IN ('run', 'trail_run')
        AND w.EMBEDDING IS NOT NULL
)
SELECT 
    ID,
    WORKOUT_PREVIEW,
    SPORT_TYPE,
    DIFFICULTY,
    DISTANCE_KM,
    DURATION_MIN,
    SIMILARITY_SCORE,
    CASE 
        WHEN SIMILARITY_SCORE > 0.80 THEN ' CACHE HIT - Excellent Match'
        WHEN SIMILARITY_SCORE > 0.70 THEN ' CACHE HIT - Good Match'
        ELSE ' CACHE MISS - Generate New'
    END AS CACHE_DECISION
FROM ranked_workouts
WHERE SIMILARITY_SCORE > 0.70  -- Apply similarity threshold
ORDER BY SIMILARITY_SCORE DESC
LIMIT 5;

-- =====================================================
-- STEP 9: RETRIEVE FULL JSON FOR MATCHED WORKOUTS
-- =====================================================
-- Join back to table to get complete workout details including JSON

WITH query_embedding AS (
    SELECT SNOWFLAKE.CORTEX.EMBED_TEXT_768('e5-base-v2', 'swimming technique drills') AS embedding
),
search_results AS (
    SELECT 
        w.ID,
        LEFT(w.EMBED_STR, 80) AS WORKOUT_PREVIEW,
        w.SPORT_TYPE,
        w.DIFFICULTY,
        VECTOR_COSINE_SIMILARITY(w.EMBEDDING, qe.embedding) AS SIMILARITY_SCORE
    FROM WORKOUTS_WITH_VECTORS w
    CROSS JOIN query_embedding qe
    WHERE 
        w.SPORT_TYPE = 'swim'
        AND w.EMBEDDING IS NOT NULL
    ORDER BY SIMILARITY_SCORE DESC
    LIMIT 3
)
SELECT 
    s.ID,
    s.WORKOUT_PREVIEW,
    s.SIMILARITY_SCORE,
    w.RAW_JSON_STR AS FULL_WORKOUT_JSON
FROM search_results s
JOIN WORKOUTS_WITH_VECTORS w ON s.ID = w.ID;

-- =====================================================
-- PERFORMANCE MONITORING AND STATISTICS
-- =====================================================

-- Check table size and row count
SELECT 
    COUNT(*) AS total_workouts,
    COUNT(EMBEDDING) AS workouts_with_embeddings,
    ROUND(100.0 * COUNT(EMBEDDING) / COUNT(*), 1) AS pct_embedded
FROM WORKOUTS_WITH_VECTORS;

-- Distribution by sport and difficulty
SELECT 
    SPORT_TYPE,
    DIFFICULTY,
    COUNT(*) AS COUNT,
    ROUND(AVG(DISTANCE_METERS/1000.0), 1) AS AVG_DISTANCE_KM,
    ROUND(AVG(MOVING_TIME_SECONDS/60.0), 0) AS AVG_DURATION_MIN
FROM WORKOUTS_WITH_VECTORS
GROUP BY SPORT_TYPE, DIFFICULTY
ORDER BY SPORT_TYPE, DIFFICULTY;

-- Sample similarity score distribution for a test query
WITH query_embedding AS (
    SELECT SNOWFLAKE.CORTEX.EMBED_TEXT_768('e5-base-v2', 'interval training workout') AS embedding
)
SELECT 
    CASE 
        WHEN VECTOR_COSINE_SIMILARITY(w.EMBEDDING, qe.embedding) >= 0.90 THEN '0.90-1.00 (Excellent)'
        WHEN VECTOR_COSINE_SIMILARITY(w.EMBEDDING, qe.embedding) >= 0.80 THEN '0.80-0.89 (Very Good)'
        WHEN VECTOR_COSINE_SIMILARITY(w.EMBEDDING, qe.embedding) >= 0.70 THEN '0.70-0.79 (Good)'
        WHEN VECTOR_COSINE_SIMILARITY(w.EMBEDDING, qe.embedding) >= 0.60 THEN '0.60-0.69 (Fair)'
        ELSE '< 0.60 (Poor)'
    END AS similarity_range,
    COUNT(*) AS workout_count
FROM WORKOUTS_WITH_VECTORS w
CROSS JOIN query_embedding qe
WHERE w.EMBEDDING IS NOT NULL
GROUP BY similarity_range
ORDER BY similarity_range DESC;

-- =====================================================
-- NOTES ON PRODUCTION DEPLOYMENT FOR 1000 QPS
-- =====================================================
/*
For Strava's production deployment targeting 1000 requests/sec:

1. WAREHOUSE SIZING:
   - Use LARGE or X-LARGE warehouse for similarity search
   - Consider MULTI-CLUSTER warehouse with auto-scaling
   - Set MIN_CLUSTER_COUNT=2, MAX_CLUSTER_COUNT=10 for the 24-hour peak
   - Enable auto-suspend (60 seconds) for cost optimization

2. QUERY OPTIMIZATION:
   - Pre-compute embeddings for all workouts (DONE in this script)
   - Generate query embeddings on-demand using EMBED_TEXT_768
   - Use metadata filters to reduce search space before similarity calculation
   - Consider clustering the table by SPORT_TYPE for faster filtering

3. CONCURRENCY HANDLING:
   - Multi-cluster warehouse automatically handles concurrent queries
   - Each cluster can process multiple queries in parallel
   - Snowflake's query queueing prevents resource exhaustion
   - Monitor QUERY_HISTORY for queue times and adjust cluster count

4. CACHING STRATEGY:
   - Implement result caching at application layer for identical queries
   - Use similarity threshold (e.g., 0.70) to determine cache hits
   - Store generated workouts back to table to grow the cache over time

5. PERFORMANCE OPTIMIZATION:
   - Batch multiple user queries together for efficiency
   - Use materialized views for frequently filtered result sets
   - Consider Search Optimization Service for metadata filtering
   - Pre-warm warehouse before peak load periods

6. MONITORING AND ALERTING:
   - Track query latency percentiles (p50, p90, p99)
   - Monitor warehouse queue depth and execution times
   - Set alerts for > 300ms p50 latency
   - Monitor credit consumption during peak periods

7. COST OPTIMIZATION:
   - Direct similarity search is compute-intensive
   - 1000 QPS for 24 hours = 86.4M queries per week
   - Consider caching query results for 5-10 minutes at app layer
   - Use smaller warehouse (MEDIUM) for off-peak periods

8. SCALING BEYOND 10K WORKOUTS:
   - Current approach scales linearly with document count
   - At 10K workouts: direct search is efficient
   - At 100K workouts: consider partitioning by sport type
   - At 1M+ workouts: may need approximate search or external vector DB

9. TESTING RECOMMENDATIONS:
   - Load test with concurrent queries to validate 1000 QPS target
   - Measure actual latency under load (not just single query)
   - Test with realistic query patterns from Strava users
   - Validate similarity thresholds with sample workout comparisons

10. PRODUCTION CONFIGURATION EXAMPLE:
    CREATE WAREHOUSE VECTOR_SEARCH_WH WITH
        WAREHOUSE_SIZE = 'LARGE'
        MIN_CLUSTER_COUNT = 2
        MAX_CLUSTER_COUNT = 10
        SCALING_POLICY = 'STANDARD'
        AUTO_SUSPEND = 60
        AUTO_RESUME = TRUE;
*/

