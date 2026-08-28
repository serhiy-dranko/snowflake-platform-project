-- 1. Baseline — measure before touching anything
USE ROLE data_engineer;
USE WAREHOUSE project_wh;
USE DATABASE snowflake_platform_project;
USE SCHEMA snowflake_platform_project.raw;

SELECT SYSTEM$CLUSTERING_INFORMATION(
  'snowflake_sample_data.tpch_sf10.lineitem', '(l_shipdate)'
);

-- "average_depth" : 116.0,
-- If filter WHERE l_shipdate BETWEEN '1995-01-01' AND '1995-01-31', Snowflake technically cannot exclude any partition. 
-- Desired date could theoretically be in any of the 116, so it would have to scan almost the entire table, even though the filter looks very selective

-- 2. Apply and verify a clustering key

CREATE OR REPLACE TABLE snowflake_platform_project.raw.lineitem_clustered
  CLUSTER BY (l_shipdate)
AS
SELECT * FROM snowflake_sample_data.tpch_sf10.lineitem;

-- SQL execution error: Creating table on shared database 'SNOWFLAKE_SAMPLE_DATA' is not allowed.
-- switch from lineitem_clustered to snowflake_platform_project.raw.lineitem_clustered
-- Table LINEITEM_CLUSTERED successfully created.

SELECT SYSTEM$CLUSTERING_INFORMATION('snowflake_platform_project.raw.lineitem_clustered', '(l_shipdate)');

-- "average_depth" : 2.0

SELECT COUNT(*) FROM snowflake_sample_data.tpch_sf10.lineitem
WHERE l_shipdate BETWEEN '1995-01-01' AND '1995-01-31';

-- COUNT(*) 775032

SELECT COUNT(*) FROM snowflake_platform_project.raw.lineitem_clustered
WHERE l_shipdate BETWEEN '1995-01-01' AND '1995-01-31';

-- COUNT(*) 775032

-- Yes, it's definitely worth it. The `lineitem` table is very large here, and queries almost always filter by date. 
-- The one-time cost of rewriting a table with a clustering key pays for itself with every subsequent query that previously scanned 100% of the data but now scans only a few percent. 
-- In production, I would apply a clustering key specifically to such large tables that are consistently filtered by a single column

-- 3. Result cache vs. warehouse cache vs. cold read

-- Run 1: cold baseline (note the timing)

SELECT l_returnflag, COUNT(*), SUM(l_extendedprice)
FROM snowflake_sample_data.tpch_sf10.lineitem
GROUP BY l_returnflag;

-- Compilation 753 ms
-- Queued provisioning 218 ms
-- Execution 576 ms
-- Total 1.5 s

-- Run 2: identical query again immediately (result cache)

SELECT l_returnflag, COUNT(*), SUM(l_extendedprice)
FROM snowflake_sample_data.tpch_sf10.lineitem
GROUP BY l_returnflag;

-- Compilation 92 ms
-- Execution 19 ms
-- Total 111 ms

-- Run 3: a DIFFERENT query against the SAME table, warehouse still warm (warehouse cache)

SELECT l_linestatus, COUNT(*), AVG(l_discount)
FROM snowflake_sample_data.tpch_sf10.lineitem
GROUP BY l_linestatus;

-- Compilation 290 ms
-- Execution 321 ms
-- Total 611 ms

-- Force a cold state, then repeat Run 1

ALTER WAREHOUSE project_wh SUSPEND;
ALTER WAREHOUSE project_wh RESUME;

SELECT l_returnflag, COUNT(*), SUM(l_extendedprice)
FROM snowflake_sample_data.tpch_sf10.lineitem
GROUP BY l_returnflag;

-- Compilation 167 ms
-- Execution 17 ms
-- Total 184 ms

-- Suspending and resuming didn't actually erase the speed advantage in our test Run 4 came back at 184ms, close to the result-cache speed, not the 1.5s cold baseline. 
-- Because the result cache lives at the Snowflake service/metadata layer, independent of any warehouse, so it survives suspend/resume as long as the query text is identical and the data hasn't changed. 
-- What suspend/resume does erase is the warehouse's local disk cache, which is why a different query re-run after suspend/resume would go back to cold-read speed.

-- 4. Scale up — one query, bigger single warehouse

CREATE WAREHOUSE IF NOT EXISTS scale_up_test_wh WAREHOUSE_SIZE = 'XSMALL' AUTO_SUSPEND = 60;

-- status Warehouse SCALE_UP_TEST_WH successfully created.
USE WAREHOUSE scale_up_test_wh;

SELECT * FROM snowflake_sample_data.tpch_sf100.lineitem
LIMIT 15000000;


-- Compilation 545 ms
-- Queued provisioning 251 ms
-- Execution 11 s

ALTER WAREHOUSE scale_up_test_wh SUSPEND;

-- sytatus Statement executed successfully.

ALTER WAREHOUSE scale_up_test_wh SET WAREHOUSE_SIZE = 'LARGE';

-- sytatus Statement executed successfully.

ALTER WAREHOUSE scale_up_test_wh RESUME;

-- sytatus Statement executed successfully.

ALTER SESSION SET USE_CACHED_RESULT = FALSE; -- exclude cached result XS Small

SELECT * FROM snowflake_sample_data.tpch_sf100.lineitem
LIMIT 15000000;

-- Compilation 906ms
-- Queued provisioning 197ms
-- Execution 3.5s


-- 5. Scale out — multi-cluster, concurrent queries

CREATE WAREHOUSE IF NOT EXISTS concurrency_test_wh
  WAREHOUSE_SIZE = 'XSMALL'
  WAREHOUSE_TYPE = 'STANDARD'
  MIN_CLUSTER_COUNT = 1
  MAX_CLUSTER_COUNT = 1
  AUTO_SUSPEND = 60;

USE WAREHOUSE concurrency_test_wh;

-- sytatus Statement executed successfully.

ALTER WAREHOUSE concurrency_test_wh SET MAX_CLUSTER_COUNT = 4;

-- sytatus Statement executed successfully.


-- Tab 1

USE WAREHOUSE concurrency_test_wh;
ALTER SESSION SET USE_CACHED_RESULT = FALSE;
SELECT l_returnflag, l_linestatus, SUM(l_quantity), AVG(l_extendedprice)
FROM snowflake_sample_data.tpch_sf10.lineitem
WHERE l_shipdate <= '1998-09-01'
GROUP BY l_returnflag, l_linestatus;

-- Run 1
-- Compilation 929ms
-- Queued provisioning 95ms
-- Execution 782ms
-- Total 1.8 s

-- Run 2
-- Compilation 986ms
-- Execution 834ms
-- Total 1.8 s

-- Tab 2

USE WAREHOUSE concurrency_test_wh;
ALTER SESSION SET USE_CACHED_RESULT = FALSE;
SELECT c_mktsegment, COUNT(*), SUM(o_totalprice)
FROM snowflake_sample_data.tpch_sf10.customer c
JOIN snowflake_sample_data.tpch_sf10.orders o ON c.c_custkey = o.o_custkey
GROUP BY c_mktsegment;

-- Run 1
-- Compilation 339 ms
-- Execution 712 ms 
-- Total 1.1 s

-- Run 2
-- Compilation 702 ms
-- Execution 595 ms
-- Total 1.3 s

-- Tab 3

USE WAREHOUSE concurrency_test_wh;
ALTER SESSION SET USE_CACHED_RESULT = FALSE;
SELECT s_nationkey, COUNT(*), AVG(ps_supplycost)
FROM snowflake_sample_data.tpch_sf10.supplier s
JOIN snowflake_sample_data.tpch_sf10.partsupp ps ON s.s_suppkey = ps.ps_suppkey
GROUP BY s_nationkey;

-- Run 1
-- Compilation 139 ms
-- Execution 393 ms
-- Total 532 s

-- Run 2
-- Compilation 106 ms
-- Execution 442 ms
-- Total 548 ms

-- Tab 4

USE WAREHOUSE concurrency_test_wh;
ALTER SESSION SET USE_CACHED_RESULT = FALSE;
SELECT p_brand, COUNT(*), AVG(p_retailprice)
FROM snowflake_sample_data.tpch_sf10.part
GROUP BY p_brand;

-- Run 1
-- Compilation 302 ms
-- Execution 218 ms
-- Total 520 ms

-- Run 2
-- Compilation 75 ms
-- Execution 231 ms
-- Total 306 ms

-- 6. Read a query profile for spillage

SELECT query_id, query_text, total_elapsed_time, bytes_spilled_to_local_storage, bytes_spilled_to_remote_storage

FROM TABLE(snowflake_platform_project.INFORMATION_SCHEMA.QUERY_HISTORY())
WHERE warehouse_name IN ('SCALE_UP_TEST_WH', 'PROJECT_WH', 'CONCURRENCY_TEST_WH')
    AND query_text != 'CALL SYSTEM$WAIT(15);'
ORDER BY total_elapsed_time DESC
LIMIT 5;

--- bytes_spilled_to_local_storage do not have this column in QUERY_HISTORY()

SELECT query_id, query_text, total_elapsed_time, bytes_spilled_to_local_storage,
       bytes_spilled_to_remote_storage
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE warehouse_name IN ('SCALE_UP_TEST_WH', 'PROJECT_WH', 'CONCURRENCY_TEST_WH')
   ORDER BY total_elapsed_time DESC
LIMIT 5;

-- 7. Resource monitor with multiple thresholds.

USE ROLE accountadmin;

CREATE OR REPLACE RESOURCE MONITOR project_week_monitor
  WITH CREDIT_QUOTA = 20
  FREQUENCY = DAILY
  START_TIMESTAMP = IMMEDIATELY
  TRIGGERS
    ON 50 PERCENT DO NOTIFY
    ON 75 PERCENT DO NOTIFY
    ON 100 PERCENT DO SUSPEND
    ON 110 PERCENT DO SUSPEND_IMMEDIATE;
-- Resource monitor PROJECT_WEEK_MONITOR successfully created.
ALTER WAREHOUSE project_wh SET RESOURCE_MONITOR = project_week_monitor;
-- sytatus Statement executed successfully.
ALTER WAREHOUSE scale_up_test_wh SET RESOURCE_MONITOR = project_week_monitor;
-- sytatus Statement executed successfully.
ALTER WAREHOUSE concurrency_test_wh SET RESOURCE_MONITOR = project_week_monitor;
-- sytatus Statement executed successfully.
USE ROLE data_engineer;
-- sytatus Statement executed successfully.

-- SUSPEND at 100% blocks new queries but lets running ones finish, avoiding mid-write data corruption.
-- SUSPEND_IMMEDIATE at 110% is a backstop are kills overshooting queries if the buffer isn't enough. 
-- Pure SUSPEND_IMMEDIATE at 100% would be stricter on cost but risks corrupting in procces queries.

-- 8. Check the real cost of today


SELECT warehouse_name, SUM(credits_used) AS total_credits
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= DATEADD(hour, -6, CURRENT_TIMESTAMP())
GROUP BY warehouse_name
ORDER BY total_credits DESC;

-- PROJECT_WH 1.892941110
-- CONCURRENCY_TEST_WH 0.420462503
-- SCALE_UP_TEST_WH 0.396168889
-- COMPUTE_WH 0.554945001
-- Total 3.264517503

-- Saved as csv. (4_8_2026-08-28-1004.csv)

--- PROJECT_WH cost the most (1.89 credits), which is logical it carried the main part of the week's work, including copying the huge lineitem table for today's clustering test. 
--- Among the three warehouses created just for today, SCALE_UP_TEST_WH was cheapest despite being sized to LARGEtat is confirming that cost depends on runtime duration as much as warehouse size.

DROP WAREHOUSE IF EXISTS scale_up_test_wh;
DROP WAREHOUSE IF EXISTS concurrency_test_wh;
