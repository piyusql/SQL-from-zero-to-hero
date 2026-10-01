# Chapter 28 — Full-Text Search

Chapter 27 showed how to make `LIKE '%diya%'` fast with a trigram index. That solves
*substring* search. It does not solve what a shopper actually types: `cooking` should find
"Cooks rice evenly", `pressure cooker` should find a cooker whatever order the words
appear in, and the results should come back best-first. Substring matching knows nothing
about words, and words are the whole game.

Postgres has shipped a word-aware search engine in core since 8.3. It is good enough
for most catalogs and internal tools, and it stops being good enough at a point you
should recognise before you hit it. This chapter builds a search over a 60,000-product
catalog, measures what each piece buys, and states the limits plainly. The catalog is invented (there is no description column in `retail`): the
generator is the Setup of Practice Session 28.1 in the workbook, and every number below
comes from that exact script, which is deterministic (`md5`, not `random()`).

```bash
createdb ch28_scratch
psql -d ch28_scratch     # then run the Session 28.1 Setup
```

```sql
\pset null '(null)'
SET max_parallel_workers_per_gather = 0;   -- pin plans: no parallel workers in any plan below
SELECT id, name, category, description FROM catalog WHERE id = 2;
```

```text
 id |                    name                    | category |                                                                    description                                                                     
----+--------------------------------------------+----------+----------------------------------------------------------------------------------------------------------------------------------------------------
  2 | Handcrafted Pressure Cooker from Moradabad | kitchen  | Handcrafted pressure cooker made of stainless steel by artisans in Moradabad. Cooked food stays warm for hours. Easy to clean and dishwasher safe.
(1 row)
```

---

## 28.1 What gets indexed: `tsvector` and `tsquery`

Full-text search does not compare your string to the shopper's. It converts both to a
normal form and compares those. A **`tsvector`** is a sorted list of *lexemes* with
positions; a **`tsquery`** is a boolean expression over lexemes; `@@` asks whether one
matches the other. The conversion is done by a **text search configuration**, which
splits the text into tokens and passes each through dictionaries. Compare the `english`
configuration with `simple`:

```sql
SELECT to_tsvector('english', 'Cooks rice and dal; not suitable for induction cooktops.') AS english;
SELECT to_tsvector('simple',  'Cooks rice and dal; not suitable for induction cooktops.') AS simple;
```

```text
                           english
--------------------------------------------------------------
 'cook':1 'cooktop':9 'dal':4 'induct':8 'rice':2 'suitabl':6
(1 row)

                                           simple
--------------------------------------------------------------------------------------------
 'and':3 'cooks':1 'cooktops':9 'dal':4 'for':7 'induction':8 'not':5 'rice':2 'suitable':6
(1 row)
```

Three things happened in `english`. Words were **stemmed** (`Cooks` became `cook`,
`suitable` became `suitabl`, which is not a word and is not meant to be). **Stop words**
(`and`, `for`, `not`) were dropped, though their positions still count: `induct` is at 8,
not 6. And case was folded. `simple` only lowercases and splits. (`ts_debug` shows each token's
dictionary decision.)

Now count what stemming buys over Chapter 27's
`ILIKE`, on the same 60,000 rows:

```sql
SELECT count(*) FILTER (WHERE description ILIKE '%cooking%') AS ilike_cooking,
       count(*) FILTER (WHERE to_tsvector('english', description)
                        @@ plainto_tsquery('english', 'cooking')) AS fts_english,
       count(*) FILTER (WHERE to_tsvector('simple', description)
                        @@ plainto_tsquery('simple', 'cooking')) AS fts_simple
FROM   catalog;
```

```text
 ilike_cooking | fts_english | fts_simple 
---------------+-------------+------------
          9354 |       26106 |       9354
(1 row)
```

`ILIKE` and the `simple` configuration find only the 9,354 rows that contain the literal
word. `english` finds 26,106, because `cooks`, `cooked` and `cooking` all reduce to
`cook`. That is the feature, and also the first surprise: **stemming widens results in
ways you did not ask for.** A search for "cooker" and one for "cook" are different
lexemes; a search for "induction" also finds "inducted".

The stop-word list has its own failure mode:

```sql
SELECT to_tsvector('english', 'to be or not to be') AS doc,
       plainto_tsquery('english', 'to be or not to be') AS query;
```

```text
 doc | query 
-----+-------
     | 
(1 row)
```

Every word is a stop word, so both sides are empty and nothing matches. A brand called
"The Body Shop" will not be found by name under `english`. Use `simple` for fields like
brand and SKU, where every token matters.

## 28.2 Four ways to build a query

Most tutorials teach `to_tsquery`. In an application it is the wrong default, because it
expects a *query language* and shoppers do not type one:

```sql
SELECT to_tsquery('english', 'pressure cooker');
```

```text
ERROR:  syntax error in tsquery: "pressure cooker"
```

Postgres has four constructors, and they differ in one question: what do they do with raw
user input?

```sql
SELECT plainto_tsquery('english', 'pressure cooker')  AS plain,
       phraseto_tsquery('english', 'pressure cooker') AS phrase,
       websearch_to_tsquery('english', '"pressure cooker" -induction OR tawa') AS web;
SELECT websearch_to_tsquery('english', 'rice & (dal | ') AS survives_junk;
SELECT to_tsquery('english', 'rice & (dal | ');
```

```text
        plain         |         phrase         |                     web                     
----------------------+------------------------+---------------------------------------------
 'pressur' & 'cooker' | 'pressur' <-> 'cooker' | 'pressur' <-> 'cooker' & !'induct' | 'tawa'
(1 row)

 survives_junk  
----------------
 'rice' & 'dal'
(1 row)

ERROR:  no operand in tsquery: "rice & (dal | "
```

`plainto_tsquery` ANDs every word. `phraseto_tsquery` requires them adjacent and in order
(`<->` means "followed by"). `websearch_to_tsquery` reads quotes as phrases, `-` as NOT and
`OR` as OR, and **never raises a syntax error**, which is why it is the one to put behind
a search box. `to_tsquery` is for queries you assemble yourself in code, and it is the
only one with **prefix matching**, for type-ahead:

```sql
SELECT count(*) FILTER (WHERE doc @@ to_tsquery('english', 'cook'))   AS cook,
       count(*) FILTER (WHERE doc @@ to_tsquery('english', 'cook:*')) AS cook_prefix
FROM   (SELECT to_tsvector('english', description) AS doc FROM catalog) s;
```

```text
 cook  | cook_prefix 
-------+-------------
 26106 |       34751
(1 row)
```

`cook:*` matches any lexeme *starting with* `cook`, so it also picks up `cooker` and
`cooktop`. Phrases respect the stop-word gaps from earlier:

```sql
SELECT phraseto_tsquery('english', 'suitable for induction');
```

```text
    phraseto_tsquery    
------------------------
 'suitabl' <2> 'induct'
(1 row)
```

`<2>` means "exactly two positions later", the dropped `for` still occupying one. That is
correct behaviour and worth knowing when a phrase search unexpectedly misses because the
text and the query disagree about a stop word.

> **Trap —** Do not hand raw input to `to_tsquery`. Your search box will return a 500 for
> `c++`, `rice &` or an apostrophe. Use `websearch_to_tsquery`.

## 28.3 Storing and indexing it

The obvious query computes the vector for every row, on every search:

```sql
\o /dev/null
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)   -- warm-up, discarded
SELECT id FROM catalog
WHERE  to_tsvector('english', description) @@ plainto_tsquery('english', 'tiffin diwali');
\o
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT id FROM catalog
WHERE  to_tsvector('english', description) @@ plainto_tsquery('english', 'tiffin diwali');
```

```text
                                            QUERY PLAN
--------------------------------------------------------------------------------------------------
 Seq Scan on catalog (actual rows=509 loops=1)
   Filter: (to_tsvector('english'::regconfig, description) @@ '''tiffin'' & ''diwali'''::tsquery)
   Rows Removed by Filter: 59491
   Buffers: shared hit=1738
(4 rows)
```

Every row is read and re-parsed to find 509. An expression index on
`to_tsvector('english', description)` would fix the plan, but a stored column is better:
it can combine several fields, it is visible to `ts_rank` later, and it keeps the
parsing cost on writes rather than reads. Chapter 23 introduced generated columns; the
catch here is that the configuration name must be spelled out:

```sql
SELECT pg_size_pretty(pg_relation_size('catalog')) AS heap_before;
ALTER TABLE catalog ADD COLUMN doc tsvector
  GENERATED ALWAYS AS (to_tsvector(description)) STORED;
```

```text
 heap_before
-------------
 14 MB
(1 row)

ERROR:  generation expression is not immutable
```

The one-argument `to_tsvector` uses `default_text_search_config`, a setting that can
change per session, so it is only `STABLE`. The two-argument form with a literal
configuration is `IMMUTABLE`, which is what a generated column and an index both require.

```sql
ALTER TABLE catalog ADD COLUMN doc tsvector
  GENERATED ALWAYS AS (to_tsvector('english', name || ' ' || description)) STORED;
CREATE INDEX catalog_doc_gin ON catalog USING gin (doc);
ANALYZE catalog;
SELECT pg_size_pretty(pg_relation_size('catalog'))         AS heap_after,
       pg_size_pretty(pg_relation_size('catalog_doc_gin')) AS gin;
\o /dev/null
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)   -- warm-up run, output discarded
SELECT id FROM catalog WHERE doc @@ plainto_tsquery('english', 'tiffin diwali');
\o
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT id FROM catalog WHERE doc @@ plainto_tsquery('english', 'tiffin diwali');
```

```text
 heap_after |   gin
------------+---------
 27 MB      | 2200 kB
(1 row)

                              QUERY PLAN
----------------------------------------------------------------------
 Bitmap Heap Scan on catalog (actual rows=509 loops=1)
   Recheck Cond: (doc @@ '''tiffin'' & ''diwali'''::tsquery)
   Heap Blocks: exact=476
   Buffers: shared hit=484
   ->  Bitmap Index Scan on catalog_doc_gin (actual rows=509 loops=1)
         Index Cond: (doc @@ '''tiffin'' & ''diwali'''::tsquery)
         Buffers: shared hit=8
 Planning:
   Buffers: shared hit=1
(9 rows)
```

The index probe cost 8 buffers and the whole query 484, against 1,738 for the scan.
Two costs come with that: the stored vector nearly **doubled the heap** (14 MB to 27 MB,
every lexeme with every position), and the GIN index adds 2.2 MB. That also makes the
1,738 figure an unfair yardstick, since a scan of the wider table now reads about 3,400
pages. The evidence to trust is the plan: 509 rows out of 60,000, from 476 heap pages.

A GIN index answers "which rows contain these words"; it cannot make a common word
cheap. `rice` matches 9,953 rows, and the plan in the next section visits 3,286 heap
pages for it, nearly the whole table.

> **In production —** GIN is write-hungry. With `fastupdate` on (the default), inserts
> land in a pending list that is merged later, which keeps writes cheap and defers the
> work to autovacuum or to whichever insert overflows `gin_pending_list_limit` (4MB).
> Session 28.1 makes the pending list visible with `pageinspect`. On a table that takes
> bulk loads, budget for that merge landing on an unlucky insert.

## 28.4 Ranking, weights and headlines

A match is boolean; a results page needs an order. Two things to fix first. A hit in the
product *name* should beat a hit buried in a sentence, so build the vector from weighted
parts (`setweight` labels lexemes `A` through `D`, and the default weights are 1.0, 0.4,
0.2, 0.1). On PostgreSQL 15, changing a generated expression means dropping and re-adding
the column:

> **Version note —** PostgreSQL 17 adds `ALTER COLUMN ... SET EXPRESSION`. On 15 and 16,
> `DROP COLUMN` and `ADD COLUMN` rewrite the table.

```sql
DROP INDEX catalog_doc_gin;
ALTER TABLE catalog DROP COLUMN doc;
ALTER TABLE catalog ADD COLUMN doc tsvector GENERATED ALWAYS AS (
    setweight(to_tsvector('english', name), 'A') ||
    setweight(to_tsvector('english', description), 'B')) STORED;
CREATE INDEX catalog_doc_gin ON catalog USING gin (doc);
ANALYZE catalog;
SELECT doc FROM catalog WHERE id = 1;
```

```text
                                                                                            doc                                                                                             
--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
 'artisan':13B 'bag':28B 'bengaluru':20B 'cloth':27B 'come':23B 'custom':18B 'jute':11B 'kutch':5A,15B 'love':16B 'made':9B 'mat':3A,8B 'organ':1A,6B 'pune':22B 'reusabl':26B 'yoga':2A,7B
(1 row)
```

`kutch` appears at position 5 with weight A (in the name) and 15 with B. Now rank a
two-word `OR` query and count how many *distinct scores* come back:

```sql
SELECT round(ts_rank(doc, q)::numeric, 4) AS rank, count(*)
FROM   catalog, websearch_to_tsquery('english', 'tiffin OR rice') AS q
WHERE  doc @@ q GROUP BY 1 ORDER BY 1 DESC;
```

```text
  rank  | count 
--------+-------
 0.4863 |    19
 0.4559 |   470
 0.3344 |  2497
 0.1520 |   446
 0.1216 |  9018
(5 rows)
```

12,450 documents collapse into five scores. The A-weight tiffin matches sit above
the description-only rice matches, which is the weights working, and within a tier the
order is **arbitrary** unless you add a tiebreaker: `ORDER BY rank DESC, id`, or the
page will reshuffle between requests. This is the honest state of Postgres relevance:
`ts_rank` scores term frequency and weights, with optional length normalisation, and
that is all. There is no inverse document frequency, so a rare word and a common word
count the same. `ts_rank_cd` adds *cover density*, rewarding query words that sit close
together. It is worth trying for phrase-like queries, and it produces the same kind of
ties.

Ranking has a cost the match itself does not. `LIMIT 10` on a match can stop early, but
`ORDER BY ts_rank(...)` cannot know the best ten until it has scored all of them:

```sql
\o /dev/null
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)   -- warm-up, discarded
SELECT id FROM catalog WHERE doc @@ plainto_tsquery('english', 'rice') LIMIT 10;
\o
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT id FROM catalog WHERE doc @@ plainto_tsquery('english', 'rice') LIMIT 10;
\o /dev/null
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT id FROM catalog WHERE doc @@ plainto_tsquery('english', 'rice')
ORDER BY ts_rank(doc, plainto_tsquery('english', 'rice')) DESC, id LIMIT 10;
\o
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT id FROM catalog WHERE doc @@ plainto_tsquery('english', 'rice')
ORDER BY ts_rank(doc, plainto_tsquery('english', 'rice')) DESC, id LIMIT 10;
```

```text
                     QUERY PLAN
----------------------------------------------------
 Limit (actual rows=10 loops=1)
   Buffers: shared hit=4
   ->  Seq Scan on catalog (actual rows=10 loops=1)
         Filter: (doc @@ '''rice'''::tsquery)
         Rows Removed by Filter: 57
         Buffers: shared hit=4
 Planning:
   Buffers: shared hit=1
(8 rows)

                                    QUERY PLAN
-----------------------------------------------------------------------------------
 Limit (actual rows=10 loops=1)
   Buffers: shared hit=3291
   ->  Sort (actual rows=10 loops=1)
         Sort Key: (ts_rank(doc, '''rice'''::tsquery)) DESC, id
         Sort Method: top-N heapsort  Memory: 25kB
         Buffers: shared hit=3291
         ->  Bitmap Heap Scan on catalog (actual rows=9953 loops=1)
               Recheck Cond: (doc @@ '''rice'''::tsquery)
               Heap Blocks: exact=3286
               Buffers: shared hit=3291
               ->  Bitmap Index Scan on catalog_doc_gin (actual rows=9953 loops=1)
                     Index Cond: (doc @@ '''rice'''::tsquery)
                     Buffers: shared hit=5
 Planning:
   Buffers: shared hit=1
(15 rows)
```

`LIMIT 10` alone read 4 buffers. Adding the ranking read 3,291, every page holding a
match, to score 9,953 documents and keep ten. `ts_rank` runs against the stored vector
in the heap, not the index, so the index cannot help. If your users search common words,
ranking is where the latency goes, and the fixes are architectural: cap the candidate set
(a subquery with `LIMIT 1000` before ranking, accepting that it ranks an arbitrary
thousand), add filters that shrink the match set (category, in-stock), or admit that
common-word ranked search is a job for a real search engine.

Then the snippet. `ts_headline` re-parses the *original text*, not the stored vector, so it
is meant for the ten rows you are about to display and never for the whole match set:

```sql
SELECT id, ts_headline('english', description, q,
       'StartSel=<b>, StopSel=</b>, MaxFragments=1, MaxWords=12, MinWords=5') AS snippet
FROM   catalog, websearch_to_tsquery('english', 'induction cooktops') AS q
WHERE  doc @@ q ORDER BY id LIMIT 3;
```

```text
 id |                                       snippet                                        
----+--------------------------------------------------------------------------------------
  3 | small kitchens. Not suitable for <b>induction</b> <b>cooktops</b>
 12 | across India. Not suitable for <b>induction</b> <b>cooktops</b>
 29 | Mysuru. Not suitable for <b>induction</b> <b>cooktops</b>. Cooks rice and dal evenly
(3 rows)
```

Call it for the rows on the page you are displaying, never over the whole match set.

> **Trap —** `ts_headline` output is HTML-shaped but not HTML-safe. It does not escape
> the source text. If descriptions can hold user-supplied markup, escape first and highlight
> second, or you have built an XSS hole with a nice yellow marker.

## 28.5 Languages, accents, and what Postgres does not ship

Configurations are per language, and Indian-language coverage is thin. PostgreSQL 15.10
ships three stemmers:

```sql
SELECT cfgname FROM pg_ts_config
WHERE  cfgname IN ('hindi', 'tamil', 'nepali', 'bengali', 'marathi', 'telugu') ORDER BY 1;
```

```text
 cfgname 
---------
 hindi
 nepali
 tamil
(3 rows)
```

There is nothing for Bengali, Marathi, Telugu, Kannada, Malayalam or Gujarati; those fall
back to `simple`. And `hindi` is a stemmer, not a search engine. Compare it with `simple`:

```sql
SELECT to_tsvector('hindi',  'स्टील का के की कुकरों और लड़कियाँ लड़की') AS hindi;
SELECT to_tsvector('simple', 'स्टील का के की कुकरों और लड़कियाँ लड़की') AS simple;
SELECT to_tsvector('hindi', 'कुकर') @@ plainto_tsquery('hindi', 'कुकरों') AS plural_hit,
       to_tsvector('hindi', 'कुकर') @@ plainto_tsquery('hindi', 'कुक्कर') AS spelling_hit;
```

```text
                    hindi
---------------------------------------------
 'और':6 'क':2,3,4 'कुकर':5 'लड़क':7,8 'स्टील':1
(1 row)

                              simple
------------------------------------------------------------------
 'और':6 'का':2 'की':4 'कुकरों':5 'के':3 'लड़कियाँ':7 'लड़की':8 'स्टील':1
(1 row)

 plural_hit | spelling_hit
------------+--------------
 t          | f
(1 row)
```

The stemmer does its job on inflection: `कुकरों` (plural) reduces to `कुकर`, and both forms
of "girl" reduce to `लड़क`. It has no working stop-word list: `का`, `के` and `की` all
collapse to the single lexeme `क`, which then matches any description containing any of
them, and `और` ("and") is indexed as a content word. Spelling variants are invisible to
it (`कुक्कर` misses `कुकर`), and transliteration variants (`kurta`, `kurtha`, `kurata`)
are just different strings. For Marathi, Bengali and the rest you are on `simple` plus
whatever normalisation the application does, a `thesaurus` dictionary for the variants
you know about, or the trigram approach in 28.6.

Accents are a smaller version of the same problem. The `unaccent` extension strips them,
and it will not go into a generated column as-is:

```sql
CREATE EXTENSION unaccent;
CREATE TABLE t_un (a text, d tsvector
  GENERATED ALWAYS AS (to_tsvector('english', unaccent(a))) STORED);
SELECT provolatile FROM pg_proc WHERE proname = 'unaccent' AND pronargs = 1;
```

```text
ERROR:  generation expression is not immutable
 provolatile 
-------------
 s
(1 row)
```

`unaccent` is `STABLE` because its behaviour depends on a rules file that an administrator
can edit. The standard workaround is an `IMMUTABLE` wrapper that pins the dictionary:

```sql
CREATE FUNCTION immutable_unaccent(text) RETURNS text
  LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT
  AS $$ SELECT public.unaccent('public.unaccent', $1) $$;
CREATE TABLE t_un (a text, d tsvector
  GENERATED ALWAYS AS (to_tsvector('english', immutable_unaccent(a))) STORED);
INSERT INTO t_un VALUES ('Crème brûlée ramekin set');
SELECT d, d @@ plainto_tsquery('english', immutable_unaccent('creme brulee')) AS hit FROM t_un;
```

```text
CREATE FUNCTION
CREATE TABLE
INSERT 0 1
                    d                    | hit 
-----------------------------------------+-----
 'brule':2 'creme':1 'ramekin':3 'set':4 | t
(1 row)
```

The wrapper is a promise to Postgres that you will not change the rules file. If you do,
stored vectors and indexes silently disagree with new queries, and you must rebuild
them. That is the honest price of the trick, and why the rules file belongs in change
control.

## 28.6 Typo tolerance: full-text plus trigrams

Full-text search has no notion of a near miss. Misspell one word and an AND query returns
nothing:

```sql
SELECT count(*) AS typed_hits FROM catalog
WHERE  doc @@ websearch_to_tsquery('english', 'presure cooker');
```

```text
 typed_hits 
------------
          0
(1 row)
```

The fix uses each tool for what it is good at. Full-text finds *documents*; `pg_trgm`
(Chapter 27) measures *similarity between short strings*. So put the corpus's own
vocabulary in a table with `ts_stat`, and match the mistyped word against **that**, not
against 60,000 descriptions:

```sql
CREATE EXTENSION pg_trgm;
CREATE TABLE lexemes AS SELECT word, ndoc FROM ts_stat('SELECT doc FROM catalog');
CREATE INDEX lexemes_trgm ON lexemes USING gin (word gin_trgm_ops);
SELECT t.word AS typed, l.word AS fixed, round(similarity(t.word, l.word)::numeric, 3) AS sim
FROM (VALUES ('presure'), ('dupata'), ('tiffn'), ('kurtha')) t(word)
CROSS JOIN LATERAL (SELECT word FROM lexemes WHERE word % t.word
                    ORDER BY similarity(word, t.word) DESC, ndoc DESC LIMIT 1) l;
```

```text
  typed  |  fixed  |  sim  
---------+---------+-------
 presure | pressur | 0.455
 dupata  | dupatta | 0.667
 tiffn   | tiffin  | 0.444
 kurtha  | kurta   | 0.444
(4 rows)
```

The vocabulary is 113 lexemes here, so the trigram index is decoration; on a real catalog
with hundreds of thousands of distinct tokens it is what keeps the lookup at
milliseconds (the index mechanics are Chapter 27's). `ts_stat` gives the lexemes in stored
(stemmed) form, which the function below exploits: it stems each typed word, keeps it if
it is already a lexeme, otherwise substitutes the nearest one, and builds the query
against the `simple` configuration so nothing is stemmed twice.

```sql
CREATE FUNCTION fix_query(q text) RETURNS tsquery LANGUAGE sql STABLE AS $$
  WITH typed AS (
    SELECT w, ord, (ts_lexize('english_stem', w))[1] AS stem
    FROM unnest(string_to_array(lower(trim(q)), ' ')) WITH ORDINALITY AS t(w, ord)
    WHERE cardinality(ts_lexize('english_stem', w)) > 0),
  fixed AS (
    SELECT t.ord, coalesce(e.word, n.word, t.stem) AS lexeme
    FROM typed t
    LEFT JOIN lexemes e ON e.word = t.stem
    LEFT JOIN LATERAL (SELECT word FROM lexemes
                       WHERE e.word IS NULL AND word % t.stem
                       ORDER BY similarity(word, t.stem) DESC, ndoc DESC LIMIT 1) n ON true)
  SELECT to_tsquery('simple', string_agg(quote_literal(lexeme), ' & ' ORDER BY ord)) FROM fixed
$$;

SELECT fix_query('presure cooker') AS fixed, fix_query('the kurtha for diwali') AS with_stopwords;
SELECT count(*) AS fixed_hits FROM catalog WHERE doc @@ fix_query('presure cooker');
SELECT count(*) AS correct_spelling FROM catalog
WHERE  doc @@ websearch_to_tsquery('english', 'pressure cooker');
```

```text
        fixed         |   with_stopwords   
----------------------+--------------------
 'pressur' & 'cooker' | 'kurta' & 'diwali'
(1 row)

 fixed_hits 
------------
       3069
(1 row)

 correct_spelling 
------------------
             3069
(1 row)
```

The corrected query returns exactly what the correctly spelt one does. It also fails, in
one way you should know about, because similarity measures spelling and not intent:

```sql
SELECT fix_query('cookr') AS fixed, count(*) AS hits,
       round(similarity('cookr', 'cook')::numeric, 3)   AS to_cook,
       round(similarity('cookr', 'cooker')::numeric, 3) AS to_cooker
FROM   catalog WHERE doc @@ fix_query('cookr');
```

```text
 fixed  | hits  | to_cook | to_cooker
--------+-------+---------+-----------
 'cook' | 26106 |   0.571 |     0.444
(1 row)
```

`cookr` is closer to `cook` (0.571) than to `cooker` (0.444), so the shopper who meant
"cooker" gets 26,106 products about cooking. The `ndoc` tiebreaker only helps on ties.
Real systems either show "Did you mean ...?" and let the user choose, or gate
auto-correction on a high similarity threshold and a lexeme that appears in enough
documents. A word with no near neighbour is left as typed, so it returns nothing rather
than something wrong.

## 28.7 The honest limits

What you now have is a good product search for a single-language catalog: stemming,
phrases, prefixes, weighted fields, snippets, and typo correction assembled from two
extensions. Know where it ends.

- **Relevance is crude.** No IDF, no tuning by click data, no learning to rank, no
  per-field boosts beyond four fixed weights. Five score tiers for 12,450
  matches is what you get.
- **Synonyms need work.** `sofa` and `couch` are different lexemes unless you write a
  thesaurus dictionary by hand and keep it current.
- **No facets.** "Results per category" is a `GROUP BY` over every match.
- **Common words are expensive to rank**, as the 3,291-buffer plan showed.
- **One language per configuration.** A multilingual catalog needs a `regconfig` column
  and a vector built per row, and most Indian languages have no stemmer at all.

I would stay in Postgres when the data is already here and "find the right product by
its words" is the requirement. The gain is real: results never lag the row, there is no
second system to run, and one query joins search with prices and stock. I would move to
OpenSearch or Elasticsearch when relevance itself is a product feature, or when you need
low-latency facet counts, managed synonyms or Indian-language analysers, and I would keep
Postgres as the source of truth and feed the search engine from it. Chapter 49,
*Extensions Worth Knowing*, covers other extensions in the same territory.

## Summary

- A `tsvector` is stemmed lexemes with positions; a `tsquery` is a boolean over lexemes;
  `@@` matches them. Stemming turned 9,354 literal `cooking` matches into 26,106.
- Stop words drop out but keep their positions (`<2>`). A text made entirely of stop
  words becomes an empty vector.
- Put `websearch_to_tsquery` behind a search box; `to_tsquery` raises syntax errors on raw
  input and is for prefix (`:*`) queries you build yourself.
- Store the vector in a generated column built with the **two-argument**
  `to_tsvector('english', ...)`; the one-argument form is not immutable. Index it with
  GIN: the plan went from a Seq Scan (1,738 buffers) to a Bitmap Index Scan (484), at the
  price of doubling the heap and a 2.2 MB index.
- Ranking is crude (five scores for 12,450 matches) and forces a read of every matching
  row: 3,291 buffers against 4 for the same query without `ORDER BY`. Add a tiebreaker.
- `ts_headline` is for the page you display, not the result set.
- PostgreSQL 15 ships `hindi`, `tamil` and `nepali` stemmers and nothing else Indian;
  `hindi` has no usable stop words. `unaccent` needs an immutable wrapper you must treat
  as a contract.
- Typos: match the word against `ts_stat` lexemes with `pg_trgm`, then run the corrected
  full-text query. It is right about spelling and blind to intent.

**Exercises:** Practice Sessions 28.1–28.3 accompany this chapter and are in the
workbook at the back of the book.

**Next:** Part VI closes here. Part VII opens with Chapter 29, *Transactions in Practice*:
`BEGIN`, `COMMIT`, savepoints, transactional DDL, and why an idle-in-transaction session is
a hazard.
