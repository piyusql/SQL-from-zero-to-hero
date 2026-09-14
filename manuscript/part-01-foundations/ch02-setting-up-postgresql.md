# Chapter 2 — Setting Up PostgreSQL 15+ on macOS and Linux

This chapter gets a working PostgreSQL server onto your machine, gets you comfortable in
`psql`, and loads the three datasets the rest of the book depends on. It is the only
chapter where nothing you learn is transferable knowledge about databases — it is all
plumbing. Do it once, properly, and you will not think about it again.

One thing before we start, because it catches people out constantly.

---

## 2.1 A server and a client are different things

PostgreSQL is two pieces of software that happen to share a name.

The **server** is a program that runs continuously, owns a directory of files on disk, and
listens on a port — 5432 by default. It is the database.

The **client** is a program that connects to a server and sends it SQL. `psql` is a
client. So is your application. So is pgAdmin. Clients hold no data.

You can install a client without a server, and on macOS this happens by accident all the
time. Homebrew's `libpq` formula installs the client libraries and `psql` but no server,
and so does any language driver that bundles `libpq`. (The reverse is rare: a server
package always ships the client alongside it.) The result is that `psql --version` prints a version number,
you conclude Postgres is installed, and then every connection attempt fails with something
like this:

```text
psql: error: connection to server on socket "/tmp/.s.PGSQL.5432" failed:
No such file or directory
    Is the server running locally and accepting connections on that socket?
```

That message is precise and people still misread it. It is not saying your credentials are
wrong or your database is missing. It is saying **there is nothing listening**. You have a
client and no server.

Check which you have:

```bash
psql --version        # the client
pg_ctl status         # the server, if its bin directory is on your PATH
pg_lsclusters         # the server, on Debian and Ubuntu
```

There is no single portable command, because Debian and Ubuntu deliberately keep the
server binaries off your `PATH` even when a cluster is running. The reliable test is not
"does a binary exist" but **"can I connect"** — which is what the error above answers.

> **Trap —** a client from one major version talking to a server from another is fine and
> normal; `libpq` is good at this. So do not be alarmed if `psql --version` says 18 and
> your server says 16. What matters for this book is the *server* version.

## 2.2 Choosing how to install

Three reasonable options. Pick one.

| | Best for | Trade-off |
|---|---|---|
| **Homebrew** (macOS) | Everyday local development on a Mac | One version at a time is comfortable; more takes care |
| **Docker** | Matching a production version exactly, or juggling several versions | Slight I/O overhead; volumes are easy to destroy by accident |
| **PGDG packages** (Linux) | Linux workstations and anything resembling a server | Requires adding a repository; distro defaults are usually too old |

If you have no strong preference: **Homebrew on macOS, PGDG packages on Linux.** Use
Docker when you need to reproduce a specific production version, which in the performance
chapters of this book you eventually will.

### macOS with Homebrew

```bash
brew install postgresql@17
brew services start postgresql@17
```

The formula creates a cluster and starts it. Add the binaries to your `PATH` — the
versioned formulae are keg-only, meaning Homebrew deliberately does not link them:

```bash
echo 'export PATH="/opt/homebrew/opt/postgresql@17/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

On Intel Macs the prefix is `/usr/local` rather than `/opt/homebrew`.

Homebrew creates a superuser role named after your macOS username and trusts local
connections. It does **not** create a database of that name, which is why `psql` on its
own may fail while this works:

```bash
psql postgres
```

> **In production —** that trust-everything-local configuration is a development
> convenience and nothing else. Chapter 44 covers `pg_hba.conf` and how real
> authentication is configured. Do not carry this setup onto a shared machine.

### Docker, on either platform

```bash
docker run -d \
  --name pgbook \
  -e POSTGRES_PASSWORD=postgres \
  -p 5432:5432 \
  -v pgbook-data:/var/lib/postgresql/data \
  postgres:17
```

Connect from the host:

```bash
psql -h localhost -U postgres
```

The `-v` flag is the important one. Without a named volume, the data lives inside the
container and `docker rm` destroys it silently. With it, the data survives the container.

> **Trap —** `-p 5432:5432` binds to every interface on some Docker configurations, not
> just loopback. On a laptop on a café network that is a database exposed to strangers,
> with a password you set to `postgres`. Bind it explicitly: `-p 127.0.0.1:5432:5432`.

### Debian and Ubuntu

The version in the distribution's own repository is usually several years old. Add the
PostgreSQL Global Development Group repository instead:

```bash
sudo apt install -y postgresql-common
sudo /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh
sudo apt install -y postgresql-17
```

Debian and Ubuntu create and start a cluster for you, and they wrap the standard tooling
in their own multi-cluster layer:

```bash
pg_lsclusters                      # what exists
sudo pg_ctlcluster 17 main start   # start it
```

Configuration lives in `/etc/postgresql/17/main/` and data in
`/var/lib/postgresql/17/main/`. This split is a Debian convention, not a PostgreSQL one —
worth knowing, because most documentation you find online assumes the config sits in the
data directory.

Debian authenticates local connections by operating system user, so:

```bash
sudo -u postgres psql
```

### RHEL, Rocky and AlmaLinux

```bash
sudo dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm
sudo dnf -qy module disable postgresql
sudo dnf install -y postgresql17-server
sudo /usr/pgsql-17/bin/postgresql-17-setup initdb
sudo systemctl enable --now postgresql-17
```

Unlike Debian, the Red Hat packages do **not** create a cluster for you. That is what the
`initdb` line does, and skipping it is the usual reason the service refuses to start.

That repository URL is specific to EL 9 on x86-64. For a different release or
architecture, browse `download.postgresql.org/pub/repos/yum/reporpms/` and take the
matching RPM; Fedora uses `pgdg-fedora-repo-latest.noarch.rpm` instead.

## 2.3 What actually got installed

Whichever route you took, you now have a **cluster**: one server process, one port, one
directory of files, and inside it several databases.

The word is unfortunate. A PostgreSQL "cluster" has nothing to do with multiple machines.
It means one server instance and the databases it holds. When someone says "we run three
clusters", they may well mean three servers on one host.

Find the directory:

```sql
SHOW data_directory;
```

```text
         data_directory
---------------------------------
 /opt/homebrew/var/postgresql@17
(1 row)
```

Inside it, `base/` holds the actual table data, `pg_wal/` holds the write-ahead log —
every change is written there before it is written anywhere else, which is the mechanism
that makes crash recovery possible — and `postgresql.conf` holds the settings.

Do not edit files in that directory by hand, and never delete anything from it. The one
thing worth knowing now is that `pg_wal/` can grow without bound if a replication slot or
an archive command is misconfigured, and a full `pg_wal/` stops the database. Chapter 47
explains how that happens; for now, just recognise the name.

Three databases exist at the start:

```bash
psql -l
```

```text
                                                     List of databases
   Name    |  Owner   | Encoding | Locale Provider |   Collate   |    Ctype    | Locale | ICU Rules |   Access privileges
-----------+----------+----------+-----------------+-------------+-------------+--------+-----------+-----------------------
 postgres  | postgres | UTF8     | libc            | en_US.UTF-8 | en_US.UTF-8 |        |           |
 template0 | postgres | UTF8     | libc            | en_US.UTF-8 | en_US.UTF-8 |        |           | =c/postgres          +
           |          |          |                 |             |             |        |           | postgres=CTc/postgres
 template1 | postgres | UTF8     | libc            | en_US.UTF-8 | en_US.UTF-8 |        |           | =c/postgres          +
           |          |          |                 |             |             |        |           | postgres=CTc/postgres
(3 rows)
```

> **Version note —** the `Locale Provider` and `ICU Rules` columns arrived in PostgreSQL
> 15. On 14 and earlier you will see a narrower table without them.

`postgres` is a scratch database that exists so clients have something to connect to.
`template1` is copied every time you run `CREATE DATABASE` — anything you install into it
appears in every future database, which is occasionally useful and more often a trap.
`template0` is a pristine copy that is never modified, kept so you can always recreate a
clean database with a different encoding. Chapter 3 goes into this properly.

## 2.4 Connecting

`psql` takes connection details four ways, and knowing all four saves a lot of confusion.

```bash
psql -h localhost -p 5432 -U postgres -d retail      # flags
psql postgresql://postgres@localhost:5432/retail      # URI
PGHOST=localhost PGUSER=postgres psql retail          # environment
psql retail                                           # defaults
```

The defaults are: host = a local Unix socket, port = 5432, user = your operating system
username, database = the same as the username. This is why `psql` alone sometimes works
and sometimes says `database "pk" does not exist`.

For passwords, never put them in a shell command — they land in your shell history and in
the process list where any other user on the machine can read them. Use `~/.pgpass`:

```text
# hostname:port:database:username:password
localhost:5432:*:postgres:postgres
```

```bash
chmod 0600 ~/.pgpass
```

PostgreSQL ignores the file if the permissions are wider than that and prompts you for a
password instead — but it does tell you:

```text
WARNING: password file "/tmp/.pgpass" has group or world access; permissions should be
u=rw (0600) or less
```

If `.pgpass` "isn't working", check the mode first, and read the warning you scrolled past.

## 2.5 `psql` is better than it looks

`psql` has a reputation as a bare-bones fallback. It is not. It is the most capable
PostgreSQL client there is, and it is the only one guaranteed to be available on a machine
you have been given emergency access to at 3am. Learn it.

Commands starting with a backslash are **meta-commands** — handled by `psql` itself, not
sent to the server.

**Getting around:**

```text
\l              list databases
\c retail       connect to another database
\dn             list schemas
\dt             list tables in the search path
\dt *.*         list tables in every schema
\d orders       describe the orders table — columns, types, indexes, constraints
\d+ orders      the same, plus storage, compression and comments
\di             list indexes
\df             list functions
\du             list roles
```

`\d orders` is the one you will use hundreds of times. It shows the columns, the indexes,
the foreign keys pointing out, and the foreign keys pointing in. That last part is how you
discover what else depends on a table before you change it.

**Making output readable:**

```text
\x              expanded display — one column per line. Toggle it.
\x auto         expanded only when the row is too wide for the terminal. Better.
\timing         print execution time after every statement. Turn this on now.
\pset null '(null)'   print NULL visibly instead of as blank
```

That last one deserves a moment. By default, `psql` prints `NULL` as nothing at all —
which is visually identical to an empty string. Those are completely different values with
completely different behaviour, and Chapter 7 is largely about the consequences of
confusing them. Make them look different on screen.

**Actually working:**

```text
\e                    open the last query in $EDITOR; on save, run it
\i script.sql         run a file
\copy t FROM 'f.csv' CSV HEADER    load a file from the *client* machine
\watch 2              re-run the last query every 2 seconds
\?                    all meta-commands
\h UPDATE             syntax for a specific SQL statement
```

`\copy` versus `COPY` is a distinction worth internalising now. `COPY` is a SQL command
executed by the server, so the path refers to a file on the **server's** filesystem and
requires elevated privileges. `\copy` is a `psql` meta-command that reads the file locally
and streams it over the connection. On your laptop they look the same because the server
is also your laptop. Against a remote database they are entirely different, and `\copy` is
almost always the one you want.

`\watch` is the one people are most pleased to discover. Run a query against
`pg_stat_activity`, type `\watch 1`, and you have a live view of what the database is
doing. We use it repeatedly in Chapter 39.

## 2.6 A `.psqlrc` worth having

`psql` reads `~/.psqlrc` at startup. This is a reasonable starting point:

```text
\set QUIET 1

\timing on
\x auto
\pset null '(null)'
\pset border 2

\set HISTSIZE 5000
\set HISTFILE ~/.psql_history-:DBNAME
\set COMP_KEYWORD_CASE upper

\set PROMPT1 '%[%033[1;32m%]%n@%/%[%033[0m%]%R%# '

\unset QUIET
```

`QUIET` suppresses the noise of the settings being applied. Per-database history means
your recall in one database is not polluted by another. The prompt shows user and
database, which stops the specific mistake of running a statement against the wrong one.

> **In production —** add this to the prompt on any machine that can reach production:
>
> ```text
> \set PROMPT1 '%[%033[1;31m%]PROD %n@%/%[%033[0m%]%R%# '
> ```
>
> A red prompt saying PROD has prevented more incidents than most tooling. Make dangerous
> environments *look* dangerous.

## 2.7 Graphical clients, and where they mislead you

pgAdmin, DBeaver, TablePlus, DataGrip and Postico are all fine. Use one if you like one —
browsing an unfamiliar schema is genuinely nicer with a tree view.

But know what they do that `psql` does not, because each of these has cost someone a
confusing afternoon:

- **They add `LIMIT` silently.** Most GUIs append a row limit to keep the grid
  responsive. Your query returns in 40ms and you conclude it is fast. It returned the
  first 200 rows of 4 million.
- **Their timing includes rendering.** The number in the corner is not server execution
  time. For anything in Part VIII, use `\timing` in `psql` or read `EXPLAIN ANALYZE`.
- **They hold transactions open.** Several default to a transaction per session rather
  than autocommit. You run a `SELECT`, walk away, and now there is an idle-in-transaction
  connection holding back vacuum across the whole database. Chapter 37 explains exactly
  how much damage that does.
- **They run their own queries.** The catalog queries powering the object tree show up in
  `pg_stat_statements` alongside yours, which muddies analysis.

Use a GUI to explore. Use `psql` to measure, and to fix things.

---

## Summary

- A client and a server are separate installations. `psql --version` tells you nothing
  about whether a server exists; `postgres -V` does.
- A PostgreSQL "cluster" is one server instance and its databases — not multiple machines.
- Homebrew on macOS, PGDG packages on Linux, Docker when you need to match a specific
  production version. Distro-default packages are usually too old.
- Connection details come from flags, a URI, environment variables or defaults. Passwords
  belong in `~/.pgpass` with mode `0600`, never on a command line.
- `psql` is the most capable client available and the only one you are guaranteed to have
  in an emergency. `\d`, `\timing`, `\x auto`, `\watch` and `\copy` earn their keep
  immediately.
- Make NULL visible with `\pset null`. You cannot debug what you cannot see.
- GUI clients silently add `LIMIT`, report timings that include rendering, and can hold
  transactions open. Explore with them; measure with `psql`.
- The three sample datasets are loaded with `./load.sh all sm` and are assumed present
  from here on.

**Exercises:** Practice Sessions 2.1–2.3 accompany this chapter and are in
the workbook at the back of the book.

**Next:** Chapter 3 looks at what a database and a schema actually are, how `search_path`
resolves names, and why the collation your cluster was created with is a decision you can
be punished for years later.
