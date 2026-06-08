# API Stability

Ector follows [Semantic Versioning](https://semver.org/). This document defines
which parts of the codebase are covered by that contract so you know what you
can rely on and what may change without a major version bump.

## Public API (SemVer-stable)

These modules and functions are the supported surface. Breaking changes here
only happen in a major release and are documented in the [CHANGELOG](CHANGELOG.md).

| Module | What you depend on |
|--------|--------------------|
| `Ector` | The query façade macros (`from`, `where`, `select`, `join`, …). |
| `Ector.Node` / `Ector.Edge` | The `use` macro, `schema do … end`, and the `has_many`/`has_one`/`belongs_to` association DSL. |
| `Ector.Changeset` | `put_edge/3` and the tuple-payload shape. |
| `Ector.Repo` | The `use Ector.Repo` macro and the overridden `Ecto.Repo` callbacks (`all`, `one`, `insert`, `update`, `delete`, `delete_all`, `update_all`). |
| `Ector.Migration` | `use Ector.Migration`, `up/1`, `down/1`, and the smart `index/3`. |
| `Ector.Query` | The query-building macros. |

### Stable reflection

The generated reflection callbacks `__ector_kind__/0` and `__ector_label__/0`
on your node/edge modules are part of the public contract and safe to call.

## Internal API (NOT covered by SemVer)

These may change at any time, in any release. Do not depend on them from
application code:

- `Ector.Schema` — the macro engine behind `Ector.Node`/`Ector.Edge`.
- `Ector.Translator` and `Ector.Translator.Postgres` / `Ector.Translator.SQLite`
  — adapter-specific JSON mutation builders.
- Internal reflection/helpers: `__storage_source__/1`, `__association__!/2`,
  `__edge_label__/1`, `__ector_table__/0`, `__ector_associations__/0`.
- The `__ector_edges__` changeset key and the `__id__` virtual field's storage
  semantics.
- The physical `nodes`/`edges` embedded schemas exposed by `Ector.Node` and
  `Ector.Edge` (these are documented as an **informational storage contract**
  for operators and debuggers, not a programmable API).

## The "Glass Box"

Ector intentionally keeps its storage shape visible so you can reason about,
index, and debug the underlying `nodes`/`edges` tables. Visibility is a
*documentation* feature — it does not promote the internal storage layout to a
stable API. Treat anything under "Internal API" above as subject to change.
