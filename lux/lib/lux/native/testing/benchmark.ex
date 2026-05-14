defmodule Lux.Native.Testing.Benchmark do
  @moduledoc """
  Performance benchmarking utilities for Rust NIF functions.

  Measures latency, throughput, and memory overhead of NIF calls
  to help identify performance regressions.

  ## Usage

      defmodule MyBenchmarkTest do
        use ExUnit.Case, async: false
        import Lux.Native.Testing.Benchmark

        test "add/2 performance" do
          report = benchmark("add/2", fn ->
            Lux.Native.Rust.add(1, 2)
          end)

          assert report.avg_us < 100, "add/2 too slow: #{report.avg_us}µs"
        end
      end

  ## Benchmark Report

  Each benchmark returns a `%BenchmarkReport{}` with:

  - `:name` — Benchmark label
  - `:iterations` — Number of iterations run
  - `:total_us` — Total wall-clock time in microseconds
  - `:avg_us` — Average time per iteration in microseconds
  - `:min_us` — Fastest iteration in microseconds
  - `:max_us` — Slowest iteration in microseconds
  - `:p50_us` — Median (50th percentile)
  - `:p95_us` — 95th percentile
  - `:p99_us` — 99th percentile
  - `:ops_per_sec` — Estimated operations per second
  """

  defstruct [
    :name,
    :iterations,
    :total_us,
    :avg_us,
    :min_us,
    :max_us,
    :p50_us,
    :p95_us,
    :p99_us,
    :ops_per_sec
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          iterations: pos_integer(),
          total_us: integer(),
          avg_us: float(),
          min_us: integer(),
          max_us: integer(),
          p50_us: float(),
          p95_us: float(),
          p99_us: float(),
          ops_per_sec: float()
        }

  @default_warmup 50
  @default_iterations 10_000

  @doc """
  Runs a benchmark of the given function.

  ## Options

  - `:warmup` — Number of warmup iterations (default: 50)
  - `:iterations` — Number of measured iterations (default: 10_000)

  ## Returns

  A `%BenchmarkReport{}` struct with timing statistics.
  """
  def benchmark(name, fun, opts \\ []) when is_function(fun, 0) do
    warmup = Keyword.get(opts, :warmup, @default_warmup)
    iterations = Keyword.get(opts, :iterations, @default_iterations)

    # Warmup phase
    for _ <- 1..warmup, do: fun.()

    # Collect GC stats before
    :erlang.garbage_collect()
    {:reductions, reductions_before} = Process.info(self(), :reductions)

    # Measured phase
    times =
      for _ <- 1..iterations do
        start = System.monotonic_time(:nanosecond)
        fun.()
        finish = System.monotonic_time(:nanosecond)
        div(finish - start, 1000) # Convert to microseconds
      end

    {:reductions, reductions_after} = Process.info(self(), :reductions)

    # Calculate statistics
    sorted = Enum.sort(times)
    total = Enum.sum(sorted)
    avg = total / iterations
    min_us = List.first(sorted)
    max_us = List.last(sorted)
    p50 = percentile(sorted, 0.50)
    p95 = percentile(sorted, 0.95)
    p99 = percentile(sorted, 0.99)
    ops_per_sec = if avg > 0, do: 1_000_000.0 / avg, else: :infinity

    %__MODULE__{
      name: name,
      iterations: iterations,
      total_us: total,
      avg_us: Float.round(avg, 3),
      min_us: min_us,
      max_us: max_us,
      p50_us: Float.round(p50, 3),
      p95_us: Float.round(p95, 3),
      p99_us: Float.round(p99, 3),
      ops_per_sec: Float.round(ops_per_sec, 1)
    }
  end

  @doc """
  Runs a benchmark comparing two functions.

  Returns a map with `:left` and `:right` benchmark reports,
  plus `:speedup` (left_ops / right_ops).
  """
  def compare(left_name, left_fun, right_name, right_fun, opts \\ []) do
    left_report = benchmark(left_name, left_fun, opts)
    right_report = benchmark(right_name, right_fun, opts)

    speedup =
      cond do
        left_report.avg_us > 0 and right_report.avg_us > 0 ->
          Float.round(right_report.avg_us / left_report.avg_us, 2)
        true ->
          :unknown
      end

    %{
      left: left_report,
      right: right_report,
      speedup: speedup
    }
  end

  @doc """
  Formats a benchmark report as a human-readable string.

  ## Example

      report = benchmark("sha256", fn -> Rust.sha256("test") end)
      IO.puts(format_report(report))
  """
  def format_report(%__MODULE__{} = report) do
    """
    Benchmark: #{report.name}
    ─────────────────────────────────
    Iterations:  #{report.iterations}
    Total:       #{report.total_us} µs
    Average:     #{report.avg_us} µs
    Min:         #{report.min_us} µs
    Max:         #{report.max_us} µs
    P50:         #{report.p50_us} µs
    P95:         #{report.p95_us} µs
    P99:         #{report.p99_us} µs
    Ops/sec:     #{report.ops_per_sec}
    """
  end

  @doc """
  Asserts that a benchmark's average latency is below a threshold.

  ## Example

      report = benchmark("add", fn -> Rust.add(1, 2) end)
      assert_below(report, 100)  # asserts avg < 100µs
  """
  def assert_below(%__MODULE__{} = report, max_avg_us) do
    if report.avg_us > max_avg_us do
      raise ExUnit.AssertionError,
        message: """
        Benchmark "#{report.name}" exceeded threshold.

        Average: #{report.avg_us} µs (threshold: #{max_avg_us} µs)

        #{format_report(report)}
        """
    end

    :ok
  end

  @doc """
  Benchmarks each function in a keyword list and returns formatted results.
  Useful for comparing multiple NIF operations at once.

  ## Example

      suite = [
        {"add", fn -> Rust.add(1, 2) end},
        {"uuid_v4", fn -> Rust.uuid_v4() end},
        {"sha256", fn -> Rust.sha256("test") end}
      ]

      results = benchmark_suite(suite)
      for report <- results, do: IO.puts(Benchmark.format_report(report))
  """
  def benchmark_suite(suite, opts \\ []) do
    Enum.map(suite, fn {name, fun} ->
      benchmark(name, fun, opts)
    end)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp percentile(sorted_list, p) when p >= 0.0 and p <= 1.0 do
    len = length(sorted_list)
    index = max(0, round(p * len) - 1)
    Enum.at(sorted_list, index, 0)
  end
end
