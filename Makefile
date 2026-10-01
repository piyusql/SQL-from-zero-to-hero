# Handy commands for working on "SQL from Zero to Hero".   Run `make` for the list.
#
# Wraps ./book.sh and the verification container described in CLAUDE.md. Works with
# the old GNU Make 3.81 that ships with macOS.

SHELL := /bin/bash

# --- verification container (CLAUDE.md): PostgreSQL 15.10 on 5431. NEVER 5432. ---
export PATH := /opt/homebrew/opt/libpq/bin:$(PATH)
export PGHOST ?= 127.0.0.1
export PGPORT ?= 5431
export PGUSER ?= postgres

# Scratch databases the chapters create: ch18_scratch, ch24_eav, v23, ... and their roles.
SCRATCH_DB_RE   := ^(ch[0-9]+_|v[0-9]+)
SCRATCH_ROLE_RE := ^ch[0-9]+_

PDF := SQL-from-zero-to-hero.pdf

.DEFAULT_GOAL := help
.PHONY: help install serve stop build pdf open-pdf clean words stats todo errata \
        db-check db-list db-clean psql load-datasets guard-port

help: ## Show this list
	@echo "Setup"
	@grep -E '^(install):.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-14s %s\n", $$1, $$2}'
	@echo "Book"
	@grep -E '^(serve|stop|build|pdf|open-pdf|clean):.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-14s %s\n", $$1, $$2}'
	@echo "Writing"
	@grep -E '^(words|stats|todo|errata):.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-14s %s\n", $$1, $$2}'
	@echo "Database (test container, port $(PGPORT))"
	@grep -E '^(db-check|db-list|db-clean|psql|load-datasets):.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-14s %s\n", $$1, $$2}'
	@echo ""
	@echo "Options:  CHUNK_CHAPTERS=6 make pdf   (faster PDF, coarser running headers)"
	@echo "          DB=hr make psql             (default DB=retail)"
	@echo "          CONFIRM=yes make db-clean   (needed for anything that drops databases)"

# ------------------------------------------------------------- setup

install: ## Install everything the book build needs (mdbook, poppler, libpq, Chrome); safe to re-run
	@command -v brew >/dev/null || { echo "Homebrew is required: https://brew.sh"; exit 1; }
	@command -v python3 >/dev/null || { echo "python3 is required (book.sh uses it to split the PDF)"; exit 1; }
	@for f in mdbook poppler libpq; do \
	  if brew list --formula "$$f" >/dev/null 2>&1; then echo "ok        $$f"; \
	  else echo "installing $$f"; brew install "$$f" || exit 1; fi; done
	@if [ -d "/Applications/Google Chrome.app" ]; then echo "ok        Google Chrome"; \
	  else echo "installing Google Chrome"; brew install --cask google-chrome || exit 1; fi
	@echo ""
	@echo "Book tools ready. For the verification database, start Colima and the"
	@echo "pk017347-test-pgdb container (port $(PGPORT)), then run: make db-check"

# ---------------------------------------------------------------- book

serve: ## Browsable site at http://localhost:3000 (re-run after editing manuscript/)
	./book.sh serve

stop: ## Stop a running `mdbook serve` (it shares .book-src/.book-out with build and pdf)
	@pkill -f "mdbook serve" && echo "stopped mdbook serve" || echo "no mdbook serve running"
	@pkill -f "book.sh serve" 2>/dev/null || true

build: ## Static site into .book-out/
	./book.sh build

pdf: ## The PDF: chunked print with cover, page numbers and running headers
	@if pgrep -f "mdbook serve" >/dev/null; then \
	  echo "mdbook serve is running and shares .book-src/.book-out with the PDF build."; \
	  echo "Run 'make stop' first."; exit 1; fi
	./book.sh pdf

open-pdf: ## Open the PDF (macOS)
	open $(PDF)

clean: ## Remove generated output (.book-src/, .book-out/, the PDF)
	rm -rf .book-src .book-out $(PDF)

# ------------------------------------------------------------- writing

words: ## Word count per chapter and workbook (house length: 2,500-4,000, see CONVENTIONS.md)
	@for f in manuscript/part-*/ch*.md manuscript/exercises/ch*.md; do \
	  printf "%6d  %s\n" $$(wc -w < $$f) $$f; done | sort -k2 | awk '{n++; t+=$$1; print} END {printf "%6d  total in %d files\n", t, n}'

stats: ## Progress: chapters, workbook files, practice sessions
	@echo "chapters:          $$(ls manuscript/part-*/ch*.md 2>/dev/null | wc -l | tr -d ' ') of 54"
	@echo "workbook files:    $$(ls manuscript/exercises/ch*.md 2>/dev/null | wc -l | tr -d ' ')"
	@echo "practice sessions: $$(grep -h '^## Practice Session' manuscript/exercises/ch*.md | wc -l | tr -d ' ')"
	@echo "words (all):       $$(cat manuscript/*/*.md | wc -w | tr -d ' ')"

todo: ## Find BENCHMARK-TODO / TODO / FIXME markers left in the manuscript
	@grep -rnE "BENCHMARK-TODO|TODO|FIXME" manuscript || echo "none"

errata: ## Show outstanding defects (ERRATA-OPEN.md)
	@cat ERRATA-OPEN.md

# ------------------------------------------------------------ database

guard-port:
	@if [ "$(PGPORT)" = "5432" ]; then \
	  echo "Refusing to run against port 5432: that is your real working database."; exit 1; fi

db-check: guard-port ## Is the test container up? Shows version and the sample databases
	@psql -P null='(null)' -d postgres -Atc "SELECT version()" || \
	  { echo "Cannot reach $(PGHOST):$(PGPORT). Try: colima start"; exit 1; }
	@psql -d postgres -Atc "SELECT datname FROM pg_database WHERE datname IN ('retail','hr','telemetry','retail_lg') ORDER BY 1" | sed 's/^/  loaded: /'

db-list: guard-port ## List leftover chapter scratch databases and roles
	@echo "scratch databases:"; psql -d postgres -Atc "SELECT datname FROM pg_database WHERE datname ~ '$(SCRATCH_DB_RE)' ORDER BY 1" | sed 's/^/  /'
	@echo "scratch roles:";     psql -d postgres -Atc "SELECT rolname FROM pg_roles WHERE rolname ~ '$(SCRATCH_ROLE_RE)' ORDER BY 1" | sed 's/^/  /'

db-clean: guard-port ## Drop scratch databases and roles (needs CONFIRM=yes)
	@$(MAKE) --no-print-directory db-list
	@if [ "$(CONFIRM)" != "yes" ]; then echo "Nothing dropped. Re-run with CONFIRM=yes."; exit 0; fi; \
	for d in $$(psql -d postgres -Atc "SELECT datname FROM pg_database WHERE datname ~ '$(SCRATCH_DB_RE)'"); do dropdb --if-exists "$$d" && echo "dropped database $$d"; done; \
	for r in $$(psql -d postgres -Atc "SELECT rolname FROM pg_roles WHERE rolname ~ '$(SCRATCH_ROLE_RE)'"); do \
	  psql -d postgres -qc "DROP OWNED BY $$r" && psql -d postgres -qc "DROP ROLE IF EXISTS $$r" && echo "dropped role $$r"; done

psql: guard-port ## psql shell with NULL shown as (null); DB=retail by default
	psql -P null='(null)' -d $(or $(DB),retail)

load-datasets: guard-port ## Reload retail/hr/telemetry small datasets (DROPS and recreates them; needs CONFIRM=yes)
	@if [ "$(CONFIRM)" != "yes" ]; then \
	  echo "This drops and recreates the retail, hr and telemetry databases on port $(PGPORT)."; \
	  echo "Re-run with CONFIRM=yes."; exit 1; fi
	cd datasets && ./load.sh all sm
