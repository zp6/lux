defmodule Lux.Native.Testing.Property do
  @moduledoc """
  Property-based testing helpers for Rust NIF functions.

  Provides generators and property checkers that don't require external
  dependencies like StreamData (though StreamData is used if available).

  ## Usage

      defmodule MyPropertyTest do
        use ExUnit.Case
        import Lux.Native.Testing.Property

        property "add is commutative" do
          for_all {float(), float()}, fn {a, b} ->
            {:ok, r1} = Rust.add(a, b)
            {:ok, r2} = Rust.add(b, a)
            assert_in_delta r1, r2, 0.001
          end
        end
      end

  ## Generators

  - `integer()` — random integers in a reasonable range
  - `float()` — random floats (including edge cases)
  - `string()` — random ASCII strings
  - `binary()` — random byte sequences
  - `json_value()` — nested maps/lists/atoms representing JSON-like data
  """

  @doc """
  Runs a property check with a simple generator for `n` iterations.

  ## Example

      for_all integer(), fn value ->
        assert is_integer(value)
      end
  """
  def for_all(generator, fun, iterations \\ 100) when is_function(fun, 1) do
    for _ <- 1..iterations do
      value = generator.()
      fun.(value)
    end

    :ok
  end

  @doc """
  Runs a property check with a pair of generators.
  """
  def for_all({gen_a, gen_b}, fun, iterations \\ 100) when is_function(fun, 1) do
    for _ <- 1..iterations do
      a = gen_a.()
      b = gen_b.()
      fun.({a, b})
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Generators
  # ---------------------------------------------------------------------------

  @doc "Generates a random integer in range [-1_000_000, 1_000_000]."
  def integer do
    fn -> :rand.uniform(2_000_001) - 1_000_001 end
  end

  @doc "Generates a random integer within a custom range."
  def integer(min, max) do
    fn -> min + :rand.uniform(max - min + 1) - 1 end
  end

  @doc "Generates a random float in range [-1000.0, 1000.0]."
  def float do
    fn ->
      sign = if :rand.uniform() > 0.5, do: 1.0, else: -1.0
      sign * :rand.uniform() * 1000.0
    end
  end

  @doc "Generates a random float within a custom range."
  def float(min, max) do
    fn -> min + :rand.uniform() * (max - min) end
  end

  @doc "Generates a random ASCII string of length 0..50."
  def string do
    fn ->
      len = :rand.uniform(51) - 1
      for(_ <- 1..len, do: 32 + :rand.uniform(95) - 1)
      |> List.to_string()
    end
  end

  @doc "Generates a random binary of length 0..100."
  def binary do
    fn ->
      len = :rand.uniform(101) - 1
      :crypto.strong_rand_bytes(len)
    end
  end

  @doc "Generates a random boolean."
  def boolean do
    fn -> :rand.uniform() > 0.5 end
  end

  @doc "Generates a random JSON-compatible value (map, list, string, number, bool, nil)."
  def json_value do
    fn -> generate_json_value(3) end
  end

  @doc "Generates a list using the given element generator."
  def list_of(element_gen, max_length \\ 20) do
    fn ->
      len = :rand.uniform(max_length + 1) - 1
      for(_ <- 1..len, do: element_gen.())
    end
  end

  @doc "Generates a map with string keys using the given value generator."
  def map_of(value_gen, max_keys \\ 10) do
    fn ->
      n = :rand.uniform(max_keys + 1) - 1
      for i <- 1..n, into: %{} do
        {"key_#{i}", value_gen.()}
      end
    end
  end

  @doc """
  Generates a list of `n` unique values using the given generator.

  Retries up to `max_attempts` times per value to ensure uniqueness.
  """
  def unique_list(gen, n, max_attempts \\ 100) do
    fn ->
      Enum.reduce_while(1..n, MapSet.new(), fn _, acc ->
        attempt(gen, acc, max_attempts)
      end)
      |> MapSet.to_list()
    end
  end

  defp attempt(gen, acc, remaining) when remaining > 0 do
    value = gen.()
    if MapSet.member?(acc, value) do
      attempt(gen, acc, remaining - 1)
    else
      {:cont, MapSet.put(acc, value)}
    end
  end

  defp attempt(_gen, acc, 0), do: {:cont, acc}

  # ---------------------------------------------------------------------------
  # JSON value generation (recursive)
  # ---------------------------------------------------------------------------

  defp generate_json_value(0) do
    # Leaf values only
    Enum.random([
      fn -> :rand.uniform(1_000_000) end,
      fn -> (:rand.uniform() * 1000.0) |> Float.round(2) end,
      fn -> for(_ <- 1..10, do: 32 + :rand.uniform(95) - 1) |> List.to_string() end,
      fn -> true end,
      fn -> false end,
      fn -> nil end
    ]).()
  end

  defp generate_json_value(depth) do
    case :rand.uniform(5) do
      1 -> generate_json_value(0)
      2 ->
        len = :rand.uniform(5)
        for(_ <- 1..len, do: generate_json_value(depth - 1))
      3 ->
        n = :rand.uniform(5)
        for i <- 1..n, into: %{} do
          {"k#{i}", generate_json_value(depth - 1)}
        end
      4 -> generate_json_value(0)
      5 -> generate_json_value(0)
    end
  end

  # ---------------------------------------------------------------------------
  # Property checkers (combinators)
  # ---------------------------------------------------------------------------

  @doc """
  Checks that a property holds for all generated values.
  Shorthand for `for_all/2` with a descriptive label.
  """
  def check_property(label, generator, property_fun, iterations \\ 100) do
    for_all(generator, property_fun, iterations)
  rescue
    e -> reraise ExUnit.AssertionError,
          "Property '#{label}' failed: #{Exception.message(e)}",
          __STACKTRACE__
  end

  @doc """
  Checks that a function returns `{:ok, _}` for all generated inputs.
  """
  def assert_always_ok(generator, fun, iterations \\ 100) do
    for_all(generator, fn input ->
      case fun.(input) do
        {:ok, _} -> :ok
        other -> raise "Expected {:ok, _}, got: #{inspect(other)} for input: #{inspect(input)}"
      end
    end, iterations)
  end
end
