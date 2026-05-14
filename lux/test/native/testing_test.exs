defmodule Lux.Native.TestingTest do
  @moduledoc """
  Tests for the Rust Testing Framework itself.

  Validates that the testing utilities (NifCase, Property, Benchmark)
  work correctly as infrastructure.
  """
  use ExUnit.Case, async: false

  alias Lux.Native.Testing.{Property, Benchmark}

  describe "Lux.Native.Testing" do
    test "check_nif_loaded returns :ok when NIF is available" do
      assert :ok = Lux.Native.Testing.check_nif_loaded()
    end

    test "health_check passes for all NIF functions" do
      assert :ok = Lux.Native.Testing.health_check()
    end
  end

  describe "Lux.Native.Testing.NifCase" do
    test "assert_uuid_v4 validates correct UUIDs" do
      import Lux.Native.Testing.NifCase
      assert_uuid_v4("a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d")
    end

    test "assert_uuid_v4 rejects invalid UUIDs" do
      import Lux.Native.Testing.NifCase

      assert_raise ExUnit.AssertionError, fn ->
        assert_uuid_v4("not-a-uuid")
      end
    end

    test "assert_sha256_hash validates correct hashes" do
      import Lux.Native.Testing.NifCase
      hash = String.duplicate("a", 64)
      assert_sha256_hash(hash)
    end

    test "assert_sha256_hash rejects invalid hashes" do
      import Lux.Native.Testing.NifCase

      assert_raise ExUnit.AssertionError, fn ->
        assert_sha256_hash("too-short")
      end
    end

    test "assert_round_trip checks echo round-trips" do
      import Lux.Native.Testing.NifCase
      nif = Lux.Native.Rust

      assert_round_trip(nif, 42)
      assert_round_trip(nif, "hello")
      assert_round_trip(nif, :ok)
      assert_round_trip(nif, [1, 2, 3])
      assert_round_trip(nif, true)
      assert_round_trip(nif, nil)
    end
  end

  describe "Lux.Native.Testing.Property" do
    test "for_all runs generator N times" do
      count = :counters.new(1, [:atomics])

      Property.for_all(Property.integer(), fn _value ->
        :counters.add(count, 1, 1)
      end, 42)

      assert :counters.get(count, 1) == 42
    end

    test "for_all with tuple generators" do
      results =
        Property.for_all({Property.integer(), Property.float()}, fn {i, f} ->
          assert is_integer(i)
          assert is_float(f)
        end, 20)
    end

    test "integer generator produces integers" do
      for _ <- 1..100 do
        value = Property.integer().()
        assert is_integer(value)
      end
    end

    test "float generator produces floats" do
      for _ <- 1..100 do
        value = Property.float().()
        assert is_float(value)
      end
    end

    test "string generator produces strings" do
      for _ <- 1..100 do
        value = Property.string().()
        assert is_binary(value)
      end
    end

    test "boolean generator produces booleans" do
      values = for _ <- 1..100, do: Property.boolean().()
      assert true in values
      assert false in values
    end

    test "json_value generator produces JSON-compatible values" do
      for _ <- 1..50 do
        value = Property.json_value().()
        # Should be encodable as JSON (no atoms except true/false/nil)
        assert is_json_compatible(value)
      end
    end

    test "list_of generator produces lists" do
      gen = Property.list_of(Property.integer(), 5)

      for _ <- 1..50 do
        list = gen.()
        assert is_list(list)
        assert length(list) <= 5
      end
    end

    test "map_of generator produces maps with string keys" do
      gen = Property.map_of(Property.integer(), 5)

      for _ <- 1..50 do
        map = gen.()
        assert is_map(map)

        for key <- Map.keys(map) do
          assert is_binary(key)
        end
      end
    end

    test "unique_list generator produces unique values" do
      gen = Property.unique_list(Property.integer(-100, 100), 10)

      for _ <- 1..20 do
        list = gen.()
        assert length(list) == length(Enum.uniq(list))
      end
    end

    test "assert_always_ok passes for functions that return {:ok, _}" do
      Property.assert_always_ok(Property.integer(), fn _n ->
        Lux.Native.Rust.add(1, 2)
      end, 10)
    end
  end

  describe "Lux.Native.Testing.Benchmark" do
    test "benchmark returns a BenchmarkReport struct" do
      report = Benchmark.benchmark("test", fn -> :ok end, iterations: 100)

      assert %Benchmark{} = report
      assert report.name == "test"
      assert report.iterations == 100
      assert is_number(report.avg_us)
      assert is_number(report.min_us)
      assert is_number(report.max_us)
      assert is_number(report.p50_us)
      assert is_number(report.p95_us)
      assert is_number(report.p99_us)
      assert is_number(report.ops_per_sec)
    end

    test "benchmark measures actual NIF performance" do
      report = Benchmark.benchmark("add/2", fn ->
        Lux.Native.Rust.add(1, 2)
      end, iterations: 1000)

      # NIF calls should be sub-millisecond
      assert report.avg_us < 1000, "add/2 too slow: #{report.avg_us}µs avg"
    end

    test "format_report returns readable string" do
      report = Benchmark.benchmark("test", fn -> :ok end, iterations: 10)
      formatted = Benchmark.format_report(report)

      assert formatted =~ "Benchmark: test"
      assert formatted =~ "Iterations:"
      assert formatted =~ "Average:"
      assert formatted =~ "Ops/sec:"
    end

    test "assert_below passes for fast operations" do
      report = Benchmark.benchmark("fast", fn -> :ok end, iterations: 100)
      assert :ok = Benchmark.assert_below(report, 1_000_000)
    end

    test "assert_below fails for slow operations" do
      report = Benchmark.benchmark("slow", fn -> Process.sleep(1) end, iterations: 5)

      assert_raise ExUnit.AssertionError, fn ->
        Benchmark.assert_below(report, 1)
      end
    end

    test "compare returns speedup ratio" do
      result = Benchmark.compare(
        "fast", fn -> :ok end,
        "slow", fn -> Process.sleep(1) end,
        iterations: 10
      )

      assert %{:left => _, :right => _, :speedup => _} = result
      assert is_float(result.speedup) or result.speedup == :unknown
    end

    test "benchmark_suite runs multiple benchmarks" do
      suite = [
        {"noop", fn -> :ok end},
        {"compute", fn -> 1 + 1 end}
      ]

      reports = Benchmark.benchmark_suite(suite, iterations: 100)
      assert length(reports) == 2
      assert Enum.all?(reports, &match?(%Benchmark{}, &1))
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp is_json_compatible(value) when is_number(value), do: true
  defp is_json_compatible(value) when is_binary(value), do: true
  defp is_json_compatible(value) when is_boolean(value), do: true
  defp is_json_compatible(nil), do: true
  defp is_json_compatible(value) when is_list(value) do
    Enum.all?(value, &is_json_compatible/1)
  end

  defp is_json_compatible(value) when is_map(value) do
    Enum.all?(value, fn
      {k, v} when is_binary(k) -> is_json_compatible(v)
      _ -> false
    end)
  end

  defp is_json_compatible(_), do: false
end
