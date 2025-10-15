-- =====================================================
-- STRAVA VECTOR SEARCH DEMO - CLEANUP SCRIPT
-- =====================================================
-- This script cleans up the demo schema while preserving:
-- - Database (STRAVA_DEMO_SAMPLE)
-- - Role (STRAVA_DEMO_ADMIN)
-- - Warehouse (STRAVA_DEMO_WH)
-- - Data in WORKOUTS table
--
-- Use this to reset the demo environment
-- =====================================================

USE ROLE STRAVA_DEMO_ADMIN;
USE DATABASE STRAVA_DEMO_SAMPLE;
USE SCHEMA VECTOR_SEARCH_DEMO;
USE WAREHOUSE STRAVA_DEMO_WH;

-- =====================================================
-- STEP 1: DROP CORTEX SEARCH SERVICE
-- =====================================================
-- Remove the Cortex Search service (can be recreated with 01 script)

DROP CORTEX SEARCH SERVICE IF EXISTS WORKOUT_SEARCH_SERVICE;

-- Verify service is dropped
SHOW CORTEX SEARCH SERVICES;

-- =====================================================
-- STEP 2: DROP STAGE (OPTIONAL)
-- =====================================================
-- Remove the staging area used for CSV loading

DROP STAGE IF EXISTS WORKOUT_STAGE;

-- =====================================================
-- STEP 3: DROP TEMPORARY TABLES (IF ANY)
-- =====================================================
-- Clean up any temporary tables created during demos

-- Drop temp tables created in notebook demos
DROP TABLE IF EXISTS MARATHON_SEARCH_RESULTS;

-- =====================================================
-- STEP 4: OPTIONAL - DROP AND RECREATE SCHEMA
-- =====================================================
-- Uncomment these lines if you want to completely reset the schema
-- This will DELETE ALL DATA including the WORKOUTS table!

-- DROP SCHEMA IF EXISTS VECTOR_SEARCH_DEMO CASCADE;
-- CREATE SCHEMA VECTOR_SEARCH_DEMO;

-- =====================================================
-- STEP 5: OPTIONAL - DROP WORKOUTS TABLE
-- =====================================================
-- Uncomment if you want to remove the data table as well
-- WARNING: This will delete all 1000 workout records!

-- DROP TABLE IF EXISTS WORKOUTS;

-- =====================================================
-- VERIFICATION
-- =====================================================
-- Check what objects remain

SHOW TABLES IN SCHEMA VECTOR_SEARCH_DEMO;
SHOW STAGES IN SCHEMA VECTOR_SEARCH_DEMO;
SHOW CORTEX SEARCH SERVICES IN SCHEMA VECTOR_SEARCH_DEMO;

-- =====================================================
-- CLEANUP COMPLETE!
-- =====================================================
/*
What was removed:
 Cortex Search Service (WORKOUT_SEARCH_SERVICE)
 Staging area (WORKOUT_STAGE)
 Temporary tables (MARATHON_SEARCH_RESULTS)

What was preserved:
 Database (STRAVA_DEMO_SAMPLE)
 Schema (VECTOR_SEARCH_DEMO)
 Role (STRAVA_DEMO_ADMIN)
 Warehouse (STRAVA_DEMO_WH)
 Data table (WORKOUTS with 2000 rows)

To rebuild:
1. Run: 01_cortex_search_setup.sql (STEP 5 onwards) for Cortex Search service

To completely start over:
1. Uncomment STEP 4 in this script to drop the schema
2. Run the full 01_cortex_search_setup.sql script
*/


