# Chapter 21 — Structuring a New Enterprise Database

Chapter 18 decided which table each fact lives in. This chapter decides where the *tables* live, who may touch them, how several customers share them, and how the arrangement reaches production without DDL typed into a prompt. All of it is expensive to change: a schema name is baked into every query, a tenancy model into every key.

Everything below writes, so it runs in scratch databases and roles. Roles are cluster-wide, so each carries a `ch21_` prefix and the last block drops them.

```bash
psql -d retail -Atq -c "\copy (SELECT name, email, city FROM customers WHERE id <= 40 ORDER BY id) TO '/tmp/ch21_customers.csv' CSV"
createdb ch21_erp
psql -d ch21_erp
```

---

## 21.1 Schemas are the unit of organization

A new database has one schema, `public`, and the path of least resistance is to put
everything in it. Do not. A schema is the one namespace that carries **ownership and
privileges**, so it is where separation of duties is enforced. I lay out four:

| Schema | Holds | Written by | Read by |
|---|---|---|---|
| `app` | operational tables and constraints | application role | application role |
| `audit` | append-only change history | application role, `INSERT` only | auditors |
| `staging` | landing tables for loads | ETL role | ETL role |
| `reporting` | views for analysts | owner defines them | read-only role |

Four roles fall out: an **owner** that runs migrations and owns everything, an **application** role, a **read-only** role, and an **ETL** role that owns `staging`. The application owns nothing; if it did, a SQL injection could `DROP` its tables. (`GRANT` in full: Chapter 44.) First, what 15 gives you unconfigured:

```sql
\pset null '(null)'
CREATE ROLE ch21_owner LOGIN;
CREATE ROLE ch21_app   LOGIN;
CREATE ROLE ch21_ro    LOGIN;
CREATE ROLE ch21_etl   LOGIN;

SELECT nspname, pg_get_userbyid(nspowner) AS owner, nspacl
FROM   pg_namespace WHERE nspname = 'public';

\c ch21_erp ch21_app
CREATE TABLE public.scratch (id int);
```

```text
 nspname |       owner       |                            nspacl
---------+-------------------+---------------------------------------------------------------
 public  | pg_database_owner | {pg_database_owner=UC/pg_database_owner,=U/pg_database_owner}
(1 row)

ERROR:  permission denied for schema public
LINE 1: CREATE TABLE public.scratch (id int);
                     ^
```

> **Version note —** on 15, `public` is owned by `pg_database_owner` and grants `USAGE` to
> everyone but `CREATE` to no one; the documentation says 14 and earlier also granted
> `CREATE`, which I did not test. The database owner can still create there, so a migration
> run as the owner "works on my machine" and fails under a lesser role.

The `\c` lines connect as the named role (no password here). `CREATE SCHEMA ... AUTHORIZATION` lets a superuser bootstrap a schema owned by someone else. `ALTER DEFAULT PRIVILEGES` says *whenever `ch21_owner` creates a table here, grant this*, so migrations stop ending in hand-written `GRANT`s.

```sql
\c ch21_erp postgres
CREATE SCHEMA app       AUTHORIZATION ch21_owner;
CREATE SCHEMA audit     AUTHORIZATION ch21_owner;
CREATE SCHEMA reporting AUTHORIZATION ch21_owner;
CREATE SCHEMA staging   AUTHORIZATION ch21_etl;
GRANT USAGE ON SCHEMA app, audit TO ch21_app;
GRANT USAGE ON SCHEMA reporting   TO ch21_ro;
ALTER DEFAULT PRIVILEGES FOR ROLE ch21_owner IN SCHEMA app
  GRANT SELECT, INSERT, UPDATE ON TABLES TO ch21_app;
ALTER DEFAULT PRIVILEGES FOR ROLE ch21_owner IN SCHEMA audit
  GRANT INSERT ON TABLES TO ch21_app;
ALTER DEFAULT PRIVILEGES FOR ROLE ch21_owner IN SCHEMA reporting
  GRANT SELECT ON TABLES TO ch21_ro;

\c ch21_erp ch21_owner
CREATE TABLE app.customers (
    id int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name text NOT NULL, email text NOT NULL, city text);
CREATE TABLE app.orders (
    id int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id  int NOT NULL REFERENCES app.customers,
    placed_at    timestamptz NOT NULL DEFAULT now(),
    total_amount numeric(12,2) NOT NULL CHECK (total_amount >= 0));
CREATE TABLE app.legacy_ref (id serial PRIMARY KEY, note text);
CREATE TABLE audit.change_log (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    table_name text NOT NULL, row_id bigint NOT NULL, action text NOT NULL,
    changed_by name NOT NULL DEFAULT session_user,
    changed_at timestamptz NOT NULL DEFAULT now());
\copy app.customers (name, email, city) FROM '/tmp/ch21_customers.csv' CSV
```

A design is a claim about what *cannot* happen, so test the negatives. As the application
role, try everything it should not be able to do:

```sql
\c ch21_erp ch21_app
INSERT INTO app.customers (name, email, city) VALUES ('Kavya Nair', 'kavya.nair@vyapar.example', 'Kochi');
INSERT INTO app.legacy_ref (note) VALUES ('x');
INSERT INTO audit.change_log (table_name, row_id, action) VALUES ('customers', 41, 'INSERT');
UPDATE audit.change_log SET action = 'NOOP';
DELETE FROM app.customers WHERE id = 41;
CREATE TABLE app.sneaky (id int);
DROP TABLE app.customers;
TRUNCATE app.customers;
\c ch21_erp ch21_ro
SELECT count(*) FROM app.customers;
```

```text
ERROR:  permission denied for sequence legacy_ref_id_seq
ERROR:  permission denied for table change_log
ERROR:  permission denied for table customers
ERROR:  permission denied for schema app
LINE 1: CREATE TABLE app.sneaky (id int);
                     ^
ERROR:  must be owner of table customers
ERROR:  permission denied for table customers
ERROR:  permission denied for schema app
LINE 1: SELECT count(*) FROM app.customers;
                             ^
```

The first insert and the audit insert work. The `serial` insert **fails**: a table grant does not cover a `serial`'s sequence, while `IDENTITY` needed nothing (Chapter 20). Audit is append-only *by privilege*, with no trigger to bypass. `DELETE` is refused because I withheld it; hard deletes go through a controlled path (Chapter 22). `CREATE`, `DROP` and `TRUNCATE` are refused, and the analyst cannot see `app`. Fix the gap with the two statements below.

```sql
\c ch21_erp ch21_owner
ALTER DEFAULT PRIVILEGES FOR ROLE ch21_owner IN SCHEMA app GRANT USAGE ON SEQUENCES TO ch21_app;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA app TO ch21_app;
```

> **Trap —** default privileges apply only to objects created **by the role in `FOR ROLE`**
> and only *after* the statement, which is why the second `GRANT` exists. The failure mode
> is a migration run by the wrong login: it succeeds, and the application gets
> `permission denied` at 2 a.m. Session 21.1 reproduces it. Migrations run as the owner.

### The `search_path` hijack, on 15.10

Chapter 3 warned that a `SECURITY DEFINER` function with unqualified names can be
redirected. This version survives 15's locked-down `public` because it needs no schema
right: every role has `TEMP` on the database by default, and the temporary schema is
searched **first** for relations. The function guards a hard delete, which the application
role cannot run directly, with a table named without a schema:

```sql
\c ch21_erp postgres
ALTER ROLE ch21_app IN DATABASE ch21_erp SET search_path = app;

\c ch21_erp ch21_owner
CREATE TABLE app.erasers (login_name name PRIMARY KEY);
REVOKE ALL ON app.erasers FROM ch21_app;   -- default privileges just granted it
CREATE FUNCTION app.erase_customer(cid int) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM erasers WHERE login_name = session_user) THEN
    RAISE EXCEPTION 'not an eraser: %', session_user;
  END IF;
  DELETE FROM app.customers WHERE id = cid;
END $$;

\c ch21_erp ch21_app
SELECT app.erase_customer(5);
CREATE TEMP TABLE erasers (login_name name);
INSERT INTO erasers VALUES (session_user);
GRANT SELECT ON erasers TO PUBLIC;
SELECT app.erase_customer(5);
SELECT count(*) AS customer_5_rows FROM app.customers WHERE id = 5;
```

```text
ERROR:  not an eraser: ch21_app
CONTEXT:  PL/pgSQL function erase_customer(integer) line 4 at RAISE
 erase_customer
----------------

(1 row)

 customer_5_rows
-----------------
               0
(1 row)
```

The role that cannot delete just erased a customer by shadowing the table. (The `REVOKE`
is a lesson too: default privileges are a blanket.) Pin the path with `pg_temp` **last**:

```sql
\c ch21_erp ch21_owner
ALTER FUNCTION app.erase_customer(int) SET search_path = app, pg_temp;

\c ch21_erp ch21_app
CREATE TEMP TABLE erasers (login_name name);
INSERT INTO erasers VALUES (session_user);
GRANT SELECT ON erasers TO PUBLIC;
SELECT app.erase_customer(6);
SELECT count(*) AS customer_6_rows FROM app.customers WHERE id = 6;
```

```text
ERROR:  not an eraser: ch21_app
CONTEXT:  PL/pgSQL function erase_customer(integer) line 4 at RAISE
 customer_6_rows
-----------------
               1
(1 row)
```

Every `SECURITY DEFINER` function gets `SET search_path = <its schema>, pg_temp` and `REVOKE ALL ON FUNCTION ... FROM PUBLIC` before an explicit grant, because `EXECUTE` goes to `PUBLIC` by default (Chapter 42).

---

## 21.2 OLTP and reporting in one database

Handing analysts the application's tables is how a `SELECT *` on a Friday takes checkout down. `reporting` is the contract: views the owner defines, nothing else.

```sql
\c ch21_erp ch21_app
INSERT INTO app.orders (customer_id, placed_at, total_amount)
SELECT 7 + g % 30, timestamptz '2026-09-01 00:00+05:30' + g * interval '3 hours',
       200 + (g * 37) % 1800
FROM   generate_series(0, 79) g;

\c ch21_erp ch21_owner
CREATE VIEW reporting.daily_sales AS
SELECT (placed_at AT TIME ZONE 'Asia/Kolkata')::date AS sales_date,
       count(*) AS orders, sum(total_amount) AS revenue
FROM   app.orders GROUP BY 1;

\c ch21_erp ch21_ro
SELECT * FROM reporting.daily_sales ORDER BY 1 LIMIT 3;
SELECT * FROM app.orders LIMIT 1;
```

```text
 sales_date | orders | revenue
------------+--------+---------
 2026-09-01 |      8 | 2636.00
 2026-09-02 |      8 | 5004.00
 2026-09-03 |      8 | 7372.00
(3 rows)

ERROR:  permission denied for schema app
LINE 1: SELECT * FROM app.orders LIMIT 1;
                      ^
```

A view runs with its **owner's** rights, which is how a role with no access to `app` reads through it. PostgreSQL 15 adds `security_invoker = true`, which checks the *caller's* rights instead; use it when the view sits over row-level-security tables (Chapter 44) and the policy must see the real caller. Session 21.1 runs both.

A schema does **not** isolate load. Look at what one reporting query holds:

```sql
\c ch21_erp ch21_ro
BEGIN;
SELECT count(*) FROM reporting.daily_sales;
SELECT c.oid::regclass AS locked, l.mode
FROM   pg_locks l JOIN pg_class c ON c.oid = l.relation
WHERE  l.pid = pg_backend_pid()
  AND  c.relnamespace::regnamespace::text IN ('app', 'reporting') ORDER BY 1;
ROLLBACK;
```

```text
 count
-------
    10
(1 row)

        locked         |      mode
-----------------------+-----------------
 app.orders            | AccessShareLock
 app.orders_pkey       | AccessShareLock
 reporting.daily_sales | AccessShareLock
(3 rows)
```

The report holds `AccessShareLock` on `app.orders` and its key. A migration needing `ACCESS EXCLUSIVE` there queues behind every open report, and every query behind *that* queues behind the migration (Chapter 52). Same cache, CPUs, autovacuum. My rule: **separate schemas on day one, separate hardware when reporting hurts.** Because reporting reads only `reporting.*`, moving it to a replica (Chapter 47; lag in Chapter 53) is a connection-string change; retrofitting that boundary is the expensive path.

`staging` is where loads land raw, are validated in SQL, and are promoted into `app` by a job holding both roles; its tables can be `UNLOGGED` (documented to skip WAL; not tested here).

---

## 21.3 Multi-tenancy: three models and where each stops

Many customers of yours (Kaveri Textiles in Coimbatore, Lakshmi Sweets in Chennai), one product. The model is written into every key, so choose early.

**Database per tenant.** Strongest isolation, per-tenant restore. The ceiling is a fixed
cost per tenant and a wall between tenants:

```bash
createdb ch21_tenants
psql -d ch21_tenants
```

```sql
\pset null '(null)'
SELECT pg_size_pretty(pg_database_size(current_database())) AS empty_database,
       (SELECT count(*) FROM pg_class) AS pg_class_rows;
```

```text
 empty_database | pg_class_rows
----------------+---------------
 7525 kB        |           410
(1 row)
```

An empty database is about 7.5 MB with 410 catalog rows: a thousand tenants is roughly 7 GB of catalog before any data, each with its own connection pool. Cross-tenant queries are impossible, which is a feature until finance asks for a total.

**Schema per tenant.** One database, identical tables per schema, chosen by `search_path`.
Measure it:

```sql
CREATE FUNCTION make_tenant_schema(s text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE format('CREATE SCHEMA %I', s);
  EXECUTE format('CREATE TABLE %I.customers (id int GENERATED ALWAYS AS IDENTITY PRIMARY KEY, name text NOT NULL)', s);
  EXECUTE format('CREATE TABLE %I.orders (id int GENERATED ALWAYS AS IDENTITY PRIMARY KEY, customer_id int NOT NULL REFERENCES %I.customers, placed_at timestamptz NOT NULL)', s, s);
  EXECUTE format('CREATE INDEX ON %I.orders (customer_id, placed_at)', s);
END $$;

CREATE TEMP TABLE baseline AS
SELECT (SELECT count(*) FROM pg_class) AS classes, (SELECT count(*) FROM pg_attribute) AS attrs,
       pg_database_size(current_database()) AS bytes;
DO $$ BEGIN
  FOR i IN 1..500 LOOP PERFORM make_tenant_schema('tenant_' || lpad(i::text, 4, '0')); END LOOP;
END $$;
SELECT (SELECT count(*) FROM pg_class) - classes AS new_pg_class_rows,
       (SELECT count(*) FROM pg_attribute) - attrs AS new_pg_attribute_rows,
       pg_size_pretty(pg_database_size(current_database()) - bytes) AS growth_with_zero_rows
FROM baseline;
```

```text
 new_pg_class_rows | new_pg_attribute_rows | growth_with_zero_rows
-------------------+-----------------------+-----------------------
              4501 |                 25009 | 34 MB
(1 row)
```

Five hundred empty tenants add 4,501 catalog rows and 34 MB before any data, and the growth is linear. A schema change becomes a fan-out (one new column is 500 `ALTER TABLE`s, from a tool that must survive failing halfway; Chapter 52), and any single transaction touching every object takes a lock per object from a finite lock table, which Session 21.2 measures. My *experience* puts schema-per-tenant's practical ceiling at a few hundred tenants; that figure is unmeasured.

**Shared tables with `tenant_id`.** The catalog stays one tenant's size, a migration is one
`ALTER`, a total is one `GROUP BY`. The danger is that isolation is now yours to enforce,
and the first leak is the foreign key. Compare two shapes:

```bash
createdb ch21_shared
psql -d ch21_shared
```

```sql
\pset null '(null)'
CREATE TABLE tenants (tenant_id int PRIMARY KEY, name text NOT NULL);
INSERT INTO tenants VALUES (1, 'Kaveri Textiles, Coimbatore'), (2, 'Lakshmi Sweets, Chennai');

-- Shape A: tenant_id is just a column
CREATE TABLE customers_a (id int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
                          tenant_id int NOT NULL REFERENCES tenants, name text NOT NULL);
CREATE TABLE orders_a (id int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
                       tenant_id int NOT NULL REFERENCES tenants,
                       customer_id int NOT NULL REFERENCES customers_a (id));
-- Shape B: tenant_id is part of every key
CREATE TABLE customers (tenant_id int NOT NULL REFERENCES tenants,
                        id int GENERATED ALWAYS AS IDENTITY, name text NOT NULL,
                        PRIMARY KEY (tenant_id, id));
CREATE TABLE orders (tenant_id int NOT NULL, id int GENERATED ALWAYS AS IDENTITY,
                     customer_id int NOT NULL, total_amount numeric(12,2) NOT NULL,
                     PRIMARY KEY (tenant_id, id),
                     FOREIGN KEY (tenant_id, customer_id) REFERENCES customers (tenant_id, id));

INSERT INTO customers_a (tenant_id, name) VALUES (1, 'Anita Rao'), (2, 'Harpreet Singh');
INSERT INTO orders_a (tenant_id, customer_id) VALUES (2, 1);   -- tenant 2, tenant 1's customer
SELECT tenant_id, customer_id FROM orders_a;

INSERT INTO customers (tenant_id, name) VALUES (1, 'Anita Rao'), (2, 'Harpreet Singh');
INSERT INTO orders (tenant_id, customer_id, total_amount) VALUES (2, 1, 1500);
INSERT INTO orders (tenant_id, customer_id, total_amount) VALUES (2, 2, 1500);
```

```text
 tenant_id | customer_id
-----------+-------------
         2 |           1
(1 row)

ERROR:  insert or update on table "orders" violates foreign key constraint "orders_tenant_id_customer_id_fkey"
DETAIL:  Key (tenant_id, customer_id)=(2, 1) is not present in table "customers".
```

Shape A accepted Lakshmi Sweets' order for Kaveri Textiles' customer, and nothing would flag it. Shape B refused it in the database. The price is a wider key and two-column joins; pay it. It puts `tenant_id` first in every index, which partitioning (Chapter 38) and sharding (Chapter 53) need; the policy that stops a query *forgetting* `WHERE tenant_id = ...` is Chapter 44.

The ceiling here is physical: tenants are unequal and their rows arrive interleaved. One
tenant holds 90% of 300,000 orders, a hundred small ones share the rest:

```sql
CREATE TABLE orders_skew (tenant_id int NOT NULL, id int GENERATED ALWAYS AS IDENTITY,
    placed_at timestamptz NOT NULL, total_amount numeric(12,2) NOT NULL,
    PRIMARY KEY (tenant_id, id));
INSERT INTO orders_skew (tenant_id, placed_at, total_amount)
SELECT CASE WHEN g % 10 < 9 THEN 1 ELSE 2 + (g / 10) % 100 END,
       timestamptz '2026-01-01' + g * interval '1 minute', 100 + g % 900
FROM generate_series(1, 300000) g;

SELECT count(*) FILTER (WHERE tenant_id = 1) AS tenant_1, count(*) FILTER (WHERE tenant_id = 7) AS tenant_7,
       pg_relation_size('orders_skew') / 8192 AS table_pages
FROM   orders_skew;
SELECT count(*) AS rows, count(DISTINCT (ctid::text::point)[0]) AS heap_pages
FROM   orders_skew WHERE tenant_id = 7;
CREATE TABLE tenant_7_alone AS SELECT * FROM orders_skew WHERE tenant_id = 7;
SELECT pg_relation_size('tenant_7_alone') / 8192 AS pages_in_own_table;
```

```text
 tenant_1 | tenant_7 | table_pages
----------+----------+-------------
   270000 |      300 |        1911
(1 row)

 rows | heap_pages
------+------------
  300 |        300
(1 row)

 pages_in_own_table
--------------------
                  2
(1 row)
```

Tenant 7's 300 rows sit on 300 different pages of 1,911; alone they fit in 2. A small tenant's data has no locality, and a whale's scans are everyone's cache pressure. The remedies are partitioning by tenant (Chapter 38) or moving the whale out.

**What I would do.** Default to **shared tables, composite keys and RLS**, the only model whose cost does not grow with tenant count. Move outliers (huge tenants, contractual isolation) to their own database, routed by the application. Schema-per-tenant only for tens to a few hundred tenants needing their own restore point or customised tables. Database-per-tenant when isolation is regulatory or tenants are few and huge. **Leave the default** when one tenant's share of a table makes the others' queries expensive, or a tenant demands data residency.

---

## 21.4 Lookup table, `ENUM`, or `CHECK`

Chapters 15 and 16 gave the `CHECK` and `ENUM` cost sheets (an enum label cannot be used in the transaction that adds it; there is no `DROP VALUE`). The lookup table is the third option. Build it and a `CHECK` twin over 100,000 rows and add a state to each:

```bash
createdb ch21_lookup
psql -d ch21_lookup
```

```sql
\pset null '(null)'
CREATE TABLE order_status (
    code text PRIMARY KEY, label text NOT NULL,
    is_terminal boolean NOT NULL DEFAULT false, sort_order int NOT NULL UNIQUE);
INSERT INTO order_status VALUES
 ('open','Open',false,1), ('paid','Paid',false,2), ('shipped','Shipped',false,3),
 ('delivered','Delivered',true,4), ('cancelled','Cancelled',true,5);
CREATE TABLE orders_lookup (id int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    status text NOT NULL DEFAULT 'open' REFERENCES order_status ON UPDATE CASCADE);
CREATE TABLE orders_check (id int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    status text NOT NULL DEFAULT 'open'
    CONSTRAINT orders_check_status_ck CHECK (status IN ('open','paid','shipped','delivered','cancelled')));
INSERT INTO orders_lookup (status) SELECT (ARRAY['open','paid','shipped','delivered','cancelled'])[1 + g % 5] FROM generate_series(1, 100000) g;
INSERT INTO orders_check  (status) SELECT (ARRAY['open','paid','shipped','delivered','cancelled'])[1 + g % 5] FROM generate_series(1, 100000) g;

\set mylocks 'SELECT c.oid::regclass AS locked, l.mode FROM pg_locks l JOIN pg_class c ON c.oid = l.relation WHERE l.pid = pg_backend_pid() AND c.relkind = ''r'' AND c.relnamespace = ''public''::regnamespace ORDER BY 1'

BEGIN;   -- lookup: add a state
INSERT INTO order_status VALUES ('returned', 'Returned', true, 6);
:mylocks;
COMMIT;
BEGIN;   -- check: add a state
ALTER TABLE orders_check DROP CONSTRAINT orders_check_status_ck;
ALTER TABLE orders_check ADD CONSTRAINT orders_check_status_ck
  CHECK (status IN ('open','paid','shipped','delivered','cancelled','returned')) NOT VALID;
:mylocks;
COMMIT;
BEGIN;   -- check: validate existing rows
ALTER TABLE orders_check VALIDATE CONSTRAINT orders_check_status_ck;
:mylocks;
COMMIT;
```

```text
    locked    |       mode
--------------+------------------
 order_status | RowExclusiveLock
(1 row)

    locked    |        mode
--------------+---------------------
 orders_check | AccessExclusiveLock
(1 row)

    locked    |           mode
--------------+--------------------------
 orders_check | ShareUpdateExclusiveLock
(1 row)
```

Adding a lookup row locks the lookup table and never touches `orders_lookup`. The `CHECK` swap takes `ACCESS EXCLUSIVE` on the big table (`NOT VALID` keeps the window short); the later 100,000-row scan runs under `SHARE UPDATE EXCLUSIVE`, which lets writes continue (Chapter 52). Retiring and renaming show the other difference:

```sql
DELETE FROM order_status WHERE code = 'shipped';
SELECT pg_relation_size('orders_lookup') AS heap_before \gset
UPDATE order_status SET label = 'Dispatched' WHERE code = 'shipped';
SELECT pg_relation_size('orders_lookup') - :heap_before AS heap_growth_after_label_rename;
UPDATE order_status SET code = 'dispatched' WHERE code = 'shipped';
SELECT count(*) AS rows_now_dispatched,
       pg_relation_size('orders_lookup') - :heap_before AS heap_growth_after_code_rename
FROM   orders_lookup WHERE status = 'dispatched';
INSERT INTO orders_lookup (status) VALUES ('teleported');
```

```text
ERROR:  update or delete on table "order_status" violates foreign key constraint "orders_lookup_status_fkey" on table "orders_lookup"
DETAIL:  Key (code)=(shipped) is still referenced from table "orders_lookup".
 heap_growth_after_label_rename
--------------------------------
                              0
(1 row)

 rows_now_dispatched | heap_growth_after_code_rename
---------------------+-------------------------------
               20000 |                        884736
(1 row)

ERROR:  insert or update on table "orders_lookup" violates foreign key constraint "orders_lookup_status_fkey"
DETAIL:  Key (status)=(teleported) is not present in table "order_status".
```

A code in use cannot be deleted (retire it with an `is_active` flag). Renaming the *label* grew the big table by nothing; renaming the *code* rewrote 20,000 rows. Codes are identifiers that never change; labels are what a product manager renames.

I default to a **lookup table** (`text` code key, separate label) for anything a business person can name, because its change is an `INSERT`; `ENUM` for closed data-model sets such as `debit`/`credit`; `CHECK` for two-or-three-value sets that never reach a screen.

---

## 21.5 Naming conventions, each with its failure mode

State a convention only if you can name what breaks without it:

```sql
CREATE TABLE "Orders" (id int);
SELECT count(*) FROM Orders;
CREATE TABLE order (id int);

CREATE TABLE lines (a int, b int);
CREATE INDEX lines_customer_dashboard_lookup_by_placement_date_and_fulfilment_status_a ON lines (a);
CREATE INDEX lines_customer_dashboard_lookup_by_placement_date_and_fulfilment_status_b ON lines (b);

CREATE TABLE dev_t  (a int, b int, CHECK (a < b), CHECK (a + b < 100));
CREATE TABLE prod_t (a int, b int, CHECK (a + b < 100), CHECK (a < b));
SELECT conrelid::regclass AS tbl, conname, pg_get_constraintdef(oid) AS rule
FROM   pg_constraint WHERE conrelid IN ('dev_t'::regclass, 'prod_t'::regclass) ORDER BY 1, 2;
```

```text
ERROR:  relation "orders" does not exist
LINE 1: SELECT count(*) FROM Orders;
                             ^
ERROR:  syntax error at or near "order"
LINE 1: CREATE TABLE order (id int);
                     ^
ERROR:  relation "lines_customer_dashboard_lookup_by_placement_date_and_fulfilmen" already exists
  tbl   |    conname    |          rule
--------+---------------+-------------------------
 dev_t  | dev_t_check   | CHECK ((a < b))
 dev_t  | dev_t_check1  | CHECK (((a + b) < 100))
 prod_t | prod_t_check  | CHECK (((a + b) < 100))
 prod_t | prod_t_check1 | CHECK ((a < b))
(4 rows)
```

- **Lowercase `snake_case`, never quoted** (`"Orders"` is not `orders`), and **no reserved words** (`order`, `user`): both fail, or force quoting everywhere.
- **Under 63 bytes, unique in that prefix.** Longer names are truncated to 63 bytes (at most a `NOTICE`; this container's `client_min_messages` is `error`, so none showed), and the second index collides on the cut.
- **Name every constraint and index.** Unnamed ones get `_check`, `_check1` in creation
  order, so `dev_t` and `prod_t` hold the same rules under swapped names, and
  `DROP CONSTRAINT prod_t_check1` removes a different rule in each. Pattern: `<table>_pkey`,
  `<table>_<column>_fkey`, `<table>_<columns>_key`, `<table>_<what>_ck`,
  `<table>_<columns>_idx`.
- **Plural tables, `id` keys, `<singular>_id` foreign keys, `_at` for `timestamptz`, `_on` for `date`, `is_` for booleans.** Taste, but the suffix carries the type.
- **Schema-qualify every name** in migrations and application SQL, the hijack defence from 21.1.

---

## 21.6 Migrations and environment parity

Production's schema must be reproducible from files. Any migration tool (Flyway, Liquibase, Sqitch, Alembic, `golang-migrate`) should give you **versioned files applied in order, a table recording what ran, one transaction per migration, and applied files immutable.** Transactional DDL (Chapter 29) makes the third possible; exceptions like `CREATE INDEX CONCURRENTLY` are Chapter 52's. The mechanism fits in a psql-only script:

```bash
mkdir ch21_migrations && cd ch21_migrations && mkdir migrations
createdb ch21_dev
createdb ch21_prod
cat > migrations/V001__schemas.sql <<'EOF'
CREATE SCHEMA app;
CREATE SCHEMA audit;
CREATE SCHEMA reporting;
EOF
cat > migrations/V002__customers_orders.sql <<'EOF'
CREATE TABLE app.customers (
    id int GENERATED ALWAYS AS IDENTITY, name text NOT NULL,
    CONSTRAINT customers_pkey PRIMARY KEY (id));
CREATE TABLE app.orders (
    id int GENERATED ALWAYS AS IDENTITY, customer_id int NOT NULL,
    total_amount numeric(12,2) NOT NULL,
    CONSTRAINT orders_pkey PRIMARY KEY (id),
    CONSTRAINT orders_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES app.customers (id),
    CONSTRAINT orders_total_amount_ck CHECK (total_amount >= 0));
EOF
```

The runner. `-1` wraps the migration file **and** the bookkeeping `INSERT` in one
transaction, so a migration either happened and is recorded, or did not happen:

```bash
cat > migrate.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
db=${1:?database name}; dir=${2:-migrations}
q() { psql -X -q -v ON_ERROR_STOP=1 -d "$db" "$@"; }

q -c "CREATE SCHEMA IF NOT EXISTS ops" \
  -c "CREATE TABLE IF NOT EXISTS ops.schema_migrations (
        version text PRIMARY KEY, checksum text NOT NULL,
        applied_at timestamptz NOT NULL DEFAULT now(),
        applied_by name NOT NULL DEFAULT current_user)"

for f in "$dir"/V[0-9]*__*.sql; do
  v=$(basename "$f" .sql)
  sum=$(shasum -a 256 "$f" | cut -d' ' -f1)
  old=$(q -At -c "SELECT checksum FROM ops.schema_migrations WHERE version = '$v'")
  if [ -n "$old" ]; then
    [ "$old" = "$sum" ] || { echo "CHECKSUM MISMATCH: $v was edited after it was applied" >&2; exit 1; }
    echo "skip   $v"; continue
  fi
  echo "apply  $v"
  q -1 -f "$f" -c "INSERT INTO ops.schema_migrations (version, checksum) VALUES ('$v', '$sum')"
done
EOF
chmod +x migrate.sh
./migrate.sh ch21_dev
echo "--- second run"
./migrate.sh ch21_dev
echo "--- prod"
./migrate.sh ch21_prod
```

```text
apply  V001__schemas
apply  V002__customers_orders
--- second run
skip   V001__schemas
skip   V002__customers_orders
--- prod
apply  V001__schemas
apply  V002__customers_orders
```

The second run is a no-op: that idempotency belongs to the *runner*. I do not sprinkle `IF NOT EXISTS` through migrations: one that fails because the object exists is reporting drift, and `IF NOT EXISTS` turns that alarm into a silent pass. The primary key on `version` is the real guarantee: two racing runners cannot both record a migration, and the loser's DDL rolls back with its insert.

Parity means every environment is built from the same files and nothing else. Prove it with
a fingerprint of columns and constraints, then let someone "hotfix" production by hand:

```bash
cat > fingerprint.sql <<'EOF'
SELECT md5(string_agg(line, E'\n' ORDER BY line)) AS schema_fingerprint, count(*) AS objects
FROM (
  SELECT 'col ' || table_schema || '.' || table_name || '.' || column_name || ' ' || data_type
         || ' null=' || is_nullable AS line
  FROM information_schema.columns WHERE table_schema IN ('app', 'audit', 'reporting')
  UNION ALL
  SELECT 'con ' || conrelid::regclass || ' ' || conname || ' ' || pg_get_constraintdef(oid)
  FROM pg_constraint WHERE connamespace::regnamespace::text IN ('app', 'audit', 'reporting')
) s;
EOF
for d in ch21_dev ch21_prod; do echo "$d"; psql -X -d $d -Atf fingerprint.sql; done
psql -X -q -d ch21_prod -c "ALTER TABLE app.orders ADD COLUMN note text"
echo "--- after the hotfix"
for d in ch21_dev ch21_prod; do echo "$d"; psql -X -d $d -Atf fingerprint.sql; done
```

```text
ch21_dev
4edbbef994d0b6d26b25078c7ed675ee|9
ch21_prod
4edbbef994d0b6d26b25078c7ed675ee|9
--- after the hotfix
ch21_dev
4edbbef994d0b6d26b25078c7ed675ee|9
ch21_prod
e5f14b7efaa11aad5826ea222c766ace|10
```

Now the migration that *should* have added that column arrives, and it is applied
everywhere. Then someone edits an applied file:

```bash
cat > migrations/V003__order_note.sql <<'EOF'
CREATE TABLE app.order_note_audit (id int);
ALTER TABLE app.orders ADD COLUMN note text;
EOF
./migrate.sh ch21_dev
echo "--- prod"
./migrate.sh ch21_prod || echo "runner exit status: $?"
psql -X -d ch21_prod -Atc "SELECT coalesce(to_regclass('app.order_note_audit')::text, 'no order_note_audit table')"
echo "--- edit an applied file"
echo "-- edited" >> migrations/V002__customers_orders.sql
./migrate.sh ch21_dev || echo "runner exit status: $?"
```

```text
skip   V001__schemas
skip   V002__customers_orders
apply  V003__order_note
--- prod
skip   V001__schemas
skip   V002__customers_orders
apply  V003__order_note
psql:migrations/V003__order_note.sql:2: ERROR:  column "note" of relation "orders" already exists
runner exit status: 3
no order_note_audit table
--- edit an applied file
skip   V001__schemas
CHECKSUM MISMATCH: V002__customers_orders was edited after it was applied
runner exit status: 1
```

Production refused V003 and, because the `CREATE TABLE` and the failing `ALTER` share a transaction, left no `order_note_audit`: nothing half-applied, nothing recorded. The last lines are immutability: V002's checksum no longer matches, so the runner stops. To change an applied migration you write V004.

> **In production —** run the fingerprint in CI against a fresh build and against staging. Staging also needs production-like *volume* (Chapter 35) and masked personal data (Chapter 51); roles are cluster-wide, so bootstrap them once, outside these files. Zero-downtime rollout is Chapter 52.

Clean up, roles included. `DROP OWNED` must precede `DROP ROLE`:

```bash
cd .. && rm -rf ch21_migrations
for r in ch21_owner ch21_app ch21_ro ch21_etl; do psql -X -q -d ch21_erp -c "DROP OWNED BY $r"; done
for d in ch21_erp ch21_tenants ch21_shared ch21_lookup ch21_dev ch21_prod; do dropdb $d; done
for r in ch21_owner ch21_app ch21_ro ch21_etl; do psql -X -q -d postgres -c "DROP ROLE $r"; done
rm -f /tmp/ch21_customers.csv
```

---

## Summary

- Use schemas for separation of duties: `app`, `audit`, `staging`, `reporting`. On 15.10 an ordinary role cannot `CREATE` in `public`; the database owner can.
- Migrations run as one owner role; the application owns nothing. Test the negatives. Default privileges cover only objects the named role creates afterwards; `serial` needs a sequence grant, `IDENTITY` does not.
- The `search_path` hijack works on 15.10 through a temporary table. Pin `SET search_path = <schema>, pg_temp`.
- A schema separates names and privileges, not load: one report held `AccessShareLock` on `app.orders`.
- Tenancy: default to shared tables with `(tenant_id, id)` keys and composite foreign keys, which refused a cross-tenant order. Its ceiling is physical (300 rows on 300 pages versus 2); 500 empty tenant schemas cost 4,501 catalog rows.
- Lookup table by default; renaming a code rewrote 20,000 rows, a label one.
- Name constraints, stay under 63 bytes, schema-qualify everything.
- Migrations: immutable versioned files, a checksummed table, one transaction each; idempotency belongs to the runner; a fingerprint catches drift.

**Exercises:** Practice Sessions 21.1–21.3 accompany this chapter and are in the
workbook at the back of the book.

**Next:** Chapter 22, *The Table Design Checklist*, takes one table and applies the
standard columns, audit trail, delete strategy, RLS readiness and day-one index plan that
this chapter's layout was built to hold.
