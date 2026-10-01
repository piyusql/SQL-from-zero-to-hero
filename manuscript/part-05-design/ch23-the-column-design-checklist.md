# Chapter 23 — The Column Design Checklist

Chapter 22 was the checklist for the table: keys, audit columns, deletion, partitioning.
This one is the checklist for each column inside it, and it is deliberately the most
copy-able chapter in the book. The tables in 23.2, 23.4, 23.5 and 23.8 are the source for
Appendix D.

A column is the smallest decision you cannot cheaply take back: a type change may rewrite the table under a lock, an unwanted NULL is in the data before anyone notices, and a personal-data column is in every backup and log line. Everything below runs on the small `retail` data or in a scratch database; `retail` is only read:

```bash
createdb ch23_scratch
pg_dump -t customers retail | psql -q -d ch23_scratch
psql -d ch23_scratch
```

Nothing here is timed: every claim is a row, byte or buffer count, or a catalog value.

## 23.1 The checklist

Each item names the failure it prevents; the sections prove the non-obvious ones.

1. **Pick the type by the operation, not the source** (23.2).
2. **`NOT NULL` unless you can say in one sentence what NULL means**, or every query grows an undocumented `COALESCE` (23.3).
3. **Default a `NOT NULL` column only if the default is true.** A fake default hides a forgotten field (23.4).
4. **Know the cost of the `ALTER` before you ship it**: metadata or rewrite (23.4).
5. **Same-row derivation is a `GENERATED ... STORED` column**; cross-row derivation is a query (23.4).
6. **Constrain every column by its kind**, and name the constraint (23.5).
7. **Blank strings are NULLs in disguise**; reject them (23.5).
8. **Order fixed-width columns widest first, before the first `CREATE TABLE`** (23.6).
9. **Know which columns will exceed 2 kB** and keep them out of queries that do not need them (23.7).
10. **Never index a value that can exceed 2,704 bytes** without hashing it (Chapter 13).
11. **Classify every column the day it is created** (23.8).
12. **Put the unit in the name** when the type cannot carry it: `weight_kg`.

## 23.2 Type selection

| Holds | Use | Not | Why, and where |
|---|---|---|---|
| Surrogate key | `bigint GENERATED ... AS IDENTITY` | `serial`, `integer` | Overflow at 2.1 billion is a rewrite under lock (13, 20) |
| Key made outside the DB | `uuid` | `text` | 16 bytes, not 36+ (16, 20) |
| Money | `numeric(12,2)` | `float8`, `money` | Exact; the CPU gap is small (13) |
| Count, quantity | `integer` | `smallint` unless bounded | Saves 2 bytes, often lost to padding (23.6) |
| Measurement | `double precision` | `numeric` | The input was an approximation already (13) |
| Event time | `timestamptz` | `timestamp`, `timetz` | An instant, not a wall-clock guess (14) |
| Flag | `boolean NOT NULL DEFAULT false` | `char(1)`, `int` | Three states is a status, not a flag |
| Status | `text` + `CHECK`, or lookup table | `enum` unless never removed | `ALTER TYPE` limits (16, 21) |
| Short code (SKU, country) | `text` + `CHECK` | `char(n)` | Padding semantics (13) |
| Free text | `text` | `varchar(255)` | 255 is a MySQL habit, not a requirement (13) |
| Phone | `text` + `CHECK (phone ~ '^\+[1-9][0-9]{7,14}$')` | `bigint` | Leading `+` and zeros are data |
| PIN code | `text` + `CHECK (pin ~ '^[1-9][0-9]{5}$')` | `integer` | Not arithmetic |
| IP or network | `inet` / `cidr` | `text` | Containment operators, validation (16) |
| Validity period | `tstzrange` + exclusion constraint | two columns | Overlap becomes impossible (15, 16) |
| Variable attributes | `jsonb` | JSON in `text` | Only for genuinely open-ended data (17) |
| Files, images | object storage, keep a key and checksum | `bytea` | Lives in TOAST, WAL and every backup (23.7) |

Choose the type whose *operators* match the questions you will ask. A phone number is never added, so it is not a number. Store a currency code beside every amount.

## 23.3 `NOT NULL` by default

NULL is a missing value, and three situations produce it.

| NULL means | Example | Do |
|---|---|---|
| Not applicable | `shipped_at` before shipping | Nullable; comment it |
| Unknown, may be learned | `city` at signup | Nullable |
| A real value nobody wrote down | `loyalty_tier` NULL for "no tier" | `NOT NULL`, store the value |

The third row is the common bug. Audit `customers`:

```sql
\pset null '(null)'
ANALYZE customers;
SELECT a.attnum AS n, a.attname AS column, format_type(a.atttypid, a.atttypmod) AS type,
       CASE WHEN a.attnotnull THEN 'NOT NULL' ELSE 'nullable' END AS nulls,
       coalesce(pg_get_expr(d.adbin, d.adrelid), '') AS default,
       round(s.null_frac::numeric, 3) AS null_frac
FROM pg_attribute a
LEFT JOIN pg_attrdef d ON (d.adrelid, d.adnum) = (a.attrelid, a.attnum)
LEFT JOIN pg_stats s ON (s.schemaname, s.tablename, s.attname) = ('public', 'customers', a.attname)
WHERE a.attrelid = 'customers'::regclass AND a.attnum > 0 AND NOT a.attisdropped
ORDER BY a.attnum;
```

```text
 n |    column    |  type   |  nulls   | default | null_frac 
---+--------------+---------+----------+---------+-----------
 1 | id           | integer | NOT NULL |         |     0.000
 2 | name         | text    | NOT NULL |         |     0.000
 3 | email        | text    | NOT NULL |         |     0.000
 4 | country      | text    | NOT NULL |         |     0.000
 5 | city         | text    | nullable |         |     0.128
 6 | signup_date  | date    | NOT NULL |         |     0.000
 7 | loyalty_tier | text    | nullable |         |     0.392
 8 | referred_by  | integer | nullable |         |     0.726
(8 rows)
```

(`null_frac` is a planner estimate, exact here because `ANALYZE` reads all 1,000 rows; on a large table use `count(*) FILTER (WHERE col IS NULL)`.)

`city` (12.8%) and `referred_by` (72.6%, "not referred") are honest absences: leave them. **`loyalty_tier` at 39.2% is a value never written**: those customers have no tier, and every report needs `COALESCE` or silently drops them. `signup_date` has no default though its meaning is "today". Fix both:

```sql
UPDATE customers SET loyalty_tier = 'none' WHERE loyalty_tier IS NULL;
ALTER TABLE customers
    ADD CONSTRAINT customers_tier_known CHECK (loyalty_tier IN ('none','bronze','silver','gold')),
    ALTER COLUMN loyalty_tier SET DEFAULT 'none',
    ALTER COLUMN loyalty_tier SET NOT NULL,
    ALTER COLUMN signup_date  SET DEFAULT current_date;
```

```text
UPDATE 392
ALTER TABLE
```

**On disk, NULL costs almost nothing, and that is not the argument.** A NULL takes no data bytes; a bitmap exists only in rows containing one, and is free up to eight columns (it fits the header's padding). Nine is where that ends:

```sql
CREATE EXTENSION pageinspect;
CREATE TABLE n8 (c1 int,c2 int,c3 int,c4 int,c5 int,c6 int,c7 int,c8 int);
CREATE TABLE n9 (c1 int,c2 int,c3 int,c4 int,c5 int,c6 int,c7 int,c8 int,c9 int);
INSERT INTO n8 VALUES (1,2,3,4,5,6,7,8), (1,2,3,4,5,6,7,NULL);
INSERT INTO n9 VALUES (1,2,3,4,5,6,7,8,9), (1,2,3,4,5,6,7,8,NULL);
SELECT 'n8' AS tbl, lp, lp_len, t_hoff, t_bits IS NOT NULL AS has_null_bitmap
FROM heap_page_items(get_raw_page('n8',0))
UNION ALL
SELECT 'n9', lp, lp_len, t_hoff, t_bits IS NOT NULL
FROM heap_page_items(get_raw_page('n9',0)) ORDER BY 1,2;
```

```text
 tbl | lp | lp_len | t_hoff | has_null_bitmap
-----+----+--------+--------+-----------------
 n8  |  1 |     56 |     24 | f
 n8  |  2 |     52 |     24 | t
 n9  |  1 |     60 |     24 | f
 n9  |  2 |     64 |     32 | t
(4 rows)
```

The header grew from 24 to 32 bytes and the row with the NULL is *larger* (64 against 60), but rows round up to 8, so both occupy 64 on the page: a wash. Nobody should choose nullability for storage. The cost of NULL is the `COALESCE`, the `NOT IN` that returns nothing, and the count that disagrees with the other count (Chapter 15).

**Adding `NOT NULL` later.** A 200,000-row table, used here and in 23.4; `c1` and `c2` are populated but nullable:

```sql
CREATE TABLE ev (
    id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    kind    varchar(20) NOT NULL,
    amount  numeric(10,2) NOT NULL,
    qty     int NOT NULL,
    seen_at timestamp NOT NULL,
    seen_utc timestamp NOT NULL,
    note    text,
    c1 int, c2 int
);
INSERT INTO ev (kind, amount, qty, seen_at, seen_utc, note, c1, c2)
SELECT 'k'||g%10, g/100.0, g, timestamp '2026-01-01' + g * interval '1 minute',
       timestamp '2026-01-01' + g * interval '1 minute', 'n', 1, 1
FROM generate_series(1, 200000) g;

SET client_min_messages = debug1;
ALTER TABLE ev ALTER COLUMN c1 SET NOT NULL;
ALTER TABLE ev ADD CONSTRAINT c2_present CHECK (c2 IS NOT NULL) NOT VALID;
ALTER TABLE ev VALIDATE CONSTRAINT c2_present;
ALTER TABLE ev ALTER COLUMN c2 SET NOT NULL;
RESET client_min_messages;
```

```text
DEBUG:  verifying table "ev"
ALTER TABLE
ALTER TABLE
DEBUG:  verifying table "ev"
ALTER TABLE
DEBUG:  existing constraints on column "ev.c2" are sufficient to prove that it does not contain nulls
ALTER TABLE
```

`SET NOT NULL` scans the whole table under `ACCESS EXCLUSIVE` ("verifying table"). With a validated `CHECK (col IS NOT NULL)` already present, PostgreSQL proves it from the constraint and skips the scan: the `NOT VALID`-then-`VALIDATE` route of Chapter 15 turns a table-sized lock into a catalog-sized one.

## 23.4 Defaults, generated columns, and what each `ALTER` costs

Since PostgreSQL 11 a *constant* `ADD COLUMN ... DEFAULT` is stored in the catalog and applied when old rows are read; a *volatile* one still rewrites the table. The constant is visible:

```sql
ALTER TABLE ev ADD COLUMN region text NOT NULL DEFAULT 'IN';
SELECT attname, atthasmissing, attmissingval
FROM pg_attribute WHERE attrelid = 'ev'::regclass AND attname = 'region';
```

A rewrite is provable: the table's file (`relfilenode`) changes. This helper reports it:

```sql
SET TIME ZONE 'Asia/Kolkata';
CREATE FUNCTION rewrote(stmt text) RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE before oid; after oid;
BEGIN
  SELECT relfilenode INTO before FROM pg_class WHERE oid = 'ev'::regclass;
  EXECUTE stmt;
  SELECT relfilenode INTO after  FROM pg_class WHERE oid = 'ev'::regclass;
  RETURN before <> after;
END $$;

ALTER TABLE ev ADD COLUMN channel text NOT NULL;
SELECT op, rewrote('ALTER TABLE ev ' || op) AS rewrote FROM (VALUES
 ('ADD COLUMN currency text NOT NULL DEFAULT ''INR'''),
 ('ADD COLUMN added_at timestamptz NOT NULL DEFAULT now()'),
 ('ADD COLUMN token float8 NOT NULL DEFAULT random()'),
 ('ALTER COLUMN note SET NOT NULL'),
 ('ALTER COLUMN kind TYPE varchar(40)'),
 ('ALTER COLUMN kind TYPE text'),
 ('ALTER COLUMN amount TYPE numeric(12,2)'),
 ('ALTER COLUMN amount TYPE numeric(12,3)'),
 ('ALTER COLUMN qty TYPE bigint'),
 ('ALTER COLUMN seen_at TYPE timestamptz'),
 ('ADD COLUMN line_total numeric GENERATED ALWAYS AS (qty * amount) STORED')
) v(op);
```

```text
ERROR:  column "channel" of relation "ev" contains null values
                                   op                                    | rewrote 
-------------------------------------------------------------------------+---------
 ADD COLUMN currency text NOT NULL DEFAULT 'INR'                         | f
 ADD COLUMN added_at timestamptz NOT NULL DEFAULT now()                  | f
 ADD COLUMN token float8 NOT NULL DEFAULT random()                       | t
 ALTER COLUMN note SET NOT NULL                                          | f
 ALTER COLUMN kind TYPE varchar(40)                                      | f
 ALTER COLUMN kind TYPE text                                             | f
 ALTER COLUMN amount TYPE numeric(12,2)                                  | f
 ALTER COLUMN amount TYPE numeric(12,3)                                  | t
 ALTER COLUMN qty TYPE bigint                                            | t
 ALTER COLUMN seen_at TYPE timestamptz                                   | t
 ADD COLUMN line_total numeric GENERATED ALWAYS AS (qty * amount) STORED | t
(11 rows)
```

That is the table to keep. What it corrects:

- **`DEFAULT now()` did not rewrite**: `now()` is *stable* (fixed for the statement), so it is evaluated once and stored. `random()` and `clock_timestamp()` are volatile. Judge by volatility class:

```sql
SELECT proname, provolatile FROM pg_proc
WHERE proname IN ('now','random','clock_timestamp') ORDER BY 1;
```

```text
     proname     | provolatile
-----------------+-------------
 clock_timestamp | v
 now             | s
 random          | v
(3 rows)
```

Volatility `s` is stable, `v` volatile.

- **Widening a `numeric` is free only if the scale is unchanged**: `(10,2)` to `(12,2)` did not rewrite, `(12,2)` to `(12,3)` did. `varchar(n)` to a wider `varchar` or `text` is free (Chapter 13 covered the reverse).
- **`timestamp` to `timestamptz` rewrote because the session zone is `Asia/Kolkata`**; the conversion depends on the zone:

```sql
SET TIME ZONE 'UTC';
SELECT rewrote('ALTER TABLE ev ALTER COLUMN seen_utc TYPE timestamptz') AS rewrote;
```

```text
 rewrote 
---------
 f
(1 row)
```

Under UTC it is metadata-only. Run type migrations from a session whose zone you chose on purpose.

**Generated columns** (`line_total` above) are computed from the same row and stored. They cannot be written, and the limits are precise:

```sql
ALTER TABLE ev ADD COLUMN line_virtual numeric GENERATED ALWAYS AS (qty * amount) VIRTUAL;
UPDATE ev SET line_total = 5 WHERE id = 1;
ALTER TABLE ev ADD COLUMN seen_day date GENERATED ALWAYS AS (seen_at::date) STORED;
ALTER TABLE ev ADD COLUMN seen_day date
    GENERATED ALWAYS AS ((seen_at AT TIME ZONE 'Asia/Kolkata')::date) STORED;
ALTER TABLE ev ADD COLUMN with_gst numeric GENERATED ALWAYS AS (line_total * 1.18) STORED;
ALTER TABLE ev ALTER COLUMN amount TYPE numeric(14,2);
```

```text
ERROR:  syntax error at or near "VIRTUAL"
LINE 1: ..._virtual numeric GENERATED ALWAYS AS (qty * amount) VIRTUAL;
                                                               ^
ERROR:  column "line_total" can only be updated to DEFAULT
DETAIL:  Column "line_total" is a generated column.
ERROR:  generation expression is not immutable
ALTER TABLE
ERROR:  cannot use generated column "line_total" in column generation expression
DETAIL:  A generated column cannot reference another generated column.
ERROR:  cannot alter type of a column used by a generated column
DETAIL:  Column "amount" is used by generated column "line_total".
```

> **Version note —** PostgreSQL 15 has `STORED` generated columns only. `VIRTUAL` is a
> syntax error here. If you want a computed-on-read column, use a view.

The expression must be `IMMUTABLE`: `seen_at::date` depends on the session zone and is refused; the same expression with a fixed zone is accepted. A generated column cannot use another, and its inputs are pinned: `amount`'s type cannot change without dropping it. Adding one rewrites the table (the last row of the table above).

> **Trap —** a generated column is not "cheap to add later": a full rewrite under `ACCESS EXCLUSIVE`, and it pins the source types. Use one for a function of one row that must never disagree with its inputs (`line_total = qty * unit_price`); anything needing another row or the clock is a trigger, view or query.

## 23.5 Column-level integrity

| Column kind | Constraint |
|---|---|
| Any required text | `NOT NULL` and `CHECK (btrim(col) <> '')` |
| Normalised text (email, code) | `CHECK (col = lower(btrim(col)))` |
| Fixed-format code (country, PIN, currency) | `CHECK (col ~ '^...$')` |
| Money, quantity | `CHECK (col >= 0)`, or `> 0` when zero is meaningless |
| Percentage | `CHECK (col BETWEEN 0 AND 100)` |
| Status | `CHECK (col IN (...))` or foreign key |
| Optional column with a format | Nullable *plus* `CHECK`; NULL passes a `CHECK` |
| Start and end | `CHECK (end_at > start_at)` or a range type |

Name each constraint for its rule; the name is what the application sees (Chapter 15). Assembled:

```sql
CREATE TABLE customer_v2 (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name         text NOT NULL CONSTRAINT customer_name_present CHECK (btrim(name) <> ''),
    email        text NOT NULL CONSTRAINT customer_email_shape
                 CHECK (email = lower(btrim(email)) AND email LIKE '%_@_%'),
    country      text NOT NULL DEFAULT 'IN' CONSTRAINT customer_country_iso2 CHECK (country ~ '^[A-Z]{2}$'),
    pin_code     text CONSTRAINT customer_pin_shape CHECK (pin_code ~ '^[1-9][0-9]{5}$'),
    credit_limit numeric(12,2) NOT NULL DEFAULT 0 CONSTRAINT customer_credit_nonneg CHECK (credit_limit >= 0),
    signup_date  date NOT NULL DEFAULT current_date
);

INSERT INTO customer_v2 (name, email) VALUES ('   ', 'anita.rao@vyapar.example');
INSERT INTO customer_v2 (name, email, pin_code) VALUES ('Anita Rao', 'anita.rao@vyapar.example', '012345');
INSERT INTO customer_v2 (name, email, pin_code) VALUES ('Anita Rao', 'anita.rao@vyapar.example', '560001');
```

```text
ERROR:  new row for relation "customer_v2" violates check constraint "customer_name_present"
DETAIL:  Failing row contains (1,    , anita.rao@vyapar.example, IN, null, 0.00, 2026-09-30).
ERROR:  new row for relation "customer_v2" violates check constraint "customer_pin_shape"
DETAIL:  Failing row contains (2, Anita Rao, anita.rao@vyapar.example, IN, 012345, 0.00, 2026-09-30).
INSERT 0 1
```

A `NOT NULL` alone accepts the first row: a required field that is present and empty. (The date in `DETAIL` is `current_date` on the day of capture; the failing rows burned identity values 1 and 2, Chapter 20.)

## 23.6 Column order and alignment padding

PostgreSQL stores columns in the order you declared them, and aligns each to its type's
boundary, padding the gap. The alignment is in the catalog:

```sql
SELECT typname, typlen, typalign FROM pg_type
WHERE typname IN ('bool','int2','int4','int8','float8','timestamptz','uuid','text','numeric')
ORDER BY typalign DESC, typlen DESC, typname;
```

```text
   typname   | typlen | typalign
-------------+--------+----------
 int2        |      2 | s
 int4        |      4 | i
 numeric     |     -1 | i
 text        |     -1 | i
 float8      |      8 | d
 int8        |      8 | d
 timestamptz |      8 | d
 uuid        |     16 | c
 bool        |      1 | c
(9 rows)
```

`d` aligns to 8 bytes, `i` to 4, `s` to 2, `c` to 1. A `boolean` followed by a `bigint` leaves seven bytes of zeros. Two tables, same eight columns, one in human order and one by descending alignment, one million rows each:

```sql
CREATE TABLE ship_bad (
    is_paid boolean, id bigint, is_gift boolean, shipped_at timestamptz,
    qty smallint, customer_id int, is_cod boolean, weight_kg float8);
CREATE TABLE ship_good (
    id bigint, shipped_at timestamptz, weight_kg float8, customer_id int,
    qty smallint, is_paid boolean, is_gift boolean, is_cod boolean);
INSERT INTO ship_bad
SELECT g%2=0, g, g%7=0, timestamptz '2026-01-01' + g*interval '1 second', g%5, g%1000, g%3=0, g/10.0
FROM generate_series(1,1000000) g;
INSERT INTO ship_good
SELECT g, timestamptz '2026-01-01' + g*interval '1 second', g/10.0, g%1000, g%5, g%2=0, g%7=0, g%3=0
FROM generate_series(1,1000000) g;

SELECT relname, pg_relation_size(oid) AS bytes,
       round(pg_relation_size(oid)::numeric / 1000000, 1) AS bytes_per_row
FROM pg_class WHERE relname IN ('ship_bad','ship_good') ORDER BY 1;

SELECT 'bad' AS tbl, max(lp_len) AS lp_len, max(t_hoff) AS t_hoff, count(*) AS rows_on_page
FROM heap_page_items(get_raw_page('ship_bad',0))
UNION ALL
SELECT 'good', max(lp_len), max(t_hoff), count(*)
FROM heap_page_items(get_raw_page('ship_good',0));
```

```text
  relname  |  bytes   | bytes_per_row
-----------+----------+---------------
 ship_bad  | 84459520 |          84.5
 ship_good | 68272128 |          68.3
(2 rows)

 tbl  | lp_len | t_hoff | rows_on_page
------+--------+--------+--------------
 bad  |     80 |     24 |           97
 good |     57 |     24 |          120
(2 rows)
```

**Same data, 19% smaller.** The bad row is 80 bytes (24 header, 56 data, 23 of them padding); the good row is 57, which rounds to 64. Page 0 holds 97 rows against 120, so every scan reads 19% fewer pages. Here that is 16 MB; on a 500-million-row table, extrapolating the 16 bytes per row, about 8 GB you cannot reclaim without a rewrite.

Ordering matters only when the padding is real. Six one-row tables, `lp_len` as stored and the size after the 8-byte rounding a page uses:

```sql
CREATE TABLE v1 (flag boolean, n int, big bigint);
CREATE TABLE v2 (big bigint, n int, flag boolean);
CREATE TABLE v3 (a bigint, b timestamptz, c float8);
CREATE TABLE v4 (c float8, a bigint, b timestamptz);
CREATE TABLE v5 (note text, id bigint);
CREATE TABLE v6 (id bigint, note text);
INSERT INTO v1 VALUES (true, 1, 1); INSERT INTO v2 VALUES (1, 1, true);
INSERT INTO v3 VALUES (1, now(), 1); INSERT INTO v4 VALUES (1, 1, now());
INSERT INTO v5 VALUES ('Anita Rao', 1); INSERT INTO v6 VALUES (1, 'Anita Rao');
SELECT t.tbl, lp_len, ((lp_len + 7) / 8) * 8 AS on_page
FROM (VALUES ('v1 bool,int,bigint'),('v2 bigint,int,bool'),('v3 bigint,tstz,float8'),
             ('v4 float8,bigint,tstz'),('v5 text,bigint'),('v6 bigint,text')) t(tbl)
JOIN LATERAL heap_page_items(get_raw_page(split_part(t.tbl,' ',1), 0)) ON true
ORDER BY 1;
```

```text
          tbl          | lp_len | on_page 
-----------------------+--------+---------
 v1 bool,int,bigint    |     40 |      40
 v2 bigint,int,bool    |     37 |      40
 v3 bigint,tstz,float8 |     48 |      48
 v4 float8,bigint,tstz |     48 |      48
 v5 text,bigint        |     48 |      48
 v6 bigint,text        |     42 |      48
(6 rows)
```

- **Reordering within one alignment class changes nothing** (v3, v4).
- **The tail rounds to 8 anyway**, so padding that lands there is free (v1, v2).
- **A short `text` in front pads what follows, by a data-dependent amount** (v5, v6: `lp_len` 48 against 42, same page footprint). Put variable-length columns last.
- `smallint` saves 2 bytes only if nothing after it needs alignment. Choose it for the domain, not the table.

Indexes pad too:

```sql
CREATE INDEX i1 ON ship_bad (is_paid, id, is_gift);
CREATE INDEX i2 ON ship_bad (id, is_paid, is_gift);
CREATE INDEX i3 ON ship_bad (is_paid, id);
CREATE INDEX i4 ON ship_bad (id, is_paid);
SELECT indexrelid::regclass AS idx, pg_relation_size(indexrelid) AS bytes
FROM pg_index WHERE indexrelid IN ('i1'::regclass,'i2'::regclass,'i3'::regclass,'i4'::regclass)
ORDER BY 1;
```

```text
 idx |  bytes
-----+----------
 i1  | 40583168
 i2  | 31522816
 i3  | 31563776
 i4  | 31522816
(4 rows)
```

`(is_paid, id, is_gift)` is 29% larger than `(id, is_paid, is_gift)`; the two-column pair differs by 0.1%. Index order is a query question (Chapter 33), but where the query allows a choice, wide first is free.

> **In production —** decide at `CREATE TABLE`, then leave it. If people care about the column order `SELECT *` returns, hide it behind a view. Reordering an existing table is a rewrite plus a migration.

## 23.7 TOAST: what happens to a big value

A page is 8 kB and a row must fit in one, so when a row exceeds about 2 kB PostgreSQL compresses its variable-length columns and, if that is not enough, moves them out of line into a hidden TOAST table, leaving an 18-byte pointer. The per-column policy is `attstorage`: `x` extended (compress, then move out; the `text` default), `e` external (never compress), `m` main, `p` plain. Compressible against incompressible:

```sql
CREATE FUNCTION noise(n int) RETURNS text LANGUAGE sql IMMUTABLE AS
  $$ SELECT substr(string_agg(md5(g::text), ''), 1, n) FROM generate_series(1, n/32 + 1) g $$;

CREATE TABLE st (id int, c_default text, c_external text);
ALTER TABLE st ALTER COLUMN c_external SET STORAGE EXTERNAL;
INSERT INTO st SELECT 1, repeat('Namaste ', 12500), repeat('Namaste ', 12500);
INSERT INTO st SELECT 2, noise(6000), noise(6000);
SELECT attname, attstorage FROM pg_attribute WHERE attrelid = 'st'::regclass AND attnum > 1 ORDER BY attnum;
SELECT id, octet_length(c_default) AS raw_bytes, pg_column_size(c_default) AS default_stored,
       pg_column_size(c_external) AS external_stored FROM st ORDER BY id;
```

```text
  attname   | attstorage 
------------+------------
 c_default  | x
 c_external | e
(2 rows)

 id | raw_bytes | default_stored | external_stored 
----+-----------+----------------+-----------------
  1 |    100000 |           1164 |          100000
  2 |      6000 |           6000 |            6000
(2 rows)
```

100,000 bytes of repeated text are stored as 1,164 by default and 100,000 with `EXTERNAL`; MD5 noise (like compressed images or encrypted data) is stored raw either way. `SET STORAGE` affects later rows only. Use `EXTERNAL` for large incompressible values you slice with `substr()`.

> **Version note —** from PostgreSQL 14 the algorithm is per column (`COMPRESSION lz4`, if the server was built with it). We did not measure it here.

**The 2 kB threshold applies to the whole row.** A row inside a page is measured with
`lp_len`, and a value that moves out leaves a short row behind. Rows `(id int, body text)`
with incompressible bodies from 1,980 to 2,040 bytes:

```sql
CREATE TABLE th (id int, body text);
INSERT INTO th SELECT n, noise(n) FROM generate_series(1980, 2040) n;
SELECT t.id AS body_len, i.lp_len
FROM th t
JOIN LATERAL generate_series(0, pg_relation_size('th') / 8192 - 1) p ON true
JOIN LATERAL heap_page_items(get_raw_page('th', p::int)) i ON i.t_ctid = t.ctid
WHERE t.id IN (1999, 2000, 2001, 2002) ORDER BY 1;
```

```text
 body_len | lp_len 
----------+--------
     1999 |   2031
     2000 |   2032
     2001 |     46
     2002 |     46
(4 rows)
```

A row of 2,032 bytes stays inline; one byte more and the value leaves, shrinking the row to 46. The limit is on the tuple, so two columns each under 2 kB can trigger it:

```sql
CREATE TABLE two (a text, b text);
INSERT INTO two VALUES (noise(1100), noise(1100)), (noise(900), noise(900));
SELECT lp, lp_len FROM heap_page_items(get_raw_page('two',0)) ORDER BY lp;
```

```text
 lp | lp_len
----+--------
  1 |   1148
  2 |   1832
(2 rows)
```

Two 1,100-byte columns: one goes out of line (row 1,148). Two 900-byte columns stay together (1,832). The per-table `toast_tuple_target` reloption moves that limit.

**What it means for queries.** A 5,000-row `article` table with 4,000-byte bodies:

```sql
CREATE TABLE article (
    id bigint PRIMARY KEY, author_id int NOT NULL, published_at timestamptz NOT NULL,
    view_count int NOT NULL DEFAULT 0, title text NOT NULL, body text NOT NULL);
INSERT INTO article (id, author_id, published_at, title, body)
SELECT g, g % 500, timestamptz '2026-01-01' + g * interval '1 minute', 'Post ' || g,
       (SELECT string_agg(md5(g::text || i), '') FROM generate_series(1, 125) i)
FROM generate_series(1, 5000) g;
VACUUM ANALYZE article;
SELECT c.reltoastrelid::regclass::text AS toast FROM pg_class c WHERE oid = 'article'::regclass \gset
SELECT pg_relation_size('article') AS heap_bytes, pg_relation_size(:'toast') AS toast_bytes,
       (SELECT count(*) FROM :toast) AS toast_chunks FROM article LIMIT 1;
```

```text
 heap_bytes | toast_bytes | toast_chunks
------------+-------------+--------------
     425984 |    27312128 |        15000
(1 row)
```

The heap is 0.43 MB; the bodies are in the 27.3 MB toast table, three chunks per value. Which buffers does a query touch? Parallelism is pinned off (`max_parallel_workers_per_gather = 0`) and a warm-up run precedes the plans, so every buffer is a hit:

```sql
SET max_parallel_workers_per_gather = 0;
\o /dev/null
SELECT sum(id), max(title), sum(length(body)) FROM article;
SELECT sum(id), max(title), sum(length(body)) FROM article;
\o
SELECT sum(id), max(title), sum(length(body)) FROM article;
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT sum(id), max(title) FROM article;
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT sum(id), max(title), sum(length(body)) FROM article;
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT id, title, body FROM article;
```

```text
   sum    |   max    |   sum
----------+----------+----------
 12502500 | Post 999 | 20000000
(1 row)

                      QUERY PLAN
------------------------------------------------------
 Aggregate (actual rows=1 loops=1)
   Buffers: shared hit=52
   ->  Seq Scan on article (actual rows=5000 loops=1)
         Buffers: shared hit=52
(4 rows)

                      QUERY PLAN
------------------------------------------------------
 Aggregate (actual rows=1 loops=1)
   Buffers: shared hit=16719
   ->  Seq Scan on article (actual rows=5000 loops=1)
         Buffers: shared hit=52
(4 rows)

                   QUERY PLAN
------------------------------------------------
 Seq Scan on article (actual rows=5000 loops=1)
   Buffers: shared hit=52
(2 rows)
```

52 buffers without the body, 16,719 with it: **321 times** for the same 5,000 rows, because reading `body` fetches its chunks through the toast index (charged to the aggregate node, not the scan).

> **Trap —** the third plan lies. `EXPLAIN ANALYZE SELECT id, title, body` reports 52 buffers because `EXPLAIN` never sends the rows, so never detoasts `body`. The real `SELECT *` reads the ~16,700 of the second plan. To measure a wide select, consume the column (`length(body)`); `octet_length(body)` does not detoast either.

So `SELECT *` on a table with a big column is expensive for a reason the row count hides; list your columns. And a narrow write does not touch the toast table:

```sql
SELECT pg_relation_size('article') AS heap_before, pg_relation_size(:'toast') AS toast_before \gset
UPDATE article SET view_count = view_count + 1;
SELECT pg_relation_size('article') AS heap_after, pg_relation_size(:'toast') AS toast_after,
       (SELECT count(*) FROM :toast) AS toast_chunks;
UPDATE article SET body = body || 'x' WHERE id <= 1000;
SELECT pg_relation_size(:'toast') AS toast_after_body_update;
```

```text
UPDATE 5000
 heap_after | toast_after | toast_chunks
------------+-------------+--------------
     851968 |    27312128 |        15000
(1 row)
```

Rewriting 5,000 rows doubled the heap (0.43 to 0.85 MB) and left the toast table exactly where it was: an updated row keeps its pointer. Changing `body` on 1,000 rows wrote new chunks and grew the toast table by 5.5 MB until vacuum. A hot counter beside a large text column is fine; the cost is in changing the large value. Keep the large column out of queries that do not need it, never index the raw value (Chapter 13's ceiling applies to the *compressed* size), and keep files in object storage with a key in the row.

## 23.8 PII classification

Four classes, defined by what you must do rather than by legal category:

| Class | Meaning | Handling |
|---|---|---|
| `restricted` | Serious harm on disclosure: government IDs, payment data, credentials, health | Avoid storing; column-privilege whitelist; never in non-prod, logs or analytics; encrypt (Chapter 51) |
| `personal` | Identifies or contacts a person, alone or combined: name, email, phone, address, birth date, city | Masked in non-prod; excluded from analytics grants; retention and erasure |
| `internal` | Not personal alone: keys, status, tier, amounts | Staff and services; reporting allowed |
| `public` | Meant to be shown: product name, price | None |

The class describes the column, and it is weaker than it looks: an `internal` column keyed by `id` is linkable to a person by anyone who can join to the `personal` ones, which is why the analyst below gets `id` but not `name`. Put the class in the catalog where a query can read it:

```sql
COMMENT ON COLUMN customers.id           IS 'class=internal; surrogate key, joins everything';
COMMENT ON COLUMN customers.name         IS 'class=personal; full name as given at signup';
COMMENT ON COLUMN customers.email        IS 'class=personal; login and order receipts';
COMMENT ON COLUMN customers.country      IS 'class=internal; ISO 3166 alpha-2, drives tax rules';
COMMENT ON COLUMN customers.city         IS 'class=personal; quasi-identifier with signup_date';
COMMENT ON COLUMN customers.signup_date  IS 'class=internal; cohort analysis';
COMMENT ON COLUMN customers.loyalty_tier IS 'class=internal; bronze/silver/gold';
COMMENT ON COLUMN customers.referred_by  IS 'class=internal; links two customers';

CREATE VIEW column_class AS
SELECT c.relname AS table_name, a.attname AS column_name,
       substring(d.description FROM '^class=([a-z]+)') AS class,
       substring(d.description FROM '^class=[a-z]+; (.*)$') AS why
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'public'
JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
LEFT JOIN pg_description d ON d.objoid = c.oid AND d.classoid = 'pg_class'::regclass
                          AND d.objsubid = a.attnum
WHERE c.relkind = 'r' AND c.relname = 'customers';

SELECT class, string_agg(column_name, ', ' ORDER BY column_name) AS columns
FROM column_class GROUP BY class ORDER BY class;
```

```text
  class   |                       columns                       
----------+-----------------------------------------------------
 internal | country, id, loyalty_tier, referred_by, signup_date
 personal | city, email, name
(2 rows)
```

(The view is limited to `customers` here.) The CI check is a new column with no class:

```sql
ALTER TABLE customers ADD COLUMN phone text;
SELECT table_name, column_name FROM column_class WHERE class IS NULL;
```

```text
 table_name | column_name 
------------+-------------
 customers  | phone
(1 row)
```

A migration that skips classification fails that query while the column is still empty. The class also drives privileges; generate the grant from the catalog:

```sql
CREATE ROLE ch23_analyst NOLOGIN;
SELECT format('GRANT SELECT (%s) ON customers TO ch23_analyst',
              string_agg(quote_ident(column_name), ', ' ORDER BY column_name))
FROM column_class WHERE class IN ('internal','public') \gexec
SET ROLE ch23_analyst;
SELECT * FROM customers LIMIT 1;
SELECT id, country, loyalty_tier FROM customers LIMIT 2;
SELECT id FROM customers WHERE email = 'customer1@vyapar.example';
RESET ROLE;
```

```text
GRANT
SET
ERROR:  permission denied for table customers
 id | country | loyalty_tier
----+---------+--------------
  1 | AE      | silver
  2 | IN      | bronze
(2 rows)

ERROR:  permission denied for table customers
```

`SELECT *` fails because it names ungranted columns, and so does a `WHERE` on `email`: filtering by a column is reading it. Row-level limits are Chapter 44, masking Chapter 51.

**The leak people forget is the error message.** The `DETAIL` line Chapter 15 praised is also a copy of the personal data:

```sql
ALTER TABLE customers ADD CONSTRAINT customers_email_key UNIQUE (email);
INSERT INTO customers (name, email, country, signup_date)
VALUES ('Test', 'customer1@vyapar.example', 'IN', current_date);
```

```text
ERROR:  duplicate key value violates unique constraint "customers_email_key"
DETAIL:  Key (email)=(customer1@vyapar.example) already exists.
```

I read the container's server log after that statement: the same `DETAIL` line was in it, plus the full `STATEMENT:` text with the literal. With `log_error_verbosity = terse` (checked separately) the `DETAIL` left the log and the `STATEMENT` stayed. So personal columns reach log files, which usually have wider access and longer retention than the table (Chapter 51).

> **In production —** classification is a data-flow decision: what reaches non-prod copies, extracts, logs and backups. India's Digital Personal Data Protection Act, 2023 regulates handling of personal data; which columns count and what you owe is for your counsel. This scheme organises columns; it does not establish compliance.

## Summary

- **Twelve-item checklist (23.1).** Type by operation; `NOT NULL` by default; know each `ALTER`'s cost; constrain by kind; widest fixed columns first; know your TOAST columns; classify at creation.
- **NULL is a semantic cost, not a storage one**: 64 bytes with a NULL against 60 without, both 64 on the page; 39.2% of `loyalty_tier` was a value nobody wrote. `SET NOT NULL` scans; a validated `CHECK` lets it skip.
- **Constant defaults are free since 11**; `random()` rewrites, `now()` does not. `numeric(12,3)`, `int` to `bigint`, a generated column, and `timestamp` to `timestamptz` under a non-UTC zone rewrite. Generated columns are `STORED`-only on 15, immutable, and pin their inputs.
- **Padding: 84.5 against 68.3 bytes per row** (19% smaller; 97 against 120 rows per page); reordering within an alignment class saves nothing. An index on `(is_paid, id, is_gift)` was 29% larger than `(id, is_paid, is_gift)`.
- **TOAST**: a 2,032-byte row stays inline, 2,033 does not; reading a 4,000-byte column cost 16,719 buffers against 52, and `EXPLAIN` of `SELECT *` hides it.
- **PII**: four classes in `COMMENT ON COLUMN`, a catalog view for unclassified columns, generated column grants; `DETAIL` and `STATEMENT` copy personal data into the log.

**Exercises:** Practice Sessions 23.1–23.3 accompany this chapter and are in the
workbook at the back of the book.

**Next:** Chapter 24, *Design Anti-Patterns and Safe Refactoring*, is the other side of
this checklist: what a schema looks like when it was skipped (EAV, god tables, JSONB as a
way of not deciding) and how to change it while the application keeps running.
