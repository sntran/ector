# Ector

**The Dynamic Schema Engine for Elixir.** Zero-migration, JSONB-backed topology behind pure `Ecto.Schema` and `Ecto.Changeset` mechanics.

Ector is a drop-in replacement and extension for `Ecto`. It allows you to build highly flexible, data-driven applications (like ERPs, liquidation platforms, or EAV-heavy systems) without ever writing a structural database migration when your business domain changes.

## Why Ector?

In standard relational databases, handling highly dynamic data where products might have wildly varying attributes, or external integrations send unpredictable payloads usually leads to one of three nightmares:
1. **The Migration Treadmill:** Endlessly adding nullable columns (`custom_field_1`, `custom_field_2`).
2. **The EAV Anti-Pattern:** A massive `Entity-Attribute-Value` table that destroys query performance and makes SQL joins unreadable.
3. **The Schema-less Void:** Dumping everything into a JSON column and losing Ecto's powerful type-casting, validations, and compile-time guarantees.

**Ector gives you the best of both worlds.** You define standard Elixir modules using `Ector.Node` and `Ector.Edge`. You use standard `Ecto.Changeset` to validate data. You query using standard `Ecto.Query`. But under the hood, Ector seamlessly compiles your domain into a high-performance, two-table JSONB storage engine (`nodes` and `edges`). 

Add a new field to your schema? Just type it and deploy. Zero database migrations required.

## What Ector Brings to the Table

* **Pure Ecto Developer Experience:** If you know Ecto, you know Ector. It mirrors the exact APIs you are used to.
* **Zero Migrations for Domain Entities:** Only one migration is needed to set up the core engine. After that, schemas are defined purely in application code.
* **Identity Isolation:** You own your `id` field (e.g., Stripe ID, ERP ID). Ector manages the database topology silently using a hidden `__id__` (UUIDv7).
* **Multi-Tenant Ready:** Native, zero-touch support for Ecto's `prefix` option across all queries and hidden joins.
* **High Performance:** Leverages native UUIDv7 for time-ordered B-tree indexing, and fully supports PostgreSQL GIN indexing and SQLite binary JSON.
* **Modern BEAM Power:** Built strictly for Elixir 1.20+ and Erlang 29+, utilizing gradual typing and the native C-backed `JSON` module for maximum throughput.

## What Ector Cannot Do (Limitations)

To maintain a pure Ecto experience, Ector makes specific architectural trade-offs:
* **It is not a Graph Database:** While backed by nodes and edges, Ector does not expose a graph query language (like Cypher or Gremlin) or handle infinite-depth recursive graph algorithms. It maps relational intent to a graph structure.
* **No Database-Level Foreign Keys for Domain Fields:** Because your data lives in JSONB, you cannot enforce standard SQL foreign key constraints on domain fields (e.g., `user_id` inside the properties JSON). You must rely on Ecto constraints and Ector's edge topology.
* **No `preload/2` (Yet):** Standard Ecto preloading is not supported due to the hidden double-hop edge joins. You should use `Ector.join/3` and `Ector.select/3` to build aggregate payloads.

## Extensibility & Optimizations

Because your data lives in JSONB, full-table scans are a risk if you don't index properly. Ector provides a smart migration wrapper to make indexing nested JSON fields feel exactly like standard Ecto.

### 1. Adding Partial JSON Indexes
You can add highly-optimized expression indexes to your domain fields using `use Ector.Migration`. Ector automatically scopes the index to your specific node label to prevent cross-schema collisions.

```elixir
defmodule MyApp.Repo.Migrations.AddUserIndexes do
  use Ector.Migration # Drop-in replacement!

  def change do
    # Compiles to a partial, JSONB expression index targeting ONLY the "User" label
    create index(MyApp.User, [:email])
    create index(MyApp.User, [:stripe_id], unique: true)
  end
end
```

### 2. Full-Text & Fuzzy Search

Because Ector maps to native Postgres/SQLite JSON columns under the hood, you can easily write standard Ecto migrations to leverage database-specific extensions like `pg_trgm` (trigram fuzzy search) against specific Ector schema fields.

Technical Architecture
----------------------

Ector operates across a few key boundaries to maintain the Ecto illusion:

-   **The Storage Engine:** Two generic tables (`nodes` and `edges`) using UUIDv7 primary keys. Default timestamps are omitted. Data lives in a `properties` map.

-   **AST Redirection:** `Ector.Query` macros (`from`, `where`, `select`) hygienically rewrite your Elixir AST at compile time. `u.status == "active"` is rewritten to Ecto's native dynamic JSON path syntax: `u.properties["status"] == "active"`.

-   **Adapter-Aware Bulk Mutations:** When running bulk `update_all` queries, `Ector.Repo` dynamically generates database-specific AST fragments (`jsonb_set` for Postgres, variadic `json_set` for SQLite) to update JSON fields atomically without pulling records into memory.

-   **Deterministic Edge Aliasing:** When you call `Ector.join(:carts, as: :cart)`, Ector injects a hidden join for the intermediate `edges` table, and applies your `:cart` alias directly to the target node. This keeps your bindings clean and predictable.

Contributing
------------

We welcome contributions! Ector is pushing the boundaries of what Ecto's compiler and modern Elixir can do.

1.  Review the open issues to see what's currently prioritized.

2.  **Crucial:** Read `AGENTS.md` before diving into the codebase. It contains the strict architectural invariants and design patterns that govern Ector. If you use AI coding assistants (like Copilot, Cursor, or Gemini), feed them `AGENTS.md` to ensure they don't break the query compiler hygiene.

3.  Ensure all tests pass across both Postgres and SQLite adapters.

*Built for the modern BEAM.*