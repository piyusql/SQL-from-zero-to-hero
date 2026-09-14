# Chapter 10 — Subqueries and EXISTS

*Which customers have ever returned an order?*

That sentence has three faithful translations into SQL. One returns 241 rows, one returns
241 rows, and one returns 272. Two of them compile to the identical execution plan, down
to the last cost unit. The third is a different query that happens to look like the same
question.

Chapter 9 gave you joins, which combine rows. This chapter nests one query inside another,
which is a different operation: the inner query answers a question *about* each row rather
than contributing columns to it. The distinction sounds academic until you have shipped
the 272.

The centre of the chapter is the choice between `EXISTS`, `IN` and a join — semantics
first, because semantics decide correctness, then what the planner does with each, because
on 15.10 the three are not interchangeable even where they are equivalent. One of the
pairings differs in cost by a factor of seventy thousand.

Every output below was produced with the setting Chapter 2 put in your `~/.psqlrc`:

```sql
\pset null '(null)'
```

---

## 10.1 Three places a subquery can go

A subquery is a `SELECT` in a position where SQL expects something else. There are three
such positions, and they behave differently enough to be worth naming.

**In an expression** — a *scalar subquery*. It must return exactly one column and at most
one row, and it evaluates to that value:

```sql
SELECT (SELECT max(total_amount) FROM orders)          AS biggest_order,
       (SELECT total_amount FROM orders WHERE id = -1) AS no_such_order;
```

```text
 biggest_order | no_such_order
---------------+---------------
       5982.78 | (null)
(1 row)
```

Zero rows gives NULL — not an error, not zero — and everything Chapter 7 said about NULL
applies from that moment on, so wrap `coalesce()` round any scalar subquery feeding
arithmetic or `||`. More than one row *is* an error, raised at execution time:

```text
ERROR:  more than one row returned by a subquery used as an expression
```

That error is a friend. It fires on real data the first time an assumption about
uniqueness stops holding, which beats the silent alternatives elsewhere in this book.

**In `FROM`** — a *derived table*. It produces a relation, and omitting its alias is an
error: `subquery in FROM must have an alias`.

**In `WHERE`** — a predicate, via `IN`, `ANY`, `ALL`, `EXISTS`, or a comparison against a
scalar subquery.

Cutting across all three is the distinction that actually governs performance.

## 10.2 Correlated and uncorrelated

An **uncorrelated** subquery references nothing from the outer query, so it can be
evaluated once and the result reused. `EXPLAIN` labels it an **InitPlan**:

```sql
EXPLAIN (ANALYZE, TIMING OFF, SUMMARY OFF)
SELECT o.id, o.total_amount, (SELECT avg(total_amount) FROM orders) AS overall_avg
FROM   orders o
WHERE  o.total_amount > (SELECT avg(total_amount) FROM orders);
```

```text
 Seq Scan on orders o  (cost=148.53..222.78 rows=833 width=42) (actual rows=1131 loops=1)
   Filter: (total_amount > $1)
   Rows Removed by Filter: 1369
   InitPlan 1 (returns $0)
     ->  Aggregate  (cost=74.25..74.26 rows=1 width=32) (actual rows=1 loops=1)
           ->  Seq Scan on orders  (cost=0.00..68.00 rows=2500 width=6) (actual rows=2500 loops=1)
   InitPlan 2 (returns $1)
     ->  Aggregate  (cost=74.25..74.26 rows=1 width=32) (actual rows=1 loops=1)
           ->  Seq Scan on orders orders_1  (cost=0.00..68.00 rows=2500 width=6) (actual rows=2500 loops=1)
(9 rows)
```

`loops=1` on both: the average is computed once and substituted as a parameter. Note that
the two *textually identical* subqueries became two separate InitPlans — PostgreSQL 15
does not deduplicate them, so the table is scanned twice. Compute a repeated value once,
in a derived table or a CTE.

A **correlated** subquery references a column of the outer query, so it is a different
query for every outer row. `EXPLAIN` labels it a **SubPlan**, and the number to read is
`loops`. Change that `WHERE` to compare each order against *its own customer's* average —
`o.total_amount > (SELECT avg(x.total_amount) FROM orders x WHERE x.customer_id =
o.customer_id)` — and the plan becomes a `SubPlan` with `loops=2500`: two and a half
thousand sequential scans of `orders` to answer one question about `orders`. The total
cost estimate goes from 222 to 185,824.

Correlation is not automatically bad. A correlated subquery sitting in `WHERE` as `EXISTS`
or `IN` is usually rewritten into a join before planning and the SubPlan never appears —
that is section 10.6. The dangerous position is the one the planner cannot rewrite, and
that position is the select list.

## 10.3 The correlated subquery in the `SELECT` list

This shape turns up in slow-page investigations more than any other written SQL. It is
attractive because it composes: each extra column is an extra parenthesised query, no
`GROUP BY` to maintain, no join to get wrong.

```sql
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF)
SELECT c.id, (SELECT count(*) FROM orders o WHERE o.customer_id = c.id) FROM customers c;
```

```text
 Seq Scan on customers c (actual rows=1000 loops=1)
   Buffers: shared hit=43012
   SubPlan 1
     ->  Aggregate (actual rows=1 loops=1000)
           ->  Seq Scan on orders o (actual rows=2 loops=1000)
                 Filter: (customer_id = c.id)
                 Rows Removed by Filter: 2498
                 Buffers: shared hit=43000
 Execution Time: 49.804 ms
```

The same answer as a join and a `GROUP BY`:

```sql
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF)
SELECT c.id, count(o.id) FROM customers c LEFT JOIN orders o ON o.customer_id = c.id GROUP BY c.id;
```

```text
 HashAggregate (actual rows=1000 loops=1)
   Group Key: c.id
   Buffers: shared hit=55
   ->  Hash Right Join (actual rows=2697 loops=1)
         Hash Cond: (o.customer_id = c.id)
         ->  Seq Scan on orders o (actual rows=2500 loops=1)
         ->  Hash (actual rows=1000 loops=1)
               ->  Seq Scan on customers c (actual rows=1000 loops=1)
 Execution Time: 0.462 ms
```

**43,012 buffers against 55. 49.8 ms against 0.46 ms.** On a thousand customers and two
and a half thousand orders — a dataset that fits in a spreadsheet. The buffer ratio is the
honest figure, since it does not depend on caching or on this laptop: the subquery form
reads 782 times as much data for byte-for-byte the same output. Its work is proportional
to **output rows**, and output rows grow quietly — the query was written against a page
showing twenty customers and is still there when the list reaches a hundred thousand.

> **In production —** this is the N+1 problem written in SQL rather than in an ORM. The
> ORM version issues N+1 round trips; this one issues a single round trip and performs
> N+1 scans inside the server, which hides it from your APM's query count and files it in
> `pg_stat_statements` as one statement with an alarming mean time. The tell is a
> `SubPlan` whose `loops` equals the outer row count. Chapter 36, *Query Optimization
> Patterns and Anti-Patterns*, covers the family.

I do not ban the shape. It is fine when the outer query returns a bounded, small number of
rows — a record page, a `LIMIT 20` list — and the inner query is index-supported. What
makes it a defect is an *unbounded* outer query: if you cannot state the maximum number of
rows the outer query can return, rewrite it as a join.

The rewrite is not free of semantics. The correlated form emits every outer row, including
customers with no orders, so the join must be a `LEFT JOIN`, and the aggregate must be
`count(o.id)` rather than `count(*)`, which reports 1 for a customer with none. Practice
Session 10.1 walks that trap deliberately.

## 10.4 Derived tables

A subquery in `FROM` produces a relation you can join to, filter and aggregate over. Its
usual job is to let you filter on an aggregate, or to compute something in stages:

```sql
SELECT s.city, round(s.avg_order, 2) AS avg_order, s.orders
FROM  (SELECT c.city, avg(o.total_amount) AS avg_order, count(*) AS orders
       FROM   customers c JOIN orders o ON o.customer_id = c.id
       GROUP  BY c.city) s
WHERE  s.orders >= 100
ORDER  BY s.avg_order DESC
LIMIT  5;
```

```text
     city      | avg_order | orders
---------------+-----------+--------
 Bhubaneswar   |   1572.27 |    154
 (null)        |   1516.89 |    307
 Visakhapatnam |   1510.32 |    116
 Hyderabad     |   1501.77 |    136
 Bengaluru     |   1500.92 |    115
(5 rows)
```

`(null)` is a legitimate row: 128 customers have no `city` and `GROUP BY` puts them in one
group. Whether that group belongs in a city report is a business question, and the point
of printing NULLs properly is that you get to ask it.

Everything a derived table does, a `WITH` clause also does, with a name and a flat reading
order instead of inside-out nesting. Which to prefer, what PostgreSQL 12 changed about
inlining, and when `MATERIALIZED` earns its keep are Chapter 12's argument — see
Chapter 12, *CTEs and Recursive Queries*.

A derived table cannot see the outer query's rows. When you need one that can, that is
`LATERAL`, which Chapter 9 covered.

## 10.5 `IN`, `ANY`, `ALL`, and `EXISTS`

`x IN (…)` is exactly `x = ANY (…)` and `x NOT IN (…)` is exactly `x <> ALL (…)` — the
parser produces the same node for each pair, and against a literal list `EXPLAIN` prints
both as `= ANY ('{…}'::text[])`. `ANY` and `ALL` generalise to any comparison operator
and to arrays as well as subqueries; `= ANY($1)` against an array parameter is the form
to use from application code, as Chapter 7 argued.

`ANY` is a disjunction: true if the comparison holds for *at least one* element. `ALL` is
a conjunction: true if it holds for *every* element. So `ALL` inherits the empty set, and
the empty set is where it bites:

```sql
SELECT (SELECT count(*) FROM products p WHERE p.price > ALL (SELECT price FROM products WHERE category = 'storage')) AS gt_all_storage,
       (SELECT count(*) FROM products p WHERE p.price >     (SELECT max(price) FROM products WHERE category = 'storage')) AS gt_max_storage,
       (SELECT count(*) FROM products p WHERE p.price > ALL (SELECT price FROM products WHERE category = 'books'))   AS gt_all_books,
       (SELECT count(*) FROM products p WHERE p.price >     (SELECT max(price) FROM products WHERE category = 'books'))   AS gt_max_books;
```

```text
 gt_all_storage | gt_max_storage | gt_all_books | gt_max_books
----------------+----------------+--------------+--------------
              9 |              9 |          200 |            0
(1 row)
```

There is no `books` category in the catalogue. `> ALL` over an empty set is **true** —
vacuously, every element of nothing satisfies anything — so all 200 products qualify,
while `> (SELECT max(...))` compares against NULL, yields UNKNOWN, and returns none. Both
are correct; they answer different questions. Decide which your business rule means before
a typo in a category name ships a promotion to the entire catalogue. And because `NOT IN`
*is* `<> ALL`, `ALL` carries Chapter 7's NULL hazard in full.

`EXISTS` is a different animal: it returns whether the subquery produced any rows at all
— a two-valued question, so it cannot return UNKNOWN regardless of what is in those rows.
Its select list is not evaluated:

```sql
SELECT EXISTS (SELECT 1/0 FROM orders)             AS any_orders,
       EXISTS (SELECT 1/0 FROM orders WHERE false) AS impossible;
```

```text
 any_orders | impossible
------------+------------
 t          | f
(1 row)
```

A division by zero that never raises: the planner discards the target list before
execution. Write `SELECT 1` by convention, to signal to the reader that the columns are
irrelevant, and never argue about `1` versus `*` in a code review.

## 10.6 `EXISTS` vs `IN` vs `JOIN`

Now the question the chapter exists for. *Which customers have ever returned an order?*

```sql
SELECT (SELECT count(*) FROM customers c WHERE EXISTS (SELECT 1 FROM orders o WHERE o.customer_id = c.id AND o.status = 'returned')) AS exists_form,
       (SELECT count(*) FROM customers c WHERE c.id IN (SELECT customer_id FROM orders WHERE status = 'returned'))                   AS in_form,
       (SELECT count(*) FROM customers c JOIN orders o ON o.customer_id = c.id WHERE o.status = 'returned')                          AS join_form;
```

```text
 exists_form | in_form | join_form
-------------+---------+-----------
         241 |     241 |       272
(1 row)
```

**Semantics first.** `EXISTS` and `IN` are *filters*: each outer row is kept or dropped
once, so the result holds at most one row per customer. A join is a *product*: one row per
matching pair, so a customer with three returns appears three times. 272 is the number of
returned orders, not the number of customers who returned something — Chapter 9's fan-out
in disguise. `SELECT DISTINCT` patches it, costs a sort or a hash, and hides that the
query was answering the wrong question.

That is the whole decision rule, and it is about what you need in the output:

- You need to know **whether** something exists → `EXISTS`.
- You need **columns from the other table** → join.
- You need existence against a **short literal list** → `IN`.

**Then the plans.** Take the first two forms above and run them under
`EXPLAIN (ANALYZE, TIMING OFF, SUMMARY OFF)`. Here is the finding worth carrying out of
this chapter, because it contradicts a great deal of folklore:

```text
 Hash Semi Join  (cost=77.65..108.36 rows=272 width=4) (actual rows=241 loops=1)   -- EXISTS
   Hash Cond: (c.id = o.customer_id)
   ->  Seq Scan on customers c  (cost=0.00..22.00 rows=1000 width=4) (actual rows=1000 loops=1)
   ->  Hash  (cost=74.25..74.25 rows=272 width=4) (actual rows=272 loops=1)
         ->  Seq Scan on orders o  (cost=0.00..74.25 rows=272 width=4) (actual rows=272 loops=1)
               Filter: (status = 'returned'::text)

 Hash Semi Join  (cost=77.65..108.36 rows=272 width=4) (actual rows=241 loops=1)   -- IN
   Hash Cond: (c.id = orders.customer_id)
   ->  Seq Scan on customers c  (cost=0.00..22.00 rows=1000 width=4) (actual rows=1000 loops=1)
   ->  Hash  (cost=74.25..74.25 rows=272 width=4) (actual rows=272 loops=1)
         ->  Seq Scan on orders  (cost=0.00..74.25 rows=272 width=4) (actual rows=272 loops=1)
               Filter: (status = 'returned'::text)
```

Identical, to the cost unit. **In the positive case there is no performance argument
between `EXISTS` and `IN`.** Both are pulled up into a `Semi Join` — a join node that
stops probing the inner side at the first match — before the planner considers a path.
Anyone who tells you `EXISTS` is faster than `IN` on PostgreSQL is repeating advice from a
different database, or from before 2005.

A semi-join is a first-class node, so the planner restrategises it like any other join.
Swap the predicate for `total_amount > 5900`, which only one order meets, and the same
`IN` comes out as a `Nested Loop` over a `HashAggregate` that unique-ifies the tiny side,
probing `customers_pkey` with an `Index Only Scan`. Same query text, opposite strategy,
chosen from statistics. That freedom is what the next section's losers do not get.

So choose on meaning. `EXISTS` is my default for existence questions: it *says* existence,
it is immune to NULL, and it keeps working when the inner query grows a second correlation
condition that `IN` would need a row constructor to express. `IN` is genuinely fine
against a literal list, where it is shorter and clearer. Reach for a join when you want
the other table's columns, and then own the cardinality.

## 10.7 The negative case, where they stop being equivalent

Chapter 7, *Filtering, Operators, and Three-Valued Logic*, has already done most of this
work, and done it properly. It established the trap — `x NOT IN (subquery)` returns zero
rows if the subquery yields a single NULL, because `NOT UNKNOWN` is UNKNOWN — and it
printed the plans: only `NOT EXISTS` becomes a `Hash Anti Join`; `NOT IN` stays a
`Filter: (NOT (hashed SubPlan 1))` even when the inner column is declared `NOT NULL`; and
`LEFT JOIN … IS NULL` builds every matched row and discards it afterwards, because
`IS NULL` is not strict and the planner never folds it into the join. Go back to section
7.5 if any of that is hazy. I am not going to print it a second time.

What section 7.5 showed you was the *shapes*. This section is about the **row estimates**
attached to them, which is the part that decides what happens when one of these sits
underneath another join. Asked which customers have never referred anybody — 783 of them
— the three forms estimate as follows:

| Form | Estimated | Actual |
|------|-----------|--------|
| `NOT IN` | 500 | 783 |
| `NOT EXISTS` | **783** | 783 |
| `LEFT JOIN … IS NULL` | 1 | 783 |

`NOT EXISTS` is exact, because an anti-join is estimated by the same selectivity machinery
as every other join — n_distinct and the MCV lists on both sides — and here that machinery
is right.

The `NOT IN` estimate of 500 is half of 1,000, and it is half of the outer table every
time: point it at a subquery matching a single order and it still says 500. The planner
cannot see inside a `SubPlan`, has no statistics for one, and falls back to a fixed
default for a negated clause. It is not an estimate; it is a shrug.

The `LEFT JOIN` estimate of 1 is the most interesting failure. The planner estimates the
join output correctly, then applies `r.id IS NULL` as an ordinary filter — and
`pg_stats.null_frac` for a `NOT NULL` primary key is `0`. Estimated selectivity zero,
clamped up to the minimum of one row. The statistics are perfectly accurate and the
conclusion is wrong by 783×, because the NULLs being filtered on do not exist in the
table; they are manufactured by the join the filter cannot see through.

An estimate of 1 tells everything above that node it is joining a single row. On a
two-table query that costs nothing; feed it into a third join and you get a nested loop
over the whole table, which is Chapter 35's subject.

### At two million orders

All of that is measured on 2,500 orders, where every form finishes in under a millisecond
and it is easy to file as pedantry. On `retail_lg`, the large variant built in Practice
Session 8.2 — 300,000 customers, 2,000,000 orders, `orders.customer_id` declared
`NOT NULL`, and generated with `random()`, so your row counts will differ from mine by a
few hundred and the ratio below will not:

```sql
EXPLAIN SELECT count(*) FROM customers c WHERE c.id NOT IN (SELECT customer_id FROM orders);
EXPLAIN SELECT count(*) FROM customers c WHERE NOT EXISTS (SELECT 1 FROM orders o WHERE o.customer_id = c.id);
```

```text
 Finalize Aggregate  (cost=4784101841.72..4784101841.73 rows=1 width=8)
   ->  Gather  (cost=4784101841.50..4784101841.71 rows=2 width=8)
         Workers Planned: 2
         ->  Partial Aggregate  (cost=4784100841.50..4784100841.51 rows=1 width=8)
               ->  Parallel Seq Scan on customers c  (cost=0.00..4784100685.25 rows=62500 width=0)
                     Filter: (NOT (SubPlan 1))
                     SubPlan 1
                       ->  Materialize  (cost=0.00..71542.60 rows=2001173 width=4)
                             ->  Seq Scan on orders  (cost=0.00..53718.73 rows=2001173 width=4)

 Finalize Aggregate  (cost=66692.11..66692.12 rows=1 width=8)
   ->  Gather  (cost=66691.90..66692.11 rows=2 width=8)
         Workers Planned: 2
         ->  Partial Aggregate  (cost=65691.90..65691.91 rows=1 width=8)
               ->  Parallel Hash Anti Join  (cost=55726.00..65613.40 rows=31398 width=0)
                     Hash Cond: (c.id = o.customer_id)
                     ->  Parallel Seq Scan on customers c  (cost=0.00..4904.00 rows=125000 width=4)
                     ->  Parallel Hash  (cost=42045.22..42045.22 rows=833822 width=4)
                           ->  Parallel Seq Scan on orders o  (cost=0.00..42045.22 rows=833822 width=4)
```

**4,784,101,842 against 66,692 — a factor of 71,700.** Note what changed in the `NOT IN`
plan: it is not even `hashed SubPlan` any more. Two million values will not fit in the
4 MB `work_mem`, so the hash is gone and what remains is a `Materialize` node re-scanned
once per outer row. Three hundred thousand customers times two million orders.

`NOT EXISTS` answers 45,104 in around 90 ms on the machine this book was written on.
`NOT IN`:

```sql
SET statement_timeout = '60s';
EXPLAIN (ANALYZE, TIMING OFF) SELECT count(*) FROM customers c WHERE c.id NOT IN (SELECT customer_id FROM orders);
```

```text
ERROR:  canceling statement due to statement timeout
```

I had already let that query run for two and a half minutes with no sign of finishing. The
`LEFT JOIN` form does complete, consistently but only modestly slower than `NOT EXISTS` —
about 120 ms against about 90 ms across alternating runs here — having removed 2,000,000
rows by filter, and it still estimates `rows=1` against an actual 45,104. Its problem is
not the clock; it is that estimate.

> **In production —** the failure mode is not that `NOT IN` is slow. It is that `NOT IN`
> is *fast until the subquery outgrows `work_mem`*, and then it is not slow, it is
> stopped. The transition is a cliff, it is triggered by data growth rather than by a
> deploy, and the query that falls off it was last edited eighteen months ago. That is
> the measurement behind Chapter 7's verdict, which stands unchanged.

## 10.8 Row constructors

A parenthesised list of expressions is a *row value*, and it compares as one: element by
element, left to right, using each type's own ordering.

```sql
SELECT (1, 'paid') = (1, 'paid')         AS equal,
       (1, 'paid') <  (1, 'shipped')     AS ordered,
       (1, NULL)   =  (1, NULL)          AS both_null,
       (1, NULL)   IS NULL               AS row_is_null,
       (1, 2) IS DISTINCT FROM (1, NULL) AS distinct_safe;
```

```text
 equal | ordered | both_null | row_is_null | distinct_safe
-------+---------+-----------+-------------+---------------
 t     | t       | (null)    | f           | t
(1 row)
```

Two gotchas in one line. `(1, NULL) = (1, NULL)` is UNKNOWN, exactly as element-wise
comparison implies. And `row IS NULL` is true only when **every** field is NULL, which is
not what `IS NULL` means anywhere else in SQL — `(1, NULL) IS NULL` is false.
`IS DISTINCT FROM` on row values is NULL-safe and works as you would hope.

The everyday use is matching pairs against a subquery, which turns greatest-n-per-group
into one readable predicate:

```sql
SELECT o.id, o.customer_id, o.placed_at, o.total_amount
FROM   orders o
WHERE  (o.customer_id, o.placed_at) IN (SELECT customer_id, max(placed_at) FROM orders GROUP BY customer_id)
ORDER  BY o.customer_id
LIMIT  4;
```

```text
  id  | customer_id |       placed_at        | total_amount
------+-------------+------------------------+--------------
 2462 |           1 | 2025-01-18 13:13:31+00 |      1653.92
 1396 |           2 | 2026-06-07 07:53:58+00 |       348.72
  469 |           3 | 2025-08-11 07:28:28+00 |       700.30
  686 |           4 | 2026-03-27 14:43:43+00 |       217.48
(4 rows)
```

803 rows, one per customer who has ordered — and *all* ties, not one winner per group,
which is usually what you want and occasionally a surprise. Chapter 25's `DISTINCT ON` and
window functions beat this for the specific job. The other use worth knowing now is keyset
pagination, `WHERE (placed_at, id) < ($1, $2)`, where the row comparison is index-friendly
in a way the hand-expanded `OR` chain is not; Chapter 36 measures it against `OFFSET`.

---

## Summary

- A scalar subquery returns NULL for zero rows and **raises** for more than one. The error
  is the good outcome; the NULL is the one that reaches a report.
- **Uncorrelated** subqueries become `InitPlan` and run once — but two identical ones
  become two InitPlans. **Correlated** ones become `SubPlan` and run per row; read
  `loops`.
- A correlated subquery in the **`SELECT` list** costs 43,012 buffers where the equivalent
  join costs 55 — 782× the I/O for identical output. Acceptable only when the outer query
  is bounded and small; see Chapter 36, *Query Optimization Patterns and Anti-Patterns*.
- Derived tables need an alias; derived tables versus CTEs is Chapter 12, *CTEs and
  Recursive Queries*.
- `IN (subquery)` **is** `= ANY (subquery)`; `NOT IN` **is** `<> ALL`. `ALL` over an empty
  set is **true**, where the equivalent `max()` comparison is UNKNOWN. `EXISTS` never
  returns UNKNOWN and its select list is never evaluated.
- **Positive case: `EXISTS` and `IN` compile to the identical `Hash Semi Join`.** There is
  no performance argument between them on PostgreSQL. A join is a different query — one
  row per match, 272 where the filters return 241. Choose by output: existence →
  `EXISTS`; other table's columns → join; short literal list → `IN`.
- **Negative case: only `NOT EXISTS` becomes an anti-join** — the plan shapes are
  Chapter 7's, section 7.5, and this chapter does not repeat them.
- The estimates are the argument this chapter adds: `NOT EXISTS` estimates 783 of 783;
  `NOT IN` estimates half the outer table regardless of the data; `LEFT JOIN … IS NULL`
  estimates 1, because `null_frac` on a `NOT NULL` primary key is 0 and the planner
  cannot see that the join manufactures the NULLs.
- At 2M orders, `NOT IN` costs 4.78 billion against 66,692 for `NOT EXISTS` — the hash
  outgrows `work_mem` and degrades to a re-scanned `Materialize`. It did not finish.
- Row values compare element-wise. `(1, NULL) = (1, NULL)` is UNKNOWN, and `row IS NULL`
  is true only when every field is NULL.

**Exercises:** Practice Sessions 10.1–10.2 accompany this chapter and are in the
workbook at the back of the book.

**Next:** Chapter 11 moves from nesting queries to stacking their results — `UNION`,
`INTERSECT` and `EXCEPT`, why `UNION ALL` should be your default, and what the
deduplication in plain `UNION` actually costs.
