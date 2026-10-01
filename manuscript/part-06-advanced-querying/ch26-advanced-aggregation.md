# Chapter 26 — Advanced Aggregation

Chapter 8 gave you `GROUP BY`: one grouping, one row per group. Real reports are rarely
that polite. Finance wants revenue by city and status, the subtotal per city and the grand
total, from one query. Operations wants the 95th-percentile reading, not the average. An
API wants each customer's orders as one JSON array.

This chapter covers multiple grouping levels in one pass (`ROLLUP`, `CUBE`,
`GROUPING SETS`), conditional aggregates (`FILTER`), ordered-set aggregates
(`percentile_cont`, `mode`), collecting aggregates (`array_agg`, `jsonb_agg`,
`string_agg`), and writing your own. Window functions, which look similar and are not, are
Chapter 25.

Everything reads `retail` and `telemetry`. Only the custom aggregate needs a scratch
database:

```bash
createdb ch26_scratch
```

Run these with `psql -q` to suppress `\c` and `\pset` chatter. Plans are shown with
parallelism pinned off (`SET max_parallel_workers_per_gather = 0`) so they are stable.

---

## 26.1 One pass, several levels: `ROLLUP`

The report: order counts and revenue by city and status, with a subtotal per city and a
grand total. Chapter 8 gives you one way to write it, three `GROUP BY` queries glued with
`UNION ALL`. Here is that version against the `ROLLUP` version, both aggregating the same
2,500 orders joined to their customers.

```sql
\c retail
\pset null '(null)'
SET max_parallel_workers_per_gather = 0;

SELECT count(*) AS report_rows
FROM (SELECT c.city, o.status, sum(o.total_amount)
      FROM orders o JOIN customers c ON c.id = o.customer_id
      GROUP BY ROLLUP (c.city, o.status)) r;
```

```text
 report_rows 
-------------
         148
(1 row)
```

The plan, on a warm session:

```sql
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT c.city, o.status, sum(o.total_amount)
FROM orders o JOIN customers c ON c.id = o.customer_id
GROUP BY ROLLUP (c.city, o.status);
```

```text
                              QUERY PLAN                              
----------------------------------------------------------------------
 MixedAggregate (actual rows=148 loops=1)
   Hash Key: c.city, o.status
   Hash Key: c.city
   Group Key: ()
   Batches: 1  Memory Usage: 104kB
   Buffers: shared hit=55
   ->  Hash Join (actual rows=2500 loops=1)
         Hash Cond: (o.customer_id = c.id)
         Buffers: shared hit=55
         ->  Seq Scan on orders o (actual rows=2500 loops=1)
               Buffers: shared hit=43
         ->  Hash (actual rows=1000 loops=1)
               Buckets: 1024  Batches: 1  Memory Usage: 52kB
               Buffers: shared hit=12
               ->  Seq Scan on customers c (actual rows=1000 loops=1)
                     Buffers: shared hit=12
 Planning:
   Buffers: shared hit=15
(18 rows)
```

One `MixedAggregate` feeds three groupings, `(city, status)`, `(city)` and `()`, from a
single join: 55 buffers. The `UNION ALL` version:

```sql
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT c.city, o.status, sum(o.total_amount)
FROM orders o JOIN customers c ON c.id = o.customer_id GROUP BY c.city, o.status
UNION ALL
SELECT c.city, NULL, sum(o.total_amount)
FROM orders o JOIN customers c ON c.id = o.customer_id GROUP BY c.city
UNION ALL
SELECT NULL, NULL, sum(o.total_amount)
FROM orders o JOIN customers c ON c.id = o.customer_id;
```

The top of its plan (each arm below it is a copy of the join above):

```text
                                  QUERY PLAN                                  
------------------------------------------------------------------------------
 Append (actual rows=148 loops=1)
   Buffers: shared hit=165
```

Same 148 rows, 165 buffers, three times the work, because each arm is a separate query
that scans `orders` and `customers` again. That is the deterministic argument for
`ROLLUP`: the input is read once however many levels you ask for.

`ROLLUP (a, b)` produces the sets `(a, b)`, `(a)` and `()`, dropping columns right to left. It is for *hierarchies*, where a subtotal for `b` alone
would be meaningless.

## 26.2 The NULLs are ambiguous, and `GROUPING()` is the fix

Subtotal rows show a NULL in the column that was rolled up. That collides with a NULL that
is really in the data. `customers.city` has 128 real NULLs, so the collision is live. Take
two statuses, and Pune plus the unknown-city customers:

```sql
SELECT c.city, o.status, count(*) AS n,
       grouping(c.city, o.status) AS g
FROM orders o JOIN customers c ON c.id = o.customer_id
WHERE (c.city = 'Pune' OR c.city IS NULL)
  AND o.status IN ('delivered', 'shipped')
GROUP BY ROLLUP (c.city, o.status)
ORDER BY g, 1, 2;
```

```text
  city  |  status   |  n  | g 
--------+-----------+-----+---
 Pune   | delivered |  31 | 0
 Pune   | shipped   |  25 | 0
 (null) | delivered | 106 | 0
 (null) | shipped   |  54 | 0
 Pune   | (null)    |  56 | 1
 (null) | (null)    | 160 | 1
 (null) | (null)    | 216 | 3
(7 rows)
```

Two rows read `(null) | (null)`: 160 and 216. The first is the subtotal for customers with
no recorded city. The second is the grand total. Nothing in the two visible columns
distinguishes them, and a dashboard that labels every NULL "Total" misreports one as the other.

`grouping(col, ...)` returns a bitmask: bit set means *that column was rolled up in this
row*, first argument as the most significant bit. `g = 1` means `status` rolled up; `g = 3`
means both did. Use it for labels, and use `coalesce` for the data NULL:

```sql
SELECT CASE WHEN grouping(c.city) = 1 THEN 'ALL cities'
            ELSE coalesce(c.city, '(unknown)') END AS city,
       CASE WHEN grouping(o.status) = 1 THEN 'ALL' ELSE o.status END AS status,
       count(*) AS n
FROM orders o JOIN customers c ON c.id = o.customer_id
WHERE (c.city = 'Pune' OR c.city IS NULL)
  AND o.status IN ('delivered', 'shipped')
GROUP BY ROLLUP (c.city, o.status)
ORDER BY grouping(c.city), c.city, o.status;
```

```text
    city    |  status   |  n  
------------+-----------+-----
 Pune       | delivered |  31
 Pune       | shipped   |  25
 Pune       | ALL       |  56
 (unknown)  | delivered | 106
 (unknown)  | shipped   |  54
 (unknown)  | ALL       | 160
 ALL cities | ALL       | 216
(7 rows)
```

> **Trap —** `coalesce(city, 'Total')` alone labels data NULLs and subtotal NULLs
> identically. Test a rollup on a column that contains real NULLs before you ship it.

## 26.3 `GROUPING SETS`, and why `CUBE` is dangerous

`ROLLUP` and `CUBE` are shorthand for `GROUPING SETS`, which lets you list exactly the
groupings you want. Say the report needs revenue *by city* and *by status*, with no
city-by-status cross, and a grand total:

```sql
SELECT c.city, o.status, count(*) AS n, grouping(c.city, o.status) AS g
FROM orders o JOIN customers c ON c.id = o.customer_id
WHERE c.city IN ('Pune', 'Kochi')
GROUP BY GROUPING SETS ((c.city), (o.status), ())
ORDER BY g, 1, 2;
```

```text
  city  |  status   |  n  | g 
--------+-----------+-----+---
 Kochi  | (null)    | 126 | 1
 Pune   | (null)    |  96 | 1
 (null) | cancelled |  25 | 2
 (null) | delivered |  92 | 2
 (null) | paid      |  16 | 2
 (null) | pending   |  19 | 2
 (null) | returned  |  24 | 2
 (null) | shipped   |  46 | 2
 (null) | (null)    | 222 | 3
(9 rows)
```

`CUBE (a, b, c)` is `GROUPING SETS` over every subset of the columns: 2ⁿ sets for n
columns. Nothing in the syntax warns you. Count what it costs on the same 2,500 orders:

```sql
SELECT 3 AS dims, count(DISTINCT g) AS sets, count(*) AS output_rows
FROM (SELECT grouping(c.loyalty_tier, c.country, o.status) AS g
      FROM orders o JOIN customers c ON c.id = o.customer_id
      GROUP BY CUBE (c.loyalty_tier, c.country, o.status)) s
UNION ALL
SELECT 5, count(DISTINCT g), count(*)
FROM (SELECT grouping(c.loyalty_tier, c.country, o.status, c.city, o.discount_code) AS g
      FROM orders o JOIN customers c ON c.id = o.customer_id
      GROUP BY CUBE (c.loyalty_tier, c.country, o.status, c.city, o.discount_code)) s;
```

```text
 dims | sets | output_rows 
------+------+-------------
    3 |    8 |         269
    5 |   32 |        8575
(2 rows)
```

Five dimensions: 32 grouping sets, and 8,575 output rows from 2,500 input rows. The result
is bigger than the data. At production scale it is a wide, mostly-empty cross-tabulation
that no human reads and that the application then has to filter by `grouping()`.

I use `CUBE` for two or three low-cardinality dimensions feeding a pivot. Beyond that I
write out the `GROUPING SETS` that the report actually displays. Also worth knowing: `GROUP BY a, ROLLUP (b, c)` keeps `a` in every set, and
`ROLLUP ((a, b), c)` rolls `(a, b)` up as one unit.

Each grouping set keeps its own groups in memory, so `EXPLAIN` a `CUBE` (Chapter 34,
*Deep Dive: `EXPLAIN` and `EXPLAIN ANALYZE`*) before it goes near a large table.

## 26.4 `FILTER`: conditional aggregates

The pivot idiom `sum(CASE WHEN ... THEN ... END)` works, and the standard replaced it with
`FILTER (WHERE ...)`, which PostgreSQL has supported since 9.4. The plans are the same.
Here is the top of each, `VERBOSE` so the expressions show:

```sql
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF, VERBOSE)
SELECT count(*) FILTER (WHERE status = 'paid') AS p,
       sum(total_amount) FILTER (WHERE status = 'shipped') AS s
FROM orders;
```

```text
                                                       QUERY PLAN                                                       
------------------------------------------------------------------------------------------------------------------------
 Aggregate (actual rows=1 loops=1)
   Output: count(*) FILTER (WHERE (status = 'paid'::text)), sum(total_amount) FILTER (WHERE (status = 'shipped'::text))
   Buffers: shared hit=43
```

```sql
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF, VERBOSE)
SELECT sum(CASE WHEN status = 'paid' THEN 1 ELSE 0 END) AS p,
       sum(CASE WHEN status = 'shipped' THEN total_amount END) AS s
FROM orders;
```

```text
                                                                       QUERY PLAN                                                                       
--------------------------------------------------------------------------------------------------------------------------------------------------------
 Aggregate (actual rows=1 loops=1)
   Output: sum(CASE WHEN (status = 'paid'::text) THEN 1 ELSE 0 END), sum(CASE WHEN (status = 'shipped'::text) THEN total_amount ELSE NULL::numeric END)
   Buffers: shared hit=43
```

Same node, same 43 buffers, one pass either way; I make no speed claim. The argument for
`FILTER` is correctness and legibility, and the failures are all in the `CASE` form:

```sql
SELECT count(*) FILTER (WHERE status = 'returned')                    AS good,
       count(CASE WHEN status = 'returned' THEN 1 ELSE 0 END)         AS wrong_count,
       round(avg(total_amount) FILTER (WHERE status = 'returned'), 2) AS good_avg,
       round(avg(CASE WHEN status = 'returned'
                      THEN total_amount ELSE 0 END), 2)               AS wrong_avg
FROM orders;
```

```text
 good | wrong_count | good_avg | wrong_avg 
------+-------------+----------+-----------
  272 |        2500 |  1597.65 |    173.82
(1 row)
```

`count(CASE ... ELSE 0 END)` counts every row, because `count(expr)` counts non-NULL and
`0` is not NULL. `avg(... ELSE 0 ...)` drags 2,228 zeros into the denominator. Both
queries run without error and return plausible numbers, and only the `FILTER` form makes
the mistake hard to write.

Now the premise to correct. It is folklore that `FILTER` also fixes the "sum of nothing is
NULL" problem from Chapter 8. It does not:

```sql
SELECT sum(total_amount) FILTER (WHERE status = 'nope')             AS filtered_sum,
       sum(CASE WHEN status = 'nope' THEN total_amount END)         AS case_sum,
       count(*) FILTER (WHERE status = 'nope')                      AS filtered_count
FROM orders;
```

```text
 filtered_sum | case_sum | filtered_count 
--------------+----------+----------------
       (null) |   (null) |              0
(1 row)
```

Both sums are NULL, and only `count` gives 0. Wrap with `coalesce(..., 0)` where a report
needs a zero, in both forms.

`FILTER` is not a substitute for `WHERE`: it reads every row and discards inside the
aggregate, so a single condition for the whole query belongs in `WHERE`. Use `FILTER` when
one scan feeds several different conditions.

## 26.5 Ordered-set aggregates: percentiles, and why they cost more

`avg` is a bad summary of latency-shaped data. A reading of 42 °C hiding among a thousand
readings of 25 does not move the mean, and the 95th percentile shows it. PostgreSQL has
percentiles as *ordered-set aggregates*, with `WITHIN GROUP` syntax. On the telemetry
events:

```sql
\c telemetry
\pset null '(null)'
SET max_parallel_workers_per_gather = 0;

SELECT metric_name,
       percentile_cont(0.95) WITHIN GROUP (ORDER BY metric_value) AS p95_cont,
       percentile_disc(0.95) WITHIN GROUP (ORDER BY metric_value) AS p95_disc
FROM device_events
GROUP BY 1 ORDER BY 1;
```

```text
 metric_name  | p95_cont | p95_disc 
--------------+----------+----------
 battery_v    |     4.24 |    4.240
 humidity_pct |  93.4013 |   93.426
 pressure_hpa | 1045.212 | 1045.239
 rssi_dbm     | -38.3483 |  -38.342
 temp_c       |  42.3755 |   42.377
(5 rows)
```

`percentile_cont` *interpolates* between the two nearest values, so its result usually is
not a value that exists in the data. `percentile_disc` returns an actual value from the
input, the first one whose cumulative position reaches the fraction. Here the two differ in
the third decimal. On small or discrete data the difference is large:

```sql
SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY x) AS cont,
       percentile_disc(0.5) WITHIN GROUP (ORDER BY x) AS disc
FROM (VALUES (1), (2), (3), (4)) v(x);
```

```text
 cont | disc 
------+------
  2.5 |    2
(1 row)
```

The median of 1–4 is 2.5 by interpolation and 2 by the discrete definition. Use `cont` for
continuous quantities such as latency and temperature, and `disc` when the answer must be
a real member of the set. `percentile_cont` accepts only `double precision` or `interval`,
so it rejects a `timestamptz`; take the difference from an origin for a median date.

`mode()` is the third ordered-set aggregate: the most frequent value. It is meaningless on
continuous readings, since every `numeric(12,3)` reading is almost unique and the "mode" is
an arbitrary tie-break. Use it on categories:

```sql
SELECT mode() WITHIN GROUP (ORDER BY severity) AS common_severity,
       count(*) FILTER (WHERE severity IS NOT NULL) AS flagged
FROM device_events;
```

```text
 common_severity | flagged 
-----------------+---------
 warn            |     937
(1 row)
```

`FILTER` composes with ordered-set aggregates, and an array of fractions returns an array:

```sql
SELECT percentile_cont(ARRAY[0.5, 0.95, 0.99]) WITHIN GROUP (ORDER BY metric_value)
       FILTER (WHERE severity IS NOT NULL) AS flagged_p50_p95_p99
FROM device_events WHERE metric_name = 'temp_c';
```

```text
              flagged_p50_p95_p99              
-----------------------------------------------
 {17.841,42.35304999999999,44.073359999999994}
(1 row)
```

Ordered-set aggregates are not window functions, and `OVER` is refused:

```sql
SELECT percentile_cont(0.95) WITHIN GROUP (ORDER BY metric_value)
       OVER (PARTITION BY metric_name)
FROM device_events;
```

```text
ERROR:  OVER is not supported for ordered-set aggregate percentile_cont
LINE 1: SELECT percentile_cont(0.95) WITHIN GROUP (ORDER BY metric_v...
               ^
```

To get a per-group percentile beside each row, aggregate in a subquery and join it back.

### What the exactness costs

An exact percentile needs every value in the group before it can answer. Compare the plan
with a plain `max`/`avg` over the same table:

```sql
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT metric_name, percentile_cont(0.95) WITHIN GROUP (ORDER BY metric_value)
FROM device_events GROUP BY 1;
```

```text
                            QUERY PLAN                            
------------------------------------------------------------------
 GroupAggregate (actual rows=5 loops=1)
   Group Key: metric_name
   Buffers: shared hit=267
   ->  Sort (actual rows=9800 loops=1)
         Sort Key: metric_name
         Sort Method: quicksort  Memory: 967kB
         Buffers: shared hit=267
         ->  Seq Scan on device_events (actual rows=9800 loops=1)
               Buffers: shared hit=267
(9 rows)
```

```sql
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT metric_name, max(metric_value), avg(metric_value)
FROM device_events GROUP BY 1;
```

```text
                         QUERY PLAN                         
------------------------------------------------------------
 HashAggregate (actual rows=5 loops=1)
   Group Key: metric_name
   Batches: 1  Memory Usage: 24kB
   Buffers: shared hit=267
   ->  Seq Scan on device_events (actual rows=9800 loops=1)
         Buffers: shared hit=267
```

Two corrections to the tidy story here. First, the `Sort` node in the percentile plan sorts
by `metric_name`: ordered-set aggregates cannot use `HashAggregate`, so the whole input is
sorted to group it. The sort by `metric_value` that the percentile needs happens *inside*
the aggregate, in a per-group buffer that no plan node reports. Second, the buffer count is
identical (267) and the aggregate is fed by one scan either way, so the extra cost is not
I/O. It is memory and sort work proportional to the rows in each group: 967 kB against 24 kB
here. I measured plan shapes and memory, not seconds.

> **In production —** Do not put `percentile_cont` on a dashboard that refreshes every
> ten seconds over raw events. Compute p50/p95/p99 per metric per hour into a summary table,
> or a materialized view (Chapter 41, *Views and Materialized Views*), and have the
> dashboard read that. If you must approximate, note that core PostgreSQL has no
> approximate-percentile aggregate. There are third-party extensions (t-digest is one)
> and Chapter 49, *Extensions Worth Knowing*, covers `postgres_hll` for cardinality, which
> is a different problem. I have not benchmarked either here.

## 26.6 Collecting aggregates: `array_agg`, `jsonb_agg`, `string_agg`

These fold a group into one value: an array, a JSON array, a delimited string. They are
what turns a one-to-many join into one row per parent, which is what most APIs want.

```sql
\c retail
\pset null '(null)'

SELECT c.id, c.name,
       array_agg(o.id ORDER BY o.placed_at DESC) AS order_ids,
       string_agg(DISTINCT o.status, ', ' ORDER BY o.status) AS statuses
FROM customers c LEFT JOIN orders o ON o.customer_id = c.id
WHERE c.id IN (1, 2, 999)
GROUP BY c.id, c.name ORDER BY c.id;
```

```text
 id  |     name     |      order_ids      |                statuses                 
-----+--------------+---------------------+-----------------------------------------
   1 | Imran Reddy  | {2462,806,2386,383} | cancelled, delivered, returned, shipped
   2 | Rohit Kumar  | {1396,289}          | delivered
 999 | Farhan Patel | {NULL}              | (null)
(3 rows)
```

Three things here. **Order is a promise only if you write it.** Without `ORDER BY` inside
the call, element order follows whatever order rows reached the aggregate, which is the
join's business and can change with the plan. **`DISTINCT` restricts the `ORDER BY`**: with
`DISTINCT`, the sort key must be the aggregated argument itself.

```sql
SELECT string_agg(DISTINCT status, ', ' ORDER BY placed_at) FROM orders;
```

```text
ERROR:  in an aggregate with DISTINCT, ORDER BY expressions must appear in argument list
LINE 1: SELECT string_agg(DISTINCT status, ', ' ORDER BY placed_at) ...
                                                         ^
```

After de-duplication there is no single `placed_at` per status.

**Customer 999 has no orders and got `{NULL}`.** `array_agg` over a `LEFT JOIN` collects
the NULL that the outer join produced. The same happens with `jsonb_agg`, which yields
`[null]`. Fix it with the `FILTER` from 26.4:

```sql
SELECT c.id, array_agg(o.id) FILTER (WHERE o.id IS NOT NULL) AS order_ids,
       coalesce(jsonb_agg(o.id) FILTER (WHERE o.id IS NOT NULL), '[]') AS j
FROM customers c LEFT JOIN orders o ON o.customer_id = c.id
WHERE c.id = 999 GROUP BY c.id;
```

```text
 id  | order_ids | j  
-----+-----------+----
 999 | (null)    | []
(1 row)
```

`array_agg` returns NULL, not `{}`, when everything is filtered out, so decide which your
consumer expects. `jsonb_agg(jsonb_build_object(...) ORDER BY ...)` builds the nested
documents (Chapter 17, *JSONB in Depth*) and `jsonb_object_agg(k, v)` folds rows into one
object.

### The size of a group is your responsibility

Each aggregate builds one value in memory, and a single value cannot exceed 1 GB. Nothing
bounds the group for you. Measure how big the result gets on the busiest device in
`telemetry`, which has 1,660 events:

```sql
\c telemetry
\pset null '(null)'

SELECT count(*) AS events,
       pg_column_size(array_agg(event_id)) AS ids_bytes,
       pg_column_size(jsonb_agg(to_jsonb(e))) AS json_bytes,
       pg_column_size(jsonb_agg(to_jsonb(e))) / count(*) AS bytes_per_row
FROM device_events e WHERE device_id = 1;
```

```text
 events | ids_bytes | json_bytes | bytes_per_row 
--------+-----------+------------+---------------
   1660 |     13304 |     564678 |           340
(1 row)
```

A 1,660-row group as JSON is 565 KB. At 340 bytes per row, and assuming that stays linear,
about three million rows would reach the 1 GB ceiling and the query would fail. That
extrapolation is arithmetic, not a measurement. The practical failure arrives first: a client that must parse it.

I aggregate into arrays only when the domain bounds the group (an order's line items),
never over an open-ended child such as events. Page those.

## 26.7 Writing your own aggregate

An aggregate is a state, a function that folds each row into it, and an optional function
that turns the final state into the answer. PostgreSQL 15 has no `first`, `last` or weighted
average. It has no `any_value` either:

```sql
\c retail
SELECT any_value(id) FROM orders;
```

```text
ERROR:  function any_value(integer) does not exist
LINE 1: SELECT any_value(id) FROM orders;
               ^
HINT:  No function matches the given name and argument types. You might need to add explicit type casts.
```

> **Version note —** `any_value()` arrived in PostgreSQL 16. On 15, the book's minimum, use
> `min()` or `max()`, or add the column to `GROUP BY`. Chapter 8's functional-dependency
> exception covers the primary-key case.

A weighted average needs a two-number state, `(sum of value×weight, sum of weight)`:

```sql
\c ch26_scratch
\pset null '(null)'

CREATE FUNCTION wavg_step(state float8[], v float8, w float8) RETURNS float8[]
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS
$$ SELECT ARRAY[state[1] + v * w, state[2] + w] $$;

CREATE FUNCTION wavg_final(state float8[]) RETURNS float8
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS
$$ SELECT state[1] / NULLIF(state[2], 0) $$;

CREATE AGGREGATE wavg(float8, float8) (
    sfunc = wavg_step, stype = float8[], initcond = '{0,0}', finalfunc = wavg_final);

CREATE TABLE t AS
SELECT i % 5 AS g, (i % 100)::float8 AS v, (1 + i % 3)::float8 AS w
FROM generate_series(1, 300000) i;
ANALYZE t;

SELECT g, wavg(v, w), sum(v * w) / sum(w) AS by_hand FROM t GROUP BY g ORDER BY g;
```

```text
 g | wavg | by_hand 
---+------+---------
 0 | 47.5 |    47.5
 1 | 48.5 |    48.5
 2 | 49.5 |    49.5
 3 | 50.5 |    50.5
 4 | 51.5 |    51.5
(5 rows)
```

The custom aggregate agrees with the hand-written expression. When a built-in expression can do the job, as it can here, prefer it: a custom aggregate
is for logic the built-ins cannot express.

Now parallelism. A parallel plan needs the workers' partial states merged, which requires a
`combinefunc`. Force the planner to consider parallelism on this small table
(`parallel_setup_cost = 0` and friends, a test setting and not a production one) and look
at three versions. First, the aggregate as written:

```sql
SET parallel_setup_cost = 0;
SET parallel_tuple_cost = 0;
SET min_parallel_table_scan_size = 0;

EXPLAIN (COSTS OFF) SELECT g, wavg(v, w) FROM t GROUP BY g;
```

```text
     QUERY PLAN      
---------------------
 HashAggregate
   Group Key: g
   ->  Seq Scan on t
(3 rows)
```

Serial. Add a `combinefunc` and try again:

```sql
CREATE FUNCTION wavg_combine(a float8[], b float8[]) RETURNS float8[]
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS
$$ SELECT ARRAY[a[1] + b[1], a[2] + b[2]] $$;

CREATE AGGREGATE wavg_c(float8, float8) (
    sfunc = wavg_step, stype = float8[], initcond = '{0,0}', finalfunc = wavg_final,
    combinefunc = wavg_combine);

EXPLAIN (COSTS OFF) SELECT g, wavg_c(v, w) FROM t GROUP BY g;
```

```text
     QUERY PLAN      
---------------------
 HashAggregate
   Group Key: g
   ->  Seq Scan on t
(3 rows)
```

Still serial. This is the trap: **an aggregate is `PARALLEL UNSAFE` by default**, whatever
its component functions declare. Check `pg_proc`, then declare it:

```sql
SELECT proname, proparallel FROM pg_proc
WHERE proname IN ('wavg', 'wavg_c') ORDER BY 1;

CREATE AGGREGATE wavg_p(float8, float8) (
    sfunc = wavg_step, stype = float8[], initcond = '{0,0}', finalfunc = wavg_final,
    combinefunc = wavg_combine, parallel = safe);

EXPLAIN (COSTS OFF) SELECT g, wavg_p(v, w) FROM t GROUP BY g;
```

```text
 proname | proparallel 
---------+-------------
 wavg    | u
 wavg_c  | u
(2 rows)

                   QUERY PLAN                   
------------------------------------------------
 Finalize GroupAggregate
   Group Key: g
   ->  Gather Merge
         Workers Planned: 2
         ->  Sort
               Sort Key: g
               ->  Partial HashAggregate
                     Group Key: g
                     ->  Parallel Seq Scan on t
(9 rows)
```

Only with both `combinefunc` and `parallel = safe` does the plan split into a
`Partial HashAggregate` under each worker and a `Finalize` step. Whether that is *faster* depends on table size and cores; I did not measure it.

Drop the scratch database when you are done:

```bash
dropdb ch26_scratch
```

---

## Summary

- `ROLLUP`, `CUBE` and `GROUPING SETS` compute several groupings in one pass: 55 buffers
  against 165 for the three-arm `UNION ALL`. `ROLLUP` for hierarchies; explicit
  `GROUPING SETS` for the levels the report shows.
- Rolled-up cells and real NULLs look identical. `grouping(col)` is the only reliable way to
  tell them apart.
- `CUBE` is 2ⁿ sets: 8 for three dimensions, 32 for five, and 8,575 rows from 2,500. Stop at
  three.
- `FILTER` and `CASE` give the same plan and buffers. `FILTER` wins on correctness:
  `count(CASE ... ELSE 0 END)` returned 2,500 where the answer was 272. Neither turns an
  empty `sum` into 0.
- `percentile_cont` interpolates, `percentile_disc` returns a real value, `mode()` suits
  categories, and none takes `OVER`. Precompute percentiles that a dashboard refreshes.
- `array_agg` over a `LEFT JOIN` gives `{NULL}` for a childless parent; add `FILTER`. Only
  aggregate bounded groups: JSON ran 340 bytes per row here, against a 1 GB value limit.
- A custom aggregate runs in parallel only with a `combinefunc` *and* `parallel = safe`.
  `any_value()` needs PostgreSQL 16.

**Exercises:** Practice Sessions 26.1–26.3 accompany this chapter and are in the
workbook at the back of the book.

**Next:** Chapter 27, *Pattern Matching and Regular Expressions*, moves from summarising
numbers to searching text: `LIKE`, `SIMILAR TO`, POSIX regexes, and the indexes that make
them fast.
