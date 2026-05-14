defmodule Lux.Native.Testing do
  @moduledoc """
  Testing framework for Lux Rust NIF integration.

  Provides three main modules:

  - `Lux.Native.Testing.NifCase` — Test case template with NIF-specific assertions
  - `Lux.Native.Testing.Property` — Property-based testing helpers and generators
  - `Lux.Native.Testing.Benchmark` — Performance benchmarking utilities

  ## Quick Start

      defmodule MyNifTest do
        use Lux.Native.Testing.NifCase

        test "add works", %{nif: nif} do
          assert {:ok, 3.0} = nif.add(1, 2)
        end
      end
  """

  @doc """
  Checks if the Rust NIF is loaded and available.

  Returns `:ok` if loaded, `{:error, reason}` otherwise.
  Useful as a setup step in test suites.
  """
  def check_nif_loaded do
    try do
      Lux.Native.Rust.add(0, 0)
      :ok
    rescue
      ErlangError ->
        {:error, :nif_not_loaded}
    end
  end

  @doc """
  Runs a full NIF health check: verifies all exported functions are callable.

  Returns `:ok` or `{:error, {function, reason}}`.
  """
  def health_check do
    checks = [
      {"add/2", fn -> Lux.Native.Rust.add(0, 0) end},
      {"echo/1", fn -> Lux.Native.Rust.echo(:ok) end},
      {"uuid_v4/0", fn -> Lux.Native.Rust.uuid_v4() end},
      {"sha256/1", fn -> Lux.Native.Rust.sha256("") end}
    ]

    Enum.reduce_while(checks, :ok, fn {name, fun}, _acc ->
      case fun.() do
        {:ok, _} -> {:cont, :ok}
        {:error, _} = err -> {:halt, {:error, {name, err}}}
        _other -> {:cont, :ok}
      end
    rescue
      e -> {:halt, {:error, {name, Exception.message(e)}}}
    end)
  end
end
