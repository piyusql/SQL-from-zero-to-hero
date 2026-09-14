# Chapter 8 — Aggregation and Grouping

Every dashboard in your company is an aggregate query, as is every invoice total and every
number a finance team will argue about. Aggregation is where the database stops returning
facts and starts returning *claims*, and the distance between a claim and a true one is
usually a single NULL.

Hence this chapter following Chapter 7. Aggregates have their own NULL rule, different from
the comparison rule you just learned, and almost nobody is taught it explicitly — they learn
it from a reconciliation meeting. We will also settle a piece of folklore about `WHERE` and
`HAVING` by measuring it, because what I was taught is not what PostgreSQL 15 does.

---

## 8.1 The five you will use every day

An **aggregate function** takes many rows and produces one value.

```sql
SELECT count(*)          AS orders,
       sum(total_amount) AS revenue,
       avg(total_amount) AS mean_order,
       min(total_amount) AS smallest,
       max(total_amount) AS largest
FROM   orders;
```

```text
 orders |  revenue   |      mean_order       | smallest | largest
--------+------------+-----------------------+----------+---------
   2500 | 3678982.61 | 1471.5930440000000000 |    12.32 | 5982.78
(1 row)

```

That collapse is the defining property, and it costs you the detail: you cannot ask for
`count(*)` and `placed_at` together, because there are 2,500 values of `placed_at` and one
row to hold them. Section 8.5 enforces it.

The return types are not always what you passed in. `count` yields `bigint`; `sum` and `avg`
widen a step, because a million `integer` values overflow `integer` long before `bigint` and
PostgreSQL promotes rather than let you find out in production. `avg` over exact types
returns `numeric`, which is why `mean_order` shows sixteen decimal places; cast with
`::numeric(10,2)` for display. `min` and `max` return the input type and take anything
orderable — `max(placed_at)` is the most useful aggregate in monitoring and nobody writes a
chapter about it.

## 8.2 Aggregates ignore NULLs. Except `count(*)`

This is the most important paragraph in the chapter. **Every aggregate function skips NULL
inputs** — `sum`, `avg`, `min`, `max`, `count(column)` all drop NULL rows before doing
anything else. The single exception is `count(*)`, which counts rows and never looks at a
column.

Chapter 7 taught you that NULL propagates: `NULL + 1` is NULL. You might therefore expect
`sum` over a column containing NULL to return NULL. It does not. The standard gave
aggregates a different, pragmatic rule, and you must hold both at once.

```sql
SELECT count(*)             AS rows,
       count(amt)           AS non_null,
       sum(amt)             AS total,
       avg(amt)             AS mean,
       avg(coalesce(amt,0)) AS mean_null_as_zero
FROM   (VALUES (10::numeric), (20), (NULL), (NULL)) AS t(amt);
```

```text
 rows | non_null | total |        mean         | mean_null_as_zero
------+----------+-------+---------------------+--------------------
    4 |        2 |    30 | 15.0000000000000000 | 7.5000000000000000
(1 row)

```

`avg` computed `30 / 2`, not `30 / 4`: the NULL rows left the numerator *and* the
denominator, and were not treated as zero. Same data, same function, half the answer — and
which is right depends entirely on what the NULL means.

If NULL means **"no value exists"** — an order with no shipping date because it has not
shipped — excluding it is correct; the mean delay of orders that never shipped is undefined,
not zero. If NULL means **"zero, recorded badly"** — a refund column left empty when no
refund was issued — excluding it inflates the average by every row you dropped. Nothing in
the SQL tells you which, and nothing in the output warns you.

> **In production —** the most common silent reporting bug I have been called in to
> diagnose, and silent in the worst way: the number is plausible. A mean order value that
> quietly excluded 30% of rows looks like a good quarter. The real fix is a schema decision,
> not an SQL technique — if NULL means zero, make the column `NOT NULL DEFAULT 0` and stop
> lying to every future query. Chapter 15.

### The counts

```sql
SELECT count(*)                      AS n_rows,
       count(shipped_at)             AS n_shipped,
       count(discount_code)          AS n_discounted,
       count(DISTINCT discount_code) AS n_codes,
       (SELECT count(*) FROM (SELECT DISTINCT discount_code FROM orders) d) AS distinct_rows
FROM   orders;
```

```text
 n_rows | n_shipped | n_discounted | n_codes | distinct_rows
--------+-----------+--------------+---------+---------------
   2500 |      1733 |          447 |       4 |             5
(1 row)

```

**`count(*)`** is the cardinality of the group: it reads no column, so no column can be
NULL. **`count(shipped_at)`** is 1,733, the rows with a *known* value; the other 767 have no
shipping date, which here means they have not shipped. `count(column)` is not a count of
rows, and reading it as one is how you under-report.

**`count(DISTINCT discount_code)`** is 4 while `SELECT DISTINCT` on the same column returns
5 rows: `SELECT DISTINCT` lists NULL once, `count(DISTINCT x)` drops it. Decide whether
*absent* is one of your distinct values before writing the query. And when every input is
NULL, `count` returns 0 — zero known values is a fact — while everything else returns NULL.

The three are not priced the same. On the large `retail` variant — two million orders —
with a warm cache:

```text
SELECT count(*) FROM orders;                    -- 2,000,000    ~95 ms
SELECT count(shipped_at) FROM orders;           -- 1,399,683    ~95 ms
SELECT count(DISTINCT customer_id) FROM orders; --   254,896   ~300 ms
```

`count(*)` and `count(col)` scan once and increment a counter. `count(DISTINCT col)` must
*remember every value it has seen*, sorting or hashing 254,896 integers alongside the scan —
two to four times the cost here depending on the run, and the gap widens with cardinality
rather than with row count. `count(*)` and `count(col)` sit within noise of each other —
skipping NULLs is free; remembering values is not. (The large variant uses `random()`, so
your distinct count will differ.)

> **In production —** `count(DISTINCT ...)` on a high-cardinality column in a page-load
> query is a classic slow-burn outage: fine at ten thousand rows, unusable at ten million,
> SQL unchanged. Where approximate will do, `postgres_hll` trades exactness for a fixed,
> tiny footprint. Chapter 49.

## 8.3 `sum` of nothing is NULL. `count` of nothing is 0

Ask for the revenue of `refunded` orders. `orders.status` holds exactly `cancelled`,
`delivered`, `paid`, `pending`, `returned` and `shipped` — there is no refund state, so the
filter deliberately matches nothing.

```sql
SELECT count(*) AS n, sum(total_amount) AS revenue, avg(total_amount) AS mean,
       max(total_amount) AS largest
FROM   orders
WHERE  status = 'refunded';   -- a status this dataset never uses
```

```text
 n | revenue |  mean  | largest 
---+---------+--------+---------
 0 |  (null) | (null) |  (null)
(1 row)

```

One row still came back, because a bare aggregate always produces exactly one row even over
an empty input, and in it `count` is 0 while everything else is NULL.

If you took `refunded` for this schema's word for `returned`, that is the lesson before the
lesson: run `SELECT DISTINCT status FROM orders` before trusting a report that filters on a
column whose domain you assumed. Guessing yields wrong numbers rather than errors.

The asymmetry is defensible — the sum of an empty set is undefined rather than zero — and
it causes a recurring incident: an alert comparing `sum(errors) > 100` is NULL when there
are no error rows, which is not true, which means it never fires on the day the service
returned nothing at all. `coalesce(sum(total_amount), 0)` returns 0 instead.

> **In production —** wrap `sum`, and any aggregate feeding arithmetic or a comparison, in
> `coalesce` wherever the filtered set can legitimately be empty. Do not wrap `min` and
> `max` reflexively — `coalesce(max(placed_at), '1970-01-01')` invents a date that will
> eventually be compared against something and believed.

Add `GROUP BY status` to that query and it returns **zero rows**, not one row of zeroes:
`GROUP BY` emits one row per group *present in the input*, and an empty input has no groups,
so `coalesce` has nothing to act on. Reporting "0 orders" for an absent category needs a
source of categories to join against (Chapter 9), or `generate_series` for a date axis
(Practice Session 12.3).

## 8.4 `GROUP BY`

`GROUP BY` partitions the input rows and runs the aggregates once per group.

```sql
SELECT status, count(*) AS orders, sum(total_amount) AS revenue
FROM   orders
GROUP  BY status
ORDER  BY revenue DESC;
```

```text
  status   | orders |  revenue
-----------+--------+------------
 delivered |    963 | 1371737.22
 shipped   |    498 |  712983.73
 returned  |    272 |  434560.16
 cancelled |    254 |  406422.90
 paid      |    266 |  392419.10
 pending   |    247 |  360859.50
(6 rows)

```

Grouping does not imply ordering; a grouped query without `ORDER BY` is as unordered as any
other (Chapter 1).

### `GROUP BY` and NULL, which is not what Chapter 7 led you to expect

```sql
SELECT loyalty_tier,
       count(*)            AS customers,
       count(loyalty_tier) AS non_null_tier
FROM   customers
GROUP  BY loyalty_tier
ORDER  BY loyalty_tier NULLS LAST;
```

```text
 loyalty_tier | customers | non_null_tier 
--------------+-----------+---------------
 bronze       |       225 |           225
 gold         |       183 |           183
 silver       |       200 |           200
 (null)       |       392 |             0
(4 rows)

```

Chapter 7 was emphatic that `NULL = NULL` is not true, so if grouping worked by equality you
would get 392 groups of one. `GROUP BY` does not use `=`; it uses the *not distinct from*
semantics of `IS NOT DISTINCT FROM`, under which two NULLs are the same — as do `DISTINCT`,
`UNION` and `PARTITION BY`. Equality and grouping equivalence are different relations in SQL.

The last column is section 8.2 in miniature: in the NULL group, and only there, `count(*)`
says 392 and `count(loyalty_tier)` says 0. A report built on the second shows an empty tier
holding 392 real customers.

> **Trap —** the NULL group is easy to lose: it sorts last, so it falls off the bottom of a
> `LIMIT 10`, and renders as an empty cell in most BI tools, which people read as a glitch
> rather than a category. Name it on the way out.

## 8.5 The select-list rule, and PostgreSQL's exception to it

Once you write `GROUP BY`, every select-list expression must be a grouping expression or
inside an aggregate. Anything else is ambiguous — one output row, several input values.

```sql
SELECT country, city, count(*) FROM customers GROUP BY country;
```

```text
ERROR:  column "customers.city" must appear in the GROUP BY clause or be used in an aggregate function
LINE 1: SELECT country, city, count(*) FROM customers GROUP BY count...
                        ^
```

MySQL historically returned an arbitrary row's value here and called it a feature; this
error is PostgreSQL refusing to guess.

### The functional-dependency exception

One relaxation, genuinely useful and not widely known: group by a table's **primary key**
and you may select any other column of that table ungrouped.

```sql
SELECT id, signup_date, loyalty_tier, count(*) AS rows
FROM   customers
GROUP  BY id
ORDER  BY id
LIMIT  3;
```

```text
 id | signup_date | loyalty_tier | rows 
----+-------------+--------------+------
  1 | 2025-03-02  | silver       |    1
  2 | 2021-10-11  | bronze       |    1
  3 | 2024-02-21  | (null)       |    1
(3 rows)

```

Grouping by `customers.id` puts at most one row in each group, so the other columns are
**functionally dependent** on the key — one possible value, nothing guessed. On one table
the query is pointless; the payoff arrives in Chapter 9, the first time you group orders by
customer and want the customer's name, city and signup date alongside the totals.
`GROUP BY c.id`, not a four-column list you keep in sync forever.

> **Version note —** narrower than you might hope, and I checked rather than assumed. On
> 15.10 it applies **only** when the grouping list includes the primary key. Grouping by
> `customers.email` and selecting `name` fails even though every email is unique — and still
> fails after adding `NOT NULL UNIQUE`, and after `CREATE UNIQUE INDEX`. PostgreSQL reasons
> from the declared key, never from today's contents. Add it and the query works:
> `GROUP BY email, id`.

## 8.6 `WHERE` versus `HAVING`

- **`WHERE` filters rows, before grouping.** It cannot see aggregates; they do not exist yet.
- **`HAVING` filters groups, after aggregation.** It can see aggregates. That is its reason
  for existing.

Getting that wrong is loud:

```sql
SELECT status, count(*) FROM orders WHERE count(*) > 100 GROUP BY status;
```

```text
ERROR:  aggregate functions are not allowed in WHERE
LINE 1: SELECT status, count(*) FROM orders WHERE count(*) > 100 GRO...
                                                  ^
```

`HAVING sum(total_amount) > 400000` is where such a condition belongs. One scoping rule
catches everybody once: `HAVING` runs before the select list is projected, so an output
alias fails with `column "revenue" does not exist`. `GROUP BY` and `ORDER BY` can see
aliases; `WHERE` and `HAVING` cannot. Repeat the expression, or filter outside a CTE
(Chapter 12).

### They are not interchangeable

```sql
-- Filter rows, then count what is left.
SELECT status, count(*) AS big_orders
FROM   orders
WHERE  total_amount > 5000
GROUP  BY status
ORDER  BY status;
```

```text
  status   | big_orders
-----------+------------
 delivered |          3
 paid      |          1
 pending   |          1
 returned  |          2
 shipped   |          1
(5 rows)

```

```sql
-- Count everything, then keep the groups containing a big order.
SELECT status, count(*) AS all_orders
FROM   orders
GROUP  BY status
HAVING max(total_amount) > 5000
ORDER  BY status;
```

```text
  status   | all_orders
-----------+------------
 delivered |        963
 paid      |        266
 pending   |        247
 returned  |        272
 shipped   |        498
(5 rows)

```

Same five statuses, wildly different numbers, both correct answers to different questions.
The first asks *how many large orders per status*. The second asks *how many orders per
status, among statuses that have at least one large order*. Pick the wrong one and the
report is off by two orders of magnitude while still looking like a report.

### The folklore, and what PostgreSQL 15 actually does

The rule I was taught, and that most SQL courses repeat: a non-aggregate condition in
`HAVING` is legal but slower, because rows `WHERE` could have discarded early are grouped
first and discarded afterwards. I repeated it for years. On 15.10 it is wrong for the simple
case. Two million orders, no index on `customer_id` — the sample datasets ship without
indexes on foreign keys, deliberately (Chapter 33).

```sql
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
SELECT customer_id, count(*) AS orders, sum(total_amount) AS revenue
FROM   orders
WHERE  customer_id <= 1000
GROUP  BY customer_id;
```

```text
 Finalize GroupAggregate (actual rows=1000 loops=1)
   Group Key: customer_id
   ->  Gather Merge (actual rows=2715 loops=1)
         Workers Planned: 2
         Workers Launched: 2
         ->  Partial GroupAggregate (actual rows=905 loops=3)
               Group Key: customer_id
               ->  Sort (actual rows=2585 loops=3)
                     Sort Key: customer_id
                     Sort Method: quicksort  Memory: 148kB
                     Worker 0:  Sort Method: quicksort  Memory: 217kB
                     Worker 1:  Sort Method: quicksort  Memory: 301kB
                     ->  Parallel Seq Scan on orders (actual rows=2585 loops=3)
                           Filter: (customer_id <= 1000)
                           Rows Removed by Filter: 664082
 Planning Time: 0.178 ms
 Execution Time: 58.382 ms
```

The same predicate moved to `HAVING`:

```sql
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
SELECT customer_id, count(*) AS orders, sum(total_amount) AS revenue
FROM   orders
GROUP  BY customer_id
HAVING customer_id <= 1000;
```

```text
 Finalize GroupAggregate (actual rows=1000 loops=1)
   Group Key: customer_id
   ->  Gather Merge (actual rows=2661 loops=1)
         Workers Planned: 2
         Workers Launched: 2
         ->  Partial GroupAggregate (actual rows=887 loops=3)
               Group Key: customer_id
               ->  Sort (actual rows=2585 loops=3)
                     Sort Key: customer_id
                     Sort Method: quicksort  Memory: 318kB
                     Worker 0:  Sort Method: quicksort  Memory: 134kB
                     Worker 1:  Sort Method: quicksort  Memory: 214kB
                     ->  Parallel Seq Scan on orders (actual rows=2585 loops=3)
                           Filter: (customer_id <= 1000)
                           Rows Removed by Filter: 664082
 Planning Time: 0.036 ms
 Execution Time: 48.384 ms
```

Identical plans, 58.382 ms against 48.384 ms — a gap that reverses if you run them in the
other order. `Filter: (customer_id <= 1000)` is on the **sequential scan** in both, and there
is no filter on the aggregate node in either. PostgreSQL examines each `HAVING` conjunct
and, if it holds no aggregate and the query has a plain `GROUP BY`, moves it into `WHERE`
for you — legally, because a group
cannot exist without at least one row, so discarding rows early cannot remove a group that
should have survived. You wrote `HAVING`; the planner ran `WHERE`.

So find where the folklore *is* true. The rewrite is blocked when the conjunct contains an
aggregate, and the commonest route there is a developer who believes `HAVING` requires an
aggregate and obliges it. `customer_id` is the grouping key, so `max(customer_id)` is
`customer_id`, and this returns the same 1,000 rows:

```sql
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
SELECT customer_id, count(*) AS orders, sum(total_amount) AS revenue
FROM   orders
GROUP  BY customer_id
HAVING max(customer_id) <= 1000;
```

```text
 Finalize GroupAggregate (actual rows=1000 loops=1)
   Group Key: customer_id
   Filter: (max(customer_id) <= 1000)
   Rows Removed by Filter: 253896
   ->  Gather Merge (actual rows=672830 loops=1)
         Workers Planned: 2
         Workers Launched: 2
         ->  Sort (actual rows=224277 loops=3)
               Sort Key: customer_id
               Sort Method: external merge  Disk: 23592kB
               Worker 0:  Sort Method: external merge  Disk: 23632kB
               Worker 1:  Sort Method: external merge  Disk: 17432kB
               ->  Partial HashAggregate (actual rows=224277 loops=3)
                     Group Key: customer_id
                     Batches: 17  Memory Usage: 8337kB  Disk Usage: 31208kB
                     Worker 0:  Batches: 17  Memory Usage: 8337kB  Disk Usage: 31208kB
                     Worker 1:  Batches: 17  Memory Usage: 8337kB  Disk Usage: 14928kB
                     ->  Parallel Seq Scan on orders (actual rows=666667 loops=3)
 Planning Time: 0.042 ms
 Execution Time: 496.314 ms
```

Eight and a half times slower on this run, eight to twelve across repeated runs, and every
line says why. The `Parallel Seq Scan` has **no `Filter`**, so all two million rows go
upward. The `Partial HashAggregate` builds 254,896 groups instead of 1,000, does not fit the
4 MB `work_mem`, and spills. The `Sort` above it spills too. Then the aggregate node discards
`Rows Removed by Filter: 253896` groups it had just finished computing. Across the leader and
both workers, roughly 139 MB of temporary files written and read back, to return a thousand
rows totalling a few kilobytes.

> **Trap —** `Sort Method: external merge` and `Disk Usage:` mean the query exhausted
> `work_mem` and went to disk. Since PostgreSQL 13 hash aggregation spills rather than being
> rejected by the planner — an improvement that also makes the overrun *silent*. Treat any
> `Disk Usage:` as a finding. Chapter 34 reads these plans line by line.

**So: row conditions in `WHERE`, group conditions in `HAVING`** — not because the planner
cannot fix the simple case, but because the rewrite is conjunct-by-conjunct and skips any
conjunct containing an aggregate or volatile function, it stops entirely under
`GROUPING SETS`, `CUBE` and `ROLLUP` (Chapter 26), and `WHERE` states intent.

## 8.7 Grouping by an expression, and by ordinal

Any expression works as a grouping key. Time bucketing is the one you will write most.

```sql
SELECT date_trunc('month', placed_at)::date AS month,
       count(*)                             AS orders,
       sum(total_amount)                    AS revenue
FROM   orders
WHERE  placed_at >= DATE '2026-06-01'
GROUP  BY month
ORDER  BY month;
```

```text
   month    | orders |  revenue
------------+--------+-----------
 2026-06-01 |     79 | 117088.10
 2026-07-01 |     88 | 117378.53
 2026-08-01 |     80 | 104594.21
 2026-09-01 |      3 |   3098.04
(4 rows)

```

`GROUP BY month` names the select-list alias, which PostgreSQL permits and which beats
repeating the `date_trunc` call. And `WHERE` filters the **raw column**, not the bucket:
that matters once there is an index on `placed_at`, because `WHERE placed_at >= ...` can use
it and `WHERE date_trunc(...) >= ...` cannot without an expression index (Chapter 33).
*Filter on the column, group on the expression.*

> **Trap —** `date_trunc` on a `timestamptz` resolves month boundaries in the session's
> `TimeZone`, so two offices get different numbers at the edges. Pin it with
> `AT TIME ZONE 'UTC'`, or set `TimeZone` on the reporting role. Chapter 14.

### Ordinal positions

You may name a grouping or ordering key by its position. Written `GROUP BY 1 ORDER BY 3
DESC`, the query in section 8.4 returns exactly the output shown there — concise, legal, and
a maintenance hazard, because a *position* moves. Someone adds a column:

```sql
SELECT status,
       count(DISTINCT customer_id) AS customers,   -- new
       count(*)                    AS orders,
       sum(total_amount)           AS revenue
FROM   orders
GROUP  BY 1
ORDER  BY 3 DESC;
```

```text
  status   | customers | orders |  revenue
-----------+-----------+--------+------------
 delivered |       570 |    963 | 1371737.22
 shipped   |       366 |    498 |  712983.73
 returned  |       241 |    272 |  434560.16
 paid      |       238 |    266 |  392419.10
 cancelled |       214 |    254 |  406422.90
 pending   |       203 |    247 |  360859.50
(6 rows)

```

`GROUP BY 1` survived. `ORDER BY 3` now means `orders`, and `cancelled` and `paid` have
swapped places against section 8.4 — no error, no warning, a report sorted by the wrong
column forever. Ordinals break *loudly* in `GROUP BY`, via the select-list rule, and
*quietly* in `ORDER BY`. Fine at the `psql` prompt; name the column in anything you commit.

## 8.8 What is not in this chapter

`GROUPING SETS`, `CUBE` and `ROLLUP` compute several grouping levels in one pass;
`count(*) FILTER (WHERE ...)` aggregates a subset without a second query; `string_agg`,
`array_agg` and `jsonb_agg` collapse a group into a text value or array rather than a
number, obeying the NULL rule of section 8.2; `percentile_cont` and the other ordered-set
aggregates give medians and p95. All are Chapter 26, *Advanced Aggregation*.

One thing looks like aggregation and is not. **Window functions** compute aggregate values
*without* collapsing rows, so a running total or a per-group rank sits beside each detail
row. Chapter 25, and the chapter most people wish they had read sooner.

---

## Summary

- An aggregate turns many rows into one value; the individual rows are then gone.
- **Every aggregate ignores NULL inputs except `count(*)`.** `count(*)` counts rows,
  `count(col)` counts known values, `count(DISTINCT col)` counts distinct known values and
  costs several times more than either.
- `avg` divides by the non-NULL count — correct when NULL means "no value exists", a silent
  reporting bug when it means zero. Say what each NULL means before trusting the number.
- **`sum` over zero rows returns NULL; `count` returns 0.** Use `coalesce(sum(x), 0)` where
  the result feeds arithmetic, a comparison, or a `NOT NULL` column; do not `coalesce`
  `min`/`max` reflexively. Under `GROUP BY` an empty input returns no rows at all, which
  `coalesce` cannot fix.
- `GROUP BY` groups NULLs together, using `IS NOT DISTINCT FROM` rather than `=`. Label that
  group before it reaches a report.
- Every select-list column must be grouped or aggregated — except that grouping by the
  **primary key** frees every other column of that table. PostgreSQL reasons from the
  declared key, not from the data and not from a `UNIQUE` constraint.
- **Measured on 15.10:** `WHERE` filters rows before grouping and `HAVING` filters groups
  after, but PostgreSQL moves a non-aggregate `HAVING` conjunct into `WHERE` for you, so the
  textbook penalty does not appear. Wrap the predicate in `max()` and it does — roughly 9×
  slower, ~139 MB of spill. Write `WHERE` for row conditions anyway: the rewrite stops at
  any conjunct containing an aggregate, and stops entirely under `ROLLUP`.
- Group by expressions freely, but filter on the raw column so an index can serve it.
  Ordinals break loudly in `GROUP BY` and silently in `ORDER BY`.
- `GROUPING SETS`/`CUBE`/`ROLLUP`, `FILTER`, `string_agg`/`array_agg`/`jsonb_agg` and
  ordered-set aggregates are Chapter 26; aggregating without collapsing rows is Chapter 25.

**Exercises:** Practice Sessions 8.1–8.2 accompany this chapter and are in the
workbook at the back of the book.

**Next:** Part III begins with the operation every real query needs. Chapter 9 is joins —
all the types, `ON` versus `USING`, lateral joins, and the accidental row multiplication that
turns the revenue figures you just computed into three times the truth.
