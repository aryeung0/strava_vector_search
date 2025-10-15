-- =====================================================
-- STRAVA WORKOUT VECTOR SEARCH - CORTEX SEARCH SETUP
-- =====================================================
-- This script sets up the Cortex Search service for Strava's workout caching system
-- Prerequisite: Load 00_sample_workout_data.csv into Snowflake first
-- =====================================================

-- =====================================================
-- STEP 1: WAREHOUSE AND ROLE SETUP
-- =====================================================

USE ROLE ACCOUNTADMIN;

-- Create warehouse for demo
CREATE OR REPLACE WAREHOUSE STRAVA_DEMO_WH
    WAREHOUSE_SIZE = XSMALL
    AUTO_SUSPEND = 300
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = FALSE
    COMMENT = 'Warehouse for Strava demo activities';

-- Create role for demo
CREATE ROLE IF NOT EXISTS STRAVA_DEMO_ADMIN
    COMMENT = 'Role for Strava demo';

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

-- Grant necessary privileges to create database
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

-- Create schema for vector search demo
CREATE SCHEMA IF NOT EXISTS STRAVA_DEMO_SAMPLE.VECTOR_SEARCH_DEMO;

-- Set context
USE DATABASE STRAVA_DEMO_SAMPLE;
USE SCHEMA VECTOR_SEARCH_DEMO;

-- =====================================================
-- STEP 3: CREATE WORKOUT TABLE
-- =====================================================
-- Table structure matches the customer's workout data format

DROP TABLE IF EXISTS WORKOUTS;

CREATE TABLE WORKOUTS (
    -- Primary identifier
    ID VARCHAR(50) PRIMARY KEY,
    
    -- Searchable text (workout instructions/description)
    EMBED_STR VARCHAR(16777216),  -- Large text field for workout instructions
    
    -- Metadata for filtering
    SPORT_TYPE VARCHAR(50),               -- 'run', 'ride', 'swim', 'trail_run', etc.
    DIFFICULTY VARCHAR(20),               -- 'easy', 'moderate', 'hard', 'very_hard'
    MOVING_TIME_SECONDS INTEGER,          -- Duration in seconds
    DISTANCE_METERS INTEGER,              -- Distance in meters
    
    -- System fields
    GENERATION_MODEL VARCHAR(100),
    WORKOUT_SOURCE VARCHAR(50),
    STORE_VERSION VARCHAR(10),
    
    -- Full workout JSON (not indexed in Cortex Search but can be retrieved)
    RAW_JSON_STR VARIANT,
    
    CREATED_AT TIMESTAMP_NTZ
);

-- =====================================================
-- STEP 4: LOAD DATA FROM CSV
-- =====================================================
-- Instructions: Upload 00_sample_workout_data.csv to a Snowflake stage
-- Option 1: Use Snowflake UI to upload CSV to a named stage
-- Option 2: Use SnowSQL to put the file

-- Create a stage for loading data (if not exists)
CREATE STAGE IF NOT EXISTS WORKOUT_STAGE;

-- Upload the data csv into stage if necessary

-- Load data from stage with transformation for empty numeric values
-- CSV columns: ID,EMBED_STR,SPORT_TYPE,DIFFICULTY,MOVING_TIME_SECONDS,DISTANCE_METERS,
--              GENERATION_MODEL,WORKOUT_SOURCE,STORE_VERSION,RAW_JSON_STR,CREATED_AT
COPY INTO WORKOUTS (ID, EMBED_STR, SPORT_TYPE, DIFFICULTY, MOVING_TIME_SECONDS, 
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
    FROM @WORKOUT_STAGE/00_sample_workout_data.csv
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
    ROUND(AVG(DISTANCE_METERS), 0) AS avg_distance_m,
    ROUND(AVG(MOVING_TIME_SECONDS/60.0), 0) AS avg_duration_min
FROM WORKOUTS
GROUP BY SPORT_TYPE, DIFFICULTY
ORDER BY SPORT_TYPE, DIFFICULTY;

SELECT COUNT(*) FROM WORKOUTS;

-- =====================================================
-- STEP 5: CREATE CORTEX SEARCH SERVICE
-- =====================================================
-- Cortex Search provides serverless vector search with automatic embedding generation

-- Drop existing service if it exists
DROP CORTEX SEARCH SERVICE IF EXISTS WORKOUT_SEARCH_SERVICE;

-- Create Cortex Search Service
-- Target column: EMBED_STR (workout instructions/description to be embedded)
-- Attributes: Metadata fields that can be used for filtering (VARIANT types not supported)
CREATE CORTEX SEARCH SERVICE WORKOUT_SEARCH_SERVICE
ON EMBED_STR
ATTRIBUTES ID, SPORT_TYPE, DIFFICULTY, MOVING_TIME_SECONDS, DISTANCE_METERS, 
           GENERATION_MODEL, WORKOUT_SOURCE, STORE_VERSION
WAREHOUSE = STRAVA_DEMO_WH
TARGET_LAG = '1 minute'
AS (
    SELECT 
        ID,
        EMBED_STR,
        SPORT_TYPE,
        DIFFICULTY,
        MOVING_TIME_SECONDS,
        DISTANCE_METERS,
        GENERATION_MODEL,
        WORKOUT_SOURCE,
        STORE_VERSION
    FROM WORKOUTS
);

-- Wait for the service to initialize (1-2 minutes)
-- Check service status
SHOW CORTEX SEARCH SERVICES;

-- View service details
DESC CORTEX SEARCH SERVICE WORKOUT_SEARCH_SERVICE;

-- =====================================================
-- STEP 6: TEST THE CORTEX SEARCH SERVICE
-- =====================================================
-- Simple test query to verify the service is working

SELECT 
    result.value:ID::VARCHAR AS ID,
    LEFT(result.value:EMBED_STR::VARCHAR, 100) AS WORKOUT_PREVIEW,
    result.value:SPORT_TYPE::VARCHAR AS SPORT_TYPE,
    result.value:DIFFICULTY::VARCHAR AS DIFFICULTY,
    ROUND(TRY_CAST(result.value:DISTANCE_METERS::VARCHAR AS INT) / 1000.0, 1) AS DISTANCE_KM,
    ROUND(TRY_CAST(result.value:MOVING_TIME_SECONDS::VARCHAR AS INT) / 60.0, 0) AS DURATION_MIN
FROM TABLE(FLATTEN(
    PARSE_JSON(
        SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
            'STRAVA_DEMO_SAMPLE.VECTOR_SEARCH_DEMO.WORKOUT_SEARCH_SERVICE',
            '{
                "query": "5k interval run workout",
                "columns": ["ID", "EMBED_STR", "SPORT_TYPE", "DIFFICULTY", "DISTANCE_METERS", "MOVING_TIME_SECONDS"],
                "filter": {"@eq": {"SPORT_TYPE": "run"}},
                "limit": 5
            }'
        )
    )['results']
)) result;

-- =====================================================
-- SETUP COMPLETE!
-- =====================================================
/*
Next Steps:
1. The Cortex Search service is now ready for querying
2. Use the 03_cortex_search_demo_notebook.ipynb for interactive demos
3. The service will automatically:
   - Generate embeddings for all workout descriptions
   - Update embeddings when new workouts are added (TARGET_LAG = 1 minute)
   - Handle semantic search queries via SEARCH_PREVIEW function

Production Notes:
- Service uses XSMALL warehouse for index maintenance (background tasks)
- Query execution is serverless (handled by Cortex, not your warehouse)
- For 1000 QPS requirement, test at scale or consider 02_vector_embedding_brute_force.sql
*/


