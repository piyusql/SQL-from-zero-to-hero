# Chapter 13 — Numeric and Character Types

A column's type is the only part of your schema that every future query is forced to
obey. An index can be added, a constraint relaxed, a query rewritten — but a type decision
reaches into every row on disk, and changing your mind about one is measured in table
rewrites and `ACCESS EXCLUSIVE` locks rather than in code review.

Four decisions carry this chapter: how wide an integer to declare, why money is `numeric`
and never float, whether `n` in `varchar(n)` has any defensible source, and the index-size
ceiling that turns a `text` column into a write failure eighteen months after go-live.

Everything below is measured on PostgreSQL 15.10, against tables the sample datasets do
not contain. Build them in a scratch database, and `DROP DATABASE ch13_scratch`
afterwards:

```sql
CREATE TABLE sz (t text, c2 char(2), c50 char(50),
                 n122 numeric(12,2), f8 double precision, i4 int, i8 bigint);
INSERT INTO sz VALUES ('Rajesh', 'IN', 'Rajesh', 1499.50, 1499.50, 1499, 1499);

CREATE TABLE s_i2 (v smallint);          CREATE TABLE s_i8  (v bigint);
CREATE TABLE s_f8 (v double precision);  CREATE TABLE s_num (v numeric(12,2));
INSERT INTO s_i2  SELECT i % 30000                   FROM generate_series(1,1000000) i;
INSERT INTO s_i8  SELECT i                           FROM generate_series(1,1000000) i;
INSERT INTO s_f8  SELECT round((i*0.07)::numeric, 2) FROM generate_series(1,1000000) i;
INSERT INTO s_num SELECT round((i*0.07)::numeric, 2) FROM generate_series(1,1000000) i;

CREATE TABLE ledger (amt_num numeric(12,2), amt_f8 double precision);
INSERT INTO ledger
SELECT round((99 + (i % 9973) * 0.07)::numeric, 2),
       round((99 + (i % 9973) * 0.07)::numeric, 2)
FROM   generate_series(1, 1000000) i;

CREATE TABLE sku_t (id int GENERATED ALWAYS AS IDENTITY PRIMARY KEY, sku text        NOT NULL);
CREATE TABLE sku_v (id int GENERATED ALWAYS AS IDENTITY PRIMARY KEY, sku varchar(20) NOT NULL);
INSERT INTO sku_t (sku) SELECT 'SKU-' || lpad(i::text, 8, '0') FROM generate_series(1,2000000) i;
INSERT INTO sku_v (sku) SELECT 'SKU-' || lpad(i::text, 8, '0') FROM generate_series(1,2000000) i;

ANALYZE;
```

---

## 13.1 Integers: three sizes, one real decision

| Type | Bytes | Range |
|---|---:|---|
| `smallint` (`int2`) | 2 | −32,768 … 32,767 |
| `integer` (`int4`) | 4 | −2,147,483,648 … 2,147,483,647 |
| `bigint` (`int8`) | 8 | −9,223,372,036,854,775,808 … 9,223,372,036,854,775,807 |

PostgreSQL does not wrap around on overflow. It raises:

```sql
SELECT 2147483647::int + 1 AS next_order_id;
```

```text
ERROR:  integer out of range
```

That is the right behaviour and it is also an outage. The failure lands on `INSERT`, on
the busiest table you own, the moment the sequence behind an `integer` primary key crosses
two billion — and the fix, `ALTER COLUMN id TYPE bigint`, rewrites the table while holding
a lock against every reader. Chapter 4 measured that rewrite; Chapter 20 argues identity
strategy. The type conclusion: **surrogate keys are `bigint` from day one.**

The objection is space, and it is worth testing. Four tables, one column each, a million
rows:

```sql
SELECT pg_size_pretty(pg_relation_size('s_i2'))  AS smallint_col,
       pg_size_pretty(pg_relation_size('s_i8'))  AS bigint_col,
       pg_size_pretty(pg_relation_size('s_f8'))  AS float8_col,
       pg_size_pretty(pg_relation_size('s_num')) AS numeric_col;
```

```text
 smallint_col | bigint_col | float8_col | numeric_col 
--------------+------------+------------+-------------
 35 MB        | 35 MB      | 35 MB      | 41 MB
(1 row)
```

**A `smallint` column and a `bigint` column produced identically sized tables.** Every row
carries a 23-byte header and is padded to an 8-byte boundary, so the six bytes you thought
you saved disappear into the padding. Narrowing a lone column to save space is folklore;
narrowing *several* so they pack into one alignment slot is real, and it is Chapter 23,
*The Column Design Checklist*.

So: `bigint` for anything that counts up forever, `integer` for genuine quantities —
`order_items.quantity`, a retry counter, a page number — and `smallint` only when
deliberately packing a row under Chapter 23's rules.

> **Trap —** `integer * integer` overflows before it widens. `sum()` promotes for you
> (`sum(int)` returns `bigint`); `quantity * amount_in_paise` does not. Any integer
> arithmetic that can grow needs a `bigint` operand written into the expression.

## 13.2 Money is `numeric`. Float is not a near-enough approximation

`real` and `double precision` are IEEE 754 binary floating point. They cannot represent
0.1, 0.2 or 1149.99 exactly, for the same reason base 10 cannot represent one third:

```sql
SELECT (0.1::float8 + 0.2::float8)::text     AS float_sum,
       0.1::float8  + 0.2::float8  = 0.3::float8   AS float_equal,
       0.1::numeric + 0.2::numeric = 0.3::numeric  AS numeric_equal,
       (1149.99::float8 * 3)::text           AS three_at_1149_99;
```

```text
      float_sum      | float_equal | numeric_equal |  three_at_1149_99  
---------------------+-------------+---------------+--------------------
 0.30000000000000004 | f           | t             | 3449.9700000000003
(1 row)
```

Most people file that as a curiosity, because at two decimal places it rounds away. Here
is the version that bites. `ledger` holds a million ordinary two-decimal amounts, stored
twice — `numeric(12,2)` and `double precision`:

```sql
SELECT count(*) AS rows, sum(amt_num) AS exact_total FROM ledger;
```

```text
  rows   | exact_total  
---------+--------------
 1000000 | 447332890.50
(1 row)
```

Now sum the float column three times, changing only how PostgreSQL executes it:

```sql
SET max_parallel_workers_per_gather = 0;
SELECT sum(amt_f8) AS float_total FROM ledger;
```

```text
    float_total     
--------------------
 447332890.49999845
(1 row)
```

```sql
SET max_parallel_workers_per_gather = 4;
SELECT sum(amt_f8) AS float_total FROM ledger;
```

```text
    float_total     
--------------------
 447332890.49999946
(1 row)
```

```sql
SELECT sum(amt_f8) AS float_total FROM (SELECT amt_f8 FROM ledger ORDER BY amt_f8 DESC) s;
```

```text
    float_total     
--------------------
 447332890.49999535
(1 row)
```

Three totals, same data, same column, same SQL semantics. Float addition is not
associative, so the answer depends on the order the planner happens to add in — and the
parallel figure is not stable between runs, because it depends on how the workers divided
the table. The serial and ordered figures reproduce exactly.

Note what is *not* wrong here. The error is under two-millionths of a rupee on 447
million, and `round(float_total, 2)` still gives 447332890.50. The float argument is
usually made with invented examples where the displayed total is visibly wrong, and that
undermines the real case: **the number is not reproducible and not exactly comparable**,
and finance runs on exact comparison.

```sql
SELECT count(*) AS lines,
       count(*) FILTER (WHERE amt_f8 * 3 = (amt_num * 3)::float8) AS float8_exact
FROM   ledger;
```

```text
  lines  | float8_exact 
---------+--------------
 1000000 |       691380
(1 row)
```

Three hundred thousand line totals out of a million are not the value they should be.
Each one displays correctly and fails an equality test — the exact shape of a
reconciliation ticket nobody can close.

Rounding is not a rescue either, because `round()` differs between the two types:

```sql
SELECT round(0.5::float8) AS f_half,       round(0.5::numeric) AS n_half,
       round(2.5::float8) AS f_two_half,   round(2.5::numeric) AS n_two_half,
       round(3.5::float8) AS f_three_half, round(3.5::numeric) AS n_three_half;
```

```text
 f_half | n_half | f_two_half | n_two_half | f_three_half | n_three_half 
--------+--------+------------+------------+--------------+--------------
      0 |      1 |          2 |          3 |            4 |            4
(1 row)
```

`round()` on a float rounds halves to the nearest *even* integer; on `numeric` it rounds
halves away from zero. Half a rupee becomes zero in one type and one in the other, and
nothing in your code says which you asked for.

### `numeric` is not the expensive choice people assume

```sql
SELECT pg_column_size(i4)   AS int4,   pg_column_size(i8)   AS int8,
       pg_column_size(f8)   AS float8, pg_column_size(n122) AS numeric_12_2,
       pg_column_size(t)    AS text,   pg_column_size(c2)   AS char_2,
       pg_column_size(c50)  AS char_50
FROM   sz;
```

```text
 int4 | int8 | float8 | numeric_12_2 | text | char_2 | char_50 
------+------+--------+--------------+------+--------+---------
    4 |    8 |      8 |            7 |    7 |      3 |      51
(1 row)
```

For 1499.50, `numeric(12,2)` occupies **seven bytes against `double precision`'s eight**.
`numeric` is variable-width — roughly two bytes per four decimal digits plus a header — so
ordinary money is cheaper than a float and only long values get expensive. The
million-row table came out 41 MB against 35 MB because its values reach seven significant
digits and cross into a third digit group: a 17% premium that buys exactness.

The genuine cost of `numeric` is CPU, not disk. Its arithmetic is software, not a
hardware instruction.

Summing the million rows with parallelism off, `sum(amt_num)` runs to a median of 37.7 ms
against 29.6 ms for `sum(amt_f8)` — 1.27×, and `numeric` lost all ten runs. Consistent,
but far smaller than folklore suggests.

> **In production —** that CPU gap is the only honest argument for float, and it argues
> for scientific and telemetry data, not for money. A real sensor pipeline at a billion
> rows a day would be `double precision` and would be right to be. Use float where the
> input was an approximation to begin with; use `numeric` where a human will later assert
> that two numbers are equal.

### `numeric(p,s)` or bare `numeric`?

A bare `numeric` accepts any scale. Declaring precision and scale rounds on write and
rejects values that are too large:

```sql
SELECT 1234.567::numeric(10,2) AS constrained, 1234.567::numeric AS unconstrained;
```

```text
 constrained | unconstrained 
-------------+---------------
     1234.57 |      1234.567
(1 row)
```

```sql
SELECT 123456789.00::numeric(10,2);
```

```text
ERROR:  numeric field overflow
DETAIL:  A field with precision 10, scale 2 must round to an absolute value less than 10^8.
```

**Declare the scale on money columns.** The `retail` schema does — `orders.total_amount`
is `numeric(12,2)`, `products.price` is `numeric(10,2)` — and the payoff is that
`SELECT scale(total_amount), count(*) FROM orders GROUP BY 1` returns exactly one row. A
bare `numeric` lets a three-decimal value from a currency conversion settle into the
column, where it rounds differently in every report that touches it. Pick `p` with room:
`numeric(12,2)` tops out just under ten billion, a sane ceiling for a line item and a bad
one for a company-wide total. Widening to `numeric(14,2)` later is a catalog change;
narrowing is a rewrite (Chapter 4).

> **Trap —** PostgreSQL has a `money` type. Do not use it. Its fractional precision and
> output format come from the server's `lc_monetary` setting rather than from the column,
> so on a default `C`-locale cluster `SELECT 1234.56::money` renders as `$1,234.56` —
> measured, on a database holding nothing but Indian data. A currency symbol that is a
> property of the *server configuration* is not a currency symbol. Use `numeric` for the
> amount and a separate `currency text` column.

## 13.3 `text`, `varchar(n)`, `char(n)`

In PostgreSQL, `text` and `varchar` are the *same implementation*. `varchar(n)` is `text`
with a length check bolted on at write time; bare `varchar` is `text` under another name.
`sku_t` and `sku_v` hold identical values in 2,000,000 rows, one `text` and one
`varchar(20)`, and both report a heap of exactly 100 MB.

Scanning them is the same work, exactly: both plans cost `25176.71..25176.72`, and both
scans touch 12,739 buffers. Wall-clock gaps are cache-state artifacts — whichever table is
read second finds more of itself already resident.

`char(n)` is the one to avoid. It blank-pads every value to `n` characters on disk and
then pretends the padding is not there:

```sql
SELECT length('Rajesh'::char(20))             AS char_length,
       length('Rajesh   '::text)              AS text_length,
       'Rajesh'::char(20) = 'Rajesh   '::text AS char_eq_padded_text,
       'Rajesh'::char(20) || 'x'              AS concatenated,
       length('Rajesh'::char(20) || 'x')      AS concat_length;
```

```text
 char_length | text_length | char_eq_padded_text | concatenated | concat_length 
-------------+-------------+---------------------+--------------+---------------
           6 |           9 | f                   | Rajeshx      |             7
(1 row)
```

Read that row slowly. `length()` says 6 for a value stored as 20 characters. Concatenation
drops the padding, so `char(20) || 'x'` is seven characters, not twenty-one. And a
`char(20)` holding `'Rajesh'` compares **unequal** to the `text` value `'Rajesh   '`,
because casting `char` to `text` strips trailing blanks — so whether two values match
depends on which side got cast. That filter passes review and drops rows in production
after somebody changes a column type.

It also costs more: 51 bytes for `char(50)` holding `'Rajesh'` against 7 for `text`. Only
a genuinely fixed-width code breaks even — `char(2)` holding an ISO country code came out
at 3 bytes, the same as `text` — and it brings those comparison semantics along free.
`customers.country` is `text` for that reason.

**Use `text`. Always.** No new schema needs `char(n)`; `varchar(n)` needs the argument in
the next section.

> **Trap —** `n` in `varchar(n)` counts **characters**, not bytes.
>
> ```sql
> SELECT length(repeat(chr(2325), 10))       AS characters,
>        octet_length(repeat(chr(2325), 10)) AS bytes;
> ```
>
> ```text
>  characters | bytes 
> ------------+-------
>          10 |    30
> (1 row)
> ```
>
> Ten Devanagari characters are thirty bytes in UTF-8. A `varchar(10)` column accepts that
> value and rejects `'SKU-1234567'`:
>
> ```text
> ERROR:  value too long for type character varying(10)
> ```
>
> So `n` bounds neither storage nor anything downstream that cares about bytes — including
> the index limit in section 13.5. If you sized `varchar(n)` from a byte budget, you sized
> it wrong.

## 13.4 What is a defensible `n`, and the `text` + `CHECK` pattern

Ask where the number came from. There are only two good answers.

**It came from an external specification.** A GSTIN is 15 characters, a PAN is 10, an IFSC
code is 11, an Aadhaar number is 12 digits, an Indian PIN code is 6, RFC 5321 caps an
email address at 254. Those are facts about the world, and a value that violates one is a
bug you want rejected at the door.

**It is a deliberate abuse ceiling.** `CHECK (length(bio) <= 5000)` is not a claim that
5,000 is meaningful — it refuses to let one row carry a megabyte.

Everything else is a number somebody typed. `varchar(255)` is a MySQL row-format artefact;
`varchar(50)` for a name is a guess. Here is what the guess is worth against real data:

```sql
SELECT 'country' AS col, min(length(country)) AS min_len, max(length(country)) AS max_len FROM customers
UNION ALL SELECT 'city',  min(length(city)),  max(length(city))  FROM customers
UNION ALL SELECT 'email', min(length(email)), max(length(email)) FROM customers
UNION ALL SELECT 'name',  min(length(name)),  max(length(name))  FROM customers;
```

```text
   col   | min_len | max_len 
---------+---------+---------
 country |       2 |       2
 city    |       4 |      13
 email   |      24 |      27
 name    |       9 |      19
(4 rows)
```

Sizing `email` as `varchar(30)` from that sample is the mistake: today's data stops at 27,
and the first customer with a long corporate address gets a 500 error. `varchar(254)` is
defensible because the RFC says so, not because the data does.

### When `n` is a guess, use `text` plus a `CHECK`

```sql
CREATE TABLE products (
    id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sku      text NOT NULL CHECK (length(sku) BETWEEN 4 AND 32),
    name     text NOT NULL CHECK (length(name) <= 200)
);
```

This is not a style preference. It is about the day the rule changes, and the difference
is in the **lock**. Every row below was measured on `sku_t` by reading `pg_locks` inside
the open transaction:

| Operation | Lock mode | Rewrites? |
|---|---|---|
| `ALTER COLUMN sku TYPE varchar(50)` *(from `varchar(20)`)* | `AccessExclusiveLock` | no |
| `ALTER COLUMN sku TYPE varchar(20)` *(from `text`)* | `AccessExclusiveLock`, `ShareLock` | **yes** |
| `ADD CONSTRAINT … CHECK (…)` | `AccessExclusiveLock` | no — but scans |
| `ADD CONSTRAINT … CHECK (…) NOT VALID` | `AccessExclusiveLock` | no |
| `VALIDATE CONSTRAINT …` | `ShareUpdateExclusiveLock` | no |
| `DROP CONSTRAINT …` | `AccessExclusiveLock` | no |

Five of the six take `ACCESS EXCLUSIVE`, which conflicts with everything including plain
`SELECT`; Chapter 4 showed how a blocked `ALTER` then blocks every query queued behind it.
What differs is how long it is *held*. A validated `ADD CONSTRAINT` holds it for a table
scan; narrowing to `varchar(n)` holds it for a rewrite — and does so even when an
equivalent validated `CHECK` already exists, because the type change re-derives everything
from scratch.

One row in that table is different, and it is the whole point:

```sql
BEGIN;
ALTER TABLE sku_t ADD CONSTRAINT sku_len CHECK (length(sku) <= 20) NOT VALID;
COMMIT;
ALTER TABLE sku_t VALIDATE CONSTRAINT sku_len;   -- the long part
```

While that `VALIDATE` runs, a second session reading the table sees:

```text
  pid  |        state        |                     query                      |           mode           | granted 
-------+---------------------+------------------------------------------------+--------------------------+---------
 36735 | idle in transaction | ALTER TABLE sku_t VALIDATE CONSTRAINT sku_len; | ShareUpdateExclusiveLock | t
(1 row)
```

One row — the validating session. A concurrent `SELECT count(*)` and a concurrent `INSERT`
both ran to completion and never appeared in the lock table.

The same observation during a validated `ADD CONSTRAINT`:

```text
  pid  |        state        |                     query                      |        mode         | granted 
-------+---------------------+------------------------------------------------+---------------------+---------
 36675 | idle in transaction | ALTER TABLE sku_t ADD CONSTRAINT sku_len CHECK | AccessExclusiveLock | t
 36685 | active              | SELECT count(*) FROM sku_t;                    | AccessShareLock     | f
(2 rows)
```

`granted | f` on a `SELECT count(*)`. That is your application waiting.

So: **`text` for the column, `CHECK` for the rule, added `NOT VALID` and validated
separately.** Changing your mind later costs two brief exclusive locks and one long weak
one, instead of one long exclusive one. Chapter 15 covers `NOT VALID` and `VALIDATE`
properly; Chapter 52 builds the online-migration pattern; Appendix C tabulates every
`ALTER TABLE` variant's lock mode.

## 13.5 The ceiling nobody tells you about: 2704 bytes

A B-tree index entry must fit, with two siblings, on one 8 kB page. PostgreSQL enforces
that as a hard per-entry limit, at **write time**, on the row that happens to be too big.

A `text` column with an ordinary index, and incompressible test data from MD5 output:

```sql
CREATE FUNCTION noise(n int) RETURNS text LANGUAGE sql IMMUTABLE AS
  $$ SELECT substr(string_agg(md5(g::text), ''), 1, n)
     FROM generate_series(1, n/32 + 1) g $$;

CREATE TABLE notes (
    id   int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    body text NOT NULL
);
CREATE INDEX notes_body_idx ON notes (body);
```

```sql
INSERT INTO notes (body) VALUES (noise(2692));   -- fine
INSERT INTO notes (body) VALUES (noise(2693));
```

```text
ERROR:  index row size 2712 exceeds btree version 4 maximum 2704 for index "notes_body_idx"
DETAIL:  Index row references tuple (0,2) in relation "notes".
HINT:  Values larger than 1/3 of a buffer page cannot be indexed.
Consider a function index of an MD5 hash of the value, or use full text indexing.
```

**2,692 characters of that filler go in; 2,693 do not.** The 2,704 bytes cover the stored
value, its varlena header and 8 bytes of index-tuple header, aligned — which is what takes
2,693 characters to the 2,712 the error reports. A two-column index splits the same
budget: on `(a, b)` over two `text` columns, 1,344 characters each fits and 1,345 fails.

Now the part that makes it a production incident rather than a design-time error:

```sql
INSERT INTO notes (body) VALUES (repeat('a', 5000));
SELECT id, length(body) AS chars, pg_column_size(body) AS stored FROM notes ORDER BY id;
```

```text
 id | chars | stored 
----+-------+--------
  1 |  2692 |   2692
  3 |  5000 |     69
(2 rows)
```

A 5,000-character value inserted without complaint while a 2,693-character one failed.
The limit applies to the **compressed** size, and `repeat('a', 5000)` compresses to 69
bytes. So indexability is not a function of declared length, not of character count, and
not testable with a representative sample — it depends on how well that particular value
compresses. Which is why the first failure arrives months after launch, from one unlucky
customer, on a code path that has worked ten million times.

(The gap in `id` is the failed insert consuming an identity value. Sequences are not
transactional; Chapter 20.)

`varchar(n)` does not save you either. The limit is in bytes and `n` is in characters, so
a `varchar(1000)` column accepts 3,000 bytes of Devanagari; since a UTF-8 character can
run to four bytes, only an `n` of 673 or less *guarantees* the value fits, and nobody
declares `varchar(673)`.

Nor is it only `INSERT`. Let a wide row in while the index is absent, then build the
index, and it fails at build time instead:

```sql
DROP INDEX notes_body_idx;
INSERT INTO notes (body) VALUES (noise(4000));
CREATE INDEX notes_body_idx ON notes (body);
```

```text
ERROR:  index row size 4016 exceeds btree version 4 maximum 2704 for index "notes_body_idx"
DETAIL:  Index row references tuple (0,4) in relation "notes".
HINT:  Values larger than 1/3 of a buffer page cannot be indexed.
Consider a function index of an MD5 hash of the value, or use full text indexing.
```

Which is the better day to find out, and an argument for putting the index in the original
migration rather than adding it later.

### Three fixes, and when each applies

**Fail earlier, with a message a developer can act on.** A `CHECK` on the *uncompressed*
byte length is predictable where the index limit is not, and it names itself:

```sql
CREATE TABLE notes_guarded (
    id   int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    body text NOT NULL CONSTRAINT body_indexable CHECK (octet_length(body) <= 2600)
);
CREATE INDEX ON notes_guarded (body);
INSERT INTO notes_guarded (body) VALUES (noise(4000));
```

```text
ERROR:  new row for relation "notes_guarded" violates check constraint "body_indexable"
DETAIL:  Failing row contains (1, c4ca4238a0b923820dcc509a6f75849bc81e728d9d4c2f636f067f89cc14862c...).
```

**Index a hash instead of the value.** This is what the `HINT` is telling you:

```sql
CREATE INDEX notes_body_md5 ON notes (md5(body));
```

The entry is 32 bytes whatever the value, and `WHERE md5(body) = md5($1)` will use it.
Equality and uniqueness only — no range scans, no `ORDER BY`, no prefix matching — and a
unique index on `md5(body)` constrains the *hash*, which is close enough for a document
store and not close enough for a payments key.

**Use a hash index.** `CREATE INDEX … USING hash (body)` stores only the hash, so it has
no size limit at all, and it has been crash-safe and WAL-logged since PostgreSQL 10.
Equality only, same caveats.

If you wanted to search *inside* those values rather than match them whole, none of the
three is the answer — that is `tsvector` and GIN (Chapter 28, *Full-Text Search*) or
trigrams (Chapter 27). The 2704-byte error usually means you are indexing a document as if
it were a key.

---

## Summary

- `bigint` for anything that counts up forever; `integer` for real quantities; `smallint`
  almost never on its own. **A one-million-row `smallint` table and a `bigint` table were
  both 35 MB** — row overhead and alignment eat the saving. Overflow raises
  `integer out of range`, and the fix rewrites under `ACCESS EXCLUSIVE`.
- **Money is `numeric`, with the scale declared.** Float sums are not reproducible — the
  same column summed serially, in parallel and in sorted order gave three different
  totals — and 308,620 of a million float line totals were not exactly right. `round()`
  breaks halves to even on float and away from zero on `numeric`.
- `numeric` is not the bloated choice: 1499.50 takes 7 bytes against `double precision`'s
  8. Its real cost is CPU. Avoid the `money` type entirely — its precision and symbol come
  from `lc_monetary`, not from the column.
- **`text` and `varchar(n)` are the same implementation** — a 100 MB heap each at two
  million rows. `char(n)` blank-pads, lies about `length()`, loses the padding on
  concatenation, and compares unequal to the same string as `text`. Never use it. And `n`
  counts characters, not bytes: ten Devanagari characters are thirty bytes.
- A defensible `n` comes from an external specification (GSTIN 15, PAN 10, IFSC 11, RFC
  5321's 254) or is a deliberate abuse ceiling. Otherwise use **`text` plus a `CHECK`**:
  narrowing `text` to `varchar(n)` rewrites under `ACCESS EXCLUSIVE`, whereas
  `ADD CONSTRAINT … NOT VALID` then `VALIDATE CONSTRAINT` does the long work under
  `SHARE UPDATE EXCLUSIVE`, which blocks neither readers nor writers.
- **A B-tree entry cannot exceed 2704 bytes** — about 2,692 characters of incompressible
  text in a single-column index, 1,344 per column in a two-column one. It applies to the
  *compressed* value, so a 5,000-character compressible string indexes fine while a
  2,693-character random one fails. Reject oversized values with a `CHECK`, or index
  `md5(col)`, or use a hash index; all three are equality-only. If you needed to search
  inside the text, you wanted full-text search (Chapter 28).

**Exercises:** Practice Sessions 13.1–13.3 accompany this chapter and are in the workbook
at the back of the book.

**Next:** Chapter 14 takes on *Temporal Types* — `timestamptz` as the default, why
PostgreSQL does not store a time zone anywhere, what `AT TIME ZONE` actually does, and
what arithmetic across a DST boundary really returns.
