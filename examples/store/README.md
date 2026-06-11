# Store Showcase

`examples/store` is a standalone zero-migration storefront backed by Ector. The
domain is modeled with ordinary schema fields and association macros, but the
database stores only the shared `nodes` and `edges` topology plus partial JSON
expression indexes.

## Directory Tree

```text
examples/store/
├── bench/store_bench.exs
├── config/
├── lib/
│   ├── store.ex
│   └── store/
│       ├── application.ex
│       ├── catalog.ex
│       ├── catalog/
│       │   ├── offer.ex
│       │   └── product.ex
│       ├── checkout.ex
│       ├── checkout/
│       │   ├── cart.ex
│       │   └── cart_item.ex
│       ├── repo.ex
│       ├── sandbox.ex
│       └── storage.ex
├── priv/repo/
│   ├── migrations/
│   └── seeds.exs
├── test/
├── mix.exs
└── mix.lock
```

## SQLite Run

SQLite is the default adapter and needs no external service.

```bash
cd examples/store
mix deps.get
mix test
mix run priv/repo/seeds.exs
mix phx.server
BENCH_N=1000 mix run bench/store_bench.exs
```

After `mix phx.server`, open `http://localhost:4000` to browse the LiveView
catalog, filter by vendor, sort by price, add items to the cart, and view the
checkout page.

When running from a checkout that already has the root deps installed:

```bash
cd examples/store
MIX_DEPS_PATH=../../deps mix test
```

## PostgreSQL Run

The repo adapter is compiled from `STORE_ADAPTER`, so clean the example build
when switching adapters.

```bash
cd examples/store
STORE_ADAPTER=postgres STORE_DATABASE_URL=postgres://user:pass@localhost/store_example mix clean
STORE_ADAPTER=postgres STORE_DATABASE_URL=postgres://user:pass@localhost/store_example mix test
```

## What The Tests Prove

The integration suite resets and migrates one Ector repo, then asserts:

* only `nodes`, `edges`, and the migration table are installed;
* the Offer uniqueness index targets JSON `product_id` and `offered_by` while
  staying scoped to the `Offer` label;
* offer listing uses denormalized Offer text and cursor pagination over
  descending `__id__`; and
* cart summaries load `Cart -> CartItem -> Offer -> Product` with
  `Ector.join/3` and `Ector.select/3`, without `preload/2`.

Run the browser-facing smoke tests with the same command:

```bash
mix test
```
