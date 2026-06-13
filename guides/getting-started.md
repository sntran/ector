# Getting Started

This guide walks through installing Ector, defining your first graph schema,
and reading and writing data — all using familiar Ecto mechanics.

## 1. Install the core engine

Ector needs exactly one migration to set up its shared `nodes` and `edges`
tables. Generate a migration and call `up/0`:

```elixir
defmodule MyApp.Repo.Migrations.InstallEctor do
  use Ector.Migration

  def change do
    up()
  end
end
```

This creates the two-table topology (UUIDv7 primary keys, JSONB `properties`),
the routing indexes, and — on PostgreSQL — a GIN index on `nodes.properties`.

## 2. Wire up a repo

```elixir
defmodule MyApp.Repo do
  use Ector.Repo, otp_app: :my_app, adapter: Ecto.Adapters.Postgres
end
```

`Ector.Repo` is a drop-in `Ecto.Repo`: it keeps the standard process and
adapter behavior while teaching `all`, `one`, `insert`, `update`, `delete`,
`delete_all`, and `update_all` to speak Ector's storage shape.

## 3. Define nodes and associations

You own your business identifier (`id`). Ector tracks topology with a hidden
`__id__` (UUIDv7) so your IDs are never overwritten.

```elixir
defmodule MyApp.Customer do
  use Ector.Node

  schema do
    field :email, :string
    field :name, :string

    has_many :carts, MyApp.Cart
  end
end

defmodule MyApp.Cart do
  use Ector.Node

  schema do
    field :status, :string
  end
end
```

When an association does not need edge properties, omit `through:` and Ector
will route it through the generic `edges` table using the association name as
the edge label. Add a symbolic `through:` label or an `Ector.Edge` module only
when you need a stable custom label or edge-specific fields.

Add a new field whenever your domain changes — **no database migration
required.**

## 4. Insert a graph

Use `Ector.Changeset.put_edge/3` to attach target nodes alongside the
properties stored on the connecting edge. The whole graph is written in one
transaction.

```elixir
cart = MyApp.Cart.changeset(%MyApp.Cart{}, %{id: "cart-1", status: "active"})

{:ok, customer} =
  MyApp.Customer.changeset(%MyApp.Customer{}, %{id: "cust-1", email: "ada@example.com"})
  |> Ector.Changeset.put_edge(:carts, [{cart, %{"created_via" => "web"}}])
  |> MyApp.Repo.insert()
```

## 5. Query with the façade

`import Ector` gives you the relational DSL, backed by JSON storage:

```elixir
import Ector

active_emails =
  from(c in MyApp.Customer)
  |> where([c], c.email == ^"ada@example.com")
  |> select([c], c.email)
  |> MyApp.Repo.all()
```

For relationships, `Ector.join/3` expands a logical association into the hidden
edge join plus the target node join:

```elixir
import Ector

from(c in MyApp.Customer)
|> join(:carts, as: :cart)
|> where([cart: cart], cart.status == ^"active")
|> select([c, cart: cart], {c.email, cart.status})
|> MyApp.Repo.all()
```

## 6. Update and delete

Single-struct updates and deletes operate through the hidden `__id__`:

```elixir
{:ok, _} =
  customer
  |> MyApp.Customer.changeset(%{name: "Ada Lovelace"})
  |> MyApp.Repo.update()
```

Bulk updates rewrite into adapter-native JSON mutations
(`jsonb_set` on PostgreSQL, `json_set` on SQLite):

```elixir
import Ector

from(c in MyApp.Cart)
|> where([c], c.status == ^"active")
|> MyApp.Repo.update_all(set: [status: "archived"])
```

## Next steps

- See [API Stability](STABILITY.md) for what's safe to depend on.
- See the README for indexing patterns, multi-tenancy, and current limitations
  (e.g. `preload/2` is not yet supported — use `Ector.join/3` + `select/3`).
