# Rust Integration

Lux provides native Rust integration via [Rustler](https://rustler.rs/) NIFs (Native Implemented Functions), enabling high-performance computation directly callable from Elixir with near-zero overhead.

## Prerequisites

- **Rust toolchain** — Install via [rustup](https://rustup.rs/):
  ```bash
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
  ```
- **Rustler dependency** — Add to `mix.exs`:
  ```elixir
  defp deps do
    [
      {:rustler, "~> 0.36", runtime: false}
    ]
  end
  ```

## Quick Start

```elixir
alias Lux.Native.Rust

# Arithmetic
{:ok, result} = Rust.add(1, 2)       # => {:ok, 3.0}

# UUID generation
{:ok, uuid} = Rust.uuid_v4()          # => {:ok, "a1b2c3d4-e5f6-4a7b-..."}

# SHA-256 hashing
{:ok, hash} = Rust.sha256("hello")    # => {:ok, "2cf24dba5fb0a30e..."}

# JSON serialization
{:ok, json} = Rust.serialize_json(%{"name" => "Lux"})
```

## Available Functions

| Function | Signature | Description |
|----------|-----------|-------------|
| `add/2` | `(number, number) :: {:ok, float}` | Add two numbers |
| `echo/1` | `(term) :: term` | Identity function — returns input unchanged |
| `parse_json/1` | `(String.t()) :: term` | Parse JSON string to Elixir term |
| `serialize_json/1` | `(term) :: {:ok, String.t()}` | Serialize Elixir term to JSON string |
| `uuid_v4/0` | `() :: {:ok, String.t()}` | Generate a random UUID v4 |
| `sha256/1` | `(String.t()) :: {:ok, String.t()}` | Compute SHA-256 hash (hex-encoded) |

## Type Mapping

| Elixir Type | Rust Type | Notes |
|-------------|-----------|-------|
| `integer()` | `i64` | Lossless conversion for values within 64-bit range |
| `float()` | `f64` | IEEE 754 double precision |
| `binary()` / `String.t()` | `String` | UTF-8 encoded bytes |
| `atom()` | `rustler::Atom` | `true`, `false`, `nil` map to JSON `true`/`false`/`null` |
| `list()` | `Vec<T>` | Elements are recursively converted |
| `map()` | `HashMap<String, T>` | Keys must be strings for JSON serialization |

## Architecture

```
Elixir Process
     │
     │ NIF call (BEAM → Rust, zero-copy where possible)
     ▼
┌──────────────────────────────────────┐
│  lux_native (Rust crate)             │
│  ├── lib.rs     NIF entry & exports  │
│  ├── types.rs   Type conversion      │
│  └── error.rs   Result → {:ok, :error}│
└──────────────────────────────────────┘
```

### Directory Layout

```
lux/
├── priv/rust/           # Rust NIF crate
│   ├── Cargo.toml
│   └── src/
│       ├── lib.rs       # NIF entry point
│       ├── types.rs     # Elixir ↔ Rust type conversion
│       └── error.rs     # Error handling helpers
├── lib/lux/native/
│   └── rust.ex          # Elixir NIF loader module
├── test/native/
│   └── rust_test.exs    # Tests
└── guides/native/
    └── rust_integration.md  # This guide
```

## Extending with Custom NIFs

To add a new Rust function:

### 1. Define the function in `priv/rust/src/lib.rs`

```rust
#[rustler::nif]
pub fn my_function(input: String) -> NifResult<String> {
    // Your Rust logic here
    Ok(format!("Processed: {}", input))
}
```

### 2. Register it in the `rustler::init!` macro

```rust
rustler::init!(
    "Elixir.Lux.Native.Rust",
    [add, echo, parse_json, serialize_json, uuid_v4, sha256, my_function],
    load = load
);
```

### 3. Add the Elixir stub in `lib/lux/native/rust.ex`

```elixir
@doc """
My custom function.
"""
def my_function(_input), do: exit(:nif_not_loaded)
```

### 4. Recompile

```bash
mix compile
```

## Error Handling

All Rust NIF functions follow the Elixir convention:

```elixir
# Success
{:ok, value}

# Error
{:error, reason}
```

On the Rust side, use the helpers in `error.rs`:

```rust
use crate::error;

pub fn my_nif(env: rustler::Env, input: String) -> rustler::NifResult<rustler::Term> {
    match my_fallible_operation(input) {
        Ok(val) => Ok(error::ok(env, val.encode(env))),
        Err(reason) => Ok(error::error(env, reason.encode(env))),
    }
}
```

## Performance Considerations

- **NIF calls are synchronous** — Long-running Rust functions block the BEAM scheduler.
  For CPU-intensive work, consider spawning a Rust thread and using `rustler::Term` callbacks.
- **Zero-copy strings** — Rustler avoids copying binary data when possible.
- **Type conversion overhead** — Complex nested structures incur conversion cost. Keep NIF interfaces flat for best performance.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| `nif_not_loaded` error | Run `mix compile` to build the Rust crate |
| Cargo not found | Install Rust toolchain via `rustup` |
| Compilation errors | Check Rust version: `rustc --version` (1.70+ recommended) |
| NIF crash / BEAM crash | Check BEAM logs; ensure NIF functions don't panic |
