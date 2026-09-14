# Chapter 7 — Filtering, Operators, and Three-Valued Logic

Most bugs announce themselves. A syntax error stops the deploy; a constraint violation
raises.

The bugs in this chapter do not. They run, and return a result set with plausible values
and a row count nobody questions because nobody knows what it should be. Then it goes onto
a dashboard, or — the one I have watched happen — into a campaign that skipped 783
customers because a `NOT IN` quietly evaluated to nothing at all. There was no error.
There is never an error.

The mechanism is that SQL does not have two-valued Boolean logic. It has three values, and
the third is contagious. Chapter 6 gave you `SELECT`, `WHERE` and `ORDER BY`; this chapter
is about what goes *inside* the `WHERE`.

First, one line, which belongs in your `~/.psqlrc` permanently:

```sql
\pset null '(null)'
```

By default `psql` prints NULL exactly as it prints the empty string — two different things
rendered identically, in a chapter about telling them apart. Every output below was
produced with that setting.

---

## 7.1 Operators, and the two that bite

The six comparisons (`=`, `<>`, `<`, `>`, `<=`, `>=`) work on every ordered type; `!=` is
a parser alias for `<>`. Results combine with `NOT`, then `AND`, then `OR`, in that
precedence order — the same as every language you know, and people still get it wrong,
because English reads "paid or shipped and over two thousand" the other way round. On
`retail`, `status = 'paid' OR status = 'shipped' AND total_amount > 2000` matches 399
orders; parenthesised the way it is usually meant, 205. Parenthesise every mixed
`AND`/`OR`, even when the default grouping is what you want — four characters guarantee
that whoever adds a third condition at 2 a.m. cannot silently change the meaning.

### `BETWEEN` is inclusive on both ends

`a BETWEEN x AND y` is `a >= x AND a <= y`. On integers that is usually what you want; on
anything carrying a time component it is a defect, and one of the most common I find in
reporting code:

```sql
SELECT count(*) FILTER (WHERE placed_at BETWEEN '2026-03-01' AND '2026-03-31')        AS between_ver,
       count(*) FILTER (WHERE placed_at >= '2026-03-01' AND placed_at < '2026-04-01') AS halfopen
FROM   orders;
```

```text
 between_ver | halfopen
-------------+----------
          79 |       83
(1 row)
```

Four March orders missing, worth 6,125.63, because `'2026-03-31'` widens to
`2026-03-31 00:00:00+00` — midnight at the *start* of the 31st. The last day is excluded
bar its first instant. Every month-end report written this way under-counts by a day,
every month, and the error is small enough to look like variance.

Casting (`placed_at::date BETWEEN ...`) gives the right answer and disables any B-tree
index on the column; Chapter 36 covers that family. Write date ranges as
`>= start AND < next_start` — half-open intervals compose without gaps or overlaps and
stay index-friendly.

### `IN` and `LIKE`

`x IN (a, b, c)` is defined as `x = a OR x = b OR x = c`. **Remember that definition** —
it is the entire explanation of the `NOT IN` trap in section 7.5. `<> ALL (array)` is its
negation and carries the same NULL hazard. From application code prefer `= ANY($1)`, which
takes one array parameter instead of one placeholder per element and so keeps the
statement text stable for plan caching and `pg_stat_statements`.

`LIKE` matches with two wildcards — `%` for any run of characters, `_` for exactly one —
and `ILIKE` is the case-insensitive PostgreSQL extension. Each has an operator spelling
you will meet in `EXPLAIN` output: `~~`, `!~~`, `~~*`, `!~~*` for `LIKE`, `NOT LIKE`,
`ILIKE`, `NOT ILIKE`. Write the words; read the operators. Escape a literal `%` or `_`
with a backslash, or nominate another character with `ESCAPE`.

> **Trap —** the dangerous case is not your own literals, it is user input concatenated
> into a pattern. A search box wired as `LIKE '%' || :term || '%'` behaves until someone
> types `%`: on `retail`, searching `VIP` matches 117 orders and searching `%` matches all
> 447 that carry any discount code. On a large table that is a sequential scan anyone can
> trigger from a text box, repeatedly. This is *not* SQL injection — parameterisation does
> not help, because the value is already a parameter. Escape the term before
> interpolating, or use `strpos()`, which has no pattern language at all.

Chapter 27 covers `SIMILAR TO`, POSIX regex, index-able prefix search and `pg_trgm`.

---

## 7.2 NULL is not a value

Everything from here follows from one sentence.

**NULL is not a value. It is a marker meaning that no value is present.**

If NULL were a value, `NULL = NULL` would be true the way `7 = 7` is. It is not, and it
should not be. One customer's `city` is NULL because we do not know where they live; so is
another's. Do they live in the same place? *We do not know.* Unknown equals unknown is not
true — it is unknown. NULL is also neither zero nor the empty string; if your application
treats `''` and NULL alike, pick one and enforce it with a `CHECK` (Chapter 15), because a
column holding both is a column nobody can query correctly.

So SQL's Boolean type has three values: **TRUE**, **FALSE** and **UNKNOWN**:

```sql
SELECT coalesce(ta.v::text,'UNKNOWN')            AS a,
       coalesce(tb.v::text,'UNKNOWN')            AS b,
       coalesce((NOT ta.v)::text,'UNKNOWN')      AS "NOT a",
       coalesce((ta.v AND tb.v)::text,'UNKNOWN') AS "a AND b",
       coalesce((ta.v OR  tb.v)::text,'UNKNOWN') AS "a OR b"
FROM       unnest(ARRAY[true,false,null]::boolean[]) AS ta(v)
CROSS JOIN unnest(ARRAY[true,false,null]::boolean[]) AS tb(v)
ORDER  BY (CASE WHEN ta.v THEN 1 WHEN NOT ta.v THEN 2 ELSE 3 END),
          (CASE WHEN tb.v THEN 1 WHEN NOT tb.v THEN 2 ELSE 3 END);
```

```text
    a    |    b    |  NOT a  | a AND b | a OR b
---------+---------+---------+---------+---------
 true    | true    | false   | true    | true
 true    | false   | false   | false   | true
 true    | UNKNOWN | false   | UNKNOWN | true
 false   | true    | true    | false   | true
 false   | false   | true    | false   | false
 false   | UNKNOWN | true    | false   | UNKNOWN
 UNKNOWN | true    | UNKNOWN | UNKNOWN | true
 UNKNOWN | false   | UNKNOWN | false   | UNKNOWN
 UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN
(9 rows)
```

`false AND UNKNOWN` is **false** — FALSE dominates `AND`. `true OR UNKNOWN` is **true** —
TRUE dominates `OR`. Those are the only two places UNKNOWN disappears. And the line to
tattoo somewhere: **`NOT UNKNOWN` is `UNKNOWN`.** Negation does not turn an unknown into a
known, and that is the mechanism behind every remaining bug in this chapter.

### `WHERE` keeps TRUE, and only TRUE

A row survives `WHERE` when its predicate is TRUE; FALSE and UNKNOWN are both discarded,
so in filtering UNKNOWN behaves like FALSE. Combined with `NOT UNKNOWN = UNKNOWN`, a row
can be excluded by a predicate *and* by its negation:

```sql
SELECT count(*)                                            AS total,
       count(*) FILTER (WHERE discount_code =  'DIWALI25') AS is_diwali,
       count(*) FILTER (WHERE discount_code <> 'DIWALI25') AS not_diwali
FROM   orders;
```

```text
 total | is_diwali | not_diwali
-------+-----------+------------
  2500 |       121 |        326
(1 row)
```

121 + 326 = 447. Two thousand and fifty-three orders answered *neither* question — those
with no discount code, for which both comparisons are UNKNOWN. Asked "how many orders did
not use the Diwali promotion?", the honest answer is 2,379; the query says 326.

> **Trap —** the law of the excluded middle does not hold in SQL. `WHERE p` and
> `WHERE NOT p` do not partition your table. Split data into two buckets with a predicate
> and its negation, with any nullable column involved, and rows fall down the gap. This is
> the most common reason reconciliation reports come out short.

### `CHECK` constraints keep everything except FALSE

Here is the asymmetry that catches people the moment after they learn that rule. A `CHECK`
is satisfied when its expression is TRUE **or UNKNOWN** — only FALSE is a violation. So
the same expression means opposite things in the two places you write it. In a scratch
database (`createdb ch07_scratch`):

```sql
CREATE TABLE shipments (
    id       int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    weight_g int CHECK (weight_g > 0)
);

INSERT INTO shipments (weight_g) VALUES (500);
INSERT INTO shipments (weight_g) VALUES (NULL);
INSERT INTO shipments (weight_g) VALUES (-1);
```

```text
INSERT 0 1
INSERT 0 1
ERROR:  new row for relation "shipments" violates check constraint "shipments_weight_g_check"
DETAIL:  Failing row contains (3, -1).
```

The negative weight was rejected; the NULL was accepted, because `NULL > 0` is UNKNOWN and
UNKNOWN passes. The identical expression in a `WHERE` clause rejects it:

```sql
SELECT count(*) AS stored, count(*) FILTER (WHERE weight_g > 0) AS pass_where FROM shipments;
```

```text
 stored | pass_where
--------+------------
      2 |          1
(1 row)
```

The constraint says the data is valid; the query says half of it is not.

> **In production —** `CHECK (weight_g > 0)` does not mean "every shipment has a positive
> weight". It means "no shipment has a *non-positive* weight, and some may have none at
> all". If you meant the first, write `weight_g int NOT NULL CHECK (weight_g > 0)`. I have
> reviewed many schemas where the `CHECK` was careful and the `NOT NULL` was forgotten,
> and the table filled with NULLs that every constraint cheerfully permitted.

## 7.3 Testing for NULL

`IS NULL` and `IS NOT NULL` always return TRUE or FALSE, never UNKNOWN — they are
predicates about the *presence* of a value rather than comparisons between values, which
is how they escape three-valued logic. On `orders`, `shipped_at IS NULL` gives 767 and
`IS NOT NULL` gives 1,733, summing to 2,500: the only pair in this chapter that reliably
partitions a table. The boolean family — `IS TRUE`, `IS NOT TRUE`, `IS FALSE`,
`IS NOT FALSE` — behaves the same way, and `IS NOT TRUE` beats
`coalesce(flag, false) = false` for "false or missing".

### `IS DISTINCT FROM` — the NULL-safe comparison

`IS DISTINCT FROM` is `<>` with NULL treated as an ordinary comparable value, and
`IS NOT DISTINCT FROM` is `=` with the same treatment. Two NULLs are *not distinct*; a
value and a NULL *are*. Both always return TRUE or FALSE — exactly the intuition people
wrongly expect from `=` and `<>`, under another name:

```sql
SELECT count(*) FILTER (WHERE discount_code IS DISTINCT FROM 'DIWALI25') AS not_diwali_safe
FROM   orders;
```

```text
 not_diwali_safe
-----------------
            2379
(1 row)
```

121 + 2,379 = 2,500. The table is partitioned again.

> **In production —** neither operator is indexable. Against a `coupons` table of 500,000
> rows, 25 per code value, a tenth of them NULL, with a B-tree on `code`:
>
> ```text
>  Aggregate (actual rows=1 loops=1)                          -- IS NOT DISTINCT FROM 'code-77'
>    Buffers: shared hit=2648
>    ->  Seq Scan on coupons (actual rows=25 loops=1)
>          Filter: (NOT (code IS DISTINCT FROM 'code-77'::text))
>          Rows Removed by Filter: 499975
>          Buffers: shared hit=2648
>
>  Aggregate (actual rows=1 loops=1)                          -- = 'code-77' OR (both NULL)
>    Buffers: shared hit=25 read=3
>    ->  Bitmap Heap Scan on coupons (actual rows=25 loops=1)
>          Recheck Cond: (code = 'code-77'::text)
>          ->  Bitmap Index Scan on coupons_code_idx (actual rows=25 loops=1)
>                Index Cond: (code = 'code-77'::text)
> ```
>
> Half a million rows read to return 25, against 28 buffers for
> `code = 'code-77' OR (code IS NULL AND 'code-77' IS NULL)`. Use `IS DISTINCT FROM`
> freely in reports and ad-hoc work; on a hot OLTP path with a selective index, write the
> longer form with a comment — or make the column `NOT NULL` and delete the problem.

## 7.4 `COALESCE`, `NULLIF`, `GREATEST`, `LEAST`, and `||`

```sql
SELECT coalesce(NULL, NULL, 'fallback') AS coalesce,
       nullif('x','x')                  AS nullif_hit,
       greatest(1, NULL, 3)             AS greatest,
       least(1, NULL, 3)                AS least,
       'total: ' || NULL                AS concat_op,
       concat_ws('-', 'a', NULL, 'c')   AS concat_ws;
```

```text
 coalesce | nullif_hit | greatest | least | concat_op | concat_ws
----------+------------+----------+-------+-----------+-----------
 fallback | (null)     |        3 |     1 | (null)    | a-c
(1 row)
```

**`COALESCE`** returns the first non-NULL argument and **short-circuits**: `coalesce(1,
1/0)` returns 1 while `coalesce(NULL::int, 1/0)` raises. An expensive subquery placed
second only runs when the first argument is NULL, and you can lean on that.

**`NULLIF(a, b)`** returns NULL when `a = b`, otherwise `a`. Its two everyday uses are
cleaning imports (`nullif(trim(city), '')`) and dodging division by zero
(`total / nullif(count, 0)`, which yields NULL rather than raising).

**`GREATEST` and `LEAST` skip NULLs**; only an all-NULL argument list gives NULL.

> **Trap —** the rule across the language is that aggregate-shaped things skip NULLs and
> operators propagate them. `GREATEST`/`LEAST` are written like operators and behave like
> `max()`/`min()`. They are not in the SQL standard at all — PostgreSQL's own documentation
> calls them a common extension — so there is no standard behaviour to appeal to, and
> vendors disagree: Oracle returns NULL if any argument is NULL. Check every call when
> porting.

**`||` propagates**, as `concat_op` shows: one NULL fragment annihilates the whole string,
including the parts that were fine. On `retail`, building
`'order ' || id || ' / ' || discount_code` yields NULL for 2,053 of 2,500 orders — the
order number destroyed along with the missing code. `concat()`
treats NULL as empty instead; `concat_ws()` treats it as absent, dropping the element
*and* the separator that would have preceded it, which is why it beats manual `||` for
anything assembled from optional pieces.

Three behaviours to file alongside these. **Every aggregate except `count(*)` ignores NULL
inputs** — over `{1, NULL, 3}`, `avg` is 2, not 1.33, because the NULL left the divisor
rather than becoming a zero; the gap between `count(*)` and `count(col)` is your NULL
count, and the cheapest data-quality check there is. **`GROUP BY`, `DISTINCT` and the set
operations treat NULLs as equal**, so the 392 `customers` with no `loyalty_tier` form one
group rather than 392 — the standard's notion there is "not distinct" rather than "equal",
which is what PostgreSQL 15 exposes to unique constraints in section 7.6. And **NULLs sort
high**, so `ASC` puts them last and `DESC` first: every `ORDER BY ... DESC LIMIT n` on a
nullable column needs `NULLS LAST`, or "the three most recently shipped orders" returns
three that never shipped, which is the number-one source of wrong "latest N" dashboards.

---

## 7.5 The `NOT IN` trap

This is the most valuable section in the chapter.

`customers.referred_by` is a nullable self-reference: who referred this customer, if
anyone. *Which customers have never referred anybody?* Here is the query almost everyone
writes first, and the same question asked with `NOT EXISTS`:

```sql
SELECT count(*) FROM customers c WHERE c.id NOT IN (SELECT referred_by FROM customers);

SELECT count(*) FROM customers c
WHERE  NOT EXISTS (SELECT 1 FROM customers x WHERE x.referred_by = c.id);
```

```text
 count
-------
     0
(1 row)

 count
-------
   783
(1 row)
```

Zero against 783. Same question, same data, same server, no error and no warning — and
zero is a number, and numbers go into reports.

### Why

Expand `NOT IN` using the definition from section 7.1: `c.id NOT IN (v1, …, vn)` is
`NOT (c.id = v1 OR … OR c.id = vn)`, which is `c.id <> v1 AND … AND c.id <> vn`.

The subquery returns 1,000 rows, of which **726 are NULL**, so the chain contains 726
terms of the form `c.id <> NULL`, each UNKNOWN. Apply the `AND` column of the truth table:

- If `c.id` matches one of the 274 real values, a term is FALSE, FALSE dominates `AND`,
  the expression is FALSE. Row excluded — correctly.
- If it matches none, the real terms are TRUE and the NULL terms UNKNOWN.
  `TRUE AND UNKNOWN` is UNKNOWN, and `WHERE` keeps only TRUE. **Row excluded.**

Every row goes one way or the other, so the result is empty *by construction* — it does
not depend on the data beyond the presence of one NULL. Watch it directly:

```sql
SELECT 999999 NOT IN (SELECT referred_by FROM customers) AS definitely_not_referred;
```

```text
 definitely_not_referred
-------------------------
 (null)
(1 row)
```

Customer 999999 does not exist, and the database still will not say `true` — it cannot
rule out that one of those 726 unknown referrers was 999999. This is the SQL standard, not
a PostgreSQL quirk.

> **Trap —** `x NOT IN (subquery)` returns **zero rows** whenever the subquery yields even
> one NULL, whatever `x` is. One NULL in a million-row subquery is enough, and the failure
> is total and silent. Plain `IN` is fine — it needs only one TRUE, and TRUE dominates
> `OR`. It is specifically the negation that breaks, because `NOT UNKNOWN` is UNKNOWN.

### How to diagnose it

When a `NOT IN` returns suspiciously few rows, check the subquery's output column for
NULLs. That is the whole diagnosis:

```sql
SELECT count(*)                      AS subquery_rows,
       count(referred_by)            AS non_null,
       count(*) - count(referred_by) AS nulls,
       bool_or(referred_by IS NULL)  AS has_null
FROM   customers;
```

```text
 subquery_rows | non_null | nulls | has_null
---------------+----------+-------+----------
          1000 |      274 |   726 | t
(1 row)
```

`has_null` is `t`; the `NOT IN` cannot return anything. Make this a reflex — whenever you
see `NOT IN (SELECT ...)` in review, ask whether that column is `NOT NULL`. If the answer
is "I think so", the answer is no.

### Three fixes, and which I reach for

```sql
-- 1. NOT EXISTS
SELECT count(*) FROM customers c
WHERE  NOT EXISTS (SELECT 1 FROM customers x WHERE x.referred_by = c.id);

-- 2. filter the NULLs out of the subquery
SELECT count(*) FROM customers c
WHERE  c.id NOT IN (SELECT referred_by FROM customers WHERE referred_by IS NOT NULL);

-- 3. LEFT JOIN anti-join
SELECT count(*) FROM customers c
LEFT   JOIN customers r ON r.referred_by = c.id
WHERE  r.id IS NULL;
```

All three return 783. **`NOT EXISTS`, essentially always**, for three reasons in this
order.

**Correctness.** `EXISTS` asks whether the subquery produced any rows — a two-valued
question, so UNKNOWN never enters. It is NULL-safe by construction rather than by
remembering. Fix 2 breaks the moment someone copies it and drops the `IS NOT NULL`. Fix 3
is correct only because `r.id` is a primary key; point it at a nullable column and you
have a fresh invisible bug.

**Readability.** "There is no such row" is the sentence you were asked to implement.
`LEFT JOIN ... WHERE pk IS NULL` makes the reader reconstruct outer-join semantics first.

**Plans.** Only `NOT EXISTS` becomes a genuine join node:

```text
 Aggregate (actual rows=1 loops=1)                          -- NOT IN
   ->  Seq Scan on customers c (actual rows=0 loops=1)
         Filter: (NOT (hashed SubPlan 1))
         Rows Removed by Filter: 1000
         SubPlan 1
           ->  Seq Scan on customers (actual rows=1000 loops=1)

 Aggregate (actual rows=1 loops=1)                          -- NOT EXISTS
   ->  Hash Anti Join (actual rows=783 loops=1)
         Hash Cond: (c.id = x.referred_by)
         ->  Seq Scan on customers c (actual rows=1000 loops=1)
         ->  Hash (actual rows=274 loops=1)
               ->  Seq Scan on customers x (actual rows=1000 loops=1)
```

A `Hash Anti Join` stops probing at the first match, and the planner can cost it, reorder
it and pick a strategy for it like any other join. `Filter: (NOT (hashed SubPlan 1))` is
not a join at all — it is a hash table consulted per row, and it must fit in `work_mem`.
Both `NOT IN` forms get the latter; the `LEFT JOIN` form gets a `Hash Right Join` plus a
post-join filter, because PostgreSQL 15 does not fold `WHERE pk IS NULL` into the join.

> **In production —** three findings on 15.10 that are hard to find written down.
>
> `NOT IN (subquery)` is **not** converted to an anti-join even when the subquery column
> is declared `NOT NULL`. I expected the planner to use the declaration; it does not. That
> matters because the hashed form needs the subquery to fit in `work_mem`, and when it
> does not the plan drops to a `SubPlan` with a `Materialize` re-scanned per outer row —
> O(n × m). I have watched that turn a four-second query into one that never finished.
>
> `LEFT JOIN ... IS NULL` is **not** recognised as an anti-join either. It builds every
> matched row and then discards it.
>
> And the one that matters most: the planner's **row estimate** for the `LEFT JOIN` form
> is 1 where the true answer is 783, while `NOT EXISTS` estimates 783 exactly. A 783×
> misestimate on a small table is harmless; the same misestimate feeding a join higher up
> a real query tree is how you get a nested loop over millions of rows. The anti-join is
> not merely tidier — it is the shape the planner *understands*, and Chapter 35 is about
> what happens when it is not.
>
> There is no case where `NOT IN (subquery)` is the best available tool. Use it on short
> literal lists if you like; against a subquery, write `NOT EXISTS`.

Chapter 10 revisits the `EXISTS` / `IN` / `JOIN` triangle in full.

## 7.6 NULL and `UNIQUE` constraints

A `UNIQUE` constraint permits any number of NULLs, since two NULLs are not equal and so
not duplicates. Back in the scratch database:

```sql
CREATE TABLE integrations (id int GENERATED ALWAYS AS IDENTITY, external_id text UNIQUE);
INSERT INTO integrations (external_id) VALUES ('CRM-9001'), (NULL), (NULL), (NULL);
```

```text
INSERT 0 4
```

Four rows, no complaint. The same holds per row for multi-column constraints:
`('x', NULL)` twice is permitted.

Sometimes that is right — "not yet linked" is a legitimate state for many rows. Often it
is not: you wanted at most one unlinked row, or NULL is a sentinel for "the default
variant" and there must be exactly one.

> **Version note —** `NULLS NOT DISTINCT` on `UNIQUE` constraints and unique indexes
> arrived in **PostgreSQL 15**, this book's stated minimum. On 14 and earlier, emulate it
> with a partial unique index or a generated non-null surrogate column.

```sql
CREATE TABLE integrations_v2 (id int GENERATED ALWAYS AS IDENTITY, external_id text,
                              UNIQUE NULLS NOT DISTINCT (external_id));
INSERT INTO integrations_v2 (external_id) VALUES ('CRM-9001'), (NULL);
INSERT INTO integrations_v2 (external_id) VALUES (NULL);
```

```text
INSERT 0 2
ERROR:  duplicate key value violates unique constraint "integrations_v2_external_id_key"
DETAIL:  Key (external_id)=(null) already exists.
```

The second NULL is rejected. The same clause works on a bare index
(`CREATE UNIQUE INDEX ... ON t (col) NULLS NOT DISTINCT`), and
`pg_index.indnullsnotdistinct` reports which behaviour an existing index has.

> **In production —** `NULLS NOT DISTINCT` is right when NULL means "the one unspecified
> variant": a single default price row per product, one unlinked record per external
> system. It is wrong when NULL means "unknown, and there could be many" — customers whose
> tax ID we have not collected. Ask which of those two your NULL means; if you cannot
> answer, the column needs restructuring rather than a constraint.

That is the last of the scratch work: `dropdb ch07_scratch`.

## 7.7 What I actually do

The techniques above are how you survive NULLs. The way to stop needing most of them is a
schema decision: **default every column to `NOT NULL` and require a justification to
remove it.** Nullable should be a deliberate statement that absence is a meaningful state
of this attribute — `shipped_at` on an unshipped order genuinely is. "We might not always
have it" is not a justification, it is an unanswered question about the business.

Every `NOT NULL` column is one where `=` works, `<>` partitions, `NOT IN` is safe, `||`
cannot swallow a string, and `CHECK` means what it says. Where a column must be nullable:
use `IS NULL`/`IS DISTINCT FROM` by default, never write `NOT IN` against a subquery, and
whenever you split data into complementary buckets, check that the parts sum to the whole.
That last is the only test that reliably catches this class of bug — unit tests written
against seeded data with no NULLs will pass.

---

## Summary

- Parenthesise every mixed `AND`/`OR`. `NOT` binds tightest, then `AND`, then `OR`, and
  English reads it the other way round.
- `BETWEEN` is inclusive on **both** ends, so on timestamps it silently loses the final
  day. Write date ranges as `>= start AND < next_start`.
- `x IN (a, b, c)` means `x = a OR x = b OR x = c` — everything about `NOT IN` follows.
  Prefer `= ANY($1)` from application code, and escape `%`/`_` in any user-supplied `LIKE`
  fragment, which parameterisation does not do for you.
- **NULL is not a value.** It marks the absence of one, it is neither zero nor the empty
  string, and `NULL = NULL` is UNKNOWN.
- `false AND UNKNOWN` is FALSE and `true OR UNKNOWN` is TRUE; everywhere else UNKNOWN
  propagates, and **`NOT UNKNOWN` is UNKNOWN**.
- `WHERE` keeps only TRUE, so UNKNOWN filters like FALSE — but a `CHECK` rejects only
  FALSE, so UNKNOWN **passes**. If you meant "always positive", write
  `NOT NULL CHECK (x > 0)`.
- `WHERE p` and `WHERE NOT p` do not partition a nullable column; only `IS NULL` /
  `IS NOT NULL` reliably do.
- `IS DISTINCT FROM` and `IS NOT DISTINCT FROM` are the NULL-safe comparisons and always
  return TRUE or FALSE — but they are not indexable, so on a hot path write
  `col = $1 OR (col IS NULL AND $1 IS NULL)` instead.
- `COALESCE` short-circuits, `NULLIF` turns a sentinel back into NULL, `GREATEST`/`LEAST`
  **skip** NULLs, and `||` propagates them and will destroy an entire string. NULLs sort
  high, so `ORDER BY ... DESC LIMIT n` on a nullable column needs `NULLS LAST`.
- **`x NOT IN (subquery)` returns zero rows whenever the subquery yields a single NULL.**
  Diagnose by counting NULLs in the subquery's output column; fix with `NOT EXISTS`, the
  only form PostgreSQL plans as a real anti-join and the only one whose row estimate is
  right.
- `UNIQUE` permits unlimited NULLs. **PostgreSQL 15's `NULLS NOT DISTINCT`** changes that
  where NULL means "the one unspecified variant" rather than "unknown".
- Make columns `NOT NULL` by default. Every one that is removes all of the above from your
  life.

**Exercises:** Practice Sessions 7.1–7.2 accompany this chapter and are in the
workbook at the back of the book.

**Next:** Chapter 8 moves from filtering rows to summarising them — `GROUP BY`, `HAVING`,
and the aggregates, including why `count(*)`, `count(col)` and `count(DISTINCT col)`
answer three different questions at three very different prices.
