# Chapter 25 — Window Functions

`GROUP BY` answers "how much per customer?" by throwing the orders away. The next questions
are "how much per customer, *next to each order*", "what did the previous month do", and
"which three rows per branch are the largest". Each needs the detail rows *and* a number
computed across them. Before window functions that meant a self-join or a correlated
subquery.

Window functions are also where reports go quietly wrong: ties, default frames, `NULL`
ordering and evaluation order all produce plausible wrong numbers. This chapter shows each
failure with real output, then measures the performance question that matters, top-N per
group. Sections 25.1 to 25.3
read `retail`; the rest use a scratch database built from `hr`:

```bash
dropdb --if-exists ch25_scratch
createdb ch25_scratch
pg_dump -t departments -t employees hr | psql -q -d ch25_scratch
```

---

## 25.1 What `OVER` does

An aggregate with `GROUP BY` collapses rows. The same aggregate followed by `OVER (...)`
keeps every row and attaches the result to each one. `PARTITION BY` splits the rows into
independent groups; empty parentheses mean one group holding everything.

```sql
\pset null '(null)'
SET TIME ZONE 'Asia/Kolkata';
SELECT id, total_amount, count(*) OVER () AS orders_listed,
       round(100 * total_amount / sum(total_amount) OVER (), 1) AS pct_of_total
FROM   orders WHERE customer_id = 232 ORDER BY id;
```

```text
  id  | total_amount | orders_listed | pct_of_total
------+--------------+---------------+--------------
    2 |      1973.12 |             3 |         36.6
 2183 |        14.73 |             3 |          0.3
 2242 |      3399.98 |             3 |         63.1
(3 rows)
```

`count(*) OVER ()` puts the row count beside every row, which is how you return a page and
its total in one query. It counted **3**, not 2,500, because a window function sees only the
rows that survived `WHERE`. The logical order is `FROM`, `WHERE`, `GROUP BY`, `HAVING`,
**windows**, `SELECT`, `ORDER BY`, `LIMIT`. That is also why you cannot filter *on* a window
result at the same query level:

```sql
SELECT id FROM orders WHERE rank() OVER (ORDER BY total_amount DESC) <= 3;
```

```text
ERROR:  window functions are not allowed in WHERE
LINE 1: SELECT id FROM orders WHERE rank() OVER (ORDER BY total_amou...
                                    ^
```

The rank does not exist yet when `WHERE` runs. Compute it in a subquery (or CTE, Chapter 12)
and filter outside:

```sql
SELECT id, customer_id, total_amount FROM (
  SELECT id, customer_id, total_amount, rank() OVER (ORDER BY total_amount DESC) AS rk
  FROM   orders) s
WHERE  rk <= 3;
```

```text
  id  | customer_id | total_amount
------+-------------+--------------
 2070 |         530 |      5982.78
  712 |         399 |      5620.14
 1065 |         239 |      5507.72
(3 rows)
```

If all you need is one number per customer, `GROUP BY` is the right tool: it emits one row per
group. A window function earns its place when the *detail row must survive*.

## 25.2 Running totals, moving averages and frames

Add `ORDER BY` inside `OVER` and an aggregate becomes cumulative; the rows it sees for each row
are the **frame**. Monthly revenue with a running total that restarts each year:

```sql
WITH m AS (
  SELECT date_trunc('month', placed_at)::date AS month, sum(total_amount) AS revenue
  FROM   orders WHERE status NOT IN ('cancelled','returned') AND placed_at < '2026-01-01'
  GROUP  BY 1),
w AS (
  SELECT month, revenue,
         sum(revenue) OVER (PARTITION BY extract(year FROM month) ORDER BY month) AS ytd
  FROM   m)
SELECT * FROM w WHERE month BETWEEN '2024-11-01' AND '2025-02-01' ORDER BY month;
```

```text
   month    | revenue  |    ytd
------------+----------+------------
 2024-11-01 | 84831.00 | 1012320.91
 2024-12-01 | 84120.63 | 1096441.54
 2025-01-01 | 69626.59 |   69626.59
 2025-02-01 | 85487.75 |  155114.34
(4 rows)
```

The filter sits *outside* the window on purpose. Move it inside and the window sees only the
months that pass it:

```sql
WITH m AS (
  SELECT date_trunc('month', placed_at)::date AS month, sum(total_amount) AS revenue
  FROM   orders WHERE status NOT IN ('cancelled','returned') AND placed_at < '2026-01-01'
  GROUP  BY 1)
SELECT month, revenue,
       sum(revenue) OVER (PARTITION BY extract(year FROM month) ORDER BY month) AS ytd
FROM   m WHERE month BETWEEN '2024-11-01' AND '2025-02-01' ORDER BY month;
```

```text
   month    | revenue  |    ytd
------------+----------+-----------
 2024-11-01 | 84831.00 |  84831.00
 2024-12-01 | 84120.63 | 168951.63
 2025-01-01 | 69626.59 |  69626.59
 2025-02-01 | 85487.75 | 155114.34
(4 rows)
```

November's "year to date" is now November, and nothing errors. The same mistake with `lag`
gives a wrong prior period. It is the most common window bug I get shown.

**The default frame** with `ORDER BY` and no frame clause is `RANGE BETWEEN UNBOUNDED
PRECEDING AND CURRENT ROW`, with two consequences. First, a moving average needs an explicit
frame, and its first rows average fewer rows than you asked for:

```sql
WITH m AS (
  SELECT date_trunc('month', placed_at)::date AS month, sum(total_amount) AS revenue
  FROM   orders WHERE status NOT IN ('cancelled','returned') GROUP BY 1)
SELECT month, revenue,
       round(avg(revenue) OVER w, 2) AS avg3, count(*) OVER w AS months_in_frame
FROM   m WINDOW w AS (ORDER BY month ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)
ORDER  BY month LIMIT 4;
```

```text
   month    | revenue  |   avg3   | months_in_frame
------------+----------+----------+-----------------
 2024-01-01 | 83791.42 | 83791.42 |               1
 2024-02-01 | 78645.91 | 81218.67 |               2
 2024-03-01 | 94637.24 | 85691.52 |               3
 2024-04-01 | 90497.45 | 87926.87 |               3
(4 rows)
```

January's "three-month average" is one month. To show only full windows, return `CASE WHEN
count(*) OVER w = 3 THEN avg(revenue) OVER w END`. `WINDOW w AS (...)` names a window so
several functions share it.

Second, `RANGE` treats rows that tie on the `ORDER BY` value as **peers** who enter the frame
together. Running revenue over the first days of January 2024, first with the default frame,
then with `id` as a tiebreaker and `ROWS`:

```sql
SELECT id, day, total_amount,
       sum(total_amount) OVER (ORDER BY day) AS running_default,
       sum(total_amount) OVER (ORDER BY day, id ROWS UNBOUNDED PRECEDING) AS running_rows
FROM  (SELECT id, placed_at::date AS day, total_amount FROM orders) o
WHERE day BETWEEN '2024-01-01' AND '2024-01-04' ORDER BY day, id;
```

```text
  id  |    day     | total_amount | running_default | running_rows
------+------------+--------------+-----------------+--------------
 1289 | 2024-01-01 |       198.76 |         2424.75 |       198.76
 1776 | 2024-01-01 |      2225.99 |         2424.75 |      2424.75
 1784 | 2024-01-02 |       248.20 |         2672.95 |      2672.95
  970 | 2024-01-04 |      1032.80 |         4730.58 |      3705.75
 1892 | 2024-01-04 |       816.39 |         4730.58 |      4522.14
 2324 | 2024-01-04 |       208.44 |         4730.58 |      4730.58
(6 rows)
```

Orders 1289 and 1776 both fall on 1 January and both report 2,424.75 under the default frame:
the total after order 1289 already includes its peer. The `ROWS` column answers "what had we
sold by *this order*". The two agree on the last row of each day, which is why a chart of one
row per day never notices. Practice Session 25.4 reconciles a finance report that did.

> **Trap —** `ROWS` over a non-unique `ORDER BY` is a different bug: which tied row comes
> first is unspecified, so the partial sums are arbitrary. Add a unique tiebreaker (`id`).

A third mode, `GROUPS`, counts peer groups instead of rows, and `RANGE` accepts distance
offsets. Frame sizes make the differences visible: "the current row and one step back",
measured three ways, over 4–7 January:

```sql
SELECT id, day,
       count(*) OVER (ORDER BY day, id ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) AS rows_1,
       count(*) OVER (ORDER BY day RANGE BETWEEN interval '1 day' PRECEDING AND CURRENT ROW) AS range_1day,
       count(*) OVER (ORDER BY day GROUPS BETWEEN 1 PRECEDING AND CURRENT ROW) AS groups_1
FROM  (SELECT id, placed_at::date AS day FROM orders
       WHERE placed_at >= '2024-01-04' AND placed_at < '2024-01-08') o ORDER BY day, id;
```

```text
  id  |    day     | rows_1 | range_1day | groups_1
------+------------+--------+------------+----------
  970 | 2024-01-04 |      1 |          3 |        3
 1892 | 2024-01-04 |      2 |          3 |        3
 2324 | 2024-01-04 |      2 |          3 |        3
 2198 | 2024-01-06 |      2 |          1 |        4
  663 | 2024-01-07 |      2 |          3 |        3
 1242 | 2024-01-07 |      2 |          3 |        3
(6 rows)
```

There are three orders on the 4th, none on the 5th, one on the 6th. For order 2198: `ROWS`
reaches back one row; `RANGE '1 day'` reaches back one *calendar day*, finds nothing on the
5th, and counts only itself; `GROUPS` reaches back one *day that has orders* and takes all
three from the 4th. Use `ROWS` for "the last N events", `RANGE` for "the last N days" (gaps
and all), `GROUPS` for "the last N active days".

> **Version note —** `RANGE` with an offset needs exactly one `ORDER BY` column with a
> defined distance: numbers take numbers, dates and timestamps take an `interval`, and text
> fails with `RANGE with offset PRECEDING/FOLLOWING is not supported for column type text`.
> `GROUPS` and `EXCLUDE CURRENT ROW | GROUP | TIES` both work on PostgreSQL 15.

**The `last_value` surprise.** `first_value` and `last_value` read the frame's ends, and the
default frame ends at the current row:

```sql
SELECT id, total_amount,
       last_value(total_amount)  OVER w AS last_default,
       last_value(total_amount)  OVER (w ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS last_full
FROM   orders WHERE customer_id = 232
WINDOW w AS (ORDER BY placed_at) ORDER BY placed_at;
```

```text
  id  | total_amount | last_default | last_full
------+--------------+--------------+-----------
 2242 |      3399.98 |      3399.98 |   1973.12
 2183 |        14.73 |        14.73 |   1973.12
    2 |      1973.12 |      1973.12 |   1973.12
(3 rows)
```

`last_default` is just the current row. Whenever you write `last_value` or `nth_value`, write
the frame too.

## 25.3 Period-over-period with `LAG`

`lag(x, n)` reads `x` from `n` rows earlier in the window's order; `lead` reads forward. The
default `n` is 1 and the default result, off the edge, is `NULL`:

```sql
WITH m AS (
  SELECT date_trunc('month', placed_at)::date AS month, sum(total_amount) AS revenue
  FROM   orders WHERE status NOT IN ('cancelled','returned') AND placed_at < '2026-01-01'
  GROUP  BY 1),
w AS (
  SELECT month, revenue,
         lag(revenue)     OVER (ORDER BY month) AS prev,
         lag(revenue, 12) OVER (ORDER BY month) AS year_ago
  FROM   m)
SELECT month, revenue, prev, round(100 * (revenue - prev) / prev, 1) AS mom_pct, year_ago
FROM   w WHERE month BETWEEN '2024-12-01' AND '2025-02-01' ORDER BY month;
```

```text
   month    | revenue  |   prev   | mom_pct | year_ago
------------+----------+----------+---------+----------
 2024-12-01 | 84120.63 | 84831.00 |    -0.8 |   (null)
 2025-01-01 | 69626.59 | 84120.63 |   -17.2 | 83791.42
 2025-02-01 | 85487.75 | 69626.59 |    22.8 | 78645.91
(3 rows)
```

`year_ago` is `NULL` for December 2024 (no row 12 back); leave it `NULL`. But `lag(x, 12)`
means twelve **rows** back, not twelve months, so it is correct only if every month has a
row. Drop June 2024 (a quiet month, or a failed load) and look at July:

```sql
WITH m AS (
  SELECT date_trunc('month', placed_at)::date AS month, sum(total_amount) AS revenue
  FROM   orders WHERE status NOT IN ('cancelled','returned') AND placed_at < '2026-01-01'
         AND date_trunc('month', placed_at) <> '2024-06-01'::timestamptz
  GROUP  BY 1),
w AS (SELECT month, revenue, lag(month) OVER (ORDER BY month) AS prev_month,
             lag(revenue) OVER (ORDER BY month) AS prev FROM m)
SELECT * FROM w WHERE month BETWEEN '2024-05-01' AND '2024-08-01' ORDER BY month;
```

```text
   month    |  revenue  | prev_month |   prev
------------+-----------+------------+-----------
 2024-05-01 | 102015.05 | 2024-04-01 |  90497.45
 2024-07-01 | 110568.69 | 2024-05-01 | 102015.05
 2024-08-01 |  99813.06 | 2024-07-01 | 110568.69
(3 rows)
```

July's "previous month" is May, silently. Densify first: `LEFT JOIN` the facts onto a
`generate_series` calendar, so a missing month is a row with `NULL` revenue:

```sql
WITH m AS (
  SELECT date_trunc('month', placed_at)::date AS month, sum(total_amount) AS revenue
  FROM   orders WHERE status NOT IN ('cancelled','returned') AND placed_at < '2026-01-01'
         AND date_trunc('month', placed_at) <> '2024-06-01'::timestamptz
  GROUP  BY 1),
cal AS (SELECT d::date AS month FROM generate_series('2024-01-01', '2025-12-01', interval '1 month') d),
w AS (SELECT c.month, m.revenue, lag(m.revenue) OVER (ORDER BY c.month) AS prev
      FROM cal c LEFT JOIN m USING (month))
SELECT * FROM w WHERE month BETWEEN '2024-05-01' AND '2024-08-01' ORDER BY month;
```

```text
   month    |  revenue  |   prev
------------+-----------+-----------
 2024-05-01 | 102015.05 |  90497.45
 2024-06-01 |    (null) | 102015.05
 2024-07-01 | 110568.69 |    (null)
 2024-08-01 |  99813.06 | 110568.69
(4 rows)
```

**`NULL` ordering.** In `ORDER BY`, `NULL` sorts as the largest value: last ascending, first
descending. Inside a window that decides who is "rank 1". Customer 6's orders, ranked by
most recent shipment:

```sql
SELECT id, placed_at::date AS placed, shipped_at::date AS shipped, status,
       rank() OVER (ORDER BY shipped_at DESC)             AS rk_default,
       rank() OVER (ORDER BY shipped_at DESC NULLS LAST)  AS rk_fixed
FROM   orders WHERE customer_id = 6 ORDER BY placed_at;
```

```text
  id  |   placed   |  shipped   |  status   | rk_default | rk_fixed
------+------------+------------+-----------+------------+----------
 2133 | 2024-02-01 | (null)     | cancelled |          1 |        3
  346 | 2025-02-01 | 2025-02-05 | shipped   |          4 |        2
 1306 | 2025-12-03 | 2025-12-06 | shipped   |          3 |        1
  960 | 2026-05-17 | (null)     | cancelled |          1 |        3
(4 rows)
```

The two orders that never shipped rank first by default. Say `NULLS LAST` or `NULLS FIRST` in
any window over a nullable column.

> **Trap —** `IGNORE NULLS`, which other databases offer to carry the last known value
> forward, is not PostgreSQL syntax. Practice Session 25.3 builds the carry-forward another way.

```sql
SELECT lag(shipped_at) IGNORE NULLS OVER (ORDER BY id) FROM orders LIMIT 1;
```

```text
ERROR:  syntax error at or near "NULLS"
LINE 1: SELECT lag(shipped_at) IGNORE NULLS OVER (ORDER BY id) FROM ...
                                      ^
```

## 25.4 Ranking, and what ties do to it

`row_number`, `rank` and `dense_rank` differ only in what they do with ties. From here the
queries run in the scratch database.

```sql
\c ch25_scratch
SELECT emp_id, job_title, salary,
       row_number() OVER w AS rn, rank() OVER w AS rk, dense_rank() OVER w AS dr
FROM   employees WHERE dept_id = 21
WINDOW w AS (ORDER BY salary DESC) ORDER BY rn LIMIT 6;
```

```text
 emp_id |   job_title    |  salary   | rn | rk | dr
--------+----------------+-----------+----+----+----
     11 | Vice President | 152350.72 |  1 |  1 |  1
     32 | Director       | 119582.80 |  2 |  2 |  2
     77 | Director       | 119582.80 |  3 |  2 |  2
     27 | Director       | 119582.80 |  4 |  2 |  2
    231 | Senior Manager |  98379.95 |  5 |  5 |  3
    108 | Senior Manager |  96018.83 |  6 |  6 |  4
(6 rows)
```

Three Directors share 119,582.80. `rank` gives them all 2 and skips to 5. `dense_rank` gives
them 2 and continues at 3. `row_number` never ties: it numbers them 2, 3, 4, and which
Director gets which number is decided by the executor, not by you. Change only the tiebreaker:

```sql
SELECT * FROM (
  SELECT emp_id, salary,
         row_number() OVER (ORDER BY salary DESC, emp_id)      AS rn_asc,
         row_number() OVER (ORDER BY salary DESC, emp_id DESC) AS rn_desc
  FROM   employees WHERE dept_id = 21) s
WHERE  salary = 119582.80 ORDER BY emp_id;
```

```text
 emp_id |  salary   | rn_asc | rn_desc
--------+-----------+--------+---------
     27 | 119582.80 |      2 |       4
     32 | 119582.80 |      3 |       3
     77 | 119582.80 |      4 |       2
(3 rows)
```

Employee 27 is number 4 or number 2 depending on a choice the first query never made. If "top 2
by salary" feeds a bonus, you have picked winners arbitrarily. Finish every `row_number`
ordering with a unique column. Which function to use is a business question: `row_number <= 2`
is exactly two people, `rank <= 2` is everyone who ties into the top two, `dense_rank <= 2`
is the top two *salary levels*. On department 21:

```sql
SELECT count(*) FILTER (WHERE rn <= 2) AS row_number_top2,
       count(*) FILTER (WHERE rk <= 2) AS rank_top2,
       count(*) FILTER (WHERE dr <= 2) AS dense_rank_top2
FROM (SELECT row_number() OVER w rn, rank() OVER w rk, dense_rank() OVER w dr
      FROM employees WHERE dept_id = 21 WINDOW w AS (ORDER BY salary DESC)) s;
```

```text
 row_number_top2 | rank_top2 | dense_rank_top2
-----------------+-----------+-----------------
               2 |         4 |               4
(1 row)
```

## 25.5 Top-N per group, and when a window is the wrong tool

The standard idiom is `row_number() OVER (PARTITION BY ...) <= N` in a subquery. It is
readable, and it numbers every row in the table. The alternative is `LATERAL` (Chapter 9)
with `ORDER BY ... LIMIT N`, which asks each group for its N rows and stops. Which is cheaper
depends on an index, so measure. The data is 200,000 payments over 50 branches, about 4,000
each, with tying amounts:

```sql
CREATE TABLE branch (branch_id int PRIMARY KEY);
INSERT INTO branch SELECT generate_series(1, 50);
CREATE TABLE payment (payment_id int PRIMARY KEY, branch_id int NOT NULL REFERENCES branch,
                      paid_at timestamptz NOT NULL, amount numeric(10,2) NOT NULL);
INSERT INTO payment
SELECT g, 1 + g % 50, timestamptz '2025-01-01' + g * interval '2 minutes',
       round((100 + (('x' || substr(md5(g::text), 1, 6))::bit(24)::int % 900000) / 100.0)::numeric, 2)
FROM generate_series(1, 200000) g;
VACUUM ANALYZE payment;
SET max_parallel_workers_per_gather = 0;   -- pins the plan shape for the comparison
```

The three largest payments per branch, first with no index beyond the primary key. Everything
is cached, so buffers are all `hit`; I trimmed the trailing `Planning:` lines, which vary.

```sql
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT branch_id, payment_id, amount FROM (
  SELECT branch_id, payment_id, amount,
         row_number() OVER (PARTITION BY branch_id ORDER BY amount DESC, payment_id) AS rn
  FROM   payment) s WHERE rn <= 3;
```

```text
                                     QUERY PLAN
------------------------------------------------------------------------------------
 Subquery Scan on s (actual rows=150 loops=1)
   Buffers: shared hit=1274, temp read=613 written=616
   ->  WindowAgg (actual rows=150 loops=1)
         Run Condition: (row_number() OVER (?) <= 3)
         Buffers: shared hit=1274, temp read=613 written=616
         ->  Sort (actual rows=200000 loops=1)
               Sort Key: payment.branch_id, payment.amount DESC, payment.payment_id
               Sort Method: external merge  Disk: 4904kB
               Buffers: shared hit=1274, temp read=613 written=616
               ->  Seq Scan on payment (actual rows=200000 loops=1)
                     Buffers: shared hit=1274
```

Every row is read and sorted, and the sort spills to disk at the default `work_mem`. Now
`LATERAL`:

```sql
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT b.branch_id, p.payment_id, p.amount FROM branch b
CROSS JOIN LATERAL (SELECT payment_id, amount FROM payment WHERE branch_id = b.branch_id
                    ORDER BY amount DESC, payment_id LIMIT 3) p;
```

```text
                            QUERY PLAN
-------------------------------------------------------------------
 Nested Loop (actual rows=150 loops=1)
   Buffers: shared hit=63701
   ->  Seq Scan on branch b (actual rows=50 loops=1)
         Buffers: shared hit=1
   ->  Limit (actual rows=3 loops=50)
         Buffers: shared hit=63700
         ->  Sort (actual rows=3 loops=50)
               Sort Key: payment.amount DESC, payment.payment_id
               Sort Method: top-N heapsort  Memory: 25kB
               Buffers: shared hit=63700
               ->  Seq Scan on payment (actual rows=4000 loops=50)
                     Filter: (branch_id = b.branch_id)
                     Rows Removed by Filter: 196000
                     Buffers: shared hit=63700
```

Without an index `LATERAL` is the *worst* choice: 50 full scans, 63,701 buffers against the
window's 1,274. Now add the index matching the `PARTITION BY` and `ORDER BY`, warm it, and
rerun both:

```sql
CREATE INDEX payment_branch_amount ON payment (branch_id, amount DESC, payment_id);
VACUUM ANALYZE payment;
-- warm the index, leaf pages and the descent pages both
SET enable_seqscan = off;
SELECT count(*) FROM payment WHERE branch_id > 0;
SELECT count(*) FROM branch b, LATERAL (SELECT 1 FROM payment WHERE branch_id = b.branch_id
                                        ORDER BY amount DESC, payment_id LIMIT 3) p;
RESET enable_seqscan;
```

```sql
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT branch_id, payment_id, amount FROM (
  SELECT branch_id, payment_id, amount,
         row_number() OVER (PARTITION BY branch_id ORDER BY amount DESC, payment_id) AS rn
  FROM   payment) s WHERE rn <= 3;
```

```text
                                           QUERY PLAN
-------------------------------------------------------------------------------------------------
 Subquery Scan on s (actual rows=150 loops=1)
   Buffers: shared hit=770
   ->  WindowAgg (actual rows=150 loops=1)
         Run Condition: (row_number() OVER (?) <= 3)
         Buffers: shared hit=770
         ->  Index Only Scan using payment_branch_amount on payment (actual rows=200000 loops=1)
               Heap Fetches: 0
               Buffers: shared hit=770
```

The sort is gone, and PostgreSQL 15's `Run Condition` stops the window at 150 rows, but the
scan underneath still delivers all 200,000 index entries. A window function cannot tell the
index to skip ahead. `LATERAL` can:

```sql
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT b.branch_id, p.payment_id, p.amount FROM branch b
CROSS JOIN LATERAL (SELECT payment_id, amount FROM payment WHERE branch_id = b.branch_id
                    ORDER BY amount DESC, payment_id LIMIT 3) p;
```

```text
                                         QUERY PLAN
---------------------------------------------------------------------------------------------
 Nested Loop (actual rows=150 loops=1)
   Buffers: shared hit=152
   ->  Seq Scan on branch b (actual rows=50 loops=1)
         Buffers: shared hit=1
   ->  Limit (actual rows=3 loops=50)
         Buffers: shared hit=151
         ->  Index Only Scan using payment_branch_amount on payment (actual rows=3 loops=50)
               Index Cond: (branch_id = b.branch_id)
               Heap Fetches: 0
               Buffers: shared hit=151
```

Fifty index descents of three rows each. Check both return the same rows (both orderings end
in `payment_id`, so they are deterministic):

```sql
WITH a AS (
  SELECT branch_id, payment_id FROM (
    SELECT branch_id, payment_id,
           row_number() OVER (PARTITION BY branch_id ORDER BY amount DESC, payment_id) AS rn
    FROM payment) s WHERE rn <= 3),
b AS (
  SELECT br.branch_id, p.payment_id FROM branch br
  CROSS JOIN LATERAL (SELECT payment_id FROM payment WHERE branch_id = br.branch_id
                      ORDER BY amount DESC, payment_id LIMIT 3) p)
SELECT (SELECT count(*) FROM (SELECT * FROM a EXCEPT SELECT * FROM b) x) AS only_window,
       (SELECT count(*) FROM (SELECT * FROM b EXCEPT SELECT * FROM a) x) AS only_lateral;
```

```text
 only_window | only_lateral
-------------+--------------
           0 |            0
(1 row)
```

What I would do: few groups, many rows each, and a matching index, `LATERAL`. No index, the
window. Many small groups reverse the result: on 40 departments of about 70 employees
(Practice Session 25.2) the window read 16 buffers to `LATERAL`'s 83. Measure on your own
table (Chapter 34 covers reading the plans). `DISTINCT ON` is the short form when N is 1; I did
not measure it here. Top-N for pagination is Chapter 36.

## 25.6 Named windows, and how many sorts you pay for

Every distinct window definition costs a `WindowAgg` node, and every distinct ordering costs
a `Sort`. The planner reuses one sort when a window's ordering is a prefix of another's:

```sql
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT emp_id, sum(salary) OVER (PARTITION BY dept_id ORDER BY salary),
       rank() OVER (PARTITION BY dept_id ORDER BY salary),
       avg(salary) OVER (PARTITION BY dept_id) FROM employees;
```

```text
                             QUERY PLAN
--------------------------------------------------------------------
 WindowAgg (actual rows=2774 loops=1)
   Buffers: shared hit=44
   ->  WindowAgg (actual rows=2774 loops=1)
         Buffers: shared hit=44
         ->  Sort (actual rows=2774 loops=1)
               Sort Key: dept_id, salary
               Sort Method: quicksort  Memory: 270kB
               Buffers: shared hit=44
               ->  Seq Scan on employees (actual rows=2774 loops=1)
                     Buffers: shared hit=44
```

Two `WindowAgg` nodes, one `Sort`: the first two functions share a definition, and the third
(`PARTITION BY dept_id` alone) is a prefix of the same sort key. Now an unrelated ordering:

```sql
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT emp_id, rank() OVER (PARTITION BY dept_id ORDER BY salary),
       rank() OVER (PARTITION BY dept_id ORDER BY hire_date) FROM employees;
```

```text
                                           QUERY PLAN
------------------------------------------------------------------------------------------------
 WindowAgg (actual rows=2774 loops=1)
   Buffers: shared hit=47
   ->  Incremental Sort (actual rows=2774 loops=1)
         Sort Key: dept_id, salary
         Presorted Key: dept_id
         Full-sort Groups: 40  Sort Method: quicksort  Average Memory: 29kB  Peak Memory: 29kB
         Pre-sorted Groups: 29  Sort Method: quicksort  Average Memory: 30kB  Peak Memory: 30kB
         Buffers: shared hit=47
         ->  WindowAgg (actual rows=2774 loops=1)
               Buffers: shared hit=47
               ->  Sort (actual rows=2774 loops=1)
                     Sort Key: dept_id, hire_date
                     Sort Method: quicksort  Memory: 270kB
                     Buffers: shared hit=47
                     ->  Seq Scan on employees (actual rows=2774 loops=1)
                           Buffers: shared hit=44
```

The data is sorted twice: by `dept_id, hire_date`, then an `Incremental Sort` to `dept_id,
salary`. Both are cheap at 2,774 rows; at millions each is a pass with its own `work_mem`
pressure, so six differently ordered windows are six sorts. Group functions by ordering.

## Summary

- A window function keeps the rows and attaches a computed value. It runs after `WHERE`,
  `GROUP BY` and `HAVING`, so it cannot appear in `WHERE` and sees only surviving rows.
  Filter on its result in an outer query, and put range filters *outside* the window: a
  year-to-date filtered to November reported November's revenue.
- The default frame is `RANGE UNBOUNDED PRECEDING TO CURRENT ROW`: ties become peers and share
  a running total (2,424.75 twice), and `last_value` returns the current row. Use `ROWS` with a
  unique tiebreaker for "as of this row", `RANGE` with an interval for calendar distance,
  `GROUPS` for "N active days", and write the frame.
- `row_number` is arbitrary among ties; "top 2" returned 2, 4 and 4 people from `row_number`,
  `rank` and `dense_rank`. `NULL` sorts largest, so name `NULLS LAST`.
- `lag(x, 12)` is twelve rows, not months: densify with `generate_series`. PostgreSQL 15 has
  no `IGNORE NULLS`.
- Top-N per group: with no index the window read 1,274 buffers against `LATERAL`'s 63,701;
  with a matching index `LATERAL ... LIMIT N` read 152 against the window's 770.
- Windows that share an ordering (or a prefix of one) share a sort; each new ordering adds one.

**Exercises:** Practice Sessions 25.1–25.4 accompany this chapter and are in the workbook at
the back of the book.

**Next:** Chapter 26, *Advanced Aggregation*, returns to collapsing rows: `GROUPING SETS`,
`ROLLUP` and `CUBE`, `FILTER`, ordered-set aggregates such as `percentile_cont`, and
aggregates that build arrays and JSON.
