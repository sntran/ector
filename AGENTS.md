# Ector: AI Agent Context & Directives

**Target Audience:** AI Coding Assistants (Cursor, Copilot, Gemini, Claude, etc.) and human maintainers.
**Purpose:** Provide maximum architectural context with minimal token overhead. Adhere strictly to these rules when generating or refactoring code for Ector.

## 1. Project Identity
Ector is a **Dynamic Schema Engine**. It acts as a drop-in replacement for Ecto.
* **Mechanism:** It maps relational developer intent (`Ecto.Schema`, `Ecto.Changeset`, `Ecto.Query`) down to a highly optimized, two-table JSONB storage backend (`nodes` and `edges`).
* **Environment:** Elixir 1.20+, Erlang 29+, Ecto 3.14+.
* **Adapters:** PostgreSQL (using `jsonb`, `jsonb_set`) and SQLite3 (using `json`, `json_set`).

## 2. Core Architectural Invariants (DO NOT BREAK)

### A. The Schema & Identity Boundary
* **User Identity:** The developer owns the top-level struct `id` field (or whatever they declare via `@primary_key`).
* **Database Identity:** Ector tracks database topology via a hidden UUIDv7 field named `__id__`.
* **Rule:** Never allow Ector to overwrite the user's `id`. Hydration (`Ector.Repo.all`) must explicitly map the database `id` column to the struct's `__id__` virtual field.

### B. No Global Registries
* **Rule:** Do NOT use dynamic metadata or global registries to map a string label (e.g., `"User"`) back to an Elixir module (`MyApp.User`) during hydration.
* **Enforcement:** `Ector.Repo.all/1` must inspect the `Ecto.Query` struct (`query.from.source`) to determine the target struct. Ector is strictly stateless.

### C. AST Redirection, NOT Raw SQL
* **Rule:** Do not write raw SQL (e.g., `Ecto.Adapters.SQL.query`) for dynamic queries or updates. Ector relies on Ecto's native query planner.
* **Query Builder (`Ector.Query`):** Use `Macro.prewalk/2` to rewrite Elixir AST. Convert field accesses (e.g., `c.status`) into Ecto's native JSON bracket notation (e.g., `c.properties["status"]`). Ecto 3.14+ handles the dialect-safe SQL generation natively. Exclude `__id__` from this rewrite.
* **Atomic JSON Updates:** Use `Ector.Repo.update_all(Repo, query, inc: [...])`, `set: [...]`, and `push: [...]` for domain property mutations. If the app repo uses `use Ector.Repo`, the repo-bound forms (`query |> Repo.update_all(inc: [...])`) are preferred inside application contexts. Do not replace these with raw `fragment/1` SQL strings for JSON updates.

### D. Native Prefix Inheritance (Multi-Tenancy)
* **Rule:** When dynamically injecting hidden table joins (e.g., in `Ector.join/3`), **NEVER** explicitly set or hardcode the `prefix:` option in the injected AST.
* **Why:** Omitting the prefix allows Ecto's query planner to natively cascade the user's execution prefix (from `from` or `Repo.all(prefix: "X")`) down to all tables automatically.

### E. Modern BEAM Utilization
* **Typing:** Use Elixir 1.20 gradual type specs (`$type`) heavily on API boundaries (e.g., `Ector.Changeset.put_edge/3`).
* **JSON:** Use Erlang 29's native C-backed `json` module (via Elixir's `JSON` wrapper) for all internal serialization. Do not introduce `Jason` or `Poison`.

## 3. Key Design Patterns

### The Tuple Payload Strategy (Nested Inserts)
When inserting nodes and edges simultaneously, developers pass a tuple of `{target_changeset, edge_properties_map}`.
* **Execution:** The Ector repo insert boundary recursively traverses the changeset. It executes an `Ecto.Multi` transaction: Insert Source Node -> Insert Target Node -> Build Edge Payload using extracted `__id__`s -> Insert Edge.

### Deterministic Edge Aliasing (Dynamic Joins)
When a user writes `Ector.join(:carts, as: :cart)`, they are requesting a logical join.
* **Execution:** `Ector.Query.join/3` intercepts this and injects TWO physical Ecto joins.
  1. A hidden join to the `edges` table with an injected deterministic alias (`as: :__edge_cart`).
  2. A join to the target `nodes` table, applying the user's requested alias (`as: :cart`).
* This ensures subsequent `Ector.where([cart: c], ...)` clauses bind perfectly to the target node.
* **Usage Boundary:** Use `Ector.join/3` when the query must filter, order, or project through an association. Use `Repo.preload/2` or `Repo.preload/3` when the query already has the boundary structs and only needs association hydration for display or context return values.

### Implicit Edge Routing
Associations no longer require custom edge modules or symbolic `through:` labels when the edge has no properties.
* **Forward Lookup:** For `has_many` / `has_one`, derive the edge label from the association name unless `through:` names a custom `Ector.Edge` module or symbolic label.
* **Reverse Lookup:** For `belongs_to` without a JSON UUID foreign key and without `through:`, infer the parent-side outgoing association label when exactly one matching parent association exists, then traverse `edges.target_id == child.__id__`.
* **Rule:** Do not generate edge modules for property-less relationships. Edge modules are only warranted when the relationship itself owns domain fields.

### Preferred Association Hydration (Repo.preload)
Display hydration should now use Ector's preload engine.
* **Rule:** `Repo.preload` is the preferred method for hydrating Ector schema associations.
* **Execution:** `Ector.Repo.preload/4` accepts standard Ecto preload syntax, batches top-level association loads, traverses `edges` and `nodes` for `has_many` / `has_one`, resolves UUIDv7 JSON references for `belongs_to`, and recursively resolves nested preloads.
* **Examples:** Use `offer |> Repo.preload(:product)` and `cart |> Repo.preload(items: [offer: :product])` instead of hand-written display-only graph joins.

### Adapter-Aware AST Injection (Bulk Updates)
When a user executes `Ector.Repo.update_all(Repo, query, set: [status: "archived"])`, Ector cannot use simple AST rewriting because Postgres and SQLite handle JSON mutations differently.
* **Execution:** Detect the adapter (`@ecto_repo.__adapter__()`). Delegate to `Ector.Translator.Postgres` (builds nested `jsonb_set` fragments) or `Ector.Translator.SQLite` (builds variadic `json_set` fragments). Pass the generated AST directly to native `Ecto.Repo.update_all/3`.
* **Operators:** Preserve idiomatic Ecto operators: `set: [status: "archived"]`, `inc: [quantity: -quantity]`, and `push: [events: event]`.
* **Checkout Invariant:** Atomic stock decrements must stay database-side through `Ector.Repo.update_all(repo, query, inc: [quantity: -quantity])` or a repo-bound equivalent, guarded by JSON quantity predicates in the query.

### Single-Cursor Base64 Envelope (LiveView Pagination)
The storefront uses one URL-safe cursor parameter for both directions.
* **Contract:** Public URLs use only `?cursor=token`; do not reintroduce split `after` / `before` params.
* **Envelope:** Encode `%{value: storage_uuid, dir: "next" | "prev"}` with `JSON.encode_to_iodata!() |> IO.iodata_to_binary() |> Base.url_encode64(padding: false)`.
* **Decode:** The decoded `dir` is the source of truth for pagination direction, and `value` must cast as an Ecto UUIDv7 storage cursor.

## 4. File Layout Map
* `lib/ector.ex` — Top-level API delegates.
* `lib/ector/migration.ex` — Core table `up/down` and smart `index/3` macro.
* `lib/ector/node.ex` & `edge.ex` — Ecto Persona macros (`schema do`, `has_many`, implicit labels).
* `lib/ector/changeset.ex` — `put_edge/3` logic.
* `lib/ector/repo.ex` — Unified execution wrapper (`all`, `insert`, `update`, `update_all`, `preload`).
* `lib/ector/query.ex` — The AST rewriter (`from`, `where`, `join`, `select`).
* `lib/ector/translator/*.ex` — Dialect-specific JSON update fragment generators.
