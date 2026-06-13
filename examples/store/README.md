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

## Architecture Patterns

The example is intentionally small, but it exercises the production paths that
matter for Ector-backed applications.

### Denormalized Offer Boundary

`Store.Catalog.Offer` is the catalog read boundary. It stores the fields needed
for search, filtering, sorting, and cursor pagination directly on the Offer
node: product id, vendor, price, quantity, product name, and product
description. That keeps infinite scroll on one Ector query over Offer
properties.

`Store.Catalog.Product` still owns product media. The catalog preloads the
Product hop only for visible cards and detail pages:

```elixir
Offer
|> Ector.from()
|> Repo.all()
|> Repo.preload(:product)
```

The store intentionally mirrors a standard Ecto join-table setup for cart
lines. `Store.Checkout.CartItem` is a normal node with `belongs_to :cart` and
`belongs_to :offer`, and it owns the line-specific `quantity` and
`price_at_addition` fields. Ector turns those ordinary associations into
implicit graph edges, so the example stays close to a legacy Ecto application
while still using the shared `nodes` and `edges` storage engine.

### Single-Cursor Bidirectional Pagination

The LiveView catalog uses one public query parameter: `?cursor=token`. The token
is a URL-safe Base64 envelope containing the storage cursor and direction:

```elixir
%{value: offer.__id__, dir: "next"}
|> JSON.encode_to_iodata!()
|> IO.iodata_to_binary()
|> Base.url_encode64(padding: false)
```

The decoded `dir` drives whether the query asks for the next or previous page.
No split `after` / `before` URL state is required.

### Implicit CartItem Cart Summary

Checkout fetches the selected `Cart` by business id and uses a standard nested
preload to hydrate the visible cart-line graph:

```elixir
cart
|> Repo.preload(items: [offer: :product])
```

That resolves `Cart -> CartItem -> Offer -> Product` through Ector's implicit
edge routing without adding any storefront-specific relationship module.

### Atomic Flash Sale Checkout

Checkout uses an `Ecto.Multi` transaction for stock reservation and cart
conversion. Each stock decrement stays in the database through Ector's
operator-style JSON update translation:

```elixir
query
|> Ector.Repo.update_all(repo, inc: [quantity: -quantity])
```

The decrement query is guarded by the current JSON quantity
(`quantity > 0` and `quantity >= ^quantity`). If any line is out of stock, the
transaction rolls back and the cart remains active.

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
  descending `__id__`;
* cart summaries read `Cart -> CartItem -> Offer -> Product` through a standard
  nested preload; and
* checkout decrements stock atomically with `inc: [quantity: -quantity]` before
  converting the cart.

Run the browser-facing smoke tests with the same command:

```bash
mix test
```
