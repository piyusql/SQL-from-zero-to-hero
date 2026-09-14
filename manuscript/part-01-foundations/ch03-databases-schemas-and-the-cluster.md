# Chapter 3 — Databases, Schemas, and the Cluster

Every object in PostgreSQL lives at a known address, and that address has three parts.
Most of the time you can ignore two of them, which is exactly why the day you cannot is
so disorienting — a query that works in one session fails in another, a table exists but
cannot be found, two tables with the same name behave differently depending on who is
asking.

None of that is mysterious once you know how names are resolved. That is most of this
chapter. The rest is one decision made when the cluster is created, which almost nobody
thinks about, and which can invalidate every text index you own several years later.

---

## 3.1 Three levels

```text
cluster                     one server process, one port, one data directory
└── database                an isolated namespace; connections attach to exactly one
    └── schema              a named folder inside a database
        └── table           and views, functions, sequences, types, indexes
```

A **cluster** is what you installed in Chapter 2. One `postgres` process tree, one port,
one directory on disk.

A **database** is a hard boundary inside it. A connection belongs to exactly one database
and cannot see any other. This is the part that surprises people:

> **Trap —** you cannot join across databases in PostgreSQL. There is no
> `SELECT ... FROM otherdb.public.customers`. If you need data from two databases in one
> query, you need `postgres_fdw` or `dblink` (Chapter 49), and both are meaningfully
> slower and more awkward than a local join.
>
> This catches out almost everyone arriving from MySQL, where `DATABASE` and `SCHEMA` are
> synonyms and cross-database joins are routine. In PostgreSQL the equivalent of MySQL's
> "database" is a **schema**, not a database. Get this wrong at design time and you have
> built a system whose parts cannot query each other. See Chapter 21.

A **schema** is a namespace within a database. Tables in different schemas may share a
name. Queries can join across them freely, because they are in the same database.

So the fully qualified name of a table is `database.schema.table`, but you almost never
write the first part — it is implied by your connection — and you often skip the second,
which is where `search_path` comes in.

## 3.2 Databases

```sql
CREATE DATABASE retail;
DROP DATABASE retail;
```

Or from the shell, which is usually more convenient:

```bash
createdb retail
dropdb retail
```

Two things about `DROP DATABASE` worth knowing before you need them. It cannot run inside
a transaction block, so you cannot roll it back. It is not quite alone in that —
`DROP TABLESPACE`, `CREATE DATABASE`, `ALTER SYSTEM` and `CREATE INDEX CONCURRENTLY` are
also non-transactional — but it is the one that destroys the most, fastest. And it fails if anyone is connected, which is a feature. When you
genuinely mean it:

```sql
DROP DATABASE retail WITH (FORCE);
```

That terminates other sessions and proceeds. Use it on your laptop. Think hard before
typing it anywhere else.

### Templates

`CREATE DATABASE` **copies an existing database** — `template1` by default.

> **Version note —** how it copies changed in PostgreSQL 15. Older releases did a raw
> file-level copy; 15 and later default to `STRATEGY wal_log`, which copies block by
> block through the write-ahead log. That is safer for replication but slower for a very
> large template. `STRATEGY file_copy` restores the old behaviour if you need it.

That has a useful consequence: anything you put in `template1` appears in every database
you create afterwards. If every database in your organisation needs the same extension or
the same audit function, installing it into `template1` once handles it.

It also has an unpleasant one. Objects you forgot you left in `template1` silently appear
in every new database, including ones created by a restore or by a colleague, and the
cause is not obvious when someone eventually goes looking.

`template0` is the escape hatch — a pristine, never-modified copy:

```sql
CREATE DATABASE clean_slate TEMPLATE template0;
```

You must use `template0` when creating a database with a different encoding or locale
than the cluster default, because `template1` may contain data that is not valid under
the new one.

Copying a database you already have is occasionally very handy:

```sql
CREATE DATABASE retail_backup TEMPLATE retail;
```

No connections to `retail` may be open while this runs. It is a fast, cheap way to
snapshot a development database before doing something you might regret — far quicker
than `pg_dump` for local work. It is not a backup strategy; see Chapter 46 for those.

## 3.3 Schemas

Inside a database, schemas organise objects. They exist for four reasons, in rough order
of how often they matter:

**Separating concerns.** Application tables in `app`, audit trail in `audit`, bulk-load
staging in `staging`, reporting views in `reporting`. The layout itself documents the
system, and it lets you grant a reporting user access to `reporting` and nothing else.

**Permission boundaries.** A schema is a unit you can grant on. `GRANT USAGE ON SCHEMA`
is only the first half — it permits looking names up, not reading anything — so it is
normally paired with `GRANT SELECT ON ALL TABLES IN SCHEMA` and an
`ALTER DEFAULT PRIVILEGES` so that future tables are covered too. Chapter 44 does this
properly. The point is that the schema gives you something to name in the grant.

**Multi-tenancy.** One schema per tenant, identical tables in each. A real strategy with
real trade-offs — it gives you clean isolation and becomes painful somewhere in the low
thousands of tenants, because every schema multiplies your catalog size and your migration
time. Chapter 21 weighs this against the alternatives.

**Avoiding name collisions.** Extensions install into their own schema so their functions
do not collide with yours.

```sql
CREATE SCHEMA app;
CREATE SCHEMA audit;

CREATE TABLE app.customers (
    id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email text NOT NULL UNIQUE
);

CREATE TABLE audit.customers_history (
    id          bigint,
    email       text,
    changed_at  timestamptz NOT NULL DEFAULT now()
);
```

Both tables are called `customers` in conversation and neither collides, because they are
in different schemas.

## 3.4 `search_path`, and how a name becomes an object

When you write an unqualified name — `customers` rather than `app.customers` — PostgreSQL
resolves it using `search_path`, a list of schemas consulted in order. The first match
wins.

```sql
SHOW search_path;
```

```text
   search_path
-----------------
 "$user", public
```

Two entries. `"$user"` expands to a schema named after the connected role, if one exists;
it usually does not, and is skipped. Then `public`.

So on a default setup, unqualified names mean `public.something`.

Change it for your session:

```sql
SET search_path TO app, public;
```

Now `customers` means `app.customers`, and anything not found in `app` falls through to
`public`. Set it per role so it applies to every future connection:

```sql
ALTER ROLE reporting_user SET search_path TO reporting, public;
```

Where a new object *goes* is decided the same way: `CREATE TABLE orders (...)` creates it
in the **first** schema in the path. With the default path, that is `public`, which is why
everything ends up there by accident.

> **Trap —** `search_path` is a session setting, so the same SQL can mean different things
> for different users. This is a genuine security concern, not just an inconvenience. If a
> function runs as a privileged role and calls `customers` unqualified, a user who can
> create a schema earlier in the path can substitute their own table and have the
> privileged code operate on it. This is why `SECURITY DEFINER` functions must pin their
> own path:
>
> ```sql
> CREATE FUNCTION audit_change() RETURNS trigger
> LANGUAGE plpgsql SECURITY DEFINER
> SET search_path = app, pg_temp
> AS $$ ... $$;
> ```
>
> Chapter 42 covers this properly. It is one of the few genuine footguns in PostgreSQL's
> security model, and it is entirely avoidable.

In application code and migrations, qualify names explicitly. `app.customers` means one
thing regardless of who runs it, and the small verbosity cost buys you the elimination of
a whole category of confusion.

### The `public` schema changed in PostgreSQL 15

Historically, every user could create objects in `public`. This was a long-standing
complaint — any user who could connect could create tables in a shared namespace, with the
name-shadowing consequences just described.

> **Version note —** in PostgreSQL 15 and later, the `public` schema is owned by the
> `pg_database_owner` role and ordinary users **cannot** create objects in it by default.
> On PostgreSQL 14 and earlier they could.
>
> This is the change most likely to bite you when moving an application to 15+. It
> presents as `ERROR: permission denied for schema public` on a deployment that worked
> for years. The fix is an explicit grant:
>
> ```sql
> GRANT CREATE ON SCHEMA public TO app_user;
> ```
>
> Better: stop using `public` for application objects entirely. Create a schema you own
> and control, and grant on that.

## 3.5 Encoding and collation

Two settings are fixed when a database is created. One is nearly always correct by
default. The other is a genuine trap, and it is the reason this section exists.

```sql
SELECT datname, pg_encoding_to_char(encoding) AS encoding,
       datcollate, datctype
FROM   pg_database;
```

```text
  datname  | encoding |   datcollate   |    datctype
-----------+----------+----------------+----------------
 postgres  | UTF8     | en_US.UTF-8    | en_US.UTF-8
 retail    | UTF8     | en_US.UTF-8    | en_US.UTF-8
```

**Encoding** is how characters are stored as bytes. Use `UTF8`. There is no modern reason
to choose anything else, and it is almost always the default already. Encoding cannot be
changed after creation — you would dump, recreate, and reload.

**Collation** is how text is *ordered and compared*. `ORDER BY name` consults it. So does
every B-tree index on a text column, because an index is a sorted structure.

That second fact is the whole problem.

Under `en_US.UTF-8`, sorting is roughly dictionary order: case-insensitive-ish,
punctuation largely ignored. Under `C`, sorting is by raw byte value, so all uppercase
letters sort before all lowercase.

```sql
SELECT w FROM unnest(ARRAY['apple','Banana','cherry']) AS w
ORDER  BY w COLLATE "en_US";
```

```text
   w
--------
 apple
 Banana
 cherry
(3 rows)
```

```sql
SELECT w FROM unnest(ARRAY['apple','Banana','cherry']) AS w
ORDER  BY w COLLATE "C";
```

```text
   w
--------
 Banana
 apple
 cherry
(3 rows)
```

Different answers from the same data. Both correct, under different rules.

> **Trap —** note the `FROM unnest(...) AS w` rather than
> `SELECT unnest(...) AS w ... ORDER BY w COLLATE "C"`. A bare `ORDER BY w` may reference
> an output alias, but the moment you apply `COLLATE` you have written an *expression*,
> and expressions are resolved against the input columns, where no `w` exists. You get
> `ERROR: column "w" does not exist`, which is a confusing message for what is really a
> scoping rule. Putting the function in `FROM` makes `w` a genuine column and the problem
> disappears.

### Why this can break your indexes

On Linux, the default collations come from the operating system's C library, glibc. The
ordering rules are therefore defined *outside the database*.

When glibc changes its rules — as it did substantially in version 2.28, shipped in RHEL 8
and Debian 10 — the sort order changes underneath you. Every B-tree index built on a text
column *under an affected libc collation* is now sorted according to rules the database no
longer follows. The index is silently wrong. Indexes using `C`, `POSIX` or an ICU
collation are unaffected, which is the whole argument of the next section.

The symptoms are ugly precisely because nothing errors. A `WHERE name = 'x'` that uses the
index returns no rows while the same query with a sequential scan returns one. Unique
constraints stop catching duplicates. And the trigger is not a database upgrade — it is an
operating system upgrade, or moving a data directory to a machine with a different distro,
or a base image bump in a Dockerfile that nobody thought of as a database change.

Modern PostgreSQL detects the mismatch and warns:

```text
WARNING:  database "retail" has a collation version mismatch
DETAIL:  The database was created using collation version 2.17,
         but the operating system provides version 2.31.
HINT:  Rebuild all objects in this database that use the default collation
```

That warning means: reindex everything touching text, now. Two statements, and people
routinely run only the first — after which the warning persists and everyone assumes it is
stuck:

```sql
REINDEX DATABASE retail;                            -- rebuild under the new rules
ALTER DATABASE retail REFRESH COLLATION VERSION;    -- record that you have done so
```

The `REINDEX` fixes the data. The `ALTER` updates the version PostgreSQL recorded when the
database was created, which is what silences the warning. Do not run the second without
the first — that clears the alarm while leaving every index still wrong.

### What to do about it

Three options, in descending order of how much I recommend them.

**Use ICU collations.** PostgreSQL can use the ICU library instead of glibc. ICU
collations are explicitly versioned, so PostgreSQL knows exactly which version built an
index and can tell you precisely what is affected. PostgreSQL 15 made ICU usable as a
database-level default:

```sql
CREATE DATABASE retail
    LOCALE_PROVIDER icu
    ICU_LOCALE 'en-US'
    TEMPLATE template0;
```

**Use `C` collation deliberately**, where linguistic ordering does not matter. Byte
ordering never changes, so this class of bug cannot occur. It is also measurably faster —
comparing bytes beats consulting locale rules. For columns holding identifiers, codes,
hashes, emails or slugs, `C` is often the right answer *and* the fast one. You can set it
per column:

```sql
CREATE TABLE api_keys (
    key   text COLLATE "C" PRIMARY KEY,
    label text                            -- still linguistic
);
```

**Accept glibc and manage it operationally** — pin your base image, treat OS upgrades as
database events, and reindex when the warning appears. This is what most installations
do, and it works right up until the one time somebody forgets.

> **In production —** this belongs in your runbook, not your memory. Any change to the
> host OS, base image, or the machine a data directory is attached to is a potential
> collation change. Chapter 48 covers monitoring; the collation version mismatch warning
> is one worth alerting on, because by the time a user notices, you have been returning
> wrong answers for a while.

---

## Summary

- Three levels: cluster → database → schema. A connection attaches to one database and
  cannot see the others.
- **You cannot join across databases.** PostgreSQL's equivalent of MySQL's "database" is a
  schema. Getting this wrong at design time is expensive.
- `CREATE DATABASE` copies a template. `template1` propagates whatever you leave in it;
  `template0` is pristine and required for non-default encodings.
- Schemas separate concerns, carry permissions, and can isolate tenants. Use them —
  `public` should not be where your application lives.
- `search_path` resolves unqualified names, first match wins, and new objects go in the
  first entry. It is per-session, which makes it a security consideration for
  `SECURITY DEFINER` functions.
- **PostgreSQL 15 removed the default right to create objects in `public`.** Expect this
  when upgrading an older application.
- Encoding should be UTF8 and cannot be changed later.
- Collation defines text ordering, and therefore the physical order of every text B-tree
  index. With glibc, an OS upgrade can change those rules and silently invalidate indexes.
  Prefer ICU, or use `C` deliberately where linguistic order does not matter.

**Exercises:** Practice Sessions 3.1–3.3 accompany this chapter and are in
the workbook at the back of the book.

**Next:** Part II begins. Chapter 4 creates tables in earnest — and introduces, early,
which `ALTER TABLE` operations are free and which rewrite the entire table, because that
distinction shapes every schema decision you make from here to Chapter 52.
