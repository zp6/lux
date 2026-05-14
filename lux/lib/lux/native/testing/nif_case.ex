defmodule Lux.Native.Testing.NifCase do
  @moduledoc """
  Test case template for Rust NIF integration tests.

  ## Usage

      defmodule MyNifTest do
        use Lux.Native.Testing.NifCase

        describe "add/2" do
          test "adds two numbers", %{nif: nif} do
            assert {:ok, result} = nif.add(1, 2)
            assert result == 3.0
          end
        end
      end

  ## Features

  - Automatically aliases `Lux.Native.Rust` as `:nif` in test context
  - Provides `assert_nif_ok/1` and `assert_nif_error/1` helpers
  - Includes `assert_round_trip/2` for type round-trip verification
  - Sets `async: false` by default (NIFs may share state)
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use ExUnit.Case, async: false
      import Lux.Native.Testing.NifCase

      alias Lux.Native.Rust, as: Nif
    end
  end

  setup context do
    nif_module = context[:nif_module] || Lux.Native.Rust
    {:ok, nif: nif_module}
  end

  @doc """
  Asserts that a NIF call returns `{:ok, value}` and returns the value.

  ## Example

      assert_nif_ok(Rust.add(1, 2))  # asserts and returns 3.0
  """
  defmacro assert_nif_ok({:ok, _} = _expr) do
    quote do
      {:ok, value} = unquote(_expr)
      value
    end
  end

  defmacro assert_nif_ok(expr) do
    quote do
      assert {:ok, value} = unquote(expr)
      value
    end
  end

  @doc """
  Asserts that a NIF call returns `{:error, reason}`.

  ## Example

      assert_nif_error(Rust.some_failing_call())
  """
  defmacro assert_nif_error(expr) do
    quote do
      assert {:error, _reason} = unquote(expr)
    end
  end

  @doc """
  Asserts that a value round-trips through the NIF's echo function.

  ## Example

      assert_round_trip(nif, [1, 2, 3])
      assert_round_trip(nif, %{a: 1, b: 2})
  """
  def assert_round_trip(nif, value) do
    result = nif.echo(value)
    assert result == value, """
    Round-trip failed!

    Expected: #{inspect(value)}
    Got:      #{inspect(result)}
    """
  end

  @doc """
  Asserts that a UUID string matches the UUID v4 format.
  """
  def assert_uuid_v4(uuid) when is_binary(uuid) do
    assert String.match?(uuid, ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/),
           "Expected valid UUID v4, got: #{uuid}"
  end

  @doc """
  Asserts that a string is a valid 64-character lowercase hex digest.
  """
  def assert_sha256_hash(hash) when is_binary(hash) do
    assert String.length(hash) == 64,
           "SHA-256 hash must be 64 characters, got #{String.length(hash)}"

    assert String.match?(hash, ~r/^[0-9a-f]{64}$/),
           "SHA-256 hash must be lowercase hex, got: #{hash}"
  end

  @doc """
  Runs the given NIF function `n` times and asserts all results are within
  the `timeout_ms` budget. Useful for checking NIF call overhead.

  Returns the average time per call in microseconds.
  """
  def benchmark_nif(nif_module, function, args, n \\ 100, timeout_ms \\ 1000) do
    # Warmup
    for _ <- 1..10 do
      apply(nif_module, function, args)
    end

    times =
      for _ <- 1..n do
        start = System.monotonic_time(:microsecond)
        apply(nif_module, function, args)
        finish = System.monotonic_time(:microsecond)
        finish - start
      end

    avg = Enum.sum(times) / n
    max = Enum.max(times)

    assert max < timeout_ms * 1000,
           "NIF call took too long: max=#{max}µs, budget=#{timeout_ms}ms"

    avg
  end
end
