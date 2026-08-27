-- 1. Create a standard stream on raw_orders

USE ROLE data_engineer;
USE WAREHOUSE project_wh;
USE DATABASE snowflake_platform_project;
USE SCHEMA snowflake_platform_project.raw;  


GRANT CREATE TABLE, CREATE STAGE, CREATE FILE FORMAT, CREATE STREAM, CREATE TASK, CREATE PIPE -- upd day 3
ON SCHEMA snowflake_platform_project.raw TO ROLE data_engineer;

-- current role dosen't have permisiion to CREATE STREAM

CREATE STREAM orders_stream 
ON TABLE raw_orders;

-- Stream ORDERS_STREAM successfully created.

INSERT INTO raw_orders (order_id, customer_id, order_date, order_total, status)
VALUES (9999901, 123, CURRENT_DATE(), 42.50, 'placed');

-- number of rows inserted 1

UPDATE raw_orders SET status = 'shipped' WHERE order_id = 9999901;

-- number of rows updated 1
-- number of multi-joined rows updated 0

SELECT order_id, status, METADATA$ACTION, METADATA$ISUPDATE
FROM orders_stream
WHERE order_id = 9999901;

-- ORDER_ID 9999901
-- STATUS shipped
-- METADATA$ACTION INSERT
-- METADATA$ISUPDATE FALSE

-- 2. Build a Task DAG (root + child)

CREATE TABLE orders_status_summary (
  status STRING,
  order_count INT,
  last_updated TIMESTAMP
);

-- status Table ORDERS_STATUS_SUMMARY successfully created.


GRANT EXECUTE TASK ON ACCOUNT TO ROLE data_engineer; -- upd day 3

-- current role dosen't have permisiion to EXECUTE TASK

CREATE TASK root_process_orders_stream
  WAREHOUSE = project_wh
  SCHEDULE = '5 MINUTE'
AS
  MERGE INTO orders_status_summary tgt
  USING (
    SELECT status, COUNT(*) AS cnt
    FROM orders_stream
    GROUP BY status
  ) src
  ON tgt.status = src.status
  WHEN MATCHED THEN UPDATE SET order_count = src.cnt, last_updated = CURRENT_TIMESTAMP()
  WHEN NOT MATCHED THEN INSERT (status, order_count, last_updated)
    VALUES (src.status, src.cnt, CURRENT_TIMESTAMP());

-- status Task ROOT_PROCESS_ORDERS_STREAM successfully created.

CREATE TASK child_log_summary_change
  WAREHOUSE = project_wh
  AFTER root_process_orders_stream
AS
  INSERT INTO summary_change_log
  SELECT *, CURRENT_TIMESTAMP() FROM orders_status_summary;

-- status Task CHILD_LOG_SUMMARY_CHANGE successfully created.

ALTER TASK child_log_summary_change RESUME;

-- status Statement executed successfully.

ALTER TASK root_process_orders_stream RESUME;

-- status Statement executed successfully.

SELECT name, state, scheduled_time, completed_time
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY())
ORDER BY scheduled_time DESC
LIMIT 10;

-- result saved as csv. (3_2_2026-08-26-1509.csv)

-- 3. Stream staleness and SYSTEM$STREAM_HAS_DATA

SELECT SYSTEM$STREAM_HAS_DATA('orders_stream');

-- SYSTEM$STREAM_HAS_DATA('ORDERS_STREAM') FALSE

UPDATE raw_orders SET status = 'delivered' WHERE order_id = 9999901;
-- number of rows updated 1
-- number of multi-joined rows updated 0

SELECT SYSTEM$STREAM_HAS_DATA('orders_stream');

-- SYSTEM$STREAM_HAS_DATA('ORDERS_STREAM') TRUE

SHOW STREAMS LIKE 'orders_stream';

-- result saved as csv. (3_3_2026-08-26-1517.csv)
-- stale false

SELECT TABLE_NAME, RETENTION_TIME
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_NAME = 'RAW_ORDERS';

-- TABLE_NAME RAW_ORDERS
-- RETENTION_TIME 1

-- Since the retention is only 1 day, and the task is suspended for a week (7 days), the stream is guaranteed to become stale much earlier than the week has passed. 
-- Specifically: if the root task is not run for more than 1 day, the stream offset already goes beyond the limits of what raw_orders still remembers about its change history, and SHOW STREAMS will show stale = true. 
-- After that, the stream will no longer be able to correctly "catch up" with the missed changes. It will have to be dropped and recreated again (losing visibility of what changed during the downtime).

-- 4. Fan-out — a second task off the same stream

CREATE TABLE order_status_anomalies (
  order_id INT,
  detail STRING,
  flagged_at TIMESTAMP
);
-- status Table ORDER_STATUS_ANOMALIES successfully created.

CREATE TASK root_flag_status_anomalies
  WAREHOUSE = project_wh
  SCHEDULE = '5 MINUTE'
AS
  INSERT INTO order_status_anomalies (order_id, detail, flagged_at)
  SELECT order_id, 'jumped to delivered without shipped', CURRENT_TIMESTAMP()
  FROM orders_stream
  WHERE status = 'delivered' AND METADATA$ACTION = 'INSERT';

-- status Task ROOT_FLAG_STATUS_ANOMALIES successfully created.

ALTER TASK root_flag_status_anomalies RESUME;

-- status Statement executed successfully.

-- Consumers that read independently should use SEPARATE streams per table if each needs its own, independent copy of the change history. 
-- A single orders_stream read by two different tasks is a race condition: whoever reads it first gets the change, the second one gets an empty one.

-- 5. Task failure handling
USE ROLE data_engineer;
USE WAREHOUSE project_wh;
USE DATABASE snowflake_platform_project;
USE SCHEMA snowflake_platform_project.raw; 

CREATE TASK broken_task
  WAREHOUSE = project_wh
  SCHEDULE = '5 MINUTE'
  SUSPEND_TASK_AFTER_NUM_FAILURES = 3
AS
  INSERT INTO this_table_does_not_exist SELECT * FROM orders_stream;

-- status Task BROKEN_TASK successfully created.

ALTER TASK broken_task RESUME;

-- status Statement executed successfully.

SELECT name, state, error_message, scheduled_time, completed_time
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY())
WHERE name = 'BROKEN_TASK'
ORDER BY scheduled_time DESC;

-- result saved as csv. (3_5_2026-08-26-2041.csv)

SHOW TASKS LIKE 'broken_task';

-- result saved as csv. (3_5_SHOW_TASKS_2026-08-26-2046.csv)

DROP TASK broken_task;
-- 6. Detect and handle schema drift in raw_orders_batch2.csv

ALTER TABLE raw_orders ADD COLUMN IF NOT EXISTS fulfillment_channel STRING;

-- status Statement executed successfully.

-- generate the raw_orders_batch2.csv 
-- IMPORTANT to mention that in task dosen't mention any word about creating this file and how to lad tme into Snowflake
-- LOADED INTO @raw_stage

COPY INTO raw_orders (order_id, customer_id, order_date, order_total, status, fulfillment_channel)
FROM (
  SELECT $1, $2, $3, $4, $5, $6 
  FROM @raw_stage/raw_orders_batch2.csv
)
FILE_FORMAT = (FORMAT_NAME = csv_ff)
ON_ERROR = 'CONTINUE';

-- status LOADED 
-- rows_parsed 50000
-- rows_loaded 50000
-- errors_seen 0

SELECT COUNT(*) FROM raw_orders;

-- COUNT(*) 1050498

-- 7. Snowpipe on the batch-2 location

CREATE PIPE batch2_pipe
  AUTO_INGEST = FALSE
AS
  COPY INTO raw_orders (order_id, customer_id, order_date, order_total, status, fulfillment_channel)
  FROM (
    SELECT $1, $2, $3, $4, $5, $6 
    FROM @raw_stage
  )
  FILE_FORMAT = (FORMAT_NAME = csv_ff)
  ON_ERROR = 'CONTINUE';

  -- status Pipe BATCH2_PIPE successfully created.
