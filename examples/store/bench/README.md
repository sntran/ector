# Store Benchmark

`store_bench.exs` measures the zero-migration Ector storefront under the same
storage topology used by the LiveView app: all domain attributes live in
`nodes.properties`, and relationships are represented by `edges`.

## What It Measures

The benchmark runs three scenarios:

* **Batch seed nodes and edges** inserts synthetic Product, Offer, Cart, and
  CartItem nodes plus the implicit Product -> Offer, Cart -> CartItem, and
  Offer -> CartItem relationships.
* **Single-cursor catalog search** runs the catalog search path over
  denormalized Offer text using a real `?cursor=token` envelope for the second
  page.
* **Implicit CartItem cart summary** runs the checkout read path through
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
BENCH_N=1000 BENCH_WARMUP=0.25 BENCH_TIME=1 BENCH_MEMORY_TIME=1 mix run bench/store_bench.exs
STORE_ADAPTER=postgres STORE_DATABASE_URL=postgres://user:pass@localhost/store_example mix run bench/store_bench.exs
```

## Latest Local Run

Measured locally on 2026-06-13 with:

```bash
BENCH_N=1000 BENCH_WARMUP=0.25 BENCH_TIME=1 BENCH_MEMORY_TIME=1 mix run bench/store_bench.exs
```

Environment:

```text
Adapter: sqlite
Dataset: 1000 Ector-backed offers
CPU: Intel(R) Core(TM) i5-7400 CPU @ 3.00GHz
Cores: 4
Memory: 15.57 GB
Elixir: 1.20.0
Erlang/OTP: 29.0.1
JIT: enabled
```

Throughput and latency:

| Scenario | ips | Average | Median | 99th % |
|----------|----:|--------:|-------:|-------:|
| Implicit CartItem cart summary | 392.31 | 2.55 ms | 2.29 ms | 5.23 ms |
| Single-cursor catalog search | 120.33 | 8.31 ms | 7.20 ms | 15.33 ms |
| Batch seed nodes and edges | 6.95 | 143.79 ms | 171.70 ms | 202.96 ms |

Memory:

| Scenario | Average | Median | 99th % |
|----------|--------:|-------:|-------:|
| Implicit CartItem cart summary | 160.27 KB | 160.27 KB | 160.27 KB |
| Single-cursor catalog search | 127.38 KB | 127.38 KB | 127.38 KB |
| Batch seed nodes and edges | 15111.97 KB | 15112.09 KB | 15112.41 KB |

The read paths are the enterprise-relevant signal: the implicit CartItem cart
summary completes in about 2.6 ms with roughly 160 KB allocated per operation,
while cursor catalog search completes in about 8.3 ms with roughly 127 KB
allocated per operation on this local SQLite run.

## Reading The Numbers

Benchee reports ips, average latency, and distribution statistics. Higher ips
means more completed operations per second. Lower average and percentile
latency mean the workflow is spending less time in query planning, JSON
property access, edge traversal, preload stitching, adapter encoding, and
database execution.

Use the numbers as local workload evidence, not universal performance claims.
They depend on adapter, database configuration, storage media, BEAM flags,
dataset size, and whether the database has warmed its cache.
