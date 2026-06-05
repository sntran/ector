Software Requirements Document (SRD)
====================================

Project: Ector
--------------

**Type:** Dynamic Schema Engine / Ecto Database Wrapper

### 1\. Project Overview

**Ector** is a drop-in replacement and extension for `Ecto` in the Elixir ecosystem. It abstracts a highly flexible, JSONB-backed topology behind pure `Ecto.Schema` and `Ecto.Changeset` mechanics. It provides the exact same developer experience as relational Ecto while eliminating the need to write structural database migrations when domain requirements change.

### 2\. Technical Environment & Constraints

The library must aggressively leverage modern BEAM capabilities for performance and safety:

-   **Erlang/OTP:** 29+ (Must utilize the native C-backed `json` module for encoding/decoding overhead reduction).

-   **Elixir:** 1.20+ (Must utilize the native `JSON` module wrapper and integrate the new gradual type system for API boundaries).

-   **Ecto:** 3.14+ (Required for native UUIDv7 autogeneration, advanced JSON path operators, and modernized AST structures).

### 3\. Storage Architecture (The Zero-Migration Core)

Ector relies on a static, two-table database footprint.

#### 3.1. Database Tables

-   **Tables:** `nodes` and `edges` (generic tables, isolated from standard application tables).

-   **Primary Keys:** Must utilize native Ecto **UUIDv7** for `id` columns.

-   **Storage Payload:** Business data is stored in a `properties` column. Both PostgreSQL and SQLite adapters must utilize **JSONB** natively.

-   **Timestamps:** Default Ecto `timestamps()` are strictly omitted. Creation time is derived implicitly from the UUIDv7 48-bit prefix.

#### 3.2. High-Performance Indexing

-   **Default GIN Index (PostgreSQL):** The core migration must automatically generate a Generalized Inverted Index (GIN) on the `properties` column (`CREATE INDEX nodes_properties_gin ON nodes USING GIN (properties)`). This guarantees high-speed queries across all dynamic fields without full-table scans.

-   **Partial Indexes (Documentation Requirement):** The library documentation must explicitly provide patterns for developers to write standard Ecto migrations that add partial B-tree/Expression indexes for highly accessed fields (e.g., specific ERP or e-commerce attributes) in both PG and SQLite.

#### 3.3. Namespace Isolation (Multi-Tenancy)

The underlying architecture relies on **Native Prefix Inheritance (Zero-Touch Propagation)**. Ector must **never** hardcode or manually apply prefixes to internal AST joins. By omitting the prefix on dynamically injected joins, Ecto's native query planner will automatically cascade the parent query's prefix down to all underlying tables.

#### 3.4. Packaged Core Migrations

Developers do not write manual migrations for the core tables. Ector provides an up/down execution function.

Elixir

```
def up(opts \\ []) do
  prefix = Keyword.get(opts, :prefix)

  create table(:nodes, primary_key: false, prefix: prefix) do
    add :id, :uuid, primary_key: true
    add :label, :string, null: false
    add :properties, :map, default: "{}", null: false
  end
  # ... edges table setup ...
  # ... default label and GIN index execution ...
end

```

#### 3.5. Smart Index Wrappers (`use Ector.Migration`)

When developers need to add partial/unique indexes for highly accessed business fields, Ector provides a drop-in migration wrapper.

-   **Implementation:** The `Ector.Migration.__using__/1` macro calls `use Ecto.Migration`, un-imports Ecto's native `index/2` and `index/3`, and injects Ector's smart wrappers.

-   **Smart `index/3` Behavior:** The macro intercepts the call (e.g., `create index(MyApp.User, [:email])`), extracts the implicit label `"User"`, rewrites the columns to JSONB path expressions `(properties->>'email')`, and automatically applies `where: "label = 'User'"` to ensure it is a safe partial index. It returns a standard `%Ecto.Migration.Index{}` struct that Ecto executes natively.

### 4\. Domain Modeling (The Ecto Persona)

Entities are defined using intuitive macros that mirror Ecto.

#### 4.1. Node & Edge Definitions

-   **Macros:** `use Ector.Node` and `use Ector.Edge`.

-   **Implicit Labels:** The internal routing label is deduced from the module's base name (`MyApp.User` -> `"User"`).

-   **Schema Definition:** `schema do ... end` wraps `embedded_schema`. If developers need to store arbitrary, undefined payloads, they use a standard `field :dynamic_attributes, :map, default: %{}`. Standard Ecto attributes (like `@primary_key`) are fully respected.

#### 4.2. Identity Isolation

The developer defines their own primary `field :id, :string` for their business logic, or uses `@primary_key`. The macro safely injects the database UUIDv7 as a hidden tracking field (`field :__id__, Ecto.UUID`).

#### 4.3. Association Metadata

Ecto's native association macros are bypassed. Custom `has_many`, `has_one` (outgoing), and `belongs_to` (incoming) macros register routing logic directly into a compiled `@ector_associations` module attribute.

### 5\. The Execution Gateway (`Ector.Repo`)

A code generation macro (`use Ector.Repo, ecto_repo: MyApp.Repo`) that wraps the standard Ecto Repo with unified API signatures.

#### 5.1. Hydration & Strict Query Context

Ector must NEVER use a dynamic global registry to match string labels back to Elixir modules. Hydration inspects the compiled `Ecto.Query` struct to find the requested domain module (e.g., `query.from.source`), mapping the raw JSONB row back into that exact struct and copying the `id` column to `__id__`.

#### 5.2. Unified Insertions & Typed Tuple Payloads

To handle intermediate edge properties seamlessly, Ector provides `Ector.Changeset.put_edge/3` to associate target nodes alongside their edge properties inside a single `Repo.transaction`.

-   **Type System Integration:** `put_edge/3` must utilize Elixir 1.20+ gradual type specifications to strictly enforce the Tuple Payload structure (`[{Changeset.t(), map()}]`), catching malformed payloads at compile time.

#### 5.3. Unified Updates & Adapter-Aware AST Injection

Updating a single struct operates via the hidden `__id__`. Bulk updates intercept the `set: [...]` command and generate dialect-specific `Ecto.Query.API.fragment/1` ASTs (e.g., nested `jsonb_set` for PG, variadic `json_set` for SQLite).

-   **Native JSON Serialization:** Ector must strictly utilize the native Elixir 1.20 `JSON` module to encode parameter payloads into the fragments, avoiding external dependencies.

### 6\. The Query Builder Engine (`Ector.Query`)

A complete drop-in replacement for `Ecto.Query` that translates standard Elixir ASTs into optimized JSONB SQL.

#### 6.1. Generalized AST Redirection

Ector must intercept the full suite of query macros (`from`, `where`, `select`, `order_by`, `group_by`, `having`). It acts as a hygienic AST rewriter, converting standard field accesses (e.g., `c.status`) into Ecto's native dynamic JSON path syntax (e.g., `c.properties["status"]`). This guarantees cross-dialect compatibility and secure parameterization via Ecto 3.14+ without injecting explicit SQL casts.

#### 6.2. Dynamic Joins (`join/3`) & Deterministic Edge Aliasing

When a developer requests a logical domain join (`Ector.join(:carts, as: :cart)`), Ector looks up the `@ector_associations` metadata. It injects a hidden join for the `edges` table (e.g., `as: :__edge_cart`) and assigns the requested `:cart` alias strictly to the final `nodes` table join, preserving standard named-binding resolution for the rest of the query pipeline.