# Snowflake Platform Project

A week-long, hands-on Snowflake learning project at 14th Week in Dataskool.

## Project structure

```
snowflake-platform-project/
├── README.md
├── sql/
│   ├── day1_setup_and_load.sql
│   ├── day2_variant_and_time_travel.sql
│   └── day_3_steam_task_execute_task_pipe.sql
└── data/
│   ├── late_orders.csv                    (sample file with deliberate bad rows)
│   ├── raw_order_items.json               (nested JSON: orders → items → modifiers)
│   ├── raw_orders_batch2.csv              (50K rows, deliberate schema drift)
│   └── sql_results/
│        ├── 3_2_2026-08-26-1509.csv
│        ├── 3_3_2026-08-26-1517.csv
│        ├── 3_5_2026-08-26-2041.csv
│        └── 3_6_2026-08-27-0931.csv
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

## Environment

- Database: `SNOWFLAKE_PLATFORM_PROJECT`
- Schema: `RAW`
- Warehouse: `PROJECT_WH` (X-Small, auto-suspend 60s)
- Roles: `SYSADMIN` → `DATA_ENGINEER` (load/transform), `ANALYST_READONLY` (SELECT only, via
  future grants)

---

## Day 1 — Account Setup, Role Hierarchy, Warehouses, Loading at Scale

**Built:**
- Database, `RAW` schema, X-Small warehouse
- Role hierarchy under `SYSADMIN`, with `GRANT SELECT ON FUTURE TABLES` for `ANALYST_READONLY`
- `raw_customers` (~50K rows) and `raw_orders` (1M+ rows), generated via `GENERATOR` / `SEQ8` /
  `UNIFORM`
- Real file load path: CSV with 3 deliberately malformed rows → `PUT` → `VALIDATION_MODE` →
  `COPY INTO ... ON_ERROR='CONTINUE'` → verified via `COPY_HISTORY`
- Grants independently verified with `SHOW GRANTS` (not just the role-switch test)

**Real issues hit and fixed (not in the original plan — genuine debugging practice):**
- `ARRAY_CONSTRUCT(...)[UNIFORM(...)]` returns `VARIANT`, not `VARCHAR` — CSV-exported values came
  out double-quoted (`"""placed"""`). Fixed by casting to `::STRING` in the `SELECT`, which requires
  `CREATE OR REPLACE TABLE ... AS SELECT` (an `UPDATE` can't change a column's underlying type).
- Wrong staged file name (`.csv` vs assumed `.csv.gz`) silently returned zero rows instead of an
  error — always confirm the exact name with `LIST @stage;` first.
- `VARIANT` status column caused `COPY INTO` to try (and fail) parsing every plain-text value as
  JSON, masking the real malformed-row errors underneath a wall of `Error parsing JSON` noise.

**Result:** 497 of 500 late-arriving rows loaded; 3 deliberately bad rows rejected and confirmed via
`COPY_HISTORY`; grants confirmed to survive re-verification.

---

## Day 2 — Semi-Structured Data, Views, Time Travel, Cloning

**Built:**
- `raw_order_items.json` (3,000 orders, 7,544 items, 7,492 modifiers, 2,287 items with zero
  modifiers) loaded into a `VARIANT` column
- Two-level `FLATTEN` + `LATERAL` (items, then modifiers), row counts sanity-checked at each level:
  - Items only: 7,544 rows
  - Modifiers, no `OUTER => TRUE`: 7,492 rows (items with empty modifier arrays silently dropped)
  - Modifiers, with `OUTER => TRUE`: 9,779 rows = 7,492 + 2,287 (empty-modifier items kept, `NULL`)
- `vw_order_item_totals` (view) and `mv_order_item_totals` (materialized view) — both return 3,000
  rows. **Decision:** a plain view is the right call here — the underlying query is cheap (small
  table, one `FLATTEN` + `SUM`) and the base data is static, so a materialized view's storage and
  background-maintenance cost wouldn't be justified.
- Deliberate bad `UPDATE` on `raw_orders`, recovered via Time Travel `BEFORE (STATEMENT => query_id)`
  rather than `UNDROP`
- Zero-copy clone `dev_orders`, modified independently, confirmed `raw_orders` untouched
- `DATA_RETENTION_TIME_IN_DAYS` = 1 (account default) — a mistake caught more than a day late
  would need Fail-safe (Enterprise+, Snowflake Support only) or an external backup instead.

**Real issues hit and fixed:**
- `UNIFORM(0, 1, RANDOM())` with integer bounds returns an *integer* (0 or 1, 50/50), not a float —
  so `WHERE UNIFORM(0,1,RANDOM()) < 0.1` corrupted ~50% of rows instead of the intended ~10%. Fix:
  use float bounds (`UNIFORM(0::FLOAT, 1::FLOAT, RANDOM())`) or an integer range check instead
  (`UNIFORM(1,10,RANDOM()) = 1`).
- `INFORMATION_SCHEMA.TABLES` does not have a `DATA_RETENTION_TIME_IN_DAYS` column — that name only
  applies to the object parameter (`SHOW PARAMETERS ... IN TABLE ...`). The equivalent
  `INFORMATION_SCHEMA` column is `RETENTION_TIME`.
- Session repeatedly lost its database/schema context ("This session does not have a current
  database") — worked around by fully qualifying every object
  (`snowflake_platform_project.raw.<object>`) rather than relying on `USE DATABASE` / `USE SCHEMA`
  persisting.

**Result:** both flatten levels verified by row count, Time Travel recovery brought corrupted-row
count from 500,278 back to 0, clone divergence test passed, retention window documented.

---

## Day 3 — Streams, Task DAGs, Snowpipe

**Built:**
- Standard stream `orders_stream` on `raw_orders`, proven to distinguish inserts from updates via
  `METADATA$ACTION`/`METADATA$ISUPDATE`
- A Task DAG: `root_process_orders_stream` (scheduled, `MERGE`s the stream into
  `orders_status_summary`) → `child_log_summary_change` (`AFTER` the root, logs a snapshot into
  `summary_change_log`) — confirmed sequential via `TASK_HISTORY` (child's `scheduled_time` ==
  root's `completed_time`)
- A second, independent task (`root_flag_status_anomalies`) fanned out for a different concern
  (flagging orders that jumped straight to `delivered`), on its **own** stream
- `SYSTEM$STREAM_HAS_DATA` checked before/after generating changes (`FALSE` → `TRUE`), stream
  `STALE` status and `RETENTION_TIME` (1 day) checked and connected
- `broken_task` deliberately failed 3 times, real `ERROR_MESSAGE` read from `TASK_HISTORY`,
  confirmed auto-suspend via `SUSPEND_TASK_AFTER_NUM_FAILURES = 3`
- Schema drift in `raw_orders_batch2.csv` (renamed `status`→`order_status`, new `channel` column)
  detected before loading; **Option A (widen the target table)** chosen — the drift was small and
  well-understood, so `ALTER TABLE ADD COLUMN` + positional `COPY INTO` mapping was simpler than
  staging + reconciling separately. 50,000/50,000 rows loaded, 0 errors.
- `batch2_pipe` created, triggered via `ALTER PIPE ... REFRESH`, confirmed via
  `SYSTEM$PIPE_STATUS` and `COPY_HISTORY` filtered by `PIPE_NAME`

**Real issues hit and fixed (this was the hardest day by a wide margin):**
- Day 1's grants never covered `CREATE STREAM` / `CREATE TASK` / `CREATE PIPE` — had to be granted
  on the schema as `ACCOUNTADMIN` before any of today's objects could be created.
- `EXECUTE TASK` is a separate, **account-level** privilege (`GRANT EXECUTE TASK ON ACCOUNT`) —
  granting it on a schema fails outright (`Invalid object type 'SCHEMA' for privilege
  'EXECUTE TASK'`). Without it, a role can create a task but never actually run it.
- **`CHILD_BECAME_ROOT`**: dropping and recreating a root task to fix a bug silently detaches any
  child task pointing at it via `AFTER` — the child's `predecessors` becomes `[]` and it
  auto-suspends. Recreating the root under the same name does *not* restore the link; the child
  must be dropped and recreated too. Any DAG edit requires suspending the root first
  (`Unable to update graph ... since that root task is not suspended`).
- **One stream cannot serve two independent consumers.** The checklist implies fan-out "just
  works" off a shared stream; it doesn't — whichever task consumes it first advances the offset for
  everyone, so the second task sees nothing (confirmed via `SYSTEM$STREAM_HAS_DATA` returning
  `FALSE` for the second reader). Fixed by giving the anomaly-detection task its own stream
  (`anomaly_stream`) on the same table.
- **A pipe's `COPY INTO FROM @stage` scans the whole stage, not one file**, and tracks
  already-loaded files per-pipe rather than per-stage. A brand-new pipe re-ingested Day 1's
  `late_orders.csv` (still sitting on `raw_stage`) as "new to it," producing duplicate rows,
  while the just-loaded `raw_orders_batch2.csv` was correctly skipped as already loaded. Lesson:
  keep a pipe's watched stage clean (move/remove processed files, or use subfolders) — a shared
  stage with old files on it is a live footgun for any new pipe pointed at it.
- The task-checklist material itself had gaps beyond the grants above: `summary_change_log`'s DDL
  was referenced but never given, and `INFORMATION_SCHEMA.TASK_HISTORY()` needs an explicit `WHERE`
  filter or every Snowflake-internal system task floods the result.

**Result:** full DAG proven sequential end-to-end, fan-out working correctly once each consumer had
its own stream, one task's failure-and-auto-suspend behavior confirmed with the real error text,
and the batch-2 schema drift loaded cleanly through both a manual `COPY INTO` and Snowpipe.

