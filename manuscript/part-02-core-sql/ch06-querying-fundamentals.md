# Chapter 6 — Querying Fundamentals

Chapter 5 put rows into tables. This chapter gets them back out, and it is the chapter
most readers think they can skip.

They cannot, because of one structural fact almost nobody is taught explicitly: **the
order in which you write the clauses of a `SELECT` is not the order in which the database
evaluates them.** Why an alias works in `ORDER BY` and fails in `WHERE`. Why `WHERE`
refuses to see a `count(*)`. Why you can sort by a column you did not select, except when
you used `DISTINCT`. Read as syntax rules those are arbitrary facts to memorise; read as
consequences of one pipeline they are obvious.

We use `retail` throughout. If you have not loaded it, Chapter 2 shows you how.

---

## 6.1 The shape of a query

```sql
SELECT id, sku, name, category, price
FROM   products
ORDER  BY id
LIMIT  5;
```

```text
 id |    sku    |     name     | category  | price  
----+-----------+--------------+-----------+--------
  1 | SKU-00001 | Konark Diya  | lighting  | 348.21
  2 | SKU-00002 | Mysuru Diya  | kitchen   | 184.11
  3 | SKU-00003 | Jaipur Diya  | decor     | 242.56
  4 | SKU-00004 | Nilgiri Diya | storage   | 104.85
  5 | SKU-00005 | Chola Diya   | furniture | 218.17
(5 rows)
```

`FROM` names where rows come from, `SELECT` what to produce from each one, `ORDER BY`
imposes an order, `LIMIT` truncates. The full written form, with every clause in its
mandatory position:

```text
SELECT   [DISTINCT] select_list
FROM     table_expression
WHERE    row_condition
GROUP BY grouping_columns
HAVING   group_condition
ORDER BY sort_specification
LIMIT    count
OFFSET   start
```

You cannot reorder these; `WHERE` before `FROM` is a syntax error. That rigidity is
exactly what makes the written order misleading — it looks like a sequence of steps, and
it is not one.

`FROM` is optional, incidentally, which is occasionally useful for evaluating an
expression with no table involved:

```sql
SELECT 2 + 2 AS answer, upper('slonik') AS mascot;
```

```text
 answer | mascot 
--------+--------
      4 | SLONIK
(1 row)
```

## 6.2 Written order is not evaluation order

Here is the order PostgreSQL actually evaluates a query in. Commit it to memory; it is the
most load-bearing diagram in Part II.

```text
written                     evaluated
-------                     ---------
SELECT    ─────────┐   1.   FROM        which rows exist at all
FROM      ──┐      │   2.   WHERE       discard rows
WHERE     ──┼──┐   │   3.   GROUP BY    collapse rows into groups
GROUP BY  ──┼──┼─┐ │   4.   HAVING      discard groups
HAVING    ──┼──┼─┼─┼─▶ 5.   SELECT      compute output columns, bind aliases
ORDER BY  ──┼──┼─┼─┤   6.   DISTINCT    deduplicate the output rows
LIMIT     ──┴──┴─┴─┘   7.   ORDER BY    sort
                       8.   LIMIT       truncate
```

This is a *logical* model — the planner interleaves and fuses these steps freely — but the
result is always what the pipeline would produce, and the visibility rules follow it
exactly. Four consequences — each one a question people ask on mailing lists roughly
weekly.

### An alias is not visible to `WHERE`

`SELECT` is step 5, `WHERE` is step 2. When `WHERE` runs, `gross` does not exist yet.

```sql
SELECT id, total_amount * 1.19 AS gross
FROM   orders
WHERE  gross > 5000
ORDER  BY gross DESC;
```

```text
ERROR:  column "gross" does not exist
LINE 3: WHERE  gross > 5000
               ^
```

Move the same reference to `ORDER BY` — step 7, after `SELECT` — and it resolves:

```sql
SELECT id, total_amount * 1.19 AS gross
FROM   orders
ORDER  BY gross DESC
LIMIT  5;
```

```text
  id  |   gross   
------+-----------
 2070 | 7119.5082
  712 | 6687.9666
 1065 | 6554.1868
 1126 | 6483.0248
 2404 | 6054.1845
(5 rows)
```

The fix for the `WHERE` case is to repeat the expression: `WHERE total_amount * 1.19 >
5000`. That feels like duplication and it is, but it is honest duplication — the filter
genuinely runs at a point in the pipeline where the derived column has not been computed.

`HAVING` is step 4, also before `SELECT`, so it cannot see aliases either.
> `GROUP BY` *can*, which is a PostgreSQL extension to the standard rather than a
> consequence of the pipeline, and one of the few places the model leaks. Chapter 8 deals
> with both.

### `WHERE` cannot see an aggregate

Aggregation is step 3, so when `WHERE` evaluates, groups do not exist.

```sql
SELECT customer_id, count(*)
FROM   orders
WHERE  count(*) > 8
GROUP  BY customer_id;
```

```text
ERROR:  aggregate functions are not allowed in WHERE
LINE 3: WHERE  count(*) > 8
               ^
```

This is why `HAVING` exists: not a second style but a second point in the pipeline.

### `ORDER BY` can sort by something you did not select

It resolves against the output columns *and* the input columns still available from
`FROM`:

```sql
SELECT id, loyalty_tier
FROM   customers
ORDER  BY signup_date DESC, id
LIMIT  5;
```

```text
 id  | loyalty_tier 
-----+--------------
 793 | silver
 819 | bronze
 966 | bronze
 469 | (null)
 774 | silver
(5 rows)
```

### Unless `DISTINCT` got there first

`DISTINCT` is step 6. After it each surviving row stands for many inputs with many
different `signup_date` values, so there is nothing left to sort by.

```sql
SELECT DISTINCT loyalty_tier
FROM   customers
ORDER  BY signup_date DESC;
```

```text
ERROR:  for SELECT DISTINCT, ORDER BY expressions must appear in select list
LINE 3: ORDER  BY signup_date DESC;
                  ^
```

Four behaviours, one diagram. Rederive them from the pipeline rather than recalling them
individually and this chapter has done its job.

### The pipeline in a plan

```sql
EXPLAIN
SELECT   name, upper(loyalty_tier) AS tier
FROM     customers
WHERE    loyalty_tier = 'gold'
ORDER BY signup_date DESC
LIMIT    10;
```

```text
                               QUERY PLAN                                
-------------------------------------------------------------------------
 Limit  (cost=28.91..28.94 rows=10 width=49)
   ->  Sort  (cost=28.91..29.37 rows=183 width=49)
         Sort Key: signup_date DESC
         ->  Seq Scan on customers  (cost=0.00..24.96 rows=183 width=49)
               Filter: (loyalty_tier = 'gold'::text)
(5 rows)
```

Read bottom-up: scan, filter, sort, truncate. Note that `upper(loyalty_tier)` gets no node
of its own — projection folds into whichever node produces the rows, which is why
"`SELECT` is a step" is convenient rather than physical. And `Sort Key: signup_date`
confirms the sort runs over a column that never reaches the output. Chapter 34 reads plans
properly.

## 6.3 The select list

The select list is an expression list, not a column list.

```sql
SELECT id,
       total_amount,
       round(total_amount * 0.19, 2) AS vat,
       total_amount * 1.19           AS gross
FROM   orders
ORDER  BY id
LIMIT  5;
```

```text
 id | total_amount |  vat   |   gross   
----+--------------+--------+-----------
  1 |       622.51 | 118.28 |  740.7869
  2 |      1973.12 | 374.89 | 2348.0128
  3 |      2673.55 | 507.97 | 3181.5245
  4 |      2442.23 | 464.02 | 2906.2537
  5 |       714.38 | 135.73 |  850.1122
(5 rows)
```

Note `gross`. `numeric(12,2)` multiplied by the literal `1.19` yields four decimal places,
because `numeric` multiplication adds the scales of its operands rather than rounding to
something convenient. That is correct behaviour and what you want from an exact type, but
it means **money arithmetic needs an explicit `round()` at whatever point you stop
calculating and start displaying**. Part IV goes into `numeric` properly; for now, notice
that `vat` was rounded and `gross` was not, and that the difference is visible in the
output rather than hidden.

`AS` is optional and you should write it anyway: without it a missing comma becomes a
silent rename rather than a syntax error (`SELECT id, status total_amount` is one column,
not two). Double-quote anything that is not a lowercase identifier.

> **Trap —** an alias can shadow a real column, and `ORDER BY` prefers the alias:
>
> ```sql
> SELECT status AS id, id AS status
> FROM   orders
> ORDER  BY id
> LIMIT  5;
> ```
>
> ```text
>     id     | status 
> -----------+--------
>  cancelled |     55
>  cancelled |     79
>  cancelled |     37
>  cancelled |     48
>  cancelled |     89
> (5 rows)
> ```
>
> `ORDER BY id` sorted by the *output* column named `id`, which holds statuses.
> `ORDER BY orders.id` reaches the real column. A bare name resolves against the output
> first.

## 6.4 `FROM` and `WHERE`

`FROM` establishes the rows — one table here, joins and subqueries from Chapter 9 onward.
Table aliases (`FROM orders o`) become mandatory once a query mentions a table twice.

`WHERE` discards rows for which its condition is not true. "Not true" rather than "false"
is deliberate: a condition involving `NULL` evaluates to *unknown*, so the row goes. That,
the operator set, and `AND`/`OR` precedence are Chapter 7's subject.

One thing to internalise now: **the order of predicates in your `WHERE` clause is not the
order they are evaluated in.** The planner reorders by cost and selectivity, so code
relying on short-circuit evaluation for safety relies on something PostgreSQL never
promised (Chapter 36).

## 6.5 `ORDER BY`

Chapter 1 established that rows have no inherent order. The operational form: **without
`ORDER BY`, any order you observe is an artefact of today's plan, today's physical row
placement, and today's row count.** A freshly loaded table looks reassuringly sorted,
right up until an `UPDATE` moves a row or someone adds an index.

`ORDER BY` takes a comma-separated list of sort keys, each independently `ASC` (the
default) or `DESC`:

```sql
SELECT id, status, total_amount
FROM   orders
ORDER  BY total_amount DESC, id
LIMIT  3;
```

```text
  id  |  status   | total_amount 
------+-----------+--------------
 2070 | delivered |      5982.78
  712 | paid      |      5620.14
 1065 | delivered |      5507.72
(3 rows)
```

Sort keys may be output aliases, input columns, or arbitrary expressions. There is one
restriction, and it catches people: a *bare* alias works, but an alias used inside a
larger expression does not.

```sql
SELECT id, upper(status) AS tag FROM orders ORDER BY length(tag), id LIMIT 3;
```

```text
ERROR:  column "tag" does not exist
LINE 1: ... upper(status) AS tag FROM orders ORDER BY length(tag), id L...
                                                             ^
```

An expression in `ORDER BY` is resolved against the *input* columns, where no `tag`
exists. Spell it out — `ORDER BY length(upper(status))` — or move the computation into a
subquery. Chapter 3 met the same rule from the other side, where adding `COLLATE` to a
bare alias turned it into an expression and broke it.

Sorting by ordinal position (`ORDER BY 3 DESC, 1`) is fine interactively and a defect
waiting to happen in application code and views, because the meaning of `ORDER BY 3`
changes the moment someone inserts a column into the select list, and nothing errors.

### `NULLS FIRST` and `NULLS LAST`

`NULL` sorts as *larger than everything*, so `ASC` implies `NULLS LAST` and `DESC` implies
`NULLS FIRST`. In `retail`, 767 of 2,500 orders have not shipped:

```sql
SELECT id, shipped_at FROM orders ORDER BY shipped_at DESC, id LIMIT 3;
```

```text
 id | shipped_at 
----+------------
  3 | (null)
 10 | (null)
 15 | (null)
(3 rows)
```

"Show me the most recently shipped orders" returned three orders that have never shipped.
This is not exotic; it is the single most common way a "latest activity" dashboard ends up
displaying nothing useful, and it passes code review because the SQL looks right. Say what
you mean:

```sql
SELECT id, shipped_at FROM orders ORDER BY shipped_at DESC NULLS LAST, id LIMIT 3;
```

```text
  id  |       shipped_at       
------+------------------------
 2362 | 2026-09-04 21:44:44+00
  828 | 2026-09-02 10:07:31+00
  479 | 2026-09-02 09:05:47+00
(3 rows)
```

> **In production —** write `NULLS FIRST` or `NULLS LAST` explicitly on every nullable
> sort key. A B-tree index also has a fixed null ordering, and an `ORDER BY` that
> disagrees with it cannot use the index to avoid a sort. Chapter 33 returns to this.

### Ties are not stable, and this is a correctness bug

If your sort key is not unique, tied rows come back in whatever order the sort algorithm
produced. PostgreSQL makes no stability guarantee. Watch two pages of one query:

```sql
SELECT id, loyalty_tier FROM customers ORDER BY loyalty_tier LIMIT 5;
```

```text
 id | loyalty_tier 
----+--------------
 32 | bronze
 17 | bronze
  2 | bronze
 20 | bronze
 36 | bronze
(5 rows)
```

```sql
SELECT id, loyalty_tier FROM customers ORDER BY loyalty_tier LIMIT 5 OFFSET 5;
```

```text
 id | loyalty_tier 
----+--------------
 47 | bronze
  2 | bronze
 17 | bronze
 36 | bronze
 54 | bronze
(5 rows)
```

Customers 2, 17 and 36 appear on **both** pages. Asking for the first ten in one go shows
what the user never saw:

```sql
SELECT id, loyalty_tier FROM customers ORDER BY loyalty_tier LIMIT 10;
```

```text
 id | loyalty_tier 
----+--------------
 45 | bronze
 48 | bronze
 20 | bronze
 38 | bronze
 32 | bronze
 47 | bronze
  2 | bronze
 17 | bronze
 36 | bronze
 54 | bronze
(10 rows)
```

Customers 45 and 48 are on neither page. Three duplicates and two silently skipped rows,
in the first ten rows of a thousand-row table, from a query anyone would sign off.

Nothing here is random — that output reproduces exactly. A `LIMIT` lets the planner use a
top-N heapsort, which orders only as much as it needs to, so the heap contents depend on
N and the tie order changes with the page size. A plan flipping between a sequential and
an index scan, or a `work_mem` change forcing an external merge sort, does the same. None
of it requires touching the query.

The fix is one clause:

```sql
SELECT id, loyalty_tier FROM customers ORDER BY loyalty_tier, id LIMIT 5;
SELECT id, loyalty_tier FROM customers ORDER BY loyalty_tier, id LIMIT 5 OFFSET 5;
```

```text
 id | loyalty_tier 
----+--------------
  2 | bronze
 17 | bronze
 20 | bronze
 32 | bronze
 36 | bronze
(5 rows)

 id | loyalty_tier 
----+--------------
 38 | bronze
 45 | bronze
 47 | bronze
 48 | bronze
 54 | bronze
(5 rows)
```

Disjoint, complete, reproducible.

> **In production —** every `ORDER BY` that feeds pagination must end in a unique
> tiebreaker, normally the primary key. Treat "the last sort key is unique" as a review
> checklist item alongside "does this have an index". The cost is one extra column in a
> sort you were already performing; the alternative is a defect that no test catches,
> because each page is individually correct.

## 6.6 `LIMIT` and `OFFSET`

`LIMIT n` returns at most `n` rows; `OFFSET m` discards the first `m`. Both run last, on
the sorted result. The SQL-standard spelling is `FETCH FIRST n ROWS ONLY`, which
PostgreSQL also accepts; `LIMIT` is shorter and what you will see in every Postgres
codebase.

`LIMIT` without `ORDER BY` means "any five rows". Not the first five — any five. That is
legitimate when you are eyeballing a table's shape, and a bug in anything else.

### `OFFSET` does not scale, and you should know that now

`OFFSET` does not skip work. The rows are still produced, sorted, and thrown away:

```sql
EXPLAIN (ANALYZE, TIMING OFF)
SELECT id, placed_at FROM orders ORDER BY placed_at DESC LIMIT 10 OFFSET 2400;
```

```text
                                            QUERY PLAN                                            
--------------------------------------------------------------------------------------------------
 Limit  (cost=215.10..215.12 rows=10 width=12) (actual rows=10 loops=1)
   ->  Sort  (cost=209.10..215.35 rows=2500 width=12) (actual rows=2410 loops=1)
         Sort Key: placed_at DESC
         Sort Method: quicksort  Memory: 214kB
         ->  Seq Scan on orders  (cost=0.00..68.00 rows=2500 width=12) (actual rows=2500 loops=1)
 Planning Time: 0.018 ms
 Execution Time: 0.259 ms
(7 rows)
```

Ten rows returned; the `Sort` node emitted 2,410, so 2,400 were produced solely to be
discarded. The same query at `OFFSET 0` needs only a bounded top-N heapsort of 25 kB
rather than this full 214 kB quicksort — and the two plan shapes tie-break differently,
which is §6.5's instability arriving through a second door.

At 2,500 rows that is a rounding error. At ten million rows with users clicking "next"
into page four thousand, it is a linear-cost query pretending to be a constant-cost one,
and it usually presents as "the site is fine but some pages time out".

The answer is **keyset pagination** — remember the last row you saw and ask for rows after
it, accepting that you can no longer jump to an arbitrary page. Chapter 36, *Query
Optimization Patterns and Anti-Patterns*, builds and measures it.

## 6.7 `DISTINCT`

`DISTINCT` removes duplicate rows from the output, comparing every selected column.

```sql
SELECT DISTINCT status FROM orders ORDER BY status;
```

```text
  status   
-----------
 cancelled
 delivered
 paid
 pending
 returned
 shipped
(6 rows)
```

It is not free. Deduplication needs either a hash table over the whole result or a sort of
it:

```sql
EXPLAIN (ANALYZE, TIMING OFF) SELECT DISTINCT status FROM orders;
```

```text
                                        QUERY PLAN                                         
-------------------------------------------------------------------------------------------
 HashAggregate  (cost=74.25..74.31 rows=6 width=8) (actual rows=6 loops=1)
   Group Key: status
   Batches: 1  Memory Usage: 24kB
   ->  Seq Scan on orders  (cost=0.00..68.00 rows=2500 width=8) (actual rows=2500 loops=1)
 Planning Time: 0.023 ms
 Execution Time: 0.172 ms
(6 rows)
```

All 2,500 rows are produced and hashed to yield six, and where the hash does not fit in
`work_mem` that becomes a disk spill. Fine when deduplication is the requirement — in real
codebases, most `DISTINCT`s are not.

> **In production —** when I review a slow query containing `DISTINCT`, my first question
> is never "can we make the dedup faster". It is **"why are there duplicates?"** Usually a
> join multiplied the rows and somebody reached for `DISTINCT` because it made the output
> look right. Removing the symptom removed the evidence and left the bug.

PostgreSQL also offers `DISTINCT ON (expr)`, a non-standard extension that keeps the first
row per distinct value of `expr` according to the `ORDER BY`:

```sql
SELECT DISTINCT ON (category) category, id, name
FROM   products
ORDER  BY category, price DESC, id;
```

```text
 category  | id  |      name      
-----------+-----+----------------
 decor     | 103 | Jaipur Diya
 furniture |  55 | Chola Dhurrie
 kitchen   |  87 | Kaveri Parat
 lighting  |  56 | Deccan Dhurrie
 storage   | 109 | Sundar Diya
(5 rows)
```

The most expensive product in each category — a compact "top row per group" idiom, and
genuinely useful. It is also PostgreSQL-only and does not port; window functions express
the same thing more flexibly, and Chapter 25 weighs them against each other.

## 6.8 `SELECT *`

`SELECT *` is right for exploring a table in `psql` and wrong in application code, views,
and anything under version control. Three specific failures.

**It breaks when the table changes.** Add a column and every `SELECT *` returns it — into
ORMs that map positionally, into `INSERT INTO ... SELECT *` statements that now mismatch
on column count. A view defined with `SELECT *` freezes its column list at creation, so
view and table diverge silently.

**It defeats index-only scans.** The `orders` primary key index contains `id`, so asking
for `id` alone never touches the table:

```sql
EXPLAIN SELECT id FROM orders WHERE id BETWEEN 100 AND 200;
```

```text
                                   QUERY PLAN                                    
---------------------------------------------------------------------------------
 Index Only Scan using orders_pkey on orders  (cost=0.28..6.30 rows=101 width=4)
   Index Cond: ((id >= 100) AND (id <= 200))
(2 rows)
```

Asking for every column, it must:

```sql
EXPLAIN SELECT * FROM orders WHERE id BETWEEN 100 AND 200;
```

```text
                                  QUERY PLAN                                  
------------------------------------------------------------------------------
 Index Scan using orders_pkey on orders  (cost=0.28..11.30 rows=101 width=46)
   Index Cond: ((id >= 100) AND (id <= 200))
(2 rows)
```

`Index Only Scan` became `Index Scan`, cost 6.30 to 11.30 — a heap fetch per matching row.
Chapter 33 covers covering indexes, which you cannot design for if your queries ask for
everything.

**It ships data you do not need.** Compare `width`: 4 bytes per row against 46. Now
imagine one column is a 40 kB JSON document. PostgreSQL keeps oversized values out-of-line
in TOAST storage and reads them only if you select the column, so `SELECT *` turns a cheap
index range scan into a series of TOAST fetches for data that goes straight into a garbage
collector. I have seen that change alone take 400 ms off a page load.

> **In production —** name your columns. An explicit list documents what the application
> depends on: when you want to drop a column, `grep` answers in seconds.

---

## Summary

- SQL is **written** `SELECT · FROM · WHERE · GROUP BY · HAVING · ORDER BY · LIMIT` and
  **evaluated** `FROM → WHERE → GROUP BY → HAVING → SELECT → DISTINCT → ORDER BY → LIMIT`.
  Everything else here follows from that mismatch.
- Aliases are bound in step 5, so `WHERE` and `HAVING` cannot see them and `ORDER BY` can.
  `WHERE` runs before grouping, so it cannot see an aggregate — that is `HAVING`.
- `ORDER BY` can sort by an input column you did not select, unless `DISTINCT` already
  collapsed the rows. A bare alias is a valid sort key; an alias inside an expression is
  not.
- Rows have no order without `ORDER BY`; a result that looks sorted is an accident.
- **A non-unique `ORDER BY` is an incomplete specification.** Ties come back in any order,
  and paginating over them duplicates and skips rows with no error. End every sort key
  list with something unique.
- `NULL` sorts high: `ASC` gives `NULLS LAST`, `DESC` gives `NULLS FIRST`. Write it
  explicitly on any nullable sort key.
- `OFFSET` produces and discards every skipped row, so deep pages get linearly slower.
  Chapter 36 replaces it with keyset pagination.
- `DISTINCT` costs a hash or a sort of the whole result, and usually hides an accidental
  join fan-out. Ask where the duplicates came from.
- `SELECT *` is for `psql`. In code it breaks on schema change, defeats index-only scans,
  and ships TOAST data nobody reads.

**Exercises:** Practice Sessions 6.1–6.3 accompany this chapter and are in the
workbook at the back of the book.

**Next:** Chapter 7 takes the `WHERE` clause apart — the operator set, `BETWEEN`, `IN`,
`LIKE`/`ILIKE`, and the three-valued logic that makes `NULL` the most expensive
misunderstanding in SQL.
