# Table of Contents

**SQL from My Heart** — *Mastering PostgreSQL from First Query to Terabyte Scale*
54 chapters · 12 parts · ~180 practice sessions

---

## Front Matter
- **Preface** — why the title, who the book is for, what it is not
- **How to Use This Book** — prerequisites, practice session numbering, datasets, reading paths

---

## Part I — Foundations

**1. The Relational Model and Why PostgreSQL**
Relations, tuples, declarative thinking, the planner bargain, Postgres governance and character, where it is the wrong choice, version policy.
*1.1* Find the relations · *1.2* Stop thinking in loops

**2. Setting Up PostgreSQL 15+ on macOS and Linux**
Homebrew, apt/dnf, Docker. Clusters, `initdb`, data directory. `psql` meta-commands, `.psqlrc`. GUI clients and when they mislead.
*2.1* Install and verify `server_version` · *2.2* `psql` navigation tour · *2.3* Load the sample datasets

**3. Databases, Schemas, and the Cluster**
`CREATE DATABASE`/`SCHEMA`, `search_path`, template databases, encoding and collation — and how a glibc upgrade corrupts text indexes.
*3.1* Build a schema, manipulate `search_path` · *3.2* Compare `C` vs `en_US.UTF-8` ordering · *3.3* Inspect `pg_database`

---

## Part II — Core SQL

**4. Creating and Altering Tables**
`CREATE`/`ALTER`/`DROP TABLE`. Which `ALTER` operations are instant metadata changes and which rewrite — introduced early because it never stops mattering.
*4.1* Build the `retail` core tables · *4.2* Time an instant `ALTER` against a rewriting one

**5. Inserting, Updating, and Deleting Data**
`INSERT`, multi-row, `COPY`. `UPDATE`, `DELETE`, `RETURNING`. Upsert via `ON CONFLICT` and its concurrency caveats.
*5.1* `COPY` vs row-by-row `INSERT` · *5.2* Idempotent upsert · *5.3* Capture rows with `RETURNING`

**6. Querying Fundamentals**
`SELECT`, `WHERE`, `ORDER BY`, `LIMIT`/`OFFSET`, `DISTINCT`. Logical vs written clause evaluation order.
*6.1* Progressive query building · *6.2* `NULLS FIRST`/`LAST` · *6.3* Why `DISTINCT` is often a design smell

**7. Filtering, Operators, and Three-Valued Logic**
Operators, `BETWEEN`, `IN`, `LIKE`/`ILIKE`. NULL is not a value: `IS DISTINCT FROM`, `COALESCE`, `NULLIF`, and the `NOT IN` trap.
*7.1* Reproduce and fix the `NOT IN` + NULL bug · *7.2* Rewrite NULL-unsafe comparisons

**8. Aggregation and Grouping**
`COUNT`/`SUM`/`AVG`/`MIN`/`MAX`, `GROUP BY`, `HAVING`. `count(*)` vs `count(col)` vs `count(DISTINCT col)` and their costs.
*8.1* Sales rollups by dimension · *8.2* `WHERE` vs `HAVING` placement and its performance consequence

---

## Part III — Combining Data

**9. Joins**
All join types, `USING` vs `ON`, lateral joins, cardinality and accidental row multiplication.
*9.1* Inner join orders↔customers · *9.2* `LEFT JOIN` for customers with no orders · *9.3* Self-join a hierarchy · *9.4* Diagnose a fan-out that inflated a `SUM`

**10. Subqueries and EXISTS**
Scalar, correlated, derived tables. `EXISTS` vs `IN` vs `JOIN` — semantics first, then planner preference.
*10.1* Convert a correlated subquery to a join · *10.2* `NOT EXISTS` vs `NOT IN` on nullable columns

**11. Set Operations**
`UNION`/`UNION ALL`, `INTERSECT`, `EXCEPT`, and why `UNION ALL` is the default.
*11.1* Reconcile two sources with `EXCEPT` · *11.2* Measure the dedup cost of `UNION`

**12. CTEs and Recursive Queries**
`WITH`, the PG12 inlining change, `MATERIALIZED`. Recursion for hierarchies, graphs, gap-filling. Data-modifying CTEs.
*12.1* Refactor nested subqueries into CTEs · *12.2* Walk an org chart · *12.3* Generate a date series · *12.4* See inlining in a plan

---

## Part IV — Data Types and Integrity

**13. Numeric and Character Types**
Integer sizing, `numeric` vs float for money, `text` vs `varchar(n)` vs `char(n)`, defensible values for `n`, the `text`+`CHECK` pattern, the ~2704-byte B-tree ceiling.
*13.1* Float rounding error on currency · *13.2* `ALTER` lock levels compared · *13.3* Trigger an index-size failure

**14. Temporal Types**
`timestamptz` as the default, how Postgres stores zones (it doesn't), `AT TIME ZONE`, DST arithmetic, bucketing.
*14.1* Reproduce a `timestamp` data-loss bug · *14.2* Bucket events by local day across zones · *14.3* Handle a DST boundary

**15. Constraints and Referential Integrity**
`NOT NULL`, `UNIQUE`, `CHECK`, PK/FK, deliberate `ON DELETE`, deferrable and exclusion constraints, `NOT VALID` + `VALIDATE`.
*15.1* Business rule via `CHECK` · *15.2* Prevent overlapping bookings · *15.3* Add a FK to a large table without a long lock

**16. PostgreSQL-Native Types**
Arrays, ranges/multiranges, `ENUM` and its `ALTER` limits, `uuid`, `inet`/`cidr`, composite types, `DOMAIN`.
*16.1* Tags as array vs junction table · *16.2* Range types for validity periods · *16.3* A `DOMAIN` for validated email

**17. JSONB in Depth**
`json` vs `jsonb`, operators, path queries, GIN and `jsonb_path_ops`, building API output. When JSONB is a table you refused to model.
*17.1* Query and index a JSONB column · *17.2* Compare GIN operator classes · *17.3* Benchmark JSONB vs a normalized column

---

## Part V — Enterprise Database Design

> *The highest-leverage part of the book. A bad index costs an afternoon; a bad schema costs three years.*

**18. Normalization and Deliberate Denormalization**
1NF–BCNF worked on a real schema, then the honest counter-case and how to keep redundancy correct.
*18.1* Normalize a flat import to 3NF · *18.2* Denormalize one hot path and measure both sides

**19. Modeling Real Entities**
One-to-many, many-to-many, hierarchies, optional vs mandatory. Table boundaries around domains, not screens.
*19.1* Model order fulfillment end to end · *19.2* Adjacency list → closure table

**20. Keys and Identity Strategy at Scale**
Natural vs surrogate, `IDENTITY` vs `SERIAL` vs UUID, UUIDv4's index-locality problem and UUIDv7's fix, exposing internal IDs.
*20.1* Measure bloat: bigint vs UUIDv4 vs UUIDv7 at 5M rows · *20.2* Migrate `SERIAL` to `IDENTITY`

**21. Structuring a New Enterprise Database**
Schema organization (`app`/`audit`/`staging`/`reporting`), OLTP vs reporting separation, multi-tenancy models and their ceilings, lookup vs `ENUM` vs `CHECK`, naming conventions, environment parity and migration tooling.
*21.1* Lay out a multi-schema database from requirements · *21.2* Three tenant models compared · *21.3* First versioned migration

**22. The Table Design Checklist**
Standard columns and audit trail, soft vs hard delete vs archive, RLS readiness, partitioning decided before go-live, the day-1 index plan.
*22.1* Apply the checklist to a bare table · *22.2* Trigger-based audit table · *22.3* Measure and mitigate soft-delete cost

**23. The Column Design Checklist**
Type selection, `NOT NULL` by default, defaults and generated columns, column-level integrity, TOAST and alignment padding, PII classification.
*23.1* Audit a table column by column · *23.2* Reorder columns, measure on-disk size · *23.3* Watch TOAST engage

**24. Design Anti-Patterns and Safe Refactoring**
EAV, god tables, JSONB-as-schema-avoidance, polymorphic FKs, premature sharding. Then expand/contract, backfills, dual writes.
*24.1* Refactor EAV into a typed schema · *24.2* Split a column out with zero downtime

---

## Part VI — Advanced Querying

**25. Window Functions**
`OVER`/`PARTITION BY`, ranking, `LAG`/`LEAD`, frame clauses (`ROWS` vs `RANGE` vs `GROUPS`), named windows.
*25.1* Running totals and moving averages · *25.2* Top-N per group · *25.3* Period-over-period with `LAG` · *25.4* A `ROWS` vs `RANGE` discrepancy

**26. Advanced Aggregation**
`GROUPING SETS`/`CUBE`/`ROLLUP`, `FILTER`, ordered-set aggregates, `array_agg`/`jsonb_agg`, custom aggregates.
*26.1* Multi-level report with `ROLLUP` · *26.2* Replace `CASE`-in-`SUM` with `FILTER` · *26.3* p95 with `percentile_cont`

**27. Pattern Matching and Regular Expressions**
`LIKE`/`SIMILAR TO`/POSIX regex, making prefix search index-able, rescuing leading wildcards with `pg_trgm`.
*27.1* Parse semi-structured logs · *27.2* Index a prefix search · *27.3* Accelerate `%substring%`

**28. Full-Text Search**
`tsvector`/`tsquery`, dictionaries, ranking, highlighting, generated columns + GIN, fuzzy matching, and the honest limits.
*28.1* Searchable product catalog · *28.2* Ranking and snippets · *28.3* Full-text + trigram for typo tolerance

---

## Part VII — Transactions, Concurrency, and MVCC

> *Placed before performance deliberately: bloat, vacuum lag and lock waits are MVCC consequences, and tuning without this part is guesswork.*

**29. Transactions in Practice**
`BEGIN`/`COMMIT`/`ROLLBACK`, savepoints, ACID with Postgres caveats, transactional DDL, idle-in-transaction as a hazard.
*29.1* Roll back a DDL migration mid-flight · *29.2* Create and resolve an idle-in-transaction stall

**30. MVCC Internals**
`xmin`/`xmax`, snapshots, why `UPDATE` is insert-plus-mark-dead, write amplification, dead tuples, HOT updates, `fillfactor`, wraparound and freezing.
*30.1* Inspect `xmin`/`xmax` across sessions · *30.2* Watch dead tuples accumulate · *30.3* Tune `fillfactor` for HOT updates

**31. Isolation Levels and Anomalies**
Read Committed, Repeatable Read, Serializable. Every anomaly reproduced, not just described. SSI and retry logic.
*31.1* Reproduce each anomaly, then eliminate it · *31.2* Trigger write skew, fix it two ways · *31.3* Serialization-failure retry loop

**32. Locking, Deadlocks, and Concurrency Patterns**
Lock modes and conflicts, `FOR UPDATE`/`SKIP LOCKED`/`NOWAIT`, advisory locks, deadlock prevention by lock ordering, optimistic vs pessimistic.
*32.1* Induce and read a deadlock · *32.2* Job queue on `SKIP LOCKED` · *32.3* Optimistic locking with a `version` column

---

## Part VIII — Performance Engineering

> *Work this part in order. Most people jump to adding indexes; the ones who fix things permanently learn to read a plan first.*

**33. Indexing**
B-tree mechanics, GIN/GiST/SP-GiST/BRIN/hash and their workloads, multicolumn order and leftmost-prefix, partial/expression/covering indexes, index-only scans and the visibility map, the real cost of an index, `CREATE INDEX CONCURRENTLY`, finding unused and duplicate indexes.
*33.1* Five index types on one query · *33.2* Prove the leftmost-prefix rule · *33.3* Full vs partial index · *33.4* Force an index-only scan · *33.5* Find unused indexes

**34. Deep Dive: `EXPLAIN` and `EXPLAIN ANALYZE`** — *the chapter this book was written around*
Plan anatomy and reading order. The cost model and why cost units are not milliseconds. `ANALYZE`/`BUFFERS`/`TIMING`/`SETTINGS`/`WAL`/`FORMAT JSON`. Estimated vs actual rows as the master diagnostic. `loops` arithmetic. Every scan node and what selects it. Every join strategy and what favours it. Sorts, spills and `work_mem`. Hash vs group aggregate. Parallel query. CTE nodes. `UPDATE`/`DELETE` plans and trigger time. `auto_explain` in production. Plan visualizers. A repeatable reading procedure.
*34.1* Read a plan cold, find the bottleneck · *34.2* Force each scan type · *34.3* Force each join strategy, explain the crossover · *34.4* Trace a 1000× misestimate · *34.5* Induce a disk sort, tune it away · *34.6* Capture a live plan with `auto_explain` · *34.7* Annotate a real production plan

**35. Statistics and the Query Planner**
MCVs, histograms, n_distinct, correlation. `default_statistics_target`. Extended statistics for correlated columns. Reading `pg_stats`. Cost constants and `random_page_cost` on SSDs. Generic vs custom plans for prepared statements.
*35.1* Inspect `pg_stats` for a skewed column · *35.2* Fix a correlated-column misestimate · *35.3* Reproduce a generic-plan regression

**36. Query Optimization Patterns and Anti-Patterns**
`SELECT *`, functions on indexed columns, implicit casts, `OR` and the `UNION ALL` rewrite, ORM N+1, `OFFSET` collapse and keyset pagination, batching large writes.
*36.1* Fix an index disabled by a cast · *36.2* Keyset pagination, latency vs depth · *36.3* Eliminate an N+1 · *36.4* Batch a 50M-row delete

**37. VACUUM, Bloat, and Autovacuum at Scale**
What `VACUUM` reclaims vs `VACUUM FULL`. Autovacuum triggers and per-table tuning. Detecting bloat. `REINDEX CONCURRENTLY`, `pg_repack`. Long transactions holding the vacuum horizon. Wraparound emergencies.
*37.1* Create bloat, reclaim it three ways · *37.2* Tune autovacuum for a write-heavy table · *37.3* Watch a long transaction block vacuum

**38. Partitioning Large Tables**
Range/list/hash, pruning at plan and execution time, partition-wise joins, attach/detach with minimal locking, indexing across partitions, retention by dropping partitions — and when partitioning makes things worse.
*38.1* Partition a 100M-row table by month · *38.2* Verify pruning in `EXPLAIN` · *38.3* Roll the retention window online · *38.4* Find a query partitioning hurt

**39. Diagnosing Production Performance Incidents**
Triage order. `pg_stat_statements`, `pg_stat_activity`, `log_min_duration_statement`. Blocking chains and `pg_blocking_pids()`. Connection storms. Cache ratios, I/O vs CPU bound. Plan flips. Replication lag as user-visible latency. Load shedding.
**Case studies:** missing index → seq-scan storm · ORM N+1 · lock chain from one open transaction · post-bulk-delete bloat · bad plan after stats invalidation · connection exhaustion.
*39.1* Identify the top three offenders on an unlabeled cluster · *39.2* Resolve a live blocking chain · *39.3* Diagnose a plan flip · *39.4* Full incident simulation and postmortem

**40. The Production Query Review Checklist**
Index coverage, plan reviewed at production row counts, lock level of every DDL statement, rollback plan, effect on existing plans. Reviewing others' SQL. Team query standards.
*40.1* Review a realistic PR · *40.2* Reject and rewrite a migration that takes `ACCESS EXCLUSIVE`

---

## Part IX — Programmability

**41. Views and Materialized Views**
Simple/updatable/security-barrier views. Matviews, `REFRESH CONCURRENTLY`, staleness as a design choice, matviews as load shedding.
*41.1* Layer views over a normalized schema · *41.2* Replace a dashboard query, measure the load drop · *41.3* Refresh concurrently under live reads

**42. Functions and PL/pgSQL**
SQL vs PL/pgSQL. Volatility categories and their planner consequences. `RETURNS TABLE`, control flow, exceptions. `SECURITY DEFINER` risks. When server-side logic wins and when it hides cost.
*42.1* A validated business-rule function · *42.2* How wrong volatility breaks an index · *42.3* A safe `SECURITY DEFINER` function

**43. Triggers, Procedures, and the Limits of Server-Side Logic**
`BEFORE`/`AFTER`/`INSTEAD OF`, row vs statement, ordering. Procedures and transaction control. Event triggers. The honest argument about how much logic belongs in the database.
*43.1* A concurrency-safe denormalized counter · *43.2* Trigger overhead on a bulk load · *43.3* Convert trigger logic to application logic and compare

---

## Part X — Administration and Operations

> *If you own queries but not the cluster, skip to Part XI. Come back the first time you're on the incident call anyway.*

**44. Roles, Privileges, and Row-Level Security**
Roles vs users vs groups, `GRANT`/`REVOKE`, default privileges, `pg_hba.conf`, RLS policies and their performance cost.
*44.1* Least-privilege role hierarchy · *44.2* Tenant isolation with RLS · *44.3* Measure and mitigate RLS overhead

**45. Configuration and Resource Tuning**
`shared_buffers`, `work_mem` and the per-node multiplication trap, `maintenance_work_mem`, `effective_cache_size`, WAL and checkpoints, parallelism, `pg_settings`.
*45.1* Tune a default install for a workload · *45.2* Produce then flatten a checkpoint spike · *45.3* `work_mem` multiplying across parallel workers

**46. Backup, Restore, and Point-in-Time Recovery**
Logical vs physical backups, WAL archiving and PITR, pgBackRest/Barman, RTO/RPO, and why an unverified backup is not a backup.
*46.1* Full dump and restore cycle · *46.2* Recover to a timestamp before a bad `DELETE` · *46.3* Measure your actual restore time

**47. Replication and High Availability**
Streaming replication, sync vs async, replication slots and the disk-fill hazard, hot standby query conflicts, logical replication, Patroni failover, read-replica routing.
*47.1* Set up streaming replication · *47.2* Induce and resolve lag · *47.3* Controlled failover · *47.4* Major-version upgrade via logical replication

**48. Monitoring and Observability**
The `pg_stat_*` views worth knowing. What to alert on. Useful log configuration. Prometheus + `postgres_exporter` + Grafana. Baselines, and why alerting without them is noise.
*48.1* Stand up exporter + Grafana · *48.2* Build the alert dashboard · *48.3* Baseline, then detect an injected regression

**49. Extensions Worth Knowing**
`pg_stat_statements`, `auto_explain`, `pg_trgm`, `pgcrypto`, `pg_partman`, `pg_repack`, `postgres_fdw`, `hypopg`, `postgres_hll`, PostGIS, `pgvector`, TimescaleDB. Management, upgrades, and dependency risk.
*49.1* Install and query `pg_stat_statements` · *49.2* Test a hypothetical index with `hypopg` · *49.3* Query across databases with `postgres_fdw`

---

## Part XI — Applications at Scale

**50. Connecting from Application Code**
Why connections are expensive in Postgres specifically. Application pools vs PgBouncer; transaction/session/statement pooling and what each breaks. Prepared statements through a pooler. Statement and lock timeouts. ORM vs raw SQL. Retry and idempotency.
*50.1* Benchmark direct vs PgBouncer · *50.2* Break prepared statements with transaction pooling, then fix · *50.3* Set defensive timeouts and verify they fire

**51. Security in Practice**
How injection actually happens and why parameterization is the only fix. Least privilege for app roles. Encryption in transit and at rest, `pgcrypto`. PII handling and masking for non-production. `pgaudit`. Connection-string hygiene.
*51.1* Exploit then fix an injectable query · *51.2* Build an anonymized staging copy · *51.3* Enable and read an audit trail

**52. Schema Migrations on Live Systems**
Lock levels of every common `ALTER TABLE`, tabulated. Expand/contract, batched backfills, dual writes, `NOT VALID`+`VALIDATE`, `CREATE INDEX CONCURRENTLY`. `lock_timeout` and retry. Backward-compatible deploys, rollback plans, migration review in CI.
*52.1* Add `NOT NULL` with a default to 100M rows, online · *52.2* Rename a column with zero downtime · *52.3* Watch a migration queue behind a long query, then prevent it

**53. Scaling PostgreSQL**
Vertical scaling and its real ceiling. Read replicas and the lag/consistency problem. Partitioning revisited at volume. Sharding: application-level vs Citus. Connection scaling. Archival and tiered storage. CQRS and analytics offload. When the answer is a different datastore.
*53.1* Route reads to a replica, handle read-your-writes · *53.2* Shard with Citus, compare plans · *53.3* Tiered archival for a 5TB table

---

## Part XII — Capstone

**54. Designing, Loading, and Tuning a Complete Enterprise System**
One project from blank database to tuned production. Requirements → ERD → full schema under the Part V checklists → migrations → load to 100M+ rows → realistic concurrent workload → profile, index, partition, de-bloat → survive an injected incident → write the runbook.
*54.1* Schema design and review · *54.2* Migrations and load · *54.3* Baseline the workload · *54.4* Optimization pass against an SLA · *54.5* Incident injection and response · *54.6* Operational runbook

---

## Appendices

- **A — SQL Style Guide and Naming Conventions** — the book's conventions, adoptable as a team standard
- **B — `EXPLAIN` Node Reference** — every plan node, what it means, what makes it slow *(companion to Ch. 34)*
- **C — `ALTER TABLE` Lock Level Reference** — every variant, its lock mode, whether it rewrites *(companion to Ch. 52)*
- **D — Data Type Selection Reference** — the decision tables from Part IV and Ch. 23 in one place
- **E — Diagnostic Query Cookbook** — copy-paste queries for bloat, unused indexes, blocking chains, cache ratios, vacuum lag, long transactions
- **F — PostgreSQL vs Other Dialects** — MySQL, SQL Server, Oracle: what transfers and what silently does not
- **G — Configuration Baselines by Workload** — OLTP, analytics, mixed, at several hardware tiers
- **H — Version Feature Map: 15 → current** — what arrived when
- **I — Further Reading**
