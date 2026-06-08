# Store Showcase

`examples/store` is a standalone Mix project that compares one e-commerce
domain implemented two ways:

* `Store.Relational` uses normal Ecto schemas, migrations, tables, foreign keys,
  and B-tree indexes.
* `Store.Ector` uses `Ector.Node` and `Ector.Edge` schemas over the shared
  `nodes` / `edges` storage engine, including JSON property indexes and hidden
  edge joins.

The project links to the local library with `{:ector, path: "../../"}` so it can
serve as consumer documentation, an integration suite, and a benchmark harness.

## Directory Tree

```text
examples/store/
├── bench/
│   └── store_bench.exs
├── config/
│   ├── config.exs
│   ├── dev.exs
│   ├── prod.exs
│   └── test.exs
├── lib/
│   ├── store.ex
│   └── store/
│       ├── application.ex
│       ├── catalog.ex
│       ├── ector/
│       │   ├── cart.ex
│       │   ├── contains.ex
│       │   ├── customer.ex
│       │   ├── dynamic.ex
│       │   ├── has_cart.ex
│       │   └── product.ex
│       ├── ector_repo.ex
│       ├── relational/
│       │   ├── cart.ex
│       │   ├── cart_item.ex
│       │   ├── customer.ex
│       │   └── product.ex
│       ├── relational_repo.ex
│       └── sandbox.ex
├── priv/
│   ├── ector_repo/migrations/
│   └── relational_repo/migrations/
├── test/
│   ├── store_integration_test.exs
│   └── test_helper.exs
├── mix.exs
└── mix.lock
```

## SQLite Run

SQLite is the default adapter and needs no external service.

```bash
cd examples/store
mix deps.get
mix test
BENCH_N=500 mix run bench/store_bench.exs
```

For a quick harness smoke test, shorten the Benchee timing window:

```bash
BENCH_N=3 BENCH_WARMUP=0 BENCH_TIME=0.1 mix run bench/store_bench.exs
```

When running from a checkout that already has the root deps installed, this also
works without touching Hex:

```bash
cd examples/store
MIX_DEPS_PATH=../../deps mix test
```

## PostgreSQL Run

The repo adapter is compiled from `STORE_ADAPTER`, so clean the example build
when switching between SQLite and PostgreSQL.

```bash
cd examples/store
STORE_ADAPTER=postgres STORE_DATABASE_URL=postgres://user:pass@localhost/store_example mix clean
STORE_ADAPTER=postgres STORE_DATABASE_URL=postgres://user:pass@localhost/store_example mix test
STORE_ADAPTER=postgres STORE_DATABASE_URL=postgres://user:pass@localhost/store_example BENCH_N=500 mix run bench/store_bench.exs
```

Use `STORE_RELATIONAL_DATABASE_URL` and `STORE_ECTOR_DATABASE_URL` to isolate the
two repos into separate PostgreSQL databases. If they are omitted, both repos use
`STORE_DATABASE_URL` with separate migration tables and non-overlapping storage
tables.

## What The Tests Prove

The integration suite resets and migrates both repos, then asserts that the two
implementations produce the same business data for:

* complex product filters by category and status;
* cart association loading through relational joins and Ector hidden edge joins;
* filtered bulk updates over relational columns and Ector JSON properties;
* dynamic Ector schema expansion with an unmigrated `Review` node; and
* runtime-only product attributes such as `warranty_months` and `clearance`.

Current local SQLite result:

```text
Result: 7 passed
```

## Benchmark Scenarios

`bench/store_bench.exs` runs four head-to-head Benchee groups:

* product inserts: normalized rows vs Ector node inserts;
* complex filters: B-tree index over columns vs partial JSON property index;
* association load: relational preload vs Ector graph join and projection;
* filtered bulk update: column update vs adapter-native JSON mutation.

The benchmark prints the selected adapter (`sqlite` or `postgres`) at startup.
Run it once with the default SQLite config and once with `STORE_ADAPTER=postgres`
to collect the trade-off profile for both backends.
