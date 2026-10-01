# Chapter 27 — Pattern Matching and Regular Expressions

Chapter 7 gave you `LIKE` in a paragraph and a warning about user input. This chapter is
the rest of it, organised around the question that decides everything in production: **can the
pattern use an index?** Postgres has three pattern languages, a regex library that turns a text
column into a parser, and two ways to make text search fast. Both have preconditions that fail
silently, which is why so many `LIKE` queries are slow.

Everything here that builds indexes runs in a scratch database. The data is generated:
200,000 contacts with Indian names, `userN@vyapar.example` emails, and six-digit SKUs.

```bash
createdb ch27_scratch
psql -d ch27_scratch
```

```sql
\pset null '(null)'
SET max_parallel_workers_per_gather = 0;

CREATE TABLE contact (
    id    int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name  text NOT NULL,
    email text NOT NULL,
    sku   text NOT NULL);
INSERT INTO contact (name, email, sku)
SELECT (ARRAY['Anita','Rajesh','Priya','Arjun','Fatima','Harpreet','Meera','Imran','Sneha','Rohit'])[1 + g % 10]
       || ' ' ||
       (ARRAY['Rao','Kumar','Menon','Iyer','Sheikh','Singh','Banerjee','Reddy','Mukherjee','Patel'])[1 + (g / 10) % 10],
       'user' || g || '@vyapar.example',
       'SKU-' || lpad(g::text, 6, '0')
FROM generate_series(1, 200000) g;
ANALYZE contact;

-- Runs a query once to warm the cache, then explains it. Planning lines are dropped:
-- they vary between the first and second call and carry no information here.
CREATE FUNCTION explain_warm(q text) RETURNS TABLE ("QUERY PLAN" text)
LANGUAGE plpgsql AS $$
DECLARE l text;
BEGIN
    EXECUTE 'SELECT count(*) FROM (' || q || ') s';
    FOR l IN EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF) ' || q LOOP
        EXIT WHEN l LIKE 'Planning:%';
        "QUERY PLAN" := l; RETURN NEXT;
    END LOOP;
END $$;
```

The database default here is `en_US.UTF-8`, as it is on `retail`, and that matters in 27.4.
There are no timings in this chapter: plan node types, buffer counts and index sizes make the
argument and do not depend on the machine.

---

## 27.1 Three pattern languages

**`LIKE`** has two wildcards, `%` and `_`, and must match the *whole* string. `ILIKE` is
the case-insensitive Postgres extension. **POSIX regular expressions** use `~` (match,
case-sensitive), `~*` (case-insensitive), `!~` and `!~*` (the negations) and match
*anywhere* in the string unless you anchor with `^` and `$`. **`SIMILAR TO`** is the SQL
standard's attempt to be halfway between, and it is the one to avoid.

```sql
SELECT 'abc' SIMILAR TO 'a'     AS whole_string,
       'abc' ~ 'a'              AS posix_anywhere,
       'a.c' SIMILAR TO 'a.c'   AS dot_literal,
       'abc' SIMILAR TO 'a.c'   AS dot_as_wildcard,
       'abc' ~ 'a.c'            AS posix_dot,
       'Anita' ~ 'anita'        AS case_sensitive,
       'Anita' ~* 'anita'       AS case_insensitive,
       'Anita' !~* 'anita'      AS negated;
```

```text
 whole_string | posix_anywhere | dot_literal | dot_as_wildcard | posix_dot | case_sensitive | case_insensitive | negated
--------------+----------------+-------------+-----------------+-----------+----------------+------------------+---------
 f            | t              | t           | f               | t         | f              | t                | f
(1 row)
```

`SIMILAR TO` anchors like `LIKE` (first column) but has `LIKE`'s wildcards *and* regex
alternation and character classes, while treating `.` as a literal, which is the opposite of
every regex you have ever written (fourth column). Nobody remembers which
rules apply, and it is translated to a POSIX regex internally, so it buys no performance. Use
`LIKE` when a wildcard is enough and POSIX when it is not.

> **Trap —** `LIKE` treats `%` and `_` as wildcards in *data* as well as in your literals.
> That bites whenever the pattern comes from a user, or the search term is something like a
> promo code that legitimately contains `_` or `%`.

```sql
CREATE TEMP TABLE promo (code text);
INSERT INTO promo VALUES ('DIWALI_10'),('DIWALI10'),('DIWALIX10'),('FLAT50%'),('FLAT500'),('HOLI20');

SELECT code FROM promo WHERE code LIKE 'DIWALI_10' ORDER BY 1;
SELECT code FROM promo WHERE code LIKE 'DIWALI\_10' ORDER BY 1;
SELECT code FROM promo WHERE code LIKE 'FLAT50#%' ESCAPE '#' ORDER BY 1;
SELECT count(*) AS user_typed_a_percent FROM promo WHERE code LIKE '%';
```

```text
   code
-----------
 DIWALI_10
 DIWALIX10
(2 rows)

   code
-----------
 DIWALI_10
(1 row)

  code
---------
 FLAT50%
(1 row)

 user_typed_a_percent
----------------------
                    6
(1 row)
```

The first query returns `DIWALIX10` as well, since `_` matched the `X`. The default escape
character is the backslash; `ESCAPE` nominates another, which is easier to read inside an
application string that already has backslash problems. A search box that sends `%` matches
every row. It is not injection, and parameterised queries do not prevent it, because the
wildcard is in the *value*. Escape the term before it goes into the pattern:

```sql
SELECT code FROM promo
WHERE  code LIKE replace(replace(replace('FLAT50%', '\', '\\'), '%', '\%'), '_', '\_') || '%';
```

```text
  code
---------
 FLAT50%
(1 row)
```

Backslash first, or you escape your own escapes. If all you need is "starts with this literal
text", `starts_with(code, 'FLAT50%')` has no pattern language and nothing to escape; for a
substring, `strpos(code, term) > 0` is the same idea.

## 27.2 Regex as a parsing tool

Where `LIKE` answers "does it match", the regex functions answer "what did it match". Try
them on one access-log line:

```sql
SELECT regexp_match(l, '"(GET|POST) (\S+) HTTP/[0-9.]+" (\d{3})')  AS one_match,
       substring(l FROM '"(?:GET|POST) (\S+)')                     AS path
FROM (VALUES ('103.21.58.14 - - [12/Sep/2026:09:14:02 +0530] "GET /api/orders/1042 HTTP/1.1" 200 512 "Pune"')) v(l);

SELECT (SELECT regexp_match('health-check ok', '\d+'))                  AS match_result,
       (SELECT count(*) FROM regexp_matches('health-check ok', '\d+'))  AS matches_rows;
```

```text
         one_match          |       path
----------------------------+------------------
 {GET,/api/orders/1042,200} | /api/orders/1042
(1 row)

 match_result | matches_rows
--------------+--------------
 (null)       |            0
(1 row)
```

- **`regexp_match(s, re)`** returns a `text[]` of the capture groups for the *first* match
  (or the whole match if there are no groups), and **NULL if there is no match**.
  `substring(s FROM re)` is the one-group shorthand.
- **`regexp_matches(s, re, 'g')`** is set-returning: with the `g` flag one row per match,
  without it one row for the first match, and *zero rows* if there is none. That last
  behaviour makes a row disappear from a join, where `regexp_match` would give you a NULL. Use
  `regexp_match` unless you actually want every match.
- **`regexp_replace(s, re, repl, flags)`** replaces only the first match unless the flags
  contain `g`. Backreferences in the replacement are `\1`, `\2`.

```sql
SELECT regexp_replace('103.21.58.14', '\.\d+$', '.x') AS masked,
       regexp_replace('a1b22c333', '\d+', '#')      AS first_only,
       regexp_replace('a1b22c333', '\d+', '#', 'g') AS every_match,
       regexp_replace('anita rao', '(\w+) (\w+)', '\2, \1') AS swapped;
SELECT regexp_split_to_table('SKU-1;SKU-2, SKU-3', '[;,]\s*');
```

```text
   masked    | first_only | every_match |  swapped
-------------+------------+-------------+------------
 103.21.58.x | a#b22c333  | a#b#c#      | rao, anita
(1 row)

 regexp_split_to_table
-----------------------
 SKU-1
 SKU-2
 SKU-3
(3 rows)
```

`regexp_split_to_table` and `regexp_split_to_array` split on a pattern where `string_to_table`
(Chapter 18) splits on a fixed string. Flags are single letters: `i` case-insensitive, `g`
global, `n` newline-sensitive. The regex flavour is POSIX ARE with Perl-style shortcuts
(`\d`, `\s`, `\w`, lazy quantifiers `*?`, lookahead and lookbehind), so most patterns you paste
from elsewhere work. The one trap is spelling: word boundary is `\y`, since `\b` is a backspace.

> **Version note —** PostgreSQL 15 added `regexp_count`, `regexp_instr`, `regexp_like` and
> `regexp_substr`, the Oracle-style names. They exist on 15.10 and are conveniences over the
> functions above; on 14 you count with `SELECT count(*) FROM regexp_matches(..., 'g')`.

```sql
SELECT regexp_count('a1b22c333', '\d+')          AS runs_of_digits,
       regexp_instr('Anita Rao', 'Rao')          AS position,
       regexp_like('Anita', '^a', 'i')           AS matches_ignoring_case,
       regexp_substr('order 1042 shipped', '\d+') AS first_number;
```

```text
 runs_of_digits | position | matches_ignoring_case | first_number
----------------+----------+-----------------------+--------------
              3 |        7 | t                     | 1042
(1 row)
```

## 27.3 Parsing a log, and the NULL that follows

The realistic use of all this is a text column nobody structured. Build 20,000 web-server
lines from five kinds of request, with an occasional non-request line, as a log shipper
would produce:

```sql
CREATE TABLE raw_log (id int GENERATED ALWAYS AS IDENTITY PRIMARY KEY, line text NOT NULL);
INSERT INTO raw_log (line)
SELECT CASE WHEN g % 50 = 0 THEN 'health-check ok' ELSE
       (ARRAY['103.21.58.','49.36.201.','117.99.4.','152.58.33.'])[1 + g % 4] || (1 + g % 250)
       || ' - - [12/Sep/2026:' || to_char(interval '9 hours' + g * interval '1 second', 'HH24:MI:SS')
       || ' +0530] "' || p.method || ' ' || replace(p.path, '#', (g * 7 % 5000)::text)
       || ' HTTP/1.1" ' || CASE WHEN g % 17 = 0 THEN 404 WHEN g % 41 = 0 AND p.method = 'POST' THEN 500 ELSE 200 END
       || ' ' || (g * 13 % 4000) || ' "'
       || (ARRAY['Pune','Bengaluru','Kochi','Jaipur','Chennai'])[1 + g % 5] || '"' END
FROM generate_series(1, 20000) g,
     LATERAL (SELECT * FROM (VALUES ('GET','/api/orders/#'), ('GET','/api/products?q=diya'),
                                    ('POST','/api/checkout'), ('GET','/api/customers/#'), ('POST','/login'))
                            AS t(method, path) OFFSET g % 5 LIMIT 1) p;
```

One pattern extracts every field into a typed table. `LATERAL` with `regexp_match` keeps every
input row, giving NULL fields where the line did not match:

```sql
CREATE TABLE access AS
SELECT r.id, m[1] AS ip, m[2] AS method, m[3] AS path, m[4]::int AS status, m[5]::int AS bytes, m[6] AS city
FROM   raw_log r
CROSS  JOIN LATERAL regexp_match(r.line,
   '^(\S+) \S+ \S+ \[[^\]]+\] "([A-Z]+) (\S+) HTTP/[0-9.]+" (\d{3}) (\d+) "([^"]*)"$') AS m;

SELECT count(*) AS lines, count(status) AS parsed, count(*) - count(status) AS unparsed FROM access;
```

```text
 lines | parsed | unparsed
-------+--------+----------
 20000 |  19600 |      400
(1 row)
```

Now the trap. The unparsed lines are not filtered out, they are NULL, and NULL rows
distort every ratio whose denominator is `count(*)`:

```sql
SELECT count(*) FILTER (WHERE status >= 500)                        AS errors,
       round(100.0 * count(*) FILTER (WHERE status >= 500) / count(*), 3)      AS pct_of_all_lines,
       round(100.0 * count(*) FILTER (WHERE status >= 500) / count(status), 3) AS pct_of_requests
FROM   access;
```

```text
 errors | pct_of_all_lines | pct_of_requests
--------+------------------+-----------------
    183 |            0.915 |           0.934
(1 row)
```

Neither number is wrong arithmetic. Only one answers "what fraction of *requests* failed", and
the query that used `count(*)` never said otherwise. Decide what a non-match means (drop it,
count it, alert on it), and make the query say so. Then the report, with ids folded to
`:id` and query strings removed so that `/api/orders/1042` and `/api/orders/77` are one
endpoint:

```sql
SELECT regexp_replace(regexp_replace(path, '\?.*$', ''), '/\d+$', '/:id') AS endpoint,
       count(*)                                    AS hits,
       count(*) FILTER (WHERE status >= 400)       AS failures
FROM   access
WHERE  status IS NOT NULL
GROUP  BY 1 ORDER BY hits DESC, 1;
```

```text
      endpoint      | hits | failures
--------------------+------+----------
 /api/checkout      | 4000 |      328
 /api/customers/:id | 4000 |      235
 /api/products      | 4000 |      235
 /login             | 4000 |      326
 /api/orders/:id    | 3600 |      212
(5 rows)
```

> **In production —** parse once, at load time, into a typed table like `access`. Running
> `regexp_match` on every query over a raw text column re-parses every row every time, and no
> index can help, because the index would have to be on the parsed field. If the format can
> drift, keep the raw line next to the parsed columns and add a `CHECK` or a monitor on the
> unparsed count: a log format change should page you, not quietly turn a column NULL.

## 27.4 Prefix search, and the index that is ignored

The most common pattern is `WHERE sku LIKE 'SKU-1500%'`: anchored at the start, wildcard at the end.
A B-tree is sorted, and that pattern is a range (`>= 'SKU-1500'` and `< 'SKU-1501'`), so a B-tree
*can* serve it. Whether the planner will depends on collation (Chapter 3), and the default fails:

```sql
CREATE INDEX contact_sku_idx ON contact (sku);
SELECT * FROM explain_warm($$SELECT id FROM contact WHERE sku LIKE 'SKU-1500%'$$);
```

```text
                  QUERY PLAN
-----------------------------------------------
 Seq Scan on contact (actual rows=100 loops=1)
   Filter: (sku ~~ 'SKU-1500%'::text)
   Rows Removed by Filter: 199900
   Buffers: shared hit=2091
(4 rows)
```

A Seq Scan over all 2,091 pages, with an index on that exact column. Under `en_US.UTF-8` the
index is ordered by locale rules, so strings sharing a prefix are not guaranteed to be contiguous
and the planner will not use it. Two fixes. **`text_pattern_ops`**
builds the index with byte-wise comparison:

```sql
DROP INDEX contact_sku_idx;
CREATE INDEX contact_sku_pat ON contact (sku text_pattern_ops);
SET enable_bitmapscan = off;   -- pinned: at 100 rows the planner flips between Index and Bitmap Scan
SELECT * FROM explain_warm($$SELECT id FROM contact WHERE sku LIKE 'SKU-1500%'$$);
EXPLAIN (COSTS OFF) SELECT id FROM contact WHERE sku = 'SKU-000150';
EXPLAIN (COSTS OFF) SELECT id FROM contact WHERE sku < 'SKU-000150';
RESET enable_bitmapscan;
```

```text
                                 QUERY PLAN
----------------------------------------------------------------------------
 Index Scan using contact_sku_pat on contact (actual rows=100 loops=1)
   Index Cond: ((sku ~>=~ 'SKU-1500'::text) AND (sku ~<~ 'SKU-1501'::text))
   Filter: (sku ~~ 'SKU-1500%'::text)
   Buffers: shared hit=6
(4 rows)

                 QUERY PLAN
---------------------------------------------
 Index Scan using contact_sku_pat on contact
   Index Cond: (sku = 'SKU-000150'::text)
(2 rows)

              QUERY PLAN
--------------------------------------
 Seq Scan on contact
   Filter: (sku < 'SKU-000150'::text)
(2 rows)
```

The planner rewrote the `LIKE` into a byte-order range (`~>=~`, `~<~`) and kept the original as a
`Filter` to be exact: six buffers instead of 2,091. The index also serves `=`, and an anchored
regex (`~ '^SKU-1500'`). But it does not serve `<`, `>` or `ORDER BY`, so on a column that also
needs range queries you would need a second, ordinary index. The **second fix** is a `"C"`
collation on the index:

```sql
DROP INDEX contact_sku_pat;
CREATE INDEX contact_sku_c ON contact (sku COLLATE "C");
EXPLAIN (COSTS OFF) SELECT id FROM contact WHERE sku LIKE 'SKU-1500%';
EXPLAIN (COSTS OFF) SELECT id FROM contact WHERE sku = 'SKU-000150';
EXPLAIN (COSTS OFF) SELECT id FROM contact WHERE sku COLLATE "C" < 'SKU-000150';
```

```text
                               QUERY PLAN
------------------------------------------------------------------------
 Index Scan using contact_sku_c on contact
   Index Cond: ((sku >= 'SKU-1500'::text) AND (sku < 'SKU-1501'::text))
   Filter: (sku ~~ 'SKU-1500%'::text)
(3 rows)

              QUERY PLAN
--------------------------------------
 Seq Scan on contact
   Filter: (sku = 'SKU-000150'::text)
(2 rows)

                    QUERY PLAN
--------------------------------------------------
 Index Scan using contact_sku_c on contact
   Index Cond: ((sku)::text < 'SKU-000150'::text)
(2 rows)
```

`LIKE` uses it. `=` does not: the column's collation is `en_US`, the index's is `C`, and a query
only uses an index whose collation it agrees with. This half-fix is the reason not to index a
column in `C` while declaring it in another collation. For identifier-like columns (`sku`, `code`,
`slug`) where linguistic order is meaningless, declare the *column* `COLLATE "C"`, as Chapter 3
does, and a plain index then serves `=`, ranges, `ORDER BY` and prefix `LIKE` alike. For a column
you cannot change, use `text_pattern_ops`.

**`ILIKE` cannot use either index**, because case folding breaks byte order. Either use a trigram
index (next section) or search on a folded value with an expression index:

```sql
EXPLAIN (COSTS OFF) SELECT id FROM contact WHERE sku ILIKE 'sku-1500%';
CREATE INDEX contact_email_lower ON contact (lower(email) text_pattern_ops);
EXPLAIN (COSTS OFF) SELECT id FROM contact WHERE lower(email) LIKE lower('User15000%');
```

```text
              QUERY PLAN
---------------------------------------
 Seq Scan on contact
   Filter: (sku ~~* 'sku-1500%'::text)
(2 rows)

                                              QUERY PLAN
------------------------------------------------------------------------------------------------------
 Bitmap Heap Scan on contact
   Filter: (lower(email) ~~ 'user15000%'::text)
   ->  Bitmap Index Scan on contact_email_lower
         Index Cond: ((lower(email) ~>=~ 'user15000'::text) AND (lower(email) ~<~ 'user15001'::text))
(4 rows)
```

> **Trap —** the planner can only rewrite a `LIKE` whose start it can see. From application code
> the pattern is usually a parameter, and a generic plan (which a driver may switch to after a
> few executions) cannot see into it:

```sql
SET plan_cache_mode = force_generic_plan;   -- what a driver reaches after several executions
PREPARE by_prefix(text) AS SELECT id FROM contact WHERE sku LIKE $1;
EXPLAIN (COSTS OFF) EXECUTE by_prefix('SKU-1500%');
RESET plan_cache_mode;
```

```text
      QUERY PLAN
-----------------------
 Seq Scan on contact
   Filter: (sku ~~ $1)
(2 rows)
```

The same index, the same pattern, a Seq Scan. Test prefix searches through the driver's prepared
path, not only in `psql`, and check the plan cache mode when one plan is slow only from the app.

## 27.5 Leading wildcards and `pg_trgm`

`LIKE '%r15000%'` has no starting point, so no B-tree can help, and the plan is a Seq Scan:

```sql
SELECT * FROM explain_warm($$SELECT id FROM contact WHERE email LIKE '%r15000%'$$);
```

```text
                  QUERY PLAN
----------------------------------------------
 Seq Scan on contact (actual rows=11 loops=1)
   Filter: (email ~~ '%r15000%'::text)
   Rows Removed by Filter: 199989
   Buffers: shared hit=2091
(4 rows)
```

`pg_trgm` is the fix. A *trigram* is a three-character window; `pg_trgm` indexes every trigram in
every value, and a `LIKE '%r15000%'` becomes "find rows containing all of `r15`, `150`, `500`,
`000`", then a recheck against the real pattern.

```sql
CREATE EXTENSION pg_trgm;
CREATE INDEX contact_email_gin ON contact USING gin (email gin_trgm_ops);
SELECT * FROM explain_warm($$SELECT id FROM contact WHERE email LIKE '%r15000%'$$);
```

```text
                              QUERY PLAN
-----------------------------------------------------------------------
 Bitmap Heap Scan on contact (actual rows=11 loops=1)
   Recheck Cond: (email ~~ '%r15000%'::text)
   Heap Blocks: exact=2
   Buffers: shared hit=15
   ->  Bitmap Index Scan on contact_email_gin (actual rows=11 loops=1)
         Index Cond: (email ~~ '%r15000%'::text)
         Buffers: shared hit=13
(7 rows)
```

A Bitmap Index Scan, 13 buffers for the index and 2 heap pages for 11 rows, against 2,091 pages
for the scan. `pg_trgm` ships with the PostgreSQL contrib package (Chapter 49, *Extensions Worth
Knowing*), and `CREATE EXTENSION` needs the privilege to create it. You have a choice of index type:
GIN or GiST. Build the GiST index too, and compare sizes:

```sql
CREATE INDEX contact_email_gist ON contact USING gist (email gist_trgm_ops);
CREATE INDEX contact_email_btree ON contact (email);
SELECT relname, pg_relation_size(oid) / 1048576 AS mb
FROM   pg_class
WHERE  relname IN ('contact', 'contact_email_btree', 'contact_email_gin', 'contact_email_gist')
ORDER  BY 2, 1;
DROP INDEX contact_email_gist;
```

```text
       relname       | mb
---------------------+----
 contact_email_gin   |  7
 contact_email_btree |  9
 contact             | 16
 contact_email_gist  | 25
(4 rows)
```

GIN is under a third of GiST's size and half the table's. It is also cheaper to *search*: with both
present the planner picks GiST, and Session 27.3 has you measure it reading roughly twenty times
GIN's index buffers for this same query (the exact figure varies from one GiST build to the next,
which is why it is not pasted here). Default to GIN. GiST earns its place for nearest-neighbour
ordering (`ORDER BY email <-> 'x'`), which GIN cannot do. The write cost is real for both: every
insert or update of the column touches one index entry per distinct trigram, so the index is far more
expensive to maintain than a B-tree. Do not put one on a high-churn column without measuring that on
your own workload; Session 27.3 measures the growth on a batch update, and I have not measured more.

**The limits.** A trigram index needs at least one full trigram in the pattern, and two characters do not
have one:

```sql
SELECT show_trgm('r15') AS three_chars, show_trgm('15') AS two_chars;
SET enable_seqscan = off;   -- experiment: force the index to show what it would do
SELECT * FROM explain_warm($$SELECT id FROM contact WHERE email LIKE '%15%'$$);
RESET enable_seqscan;
```

```text
       three_chars       |      two_chars
-------------------------+---------------------
 {"  r"," r1","15 ",r15} | {"  1"," 15","15 "}
(1 row)

                                QUERY PLAN
---------------------------------------------------------------------------
 Bitmap Heap Scan on contact (actual rows=17641 loops=1)
   Recheck Cond: (email ~~ '%15%'::text)
   Rows Removed by Index Recheck: 182359
   Heap Blocks: exact=2091
   Buffers: shared hit=3053
   ->  Bitmap Index Scan on contact_email_gin (actual rows=200000 loops=1)
         Index Cond: (email ~~ '%15%'::text)
         Buffers: shared hit=962
(8 rows)
```

With `enable_seqscan = off` (a labelled experiment, never a setting), the planner *does* use the index for
`'%15%'`, and it is worse: the index returned all 200,000 rows and the recheck discarded 182,359 of
them, and the total is more buffers than the Seq Scan's 2,091. This is why the planner picks the
Seq Scan by itself. A trigram index is a tool for *selective* patterns of three or more characters.
A substring that appears in most rows is the same problem at any length.

The same index accelerates the operators built on it. `ILIKE` and `~*` use it, which a B-tree
cannot do, and so do POSIX regexes, when they contain literal runs of three characters:

```sql
SELECT * FROM explain_warm($$SELECT id FROM contact WHERE email ~* 'R15[0-9]{3}@'$$);
```

```text
                                QUERY PLAN
--------------------------------------------------------------------------
 Bitmap Heap Scan on contact (actual rows=1000 loops=1)
   Recheck Cond: (email ~* 'R15[0-9]{3}@'::text)
   Rows Removed by Index Recheck: 10111
   Heap Blocks: exact=121
   Buffers: shared hit=149
   ->  Bitmap Index Scan on contact_email_gin (actual rows=11111 loops=1)
         Index Cond: (email ~* 'R15[0-9]{3}@'::text)
         Buffers: shared hit=28
(8 rows)
```

The index found 11,111 candidates for what is really a 1,000-row answer, and the recheck threw away
10,111. It has to: the index knows only the literal fragments of the pattern, not the digit-class
structure around them. The regex is still doing the work, on a tenth of the table. That is
"index-assisted", not "index-served". A `lower(col)` expression index stays the right tool for exact
case-insensitive equality (`lower(name) = 'anita rao'`), and only for exactly that expression.

**Fuzzy matching.** `similarity()` compares two strings' trigram sets, `0` to `1`, and the `%`
operator is true when it exceeds `pg_trgm.similarity_threshold`:

```sql
SHOW pg_trgm.similarity_threshold;
SELECT n, round(similarity(n, 'Mira Bannerjee')::numeric, 2) AS score, n % 'Mira Bannerjee' AS passes
FROM   unnest(ARRAY['Meera Banerjee', 'Meena Bannerji', 'Priya Menon']) AS n;
SET pg_trgm.similarity_threshold = 0.6;
SELECT n % 'Mira Bannerjee' AS passes FROM unnest(ARRAY['Meera Banerjee', 'Meena Bannerji']) AS n;
RESET pg_trgm.similarity_threshold;
```

```text
 pg_trgm.similarity_threshold
------------------------------
 0.3
(1 row)

       n        | score | passes
----------------+-------+--------
 Meera Banerjee |  0.50 | t
 Meena Bannerji |  0.36 | t
 Priya Menon    |  0.04 | f
(3 rows)

 passes
--------
 f
 f
(2 rows)
```

The threshold is a session setting and it decides recall: too low returns noise, too high misses
the misspelling you built the feature for. Tune it on real queries. Session 27.3 shows `%` using
the index. Full-text search (Chapter 28) handles words and ranking; trigrams handle typos and fragments.

## 27.6 What regex costs, and what I could not break

A regex without a trigram index is a per-row function call inside a Seq Scan filter. That is fine
for a report or a one-off cleanup and wrong on a hot path.

The textbook warning is catastrophic backtracking: nested quantifiers such as `(a+)+$` against
`aaaa...b`. Postgres uses a hybrid DFA/NFA regex engine rather than a plain backtracker, and I could
not make it misbehave:

```sql
SET statement_timeout = '10s';
SELECT repeat('a', 5000) || 'b' ~ '^(a+)+$'      AS nested_quantifier,
       repeat('a', 5000) || 'b' ~ '^(a|aa)+$'    AS alternation,
       repeat('a', 40)   || 'b' ~ '^(a*)*\1$'    AS with_backreference;
RESET statement_timeout;
```

```text
 nested_quantifier | alternation | with_backreference
-------------------+-------------+--------------------
 f                 | f           | f
(1 row)
```

All three finished under a ten-second cap that would have cancelled them. That describes these
patterns on 15.10, not a guarantee: the manual warns that some regular expressions, especially with
back-references, can take very long. Do not accept patterns from users; accept a term and build the
pattern yourself, and put a `statement_timeout` on the role regardless.

## Summary

- Three languages: `LIKE` (`%`, `_`, whole string), POSIX `~ ~* !~ !~*` (unanchored unless you
  say so), and `SIMILAR TO`, which anchors like `LIKE` but treats `.` as a literal. Avoid it.
- **Escape user input** going into `LIKE`: `%` matches every row (all 6 promo codes above),
  and `_` matched a `DIWALIX10` that a search for `DIWALI_10` should not. Better, use
  `starts_with()` or `strpos()`.
- `regexp_match` returns NULL on no match; `regexp_matches` returns *no rows*. Parse once into a
  typed table, and decide what an unparsed line means: dividing by `count(*)` instead of
  `count(status)` moved an error rate between two answers.
- Prefix search under `en_US.UTF-8` is a Seq Scan (2,091 buffers) with a plain index; with
  `text_pattern_ops` it is six. A `"C"` index serves `LIKE` but not `=` on an `en_US` column;
  declare identifier columns `COLLATE "C"`. `ILIKE` uses neither. A generic plan loses the prefix.
- Leading wildcards need `pg_trgm`: GIN by default (13 index buffers for our query, under a
  third of GiST's size), patterns of three or more selective characters only.
- I could not demonstrate catastrophic backtracking on 15.10. Do not take patterns from users.

**Exercises:** Practice Sessions 27.1–27.3 accompany this chapter and are in the workbook at the back of the book.

**Next:** Chapter 28, *Full-Text Search*, handles words rather than characters: stemming,
ranking, highlighting, and trigrams for typo tolerance.
