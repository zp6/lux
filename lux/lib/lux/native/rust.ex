defmodule Lux.Native.Rust do
  @moduledoc """
  Rust NIF integration for high-performance native operations in Lux.

  This module loads and exposes Rust functions compiled via [Rustler](https://rustler.rs/),
  enabling zero-overhead calls from Elixir to Rust for computationally intensive tasks.

  ## Configuration

  The Rust NIF is compiled automatically when `mix compile` runs (requires Rust toolchain).
  Ensure you have `cargo` installed and available in your `PATH`.

  Add `rustler` to your dependencies in `mix.exs`:

      defp deps do
        [
          {:rustler, "~> 0.36", runtime: false}
        ]
      end

  ## Available Functions

  | Function | Signature | Description |
  |----------|-----------|-------------|
  | `add/2` | `(number, number) :: {:ok, number}` | Add two numbers |
  | `echo/1` | `(term) :: term` | Return input unchanged (type round-trip) |
  | `parse_json/1` | `(String.t()) :: term` | Parse JSON string to Elixir term |
  | `serialize_json/1` | `(term) :: {:ok, String.t()}` | Serialize Elixir term to JSON |
  | `uuid_v4/0` | `() :: {:ok, String.t()}` | Generate UUID v4 |
  | `sha256/1` | `(String.t()) :: {:ok, String.t()}` | Compute SHA-256 hash |

  ## Usage Examples

      iex> Lux.Native.Rust.add(1, 2)
      {:ok, 3.0}

      iex> Lux.Native.Rust.uuid_v4()
      {:ok, "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d"}

      iex> Lux.Native.Rust.sha256("hello")
      {:ok, "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"}

  ## Error Handling

  Rust NIFs follow the Elixir convention of returning `{:ok, value}` or `{:error, reason}`
  tuples. If the NIF fails to load (e.g., Rust toolchain missing), functions will raise
  an `ErlangError` at call time.

  ## Type Mapping

  | Elixir Type | Rust Type | Notes |
  |-------------|-----------|-------|
  | `integer()` | `i64` | Lossless for 64-bit integers |
  | `float()` | `f64` | IEEE 754 double |
  | `binary()` / `String.t()` | `String` | UTF-8 encoded |
  | `atom()` | `Atom` | `true`, `false`, `nil` have special handling |
  | `list()` | `Vec<T>` | Recursive element conversion |
  | `map()` | `HashMap<String, T>` | String keys required for JSON |

  ## Architecture

  ```
  Elixir (Lux.Native.Rust)
       │
       │ Rustler NIF bridge (zero-copy where possible)
       ▼
  Rust (lux_native crate)
   ├── lib.rs      → NIF entry point & exported functions
   ├── types.rs    → Elixir ↔ Rust type conversion
   └── error.rs    → Result → {:ok, _} | {:error, _} helpers
  ```
  """

  use Rustler,
    otp_app: :lux,
    crate: "priv/rust"

  @doc """
  Adds two numbers.

  ## Examples

      iex> Lux.Native.Rust.add(1, 2)
      {:ok, 3.0}

      iex> Lux.Native.Rust.add(3.14, 2.86)
      {:ok, 6.0}
  """
  def add(_a, _b), do: exit(:nif_not_loaded)

  @doc """
  Returns the input term unchanged.
  Useful for verifying that type round-trips work correctly.

  ## Examples

      iex> Lux.Native.Rust.echo(:hello)
      :hello

      iex> Lux.Native.Rust.echo([1, 2, 3])
      [1, 2, 3]
  """
  def echo(_term), do: exit(:nif_not_loaded)

  @doc """
  Parses a JSON string into an Elixir term.

  ## Examples

      iex> Lux.Native.Rust.parse_json(~s({"key": "value"}))
      {:ok, {"raw_json", "{\"key\": \"value\"}"}}
  """
  def parse_json(_json), do: exit(:nif_not_loaded)

  @doc """
  Serializes an Elixir term into a JSON string.

  ## Examples

      iex> Lux.Native.Rust.serialize_json(%{"name" => "Lux"})
      {:ok, "{\\\"name\\\":\\\"Lux\\\"}"}
  """
  def serialize_json(_term), do: exit(:nif_not_loaded)

  @doc """
  Generates a random UUID v4 string.

  ## Examples

      iex> {:ok, uuid} = Lux.Native.Rust.uuid_v4()
      iex> String.match?(uuid, ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/)
      true
  """
  def uuid_v4, do: exit(:nif_not_loaded)

  @doc """
  Computes the SHA-256 hash of a string and returns the hex-encoded digest.

  ## Examples

      iex> Lux.Native.Rust.sha256("hello")
      {:ok, "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"}
  """
  def sha256(_data), do: exit(:nif_not_loaded)
end
