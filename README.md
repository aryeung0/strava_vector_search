# Strava Workout Vector Search Demo

## Overview

This demo showcases two methods for implementing semantic vector search for Strava's workout caching system using Snowflake. The use case is to build an intelligent caching layer that can semantically match user workout requests to existing workouts, reducing the computational cost of generating new workouts from scratch.

### Business Context

**Customer**: Strava  
**Primary Contact**: Leo Neat (Senior ML Engineer)  
**Use Case**: Vector Search / Semantic Caching for Workout Generation

### Problem

Strava's workout generation system is computationally expensive. They want to implement a smart caching layer that can semantically match user requests (e.g., "5k interval run workout") to existing workouts, enabling reuse instead of generating new workouts.

**Requirements**:
- Handle ~10,000 workout documents (demo uses 500 samples)
- Peak load: 1,000 requests/sec for 24 hours once per week
- Baseline load: 1-2 requests/sec
- Latency target: ~300ms (focus on p50 over p99)

## Methods

This demo provides two implementation approaches:

### Method 1: Cortex Search (`01_method1_cortex_search.sql`)
- **Best For**: Simplicity, serverless scaling, rapid deployment
- **Technology**: Cortex Search Service (fully managed)
- **Pros**: 
  - Serverless and auto-scaling
  - Simple to set up and maintain
  - Optimized for semantic search with metadata filtering
  - Automatic embedding generation
- **Cons**: 
  - May have concurrency limits at 1000 req/sec
  - Less control over query execution

### Method 2: Manual Vector Embedding (`02_method2_manual_vector_embedding.sql`)
- **Best For**: High concurrency (1000 QPS), maximum control
- **Technology**: Direct VECTOR data type with cosine similarity
- **Pros**: 
  - Full control over concurrency via warehouse scaling
  - Predictable performance with multi-cluster warehouses
  - Can batch queries for efficiency
  - No service-level concurrency limits
- **Cons**: 
  - More complex to set up
  - Requires manual embedding management
  - Higher compute costs for large-scale deployments

## Getting Started

### Prerequisites
- Snowflake account with Cortex features enabled
- `ACCOUNTADMIN` role or equivalent permissions
- No pre-existing warehouse needed (scripts create `STRAVA_DEMO_WH` automatically)

### Instructions

#### Step 1: Choose Your Method

**For initial testing and simplicity**: Start with Method 1 (`01_method1_cortex_search.sql`)  
**For production at 1000 QPS**: Use Method 2 (`02_method2_manual_vector_embedding.sql`)

#### Step 2: Run the SQL Script

Open your chosen SQL file in Snowflake and execute the entire script. Each script will:
- Create necessary warehouse and role
- Generate 500 realistic workout samples
- Set up the search infrastructure
- Provide example queries to test

#### Step 3: Test Semantic Search

Both scripts include multiple example queries at the end. Follow the examples in each script to test semantic search functionality.

**Example user requests to test**:
- "5k interval run workout with speed training"
- "10 kilometer steady training run"
- "easy recovery run under 30 minutes"
- "cycling endurance ride 2 hours"

#### Step 4: Evaluate Results

Results are ranked by similarity score (0.0 to 1.0):
- **> 0.90**: Excellent match (cache hit)
- **0.80-0.89**: Very good match (likely cache hit)
- **0.70-0.79**: Good match (consider cache hit)
- **< 0.70**: Poor match (generate new workout)

## Additional Files

- **`03_cortex_search_demo_notebook.ipynb`** - Interactive Jupyter notebook demonstrating search queries
- **`04_cleanup_schema.sql`** - Script to clean up demo resources when finished
- **`00_sample_workout_data.csv`** - Sample workout data used in the demo

## Cleanup

When finished testing, run `04_cleanup_schema.sql` to remove all demo resources (database, schema, warehouse, and role).

---

**Last Updated**: October 15, 2025  
**Version**: 1.1  
**Demo Status**: Ready for customer testing
