# Snowflake Platform Project

A five-day, hands-on build of a small but complete Snowflake platform at 14th Week in Dataskools: role-based access, bulk and
streaming ingestion, semi-structured data, a reactive Stream/Task/Snowpipe pipeline, and a
performance-and-cost pass at real TPC-H scale.

## Environment

- Database: `SNOWFLAKE_PLATFORM_PROJECT`, schema `RAW`
- Warehouse: `PROJECT_WH` (X-Small, auto-suspend 60s)
- Roles: `SYSADMIN` → `DATA_ENGINEER` (load/transform), `ANALYST_READONLY` (SELECT only, via
  future grants)
- Resource monitor `PROJECT_WEEK_MONITOR` (20-credit quota, NOTIFY at 50%/75%, SUSPEND at 100%,
  SUSPEND_IMMEDIATE at 110%) attached to every warehouse used this week

## Project structure

```
snowflake-platform-project/
├── README.md
├── sql/
│   ├── day1_setup_and_load.sql
│   ├── day2_variant_and_time_travel.sql
│   ├── day_3_steam_task_execute_task_pipe.sql
│   └── day_4_performance_and_cost.sql
└── data/
│   ├── late_orders.csv                    (sample file with deliberate bad rows)
│   ├── raw_order_items.json               (nested JSON: orders → items → modifiers)
│   ├── raw_orders_batch2.csv              (50K rows, deliberate schema drift)
│   └── sql_results/
│        ├── 3_2_2026-08-26-1509.csv
│        ├── 3_3_2026-08-26-1517.csv
│        ├── 3_5_2026-08-26-2041.csv
│        ├── 3_6_2026-08-27-0931.csv
│        ├── 4_6_2026-08-28-0939.csv
│        └── 4_8_2026-08-28-1004.csv
└── screenshots/
    ├── day_1/
    │   ├── analyst_readonly_failing.png   (proof that analyst role has permission only for Select)
    │   ├── raw_customers.png              (count of rows in table)
    │   └── raw_orders.png                 (count of rows in table)
    └── day_2/
        ├── bug_count.png
        ├── dev_orders_change.png
        ├── dev_orders_check.png
        ├── history_check.png
        ├── one_level_items.png
        ├── two_levels_items.png
        ├── query_history.png
        ├── raw_orders_check.png
        ├── retention_days_check.png
        └── time_travel_recovery.png

```

## What each day added

---

**Day 1 - Foundations.** Database, schema, X-Small warehouse; a `SYSADMIN → DATA_ENGINEER /
ANALYST_READONLY` role hierarchy with future grants; `raw_customers` (50K) and `raw_orders` (1M+)
generated with `GENERATOR`/`SEQ8`/`UNIFORM`; a real stage-based CSV load with 3 deliberately bad
rows, verified through `VALIDATION_MODE` and `COPY_HISTORY`.

**Day 2 - Semi-structured data & recovery.** A nested JSON file (orders → items → modifiers) loaded
into a `VARIANT` column and unpacked with two chained `FLATTEN`/`LATERAL` calls, `OUTER => TRUE`
proven against a row-count check. A view and a materialized view compared on cost/benefit. A
deliberate bad `UPDATE` on `raw_orders`, recovered with Time Travel (`BEFORE (STATEMENT => ...)`,
not `UNDROP`). A zero-copy clone (`dev_orders`) proven independent of the original.

**Day 3 - Reactive pipeline.** A standard Stream on `raw_orders` feeding a Task DAG
(`root_process_orders_stream` → `child_log_summary_change`, proven sequential via `TASK_HISTORY`),
plus a second fan-out task on its own stream for anomaly detection. A task deliberately broken to
confirm real error text and `SUSPEND_TASK_AFTER_NUM_FAILURES`. Schema drift in a 50K-row batch file
(renamed column, new column) handled by widening the target table. Snowpipe wired up and triggered
via `ALTER PIPE ... REFRESH`.

**Day 4 - Performance & cost.** A clustering key on a 10M+-row TPC-H table took `average_depth` from
116 to 2 and partition scans from 116/116 to 2/51 for the same date filter. Result cache, warehouse
cache, and cold reads timed separately (1.5s → 111ms → 611ms → 184ms) to show they're genuinely
different mechanisms. Scale-up (XSMALL→LARGE) cut a heavy join from 11s to 3.5s; scale-out testing
was inconclusive at this data volume (see below). A resource monitor with a notify/suspend/
suspend-immediate ladder was attached to every warehouse, and real credit cost was pulled from
`WAREHOUSE_METERING_HISTORY`.

**Day 5 - Presentation**
