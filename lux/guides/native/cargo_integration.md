# Cargo Integration in Lux

Lux provides first-class Cargo package management integration for Rust NIFs, enabling seamless dependency management, build orchestration, and version tracking directly from Elixir.

## Overview

The `Lux.Native.Cargo` module and its submodules provide:

- **Dependency Management** — Parse Cargo.toml, list dependencies, check versions
- **Build System** — Compile Rust NIFs with configurable profiles and targets
- **Version Tracking** — Detect outdated dependencies and update them
- **Cross-Compilation** — Build for different targets from a single host

## Quick Start

### Check Cargo Availability

```elixir
# Check if cargo is installed
Lux.Native.Cargo.available?()
# => true

# Get version info
{:ok, versions} = Lux.Native.Cargo.version()
# => %{cargo: "1.77.0", rustc: "1.77.0", rustfmt: "1.7.0"}
```

### Build the Rust NIF

```elixir
# Release build (default)
{:ok, result} = Lux.Native.Cargo.build()
# => %{profile: :release, artifacts: ["liblux_native.so"]}

# Debug build
{:ok, result} = Lux.Native.Cargo.build(profile: :debug)

# Cross-compile for Linux
{:ok, result} = Lux.Native.Cargo.build(target: "x86_64-unknown-linux-gnu")
```

### Manage Dependencies

```elixir
# List all dependencies
{:ok, deps} = Lux.Native.Cargo.dependencies()
# => [%Lux.Native.Cargo.Dependency{name: "rustler", version: "0.36", ...}]

# Check a specific dependency
{:ok, info} = Lux.Native.Cargo.Dependency.check("rustler")
# => %{name: "rustler", version: "0.36", present: true}

# Check for outdated dependencies
{:ok, outdated} = Lux.Native.Cargo.outdated()
# => [%{name: "serde", current: "1.0.195", latest: "1.0.196"}]

# Update dependencies
{:ok, results} = Lux.Native.Cargo.update_deps()
# => [%{name: "serde", updated: true}]

# Update specific packages only
{:ok, results} = Lux.Native.Cargo.update_deps(packages: ["rustler"])
```

### Analyze Dependency Tree

```elixir
{:ok, tree} = Lux.Native.Cargo.Dependency.tree()
# => %{
#   name: "lux_native",
#   version: "0.1.0",
#   dependencies: [
#     %{name: "rustler", version: "0.36.0", dependencies: []}
#   ]
# }
```

## Module Reference

### `Lux.Native.Cargo`

The main entry point for Cargo operations.

| Function | Description |
|----------|-------------|
| `available?/0` | Check if Cargo is installed |
| `version/0` | Get Cargo/Rust toolchain versions |
| `build/1` | Compile the Rust NIF project |
| `dependencies/1` | List project dependencies |
| `outdated/1` | Check for outdated dependencies |
| `update_deps/1` | Update dependencies |
| `parse_toml/1` | Parse Cargo.toml into structured data |
| `build_status/1` | Get build artifact status |
| `clean/1` | Clean build artifacts |
| `run/2` | Run arbitrary Cargo commands |

### `Lux.Native.Cargo.Dependency`

Dependency management submodule.

| Function | Description |
|----------|-------------|
| `list/1` | List all dependencies from Cargo.toml |
| `parse_toml/1` | Parse and return Cargo.toml data |
| `outdated/1` | Check for outdated packages |
| `update/1` | Update packages (supports `dry_run` and `packages` options) |
| `tree/1` | Get the full dependency tree |
| `check/2` | Check if a specific dependency exists |

### `Lux.Native.Cargo.Build`

Build system submodule.

| Function | Description |
|----------|-------------|
| `compile/1` | Compile with configurable profile/target/features |
| `status/1` | Check build status and artifact info |
| `clean/1` | Remove build artifacts |
| `default_config/0` | Get the default build configuration |
| `needs_rebuild?/1` | Check if source changes require rebuild |

## Build Profiles

### Debug vs Release

```elixir
# Debug: faster compilation, includes debug symbols
Lux.Native.Cargo.build(profile: :debug)

# Release: optimized, smaller binary (default)
Lux.Native.Cargo.build(profile: :release)
```

### Cross-Compilation

Build for different platforms by specifying a target triple:

```elixir
# Linux (GNU libc)
Lux.Native.Cargo.build(target: "x86_64-unknown-linux-gnu")

# Linux (musl libc - static linking)
Lux.Native.Cargo.build(target: "x86_64-unknown-linux-musl")

# macOS (Apple Silicon)
Lux.Native.Cargo.build(target: "aarch64-apple-darwin")

# Windows (MSVC)
Lux.Native.Cargo.build(target: "x86_64-pc-windows-msvc")
```

> **Note:** Cross-compilation requires the appropriate Rust target to be installed via `rustup target add <target>`.

## Dependency Types

Dependencies are represented as `Lux.Native.Cargo.Dependency` structs:

```elixir
%Lux.Native.Cargo.Dependency{
  name: "rustler",        # Package name
  version: "0.36",        # Version constraint
  source: "registry",     # Source: "registry", "git", or "path"
  features: [],           # Enabled Cargo features
  optional: false         # Whether the dep is optional
}
```

### Source Types

| Source | Description |
|--------|-------------|
| `"registry"` | From crates.io (default) |
| `"git"` | From a Git repository |
| `"path"` | From a local path |

## Project Structure

The Rust NIF project lives in `priv/rust/`:

```
priv/rust/
├── Cargo.toml          # Package manifest
├── src/
│   ├── lib.rs          # NIF entry point
│   ├── error.rs        # Error handling
│   └── types.rs        # Type conversions
└── target/             # Build artifacts (gitignored)
    ├── debug/
    └── release/
        └── liblux_native.so  # Compiled NIF library
```

## Configuration

Add to your `config/config.exs`:

```elixir
config :lux, :cargo,
  rust_dir: "priv/rust",
  profile: :release,
  target: nil
```

## Integration with Lux Agents

Use Cargo integration in your agent workflows:

```elixir
defmodule MyApp.Prisms.RustBuildPrism do
  use Lux.Prism, name: "Rust Build"

  def handler(_input, _ctx) do
    # Check if rebuild is needed
    {:ok, needs_rebuild} = Lux.Native.Cargo.Build.needs_rebuild?()

    if needs_rebuild do
      {:ok, result} = Lux.Native.Cargo.build(profile: :release)
      {:ok, %{rebuilt: true, artifacts: result.artifacts}}
    else
      {:ok, %{rebuilt: false, message: "Artifacts up to date"}}
    end
  end
end
```

## Error Handling

All functions return `{:ok, result}` or `{:error, reason}`:

```elixir
case Lux.Native.Cargo.build() do
  {:ok, %{artifacts: artifacts}} ->
    IO.puts("Built successfully: #{inspect(artifacts)}")

  {:error, reason} ->
    IO.puts("Build failed: #{reason}")
end
```

## Testing

```elixir
defmodule MyApp.CargoTest do
  use UnitCase, async: true

  test "dependencies include rustler" do
    {:ok, deps} = Lux.Native.Cargo.dependencies()
    assert Enum.any?(deps, &(&1.name == "rustler"))
  end
end
```

> Tests that require the full Rust toolchain are tagged with `@tag :skip` and can be run in environments where Cargo is available.

## Best Practices

1. **Use release builds for production** — Smaller, faster NIFs
2. **Pin dependency versions** — Avoid unexpected breakage from semver-compatible updates
3. **Check `needs_rebuild?` before building** — Saves time in development
4. **Clean periodically** — Build caches can grow large
5. **Use features for optional deps** — Keep the default build lean
