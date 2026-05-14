# Rust NIF Testing Guide

This guide covers testing for the Rust NIF integration in Lux, including Rust-side unit tests, Elixir integration tests, property-based testing, and CI configuration.

## Table of Contents

- [Overview](#overview)
- [Running Tests](#running-tests)
- [Rust Tests](#rust-tests)
- [Elixir NIF Tests](#elixir-nif-tests)
- [Property-Based Testing](#property-based-testing)
- [Performance Benchmarking](#performance-benchmarking)
- [Writing New Tests](#writing-new-tests)
- [CI Integration](#ci-integration)
- [Troubleshooting](#troubleshooting)

## Overview

The Lux Rust testing framework has two layers:

```
┌─────────────────────────────────────────────┐
│  Elixir Tests (test/native/)                │
│  ├── rust_test.exs        — NIF end-to-end  │
│  └── testing_test.exs     — Framework tests │
│                                              │
│  Uses: NifCase, Property, Benchmark helpers  │
├─────────────────────────────────────────────┤
│  Rust Tests (priv/rust/tests/)              │
│  ├── integration_test.rs — Function tests    │
│  ├── property_test.rs    — Property invariants│
│  └── fixtures.rs         — Test data/helpers  │
│                                              │
│  Runs: cargo test                            │
├─────────────────────────────────────────────┤
│  NIF Source (priv/rust/src/)                │
│  ├── lib.rs, types.rs, error.rs             │
│  └── types/primitive.rs                     │
└─────────────────────────────────────────────┘
```

## Running Tests

### All tests (recommended)

```bash
# From project root
./scripts/run_rust_tests.sh

# CI mode (strict formatting/lint checks)
./scripts/run_rust_tests.sh --ci
```

### Rust tests only

```bash
cd priv/rust
cargo test --verbose
```

### Elixir NIF tests only

```bash
mix test test/native/ --trace
```

### Testing framework validation

```bash
mix test test/native/testing_test.exs --trace
```

## Rust Tests

Rust tests live in `priv/rust/tests/` and run via `cargo test`. They test the NIF logic directly without the BEAM VM.

### integration_test.rs

Tests individual NIF functions with known inputs/outputs:

```rust
// Tests the add function logic
#[test]
fn test_add_positive() {
    let result = add_impl(1.0, 2.0);
    assert!((result - 3.0).abs() < f64::EPSILON);
}

// Tests SHA-256 against known test vectors
#[test]
fn test_sha256_hello() {
    assert_eq!(sha256_digest(b"hello"),
        "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824");
}
```

### property_test.rs

Tests invariants that should hold for all inputs:

- **Commutativity**: `add(a, b) == add(b, a)`
- **Determinism**: `sha256(x) == sha256(x)` always
- **Avalanche**: Small input changes → large output changes
- **Format**: UUID v4 always matches the correct pattern

### fixtures.rs

Shared test data and helpers:

```rust
use fixtures::{sha256_vectors, uuid_helpers, arithmetic_cases};

// SHA-256 known test vectors
sha256_vectors::HELLO  // ("hello", "2cf24dba...")

// UUID validation helper
uuid_helpers::is_valid_uuid_v4("a1b2c3d4-...")  // true

// Arithmetic test cases
arithmetic_cases::POSITIVE  // (1.0, 2.0, 3.0)
```

## Elixir NIF Tests

### Using NifCase

`NifCase` provides a test template with NIF-specific assertions:

```elixir
defmodule MyCustomNifTest do
  use Lux.Native.Testing.NifCase

  describe "my_function" do
    test "works correctly", %{nif: nif} do
      # assert_nif_ok unwraps {:ok, value}
      result = assert_nif_ok(nif.add(1, 2))
      assert result == 3.0

      # assert_round_trip checks echo round-trip
      assert_round_trip(nif, [1, 2, 3])

      # assert_uuid_v4 validates UUID format
      {:ok, uuid} = nif.uuid_v4()
      assert_uuid_v4(uuid)

      # assert_sha256_hash validates hash format
      {:ok, hash} = nif.sha256("test")
      assert_sha256_hash(hash)
    end
  end
end
```

### Available Assertions

| Assertion | Description |
|-----------|-------------|
| `assert_nif_ok(expr)` | Asserts `{:ok, value}`, returns value |
| `assert_nif_error(expr)` | Asserts `{:error, reason}` |
| `assert_round_trip(nif, value)` | Checks value survives echo round-trip |
| `assert_uuid_v4(uuid)` | Validates UUID v4 format |
| `assert_sha256_hash(hash)` | Validates 64-char lowercase hex hash |

## Property-Based Testing

The `Property` module provides lightweight property testing without external dependencies:

```elixir
import Lux.Native.Testing.Property

# Simple property check
for_all integer(), fn n ->
  {:ok, result} = Lux.Native.Rust.add(n, 0)
  assert result == n * 1.0  # identity element
end

# Paired generators
for_all {float(), float()}, fn {a, b} ->
  {:ok, r1} = Lux.Native.Rust.add(a, b)
  {:ok, r2} = Lux.Native.Rust.add(b, a)
  assert_in_delta r1, r2, 0.001
end

# Assert always returns ok
assert_always_ok string(), fn s ->
  Lux.Native.Rust.sha256(s)
end
```

### Generators

| Generator | Description |
|-----------|-------------|
| `integer()` | Random int in [-1M, 1M] |
| `integer(min, max)` | Random int in [min, max] |
| `float()` | Random float in [-1000, 1000] |
| `string()` | Random ASCII string (0..50 chars) |
| `binary()` | Random bytes (0..100 bytes) |
| `boolean()` | Random boolean |
| `json_value()` | Nested JSON-compatible structure |
| `list_of(gen, max)` | Random list of generator values |
| `map_of(gen, max)` | Random map with string keys |
| `unique_list(gen, n)` | List of n unique values |

## Performance Benchmarking

The `Benchmark` module measures NIF call latency:

```elixir
import Lux.Native.Testing.Benchmark

# Single benchmark
report = benchmark("sha256", fn ->
  Lux.Native.Rust.sha256("test data")
end)

# Print formatted report
IO.puts(format_report(report))

# Assert performance threshold
assert_below(report, 100)  # avg must be < 100µs

# Compare two implementations
result = compare(
  "native", fn -> Lux.Native.Rust.sha256("test") end,
  "elixir", fn -> :crypto.hash(:sha256, "test") |> Base.encode16(case: :lower) end
)
IO.puts("Speedup: #{result.speedup}x")

# Benchmark suite
suite = [
  {"add", fn -> Lux.Native.Rust.add(1, 2) end},
  {"uuid_v4", fn -> Lux.Native.Rust.uuid_v4() end},
  {"sha256", fn -> Lux.Native.Rust.sha256("test") end}
]
reports = benchmark_suite(suite)
```

### BenchmarkReport Fields

| Field | Type | Description |
|-------|------|-------------|
| `name` | String | Benchmark label |
| `iterations` | integer | Number of iterations |
| `avg_us` | float | Average latency (µs) |
| `min_us` | integer | Min latency (µs) |
| `max_us` | integer | Max latency (µs) |
| `p50_us` | float | Median latency (µs) |
| `p95_us` | float | 95th percentile (µs) |
| `p99_us` | float | 99th percentile (µs) |
| `ops_per_sec` | float | Estimated ops/sec |

## Writing New Tests

### Adding a Rust test

1. Add test functions to `priv/rust/tests/integration_test.rs`:

```rust
#[test]
fn test_my_new_function() {
    let result = my_new_function_impl("input");
    assert!(result.is_valid());
}
```

2. If needed, add test data to `priv/rust/tests/fixtures.rs`:

```rust
pub mod my_fixtures {
    pub const SAMPLE_DATA: &str = "...";
}
```

3. Run: `cd priv/rust && cargo test`

### Adding an Elixir NIF test

1. Create or extend a test file in `test/native/`:

```elixir
defmodule Lux.Native.MyFeatureTest do
  use Lux.Native.Testing.NifCase

  test "my new NIF function works", %{nif: nif} do
    assert {:ok, result} = nif.my_function("input")
    assert result == expected
  end
end
```

2. Run: `mix test test/native/my_feature_test.exs`

## CI Integration

### GitHub Actions

The `rust_tests.yml` workflow runs automatically when Rust or NIF files change:

```yaml
# Triggers on changes to:
# - lux/priv/rust/**
# - lux/lib/lux/native/**
# - lux/test/native/**
```

**Pipeline:**

1. **Rust Tests** — format check → clippy → cargo test
2. **Elixir NIF Tests** — compile (builds NIF) → mix test

### Local CI simulation

```bash
./scripts/run_rust_tests.sh --ci
```

### Integration with existing CI

The Rust tests complement the main Lux CI (`lux-ci.yml`). Both run in parallel. The Rust-specific workflow only triggers on relevant file changes to avoid wasting CI resources.

## Troubleshooting

### "cargo not found"

Install Rust: `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh`

### "nif_not_loaded" errors in Elixir tests

The NIF must be compiled before running Elixir tests:

```bash
mix compile  # This triggers Rustler compilation
mix test test/native/
```

### Rust test compilation errors

If `types/mod.rs` references missing modules:

```bash
cd priv/rust
# Check for missing module declarations
grep "pub mod" src/types/mod.rs
# Ensure referenced files exist in src/types/
```

### Slow NIF compilation

First compilation builds all Rust dependencies. Subsequent runs are incremental:

```bash
# Check Cargo cache
ls -la priv/rust/target/debug/
```

### Test isolation

Rust tests run in parallel by default. Elixir NIF tests use `async: false` to avoid NIF state conflicts. If you need isolation in Rust:

```rust
#[test]
fn test_that_needs_isolation() {
    // Use --test-threads=1 for full isolation
}
```

```bash
cargo test -- --test-threads=1
```
