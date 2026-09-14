# Chapter 12 — CTEs and Recursive Queries

Two unrelated things share the keyword `WITH`. The first is a naming device: a common
table expression names a subquery, turning a query you read inside-out into one you read
top-down. The second is the only construct in SQL that loops — `WITH RECURSIVE` feeds a
query its own output until the output stops changing, which is how you walk a management
hierarchy, a bill of materials, or a graph of anything pointing at anything.

Between them sits the most consequential thing to know about `WITH` in PostgreSQL: **its
optimiser behaviour changed in version 12**, and the internet has not caught up. Much of
the CTE advice you will find describes a database you are not running. We settle that with
plans.

---

## 12.1 A name for a subquery

Which customers spent above the average customer spend in 2026? With subqueries alone you
build a derived table of per-customer totals, join it to `customers`, then filter it
against a scalar subquery that averages a *second, character-for-character identical copy*
of that same derived table. Correct, and unpleasant: the reader's eye starts at the
innermost parenthesis and works outwards, and the two copies are the kind of maintenance
hazard that produces a wrong report, because changing the date in one and not the other
raises no error. Practice Session 12.1 has it in full.

The same question with `WITH`:

```sql
WITH spend_2026 AS (
    SELECT customer_id, sum(total_amount) AS spend
    FROM   orders
    WHERE  placed_at >= DATE '2026-01-01'
    GROUP  BY customer_id
),
average_spend AS (
    SELECT avg(spend) AS mean_spend FROM spend_2026
)
SELECT c.name, c.city, s.spend
FROM   spend_2026 s
JOIN   customers c ON c.id = s.customer_id
CROSS  JOIN average_spend a
WHERE  s.spend > a.mean_spend
ORDER  BY s.spend DESC
LIMIT  5;
```

```text
      name       |   city    |  spend  
-----------------+-----------+---------
 Farhan Patel    | (null)    | 8732.54
 Harpreet Shetty | Ahmedabad | 7268.68
 Anita Verma     | (null)    | 6652.96
 Vikram Menon    | Indore    | 6117.48
 Aditya Pillai   | Hyderabad | 6066.10
(5 rows)

```

Both forms return those five rows. (Output in this book prints NULL as `(null)`, which
Chapter 2 set with `\pset null '(null)'`; two of these customers have no city on file.)
The total is defined once and named, and `average_spend` is defined **in terms of**
`spend_2026` — a later CTE may reference any earlier one in the same `WITH`, and that
chaining is what makes them worth the keystrokes.

The plans differ too, in the direction you would want. The subquery version contains two
`Seq Scan on orders` nodes and two `HashAggregate`s, because the planner has no reason to
notice that two textually identical subqueries are one computation. The CTE version has
one of each plus two `CTE Scan` nodes reading the stored result: writing the thing once
let the database do it once.

## 12.2 The fence that stopped being a fence

Through PostgreSQL 11, a CTE was an **unconditional optimisation fence**. Every `WITH`
branch ran to completion and its rows were stored before the outer query looked at them;
no predicate from outside could reach in, and no index inside could serve an outer filter.
People used that deliberately: `WITH x AS (...)` was the query hint PostgreSQL officially
does not have.

**From PostgreSQL 12, a CTE referenced exactly once, not recursive, and free of side
effects is folded into the containing query** — inlined, as if you had written it as a
subquery in `FROM`. Predicates flow in. Indexes get used.

The difference, on the two-million-row `retail_lg` orders built in Practice Session 8.2:

```sql
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
WITH delivered AS (
    SELECT id, customer_id, placed_at, total_amount
    FROM   orders
    WHERE  status = 'delivered'
)
SELECT * FROM delivered WHERE id BETWEEN 100000 AND 100010;
```

```text
 Index Scan using orders_pkey on orders (actual rows=5 loops=1)
   Index Cond: ((id >= 100000) AND (id <= 100010))
   Filter: (status = 'delivered'::text)
   Rows Removed by Filter: 6
 Planning Time: 0.167 ms
 Execution Time: 0.047 ms
```

No CTE in that plan, and no `CTE Scan`. PostgreSQL dissolved `delivered` into the outer
query, pushed `id BETWEEN 100000 AND 100010` down to the table, and used the primary key
index.

Add one word — `MATERIALIZED`, which is what version 11 did here whether you wanted it or
not:

```sql
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
WITH delivered AS MATERIALIZED (
    SELECT id, customer_id, placed_at, total_amount
    FROM   orders
    WHERE  status = 'delivered'
)
SELECT * FROM delivered WHERE id BETWEEN 100000 AND 100010;
```

```text
 CTE Scan on delivered (actual rows=5 loops=1)
   Filter: ((id >= 100000) AND (id <= 100010))
   Rows Removed by Filter: 799981
   CTE delivered
     ->  Seq Scan on orders (actual rows=799986 loops=1)
           Filter: (status = 'delivered'::text)
           Rows Removed by Filter: 1200014
 Planning Time: 0.132 ms
 Execution Time: 174.976 ms
```

0.047 ms against 174.976 ms — roughly **3,700× slower**, same SQL, one keyword. The fence
is legible in the plan: the `Seq Scan` carries no `id` filter, so all two million rows are
examined and 799,986 stored; the `id` predicate sits one level up on the `CTE Scan`, which
discards 799,981 rows it has just been handed.

### The rules, stated exactly

On 15.10 a `WITH` branch is inlined when **all** of these hold, and materialised
otherwise:

- it is referenced **exactly once** in the rest of the query;
- it is not part of a `WITH RECURSIVE`;
- it is side-effect free — a `SELECT` containing **no volatile functions**;
- you did not write `MATERIALIZED`.

Reference the same CTE twice and it goes back to being computed once and stored — a `CTE`
node feeding two `CTE Scan`s, the behaviour section 12.1 relied on. `NOT MATERIALIZED`
inlines it anyway, and the plan then shows two independent scans of `orders`: the work
done twice, in exchange for letting the planner see through it.

But `NOT MATERIALIZED` is a **request, not an instruction**. Put `random()` in a
single-reference CTE, write `NOT MATERIALIZED`, and the plan still contains a `CTE` node.
PostgreSQL declines to inline where that could change the answer, and does not say so.

`MATERIALIZED` is not vestigial either. Inlining substitutes the CTE's expressions into
the outer query, so an expression mentioned twice out there is **evaluated more than
once**. A CTE computing a deliberately slow function over 500 rows, filtered by
`WHERE score > 10 AND score < 20`, inlines to
`Filter: ((slow_score(i) > 10) AND (slow_score(i) < 20))` — up to two calls per row
instead of one, 890 calls over 500 rows here because `AND` short-circuits, and 2,091 ms
against 1,104 ms with `MATERIALIZED`. Practice Session 12.4 has both plans and the call
count.

So: write `MATERIALIZED` when the body is expensive per row and the outer query filters on
its output. Write `NOT MATERIALIZED` when a cheap CTE is referenced two or three times and
you would rather have predicate pushdown than result reuse. Write neither the rest of the
time.

> **Trap —** if you learned "CTEs are an optimisation fence", that is now false by default
> and the advice built on it is actively harmful. The failure modes are symmetrical:
> someone half-remembering the fence adds a CTE to force materialisation, gets none, and
> cannot explain why the "optimisation" did nothing; someone else inherits a version 11
> query that depended on the fence, upgrades, and watches a batch job that ran in seconds
> take hours. Date the advice before you take it — if it does not say which major version
> it was measured on, it is a rumour.

## 12.3 `WITH RECURSIVE`

A recursive CTE has exactly three parts and the syntax lets you omit none of them: an
**anchor term** that runs once and seeds the result, `UNION ALL` (or `UNION`), and a
**recursive term** that references the CTE's own name and runs repeatedly. The execution
model is a loop over a **working table**, and holding it in your head is the difference
between writing these fluently and copying them off the internet:

1. Evaluate the anchor term. Its rows become the result, and also the working table.
2. Evaluate the recursive term, with the CTE's own name bound to *the working table only*
   and not to everything accumulated so far. Append its rows to the result; they become
   the new working table.
3. Repeat step 2 until an iteration produces **zero rows**.

That last line is the whole of termination. No iteration limit, no depth cap, no timeout:
if the recursive term never comes back empty, the query never ends.

In `hr`, `employees.manager_id` points at `employees.emp_id` and is NULL for exactly one
row, the CEO. Walking down from the root, carrying two things the walk does not give you
for free — the level, and the array of ids traversed to reach each row:

```sql
WITH RECURSIVE chart AS (
    SELECT emp_id, full_name, job_title, 1 AS depth, ARRAY[emp_id] AS path
    FROM   employees
    WHERE  manager_id IS NULL            -- anchor: the root
  UNION ALL
    SELECT e.emp_id, e.full_name, e.job_title, c.depth + 1, c.path || e.emp_id
    FROM   employees e
    JOIN   chart c ON e.manager_id = c.emp_id
)
SELECT depth, count(*) AS employees, min(job_title) AS title
FROM   chart
GROUP  BY depth
ORDER  BY depth;
```

```text
 depth | employees |          title          
-------+-----------+-------------------------
     1 |         1 | Chief Executive Officer
     2 |         5 | Senior Vice President
     3 |        18 | Vice President
     4 |        70 | Director
     5 |       280 | Senior Manager
     6 |      1100 | Team Lead
     7 |      1300 | Individual Contributor
(7 rows)

```

Seven levels, 2,774 employees, and uneven branching — 421 managers have one direct report,
two have ten. Neither `depth` nor `path` is magic: both are ordinary columns, seeded in
the anchor and extended in the recursive term. Anything you want to know about the walk,
you carry yourself.

Swap the outer query for `SELECT count(*) FROM chart` and the plan shows the loop:

```text
 Aggregate (actual rows=1 loops=1)
   CTE chart
     ->  Recursive Union (actual rows=2774 loops=1)
           ->  Seq Scan on employees (actual rows=1 loops=1)
                 Filter: (manager_id IS NULL)
                 Rows Removed by Filter: 2773
           ->  Hash Join (actual rows=396 loops=7)
                 Hash Cond: (e.manager_id = c.emp_id)
                 ->  Seq Scan on employees e (actual rows=2774 loops=7)
                 ->  Hash (actual rows=396 loops=7)
                       Buckets: 2048 (originally 1024)  Batches: 1 (originally 1)  Memory Usage: 133kB
                       ->  WorkTable Scan on chart c (actual rows=396 loops=7)
   ->  CTE Scan on chart (actual rows=2774 loops=1)
 Planning Time: 0.235 ms
 Execution Time: 1.789 ms
```

`WorkTable Scan` is the working table of step 2, and `loops=7` counts the iterations: six
that produced rows — levels 2 through 7 — and a seventh that produced none, which is how
the loop learned it was finished. That empty final pass is the termination test.

### Where a row sits, and its chain to the root

Change only the outer query and the same `chart` answers *where does this row sit*:

```sql
SELECT depth, emp_id, full_name, path
FROM   chart
WHERE  depth >= 6
ORDER  BY path
LIMIT  8;
```

```text
 depth | emp_id |   full_name   |           path           
-------+--------+---------------+--------------------------
     6 |    567 | Imran Bhat    | {1,2,9,50,194,567}
     6 |    931 | Arjun Kumar   | {1,2,9,50,194,931}
     7 |   1582 | Priya Desai   | {1,2,9,50,194,931,1582}
     7 |   2715 | Rohit Desai   | {1,2,9,50,194,931,2715}
     6 |   1028 | Kavita Shetty | {1,2,9,50,194,1028}
     7 |   1977 | Arjun Pillai  | {1,2,9,50,194,1028,1977}
     7 |   2110 | Imran Verma   | {1,2,9,50,194,1028,2110}
     6 |   1337 | Rajesh Nair   | {1,2,9,50,194,1337}
(8 rows)

```

`ORDER BY path` on an integer array compares element by element, sorting into depth-first
order — a child immediately follows its parent. That one clause is how you render an
indented org chart, and it beats sorting a concatenated string of names, which collates by
language rules you did not intend.

Now *who does this person report to, all the way up*. Same construct, arrow reversed: the
anchor is the employee, and the recursive term joins the **manager's** row to the current
one.

```sql
WITH RECURSIVE chain AS (
    SELECT emp_id, manager_id, full_name, job_title, 0 AS steps_up
    FROM   employees
    WHERE  emp_id = 2774
  UNION ALL
    SELECT m.emp_id, m.manager_id, m.full_name, m.job_title, c.steps_up + 1
    FROM   employees m
    JOIN   chain c ON m.emp_id = c.manager_id
)
SELECT steps_up, emp_id, full_name, job_title
FROM   chain
ORDER  BY steps_up;
```

```text
 steps_up | emp_id |   full_name    |        job_title        
----------+--------+----------------+-------------------------
        0 |   2774 | Vikram Desai   | Individual Contributor
        1 |   1123 | Fatima Rao     | Team Lead
        2 |     95 | Harpreet Desai | Senior Manager
        3 |     44 | Karthik Reddy  | Director
        4 |     23 | Ananya Desai   | Vice President
        5 |      2 | Sneha Reddy    | Senior Vice President
        6 |      1 | Ananya Reddy   | Chief Executive Officer
(7 rows)

```

This walk terminates on its own because `manager_id` is NULL at the root, so the join
finds nothing and the iteration comes back empty. Note what that guarantee rests on: the
data, not the query. Which brings us to the failure mode.

## 12.4 Cycles, and the query that never ends

`employees.manager_id` is a foreign key to the same table, and nothing in that constraint
prevents two employees from managing each other. `hr` has no cycles; your production data
will, eventually, because somebody will fix a reporting line in a hurry.

A directed graph in a scratch database, with `Mumbai → Pune → Hyderabad → Mumbai`:

```sql
CREATE TABLE routes (src text, dst text);
INSERT INTO routes VALUES
  ('Mumbai','Pune'), ('Pune','Hyderabad'), ('Hyderabad','Mumbai'),
  ('Mumbai','Bengaluru'), ('Bengaluru','Chennai');
```

```sql
SET statement_timeout = '3s';
WITH RECURSIVE reachable AS (
    SELECT src, dst, 1 AS hops FROM routes WHERE src = 'Mumbai'
  UNION ALL
    SELECT r.src, n.dst, r.hops + 1
    FROM   routes n JOIN reachable r ON n.src = r.dst
)
SELECT * FROM reachable;
```

```text
ERROR:  canceling statement due to statement timeout
```

Without the timeout that runs until the disk fills: the cycle regenerates the working
table forever, so it is never empty. No warning at plan time — an infinite loop with SQL
syntax.

The cheapest fix is `UNION` instead of `UNION ALL`. `UNION` discards rows already in the
result, so once the walk revisits `Mumbai` the recursive term produces nothing new and the
loop ends — five rows, every city reachable:

```sql
WITH RECURSIVE reachable AS (
    SELECT dst FROM routes WHERE src = 'Mumbai'
  UNION
    SELECT n.dst FROM routes n JOIN reachable r ON n.src = r.dst
)
SELECT * FROM reachable;
```

```text
    dst    
-----------
 Pune
 Bengaluru
 Hyderabad
 Chennai
 Mumbai
(5 rows)

```

That safety is not free. `UNION` deduplicates on **every iteration**, hashing or sorting
the whole accumulated result each time round the loop — the cost Chapter 11 measured, paid
once per level. That is why `UNION ALL` is the default in a construct whose data you
trust.

> **Trap —** `UNION` deduplicates whole rows, so carrying a counter or a path defeats it
> entirely. Write `SELECT dst, 1 AS hops ... UNION SELECT n.dst, r.hops + 1 ...` and it
> loops forever again, because `('Mumbai', 3)` and `('Mumbai', 6)` are different rows.
> This is the commonest way a query that looked safe in review is not.

The proper tool is the `CYCLE` clause, added in PostgreSQL 14 and working on 15.10 — I
checked rather than assumed. Append `CYCLE dst SET is_cycle USING visited` to the
`UNION ALL` version and it tracks the `dst` values visited along each branch, sets
`is_cycle` true on the row that closes the loop, stops descending there, and exposes the
visited list as a column. Eight rows come back, the counter survives, and the one row with
`is_cycle = t` is the cycle — which you can *report* rather than silently absorb.
`SEARCH DEPTH FIRST BY col SET ord` likewise builds the ordering column that section 12.3
assembled by hand.

> **In production —** on any hierarchy in one table, assume a cycle exists until a
> constraint says otherwise; a self-referencing foreign key cannot express acyclicity. Use
> `CYCLE`, or a depth guard (`WHERE c.depth < 50`), on every recursive query that reaches
> user-editable data. A runaway recursive CTE does not merely hang the session — it
> exhausts `work_mem`, spills, and can fill the temporary tablespace, which is everybody's
> outage.

## 12.5 `generate_series` and filling the gaps

The other everyday use of recursion-shaped thinking is not recursive at all. A report must
show every month in a period, including the months where nothing happened, and `GROUP BY`
cannot emit a row for a group with no rows in it (Chapter 8). You need a source of months
that does not come from the data. `generate_series` is that source.

```sql
WITH months AS (
    SELECT generate_series(DATE '2026-01-01',
                           DATE '2026-09-01',
                           INTERVAL '1 month')::date AS month
),
large_orders AS (
    SELECT date_trunc('month', placed_at)::date AS month,
           count(*)          AS orders,
           sum(total_amount) AS revenue
    FROM   orders
    WHERE  total_amount > 4000
      AND  placed_at >= DATE '2026-01-01'
      AND  placed_at <  DATE '2026-10-01'
    GROUP  BY 1
)
SELECT m.month, l.orders, l.revenue
FROM   months m
LEFT   JOIN large_orders l ON l.month = m.month
ORDER  BY m.month;
```

```text
   month    | orders | revenue 
------------+--------+---------
 2026-01-01 | (null) |  (null)
 2026-02-01 | (null) |  (null)
 2026-03-01 |      1 | 4825.24
 2026-04-01 |      2 | 8489.60
 2026-05-01 |      1 | 4196.31
 2026-06-01 |      1 | 4077.56
 2026-07-01 | (null) |  (null)
 2026-08-01 | (null) |  (null)
 2026-09-01 | (null) |  (null)
(9 rows)

```

Nine months, four with data. Without the series the result is four rows, and a chart drawn
from four rows shows a business with no quiet months. The `LEFT JOIN` must run **from**
the series **to** the data — reverse it and the gaps vanish again.

Then decide what a gap means. `coalesce(l.orders, 0)` turns them into zeroes, right here
because no large orders in January is genuinely zero, and wrong for *closing stock level*,
where a missing month means "unchanged" and zero is a fabrication.

Use `generate_series` whenever the step is a fixed interval. When it is not — a running
balance, a schedule that skips holidays — build the same axis with recursion: anchor on
the first value, and let the recursive term produce the next under a `WHERE` that
eventually fails. Practice Session 12.3 writes both forms.

## 12.6 Data-modifying CTEs

A `WITH` branch may be an `INSERT`, `UPDATE` or `DELETE` with `RETURNING`, and the rest of
the statement can read the returned rows. That is how you move rows between tables
atomically, with no window in which they exist in both places or neither — here from a
scratch `invoices` table to a matching `invoices_archive`:

```sql
CREATE TABLE invoices (id int PRIMARY KEY, customer text, city text,
                       amount numeric(10,2), status text);
CREATE TABLE invoices_archive (LIKE invoices);
INSERT INTO invoices VALUES
  (1,'Rajesh Kumar','Mumbai',12400.00,'paid'),
  (2,'Sneha Desai','Ahmedabad',5400.00,'sent'),
  (3,'Priya Menon','Kochi',3120.00,'paid'),
  (4,'Harpreet Singh','Pune',19880.75,'sent'),
  (5,'Vikram Reddy','Hyderabad',7650.50,'overdue'),
  (6,'Arjun Iyer','Pune',2250.25,'paid');
```

```sql
WITH closed AS (
    DELETE FROM invoices
    WHERE  status = 'paid'
    RETURNING *
)
INSERT INTO invoices_archive
SELECT * FROM closed
RETURNING id, customer, city, amount;
```

```text
 id |   customer   |  city  |  amount  
----+--------------+--------+----------
  1 | Rajesh Kumar | Mumbai | 12400.00
  3 | Priya Menon  | Kochi  |  3120.00
  6 | Arjun Iyer   | Pune   |  2250.25
(3 rows)

INSERT 0 3
```

Three rules, and the second catches everybody.

**They must be at the top level of the statement.** Nest one inside a subquery and you get
`ERROR: WITH clause containing a data-modifying statement must be at the top level`.

**Every part of the statement sees the same snapshot.** The sub-statements cannot see each
other's changes, and a `SELECT` in the outer query reads the table as it was before the
statement began:

```sql
WITH bumped AS (
    UPDATE invoices SET amount = round(amount * 1.05, 2)
    WHERE  city = 'Pune'
    RETURNING id, amount
)
SELECT i.id, i.customer, i.amount AS seen_by_select, b.amount AS returned_by_update
FROM   invoices i JOIN bumped b ON b.id = i.id;
```

```text
 id |    customer    | seen_by_select | returned_by_update 
----+----------------+----------------+--------------------
  4 | Harpreet Singh |       19880.75 |           20874.79
(1 row)

```

One row, two amounts. `seen_by_select` is the pre-update value from the snapshot;
`returned_by_update` is what `RETURNING` says the `UPDATE` wrote. Both are correct, and
the trap is assuming the first column reflects the change. The table holds 20874.79 the
moment the statement commits.

**A data-modifying CTE runs whether or not anything references it.** Every sub-statement
executes to completion, which makes `WITH log AS (INSERT INTO audit ... RETURNING id)` a
legitimate pattern and also means an unreferenced `DELETE` left in from debugging will
delete. Siblings execute in no defined order, so two of them updating the same row is
undefined behaviour rather than a sequence.

## 12.7 When a CTE is the wrong shape

Readability is a real engineering value — every report query is eventually debugged at
2 a.m. by somebody who did not write it — and the qualification is where damage happens.

A chain of six CTEs, each selecting from the last, each adding one column, is not
readable. It is a program written in a language with no local variables, and the reader
must hold six intermediate result shapes in their head to understand the seventh. The test
I apply: if a CTE is referenced once, used immediately below its definition, and does not
correspond to a concept someone in the business would name, it is a step in a calculation
rather than a thing, and it belongs in the query. Two to four well-named CTEs is a query
you can read.

The related failure is a CTE standing in for a join: a CTE per table, chained together,
reproduces the join order you happened to think of and buries the real relationships.
Write the join.

Nor is recursion free for being elegant. The `hr` walk touches all 2,774 employees seven
times over — 1.8 ms here, but the million-row variant is a different proposition, and the
fix is an index on `manager_id` so the recursive term does an index scan rather than
hashing the whole table (Chapter 33). If you walk the same hierarchy in every query, the
answer may be a different storage model — a materialised path column, or `ltree` (Chapter
49).

---

## Summary

- A CTE names a subquery so the query reads top-down instead of inside-out, and lets a
  later branch reference an earlier one.
- **The PostgreSQL 12 change is the thing to know.** A CTE referenced exactly once, not
  recursive, and free of volatile functions is **inlined**: predicates flow in, indexes
  get used. Before 12 it was an unconditional fence. Measured on 15.10, the same query ran
  in 0.047 ms inlined and 174.976 ms with `MATERIALIZED`. Advice that calls `WITH` a fence
  without naming a version is a rumour.
- `MATERIALIZED` forces the old behaviour; `NOT MATERIALIZED` *requests* inlining and is
  ignored where inlining would be unsafe. Reach for `MATERIALIZED` when the body is
  expensive per row, since inlining can evaluate an expression once per outer reference.
- `WITH RECURSIVE` is anchor / `UNION ALL` / recursive term. The recursive term sees only
  the **previous iteration's** rows, and the loop stops when an iteration returns zero
  rows. Nothing else stops it.
- The `hr` org chart is **7 levels deep**, branching 1 to 10. Depth and path are ordinary
  columns you carry yourself; `ORDER BY` an integer path array gives depth-first order.
- On cyclic data `UNION ALL` loops forever. `UNION` terminates by deduplicating, at a
  dedup pass per iteration, and is defeated by carrying a counter or path column. `CYCLE`
  and `SEARCH` (PostgreSQL 14, verified on 15.10) do it properly and let you *report* a
  cycle rather than swallow it.
- `generate_series` plus a `LEFT JOIN` from the series to the data fills gaps in a
  reporting period. Decide whether a gap means zero or means unchanged.
- Data-modifying CTEs must be top level, all see the same snapshot, and run whether or not
  anything references them.
- Six chained CTEs are not readability; two to four, named after things the business would
  recognise, are.

**Exercises:** Practice Sessions 12.1–12.4 accompany this chapter and are in the
workbook at the back of the book.

**Next:** Part III ends here. Part IV turns from combining data to the data itself, with
Chapter 13 on numeric and character types — integer sizing, why money is never a float,
and the `varchar(n)` you will come to regret.
