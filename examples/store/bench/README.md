# Store Benchmark

`store_bench.exs` measures the zero-migration Ector storefront under the same
storage topology used by the LiveView app: all domain attributes live in
`nodes.properties`, and relationships are represented by `edges`.

## What It Measures

The benchmark runs three scenarios:

* **Batch seed nodes and edges** inserts synthetic Product, Offer, Cart, and
  CartItem nodes plus Product -> Offer, Cart -> CartItem, and Offer -> CartItem
  edges.
* **Offer listing page** runs the catalog search path over denormalized Offer
  text and the Offer JSON properties used by the storefront filters.
* **Cart summary graph join** runs the checkout read path:
  `Cart -> CartItem -> Offer -> Product`.

## Baseline

The baseline is not a relational table-per-entity schema. This benchmark is for
the Ector example after it was refactored to one storage engine. The meaningful
comparison is between the three Ector workloads:

* write throughput for physical node/edge batches;
* read latency for Offer-property search and sorting;
* read latency for the multi-hop cart projection.

For adapter comparisons, run the same benchmark once with SQLite and once with
PostgreSQL. The app compiles the adapter from `STORE_ADAPTER`.

## Running

```bash
cd examples/store
mix run bench/store_bench.exs
BENCH_N=1000 BENCH_WARMUP=0 BENCH_TIME=0.5 mix run bench/store_bench.exs
STORE_ADAPTER=postgres STORE_DATABASE_URL=postgres://user:pass@localhost/store_example mix run bench/store_bench.exs
```

## Reading The Numbers

Benchee reports ips, average latency, and distribution statistics. Higher ips
means more completed operations per second. Lower average and percentile
latency mean the workflow is spending less time in query planning, JSON
property access, edge joins, adapter encoding, and database execution.

Use the numbers as local workload evidence, not universal performance claims.
They depend on adapter, database configuration, storage media, BEAM flags,
dataset size, and whether the database has warmed its cache.
