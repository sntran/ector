# Changelog

All notable changes to Ector are documented in this file.

This project has not shipped a tagged release yet. The entry below summarizes
the unreleased history on this branch from the initial bootstrap on
2026-06-04 through the latest work.

## Unreleased

### Added

- Bootstrapped the Mix project, version gate, base README, and agent-facing
  architecture notes.
- Added the core dynamic schema engine: `Ector.Node`, `Ector.Edge`,
  `Ector.Schema`, `Ector.Changeset`, and `Ector.Migration`, plus a dedicated
  test repo and storage-oriented test coverage.
- Added the repo execution gateway in `Ector.Repo` for hydration, graph-aware
  inserts, updates, deletes, and adapter-aware execution over the shared
  `nodes` and `edges` tables.
- Added adapter-specific JSON mutation translators for PostgreSQL and SQLite,
  along with environment-specific config for the test matrix.
- Added the hygienic AST rewriting engine in `Ector.Query` so domain field
  access compiles through Ecto's native JSON query support.
- Added public-facing project materials including `LICENSE`,
  `STABILITY.md`, and the getting-started guide.
- Added the `examples/store` showcase, then expanded it into a full LiveView
  storefront with seeds, sandbox helpers, browser-facing tests, and a local
  benchmark harness.
- Added operator-style bulk JSON updates through `Ector.Repo.update_all/4` for
  `set`, `inc`, and `push`, supporting both repo-first and pipe-first call
  shapes.
- Added graph-aware `Repo.preload` support for Ector schemas, including
  `belongs_to`, `has_many`, `has_one`, and nested preload traversal.
- Added implicit edge routing for property-less associations, including reverse
  `belongs_to` fallback through the parent-side edge label.
- Added `mix ector.migrate` to rewrite direct `use Ecto.Schema` modules to
  `use Ector.Node` and optionally stream legacy relational data into
  `nodes`/`edges`.

### Changed

- Stabilized the public `Ector` facade and aligned the query, migration, repo,
  and translator layers around one documented API surface.
- Reworked the store example from an earlier comparison-oriented layout into a
  single Ector-backed storefront with catalog, checkout, LiveView routing, and
  benchmarked read paths.
- Shifted the store's public pagination contract to a single URL-safe
  `?cursor=token` envelope instead of split directional params.
- Refactored store hydration to prefer `Repo.preload` for display reads while
  keeping the denormalized Offer boundary and database-side stock decrements.
- Removed property-less symbolic `through:` labels from the store example so it
  exercises implicit edge routing.
- Consolidated preload coverage into `test/ector/repo_test.exs` so repo
  boundary behavior, JSON update translation, and graph preload execution are
  verified together.

### Verified

- Built out focused test coverage for changesets, node and edge schemas,
  migrations, query rewriting, repo execution, translator output, and the
  store integration and LiveView flows.
- Captured local benchmark results for the current storefront catalog and
  checkout read paths and documented them alongside the benchmark harness.

### Commit History

- `2026-06-04` `3b5361c` `feat: new mix project`
- `2026-06-04` `1080b49` `build: set up deps and elixir version gate`
- `2026-06-04` `0fc5f0d` `docs: SRD, README, and AGENTS.md`
- `2026-06-05` `79f3529`
  `feat(core): implement dynamic storage engine and node/edge modeling`
- `2026-06-06` `c4f51ed`
  `feat(repo): implement execution gateway and cross-db json translators`
- `2026-06-06` `1de7617`
  `feat(query): implement hygienic AST rewriting engine for Ector graphs`
- `2026-06-07` `7fbcbff`
  `feat: stabilize public API and add store showcase`
- `2026-06-10` `e60c2c2` `feat(repo): \`update_all\` with ops`
- `2026-06-10` `e60886e` `feat(examples): full ledge LiveStore`
- `2026-06-11` `c448c0d`
  `feat(repo): add graph-aware preloads for Ector schemas`
