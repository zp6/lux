defmodule Lux.Integrations.Telegram.Analytics do
  @moduledoc """
  Analytics engine for tracking and analyzing Telegram bot usage and performance.

  Provides an ETS-backed metrics collection system that supports:

  - **Message analytics** — track sent/received message counts, throughput
  - **User engagement** — active users, new users, retention windows
  - **Command usage** — per-command invocation counts and success rates
  - **Error monitoring** — error counts, rates, and last error details
  - **Performance metrics** — response-time histograms and percentiles
  - **Custom metrics** — arbitrary key-value counters and gauges
  - **Usage patterns** — hourly/daily activity breakdowns

  All data is stored in an ETS table (`:telegram_analytics`) managed by this
  GenServer, making it fast for reads while keeping writes lightweight.

  ## Architecture

  The analytics engine is started under `Lux.Integrations.Telegram.Supervisor`
  and registers itself as `__MODULE__` so other processes can call it directly.

  Metrics are grouped into *namespaces* (`:messages`, `:users`, `:commands`,
  `:errors`, `:performance`, `:custom`) to keep the key-space organised.

  ## Quick Start

      # Track a sent message
      Analytics.track(:messages, :sent, 1)

      # Track a command invocation
      Analytics.track(:commands, "/start", 1, meta: %{user_id: 123})

      # Record a response time
      Analytics.record_response_time(150)

      # Get aggregated stats
      {:ok, stats} = Analytics.get_stats(:messages)
  """

  use GenServer

  require Logger

  @table :telegram_analytics
  @namespaces [:messages, :users, :commands, :errors, :performance, :custom]

  # ── Types ──────────────────────────────────────────────────────────────

  @type namespace :: :messages | :users | :commands | :errors | :performance | :custom
  @type metric_key :: atom() | String.t()
  @type metric_value :: number() | map()
  @type time_window :: :hour | :day | :week | :all

  @type stats :: %{
          total: non_neg_integer(),
          metrics: %{metric_key() => metric_value()},
          window: time_window(),
          computed_at: DateTime.t()
        }

  # ── Client API ─────────────────────────────────────────────────────────

  @doc """
  Starts the analytics engine and creates the ETS table.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Tracks a metric increment under the given namespace.

  ## Parameters

    * `namespace` — one of `#{@namespaces |> Enum.map_join(", ", &inspect/1)}`
    * `key`       — the metric identifier (e.g. `:sent`, `"/start"`)
    * `value`     — the amount to add (default `1`)
    * `opts`      — optional metadata (`:meta` map, `:timestamp`)

  ## Examples

      iex> Analytics.track(:messages, :sent, 1)
      :ok

      iex> Analytics.track(:commands, "/help", 1, meta: %{user_id: 42})
      :ok
  """
  @spec track(namespace(), metric_key(), number(), keyword()) :: :ok
  def track(namespace, key, value \\ 1, opts \\ []) do
    validate_namespace!(namespace)
    GenServer.cast(__MODULE__, {:track, namespace, key, value, opts})
  end

  @doc """
  Sets a gauge-style metric (absolute value instead of increment).

  ## Examples

      iex> Analytics.set_gauge(:users, :active, 42)
      :ok
  """
  @spec set_gauge(namespace(), metric_key(), number(), keyword()) :: :ok
  def set_gauge(namespace, key, value, opts \\ []) do
    validate_namespace!(namespace)
    GenServer.cast(__MODULE__, {:set_gauge, namespace, key, value, opts})
  end

  @doc """
  Records a response time in milliseconds for latency analysis.
  Automatically updates min, max, avg, p50, p95, p99 under the `:performance` namespace.

  ## Examples

      iex> Analytics.record_response_time(120)
      :ok
  """
  @spec record_response_time(non_neg_integer()) :: :ok
  def record_response_time(ms) when is_integer(ms) and ms >= 0 do
    GenServer.cast(__MODULE__, {:record_response_time, ms})
  end

  @doc """
  Records an error occurrence.

  ## Examples

      iex> Analytics.record_error("api_timeout", %{endpoint: "/sendMessage"})
      :ok
  """
  @spec record_error(String.t(), map()) :: :ok
  def record_error(error_type, meta \\ %{}) do
    GenServer.cast(__MODULE__, {:record_error, error_type, meta})
  end

  @doc """
  Records a user engagement event (e.g. user started the bot, sent a message).

  ## Examples

      iex> Analytics.record_user_event(123_456, :message_sent)
      :ok
  """
  @spec record_user_event(integer(), atom()) :: :ok
  def record_user_event(user_id, event) when is_integer(user_id) do
    GenServer.cast(__MODULE__, {:record_user_event, user_id, event})
  end

  @doc """
  Retrieves aggregated statistics for a namespace.

  Returns a map with `:total`, `:metrics`, `:window`, and `:computed_at`.

  ## Examples

      iex> {:ok, stats} = Analytics.get_stats(:messages)
      iex> stats.total >= 0
      true
  """
  @spec get_stats(namespace()) :: {:ok, stats()} | {:error, term()}
  def get_stats(namespace) do
    validate_namespace!(namespace)
    GenServer.call(__MODULE__, {:get_stats, namespace})
  end

  @doc """
  Retrieves aggregated statistics for all namespaces.

  ## Examples

      iex> {:ok, all} = Analytics.get_all_stats()
      iex> Map.has_key?(all, :messages)
      true
  """
  @spec get_all_stats() :: {:ok, %{namespace() => stats()}}
  def get_all_stats do
    GenServer.call(__MODULE__, :get_all_stats)
  end

  @doc """
  Returns usage pattern data grouped by hour for the last `hours` hours.

  ## Examples

      iex> {:ok, patterns} = Analytics.get_usage_patterns(24)
      iex> is_list(patterns)
      true
  """
  @spec get_usage_patterns(pos_integer()) :: {:ok, [map()]}
  def get_usage_patterns(hours \\ 24) do
    GenServer.call(__MODULE__, {:get_usage_patterns, hours})
  end

  @doc """
  Resets all collected metrics. Useful for testing.
  """
  @spec reset() :: :ok
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  @doc """
  Generates a report for the given time window.

  ## Examples

      iex> {:ok, report} = Analytics.generate_report(:day)
      iex> Map.has_key?(report, :summary)
      true
  """
  @spec generate_report(time_window()) :: {:ok, map()} | {:error, term()}
  def generate_report(window \\ :day) do
    GenServer.call(__MODULE__, {:generate_report, window})
  end

  # ── GenServer Callbacks ────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:set, :named_table, :public, read_concurrency: true])

    state = %{
      table: table,
      response_times: [],
      hourly_buckets: %{},
      started_at: DateTime.utc_now()
    }

    # Schedule periodic flush
    Process.send_after(self(), :flush_hourly, hour_ms())

    {:ok, state}
  end

  @impl true
  def handle_cast({:track, namespace, key, value, opts}, state) do
    timestamp = Keyword.get(opts, :timestamp, System.system_time(:millisecond))
    meta = Keyword.get(opts, :meta, %{})

    # Update counter
    ets_key = {namespace, key}
    case :ets.lookup(@table, ets_key) do
      [{^ets_key, existing_count, existing_meta, _ts}] ->
        merged_meta = Map.merge(existing_meta, meta)
        :ets.insert(@table, {ets_key, existing_count + value, merged_meta, timestamp})

      [] ->
        :ets.insert(@table, {ets_key, value, meta, timestamp})
    end

    # Update hourly bucket
    hour_key = current_hour_key()
    updated = Map.update(state.hourly_buckets, hour_key, 1, &(&1 + 1))
    {:noreply, %{state | hourly_buckets: updated}}
  end

  @impl true
  def handle_cast({:set_gauge, namespace, key, value, opts}, state) do
    timestamp = Keyword.get(opts, :timestamp, System.system_time(:millisecond))
    meta = Keyword.get(opts, :meta, %{})
    ets_key = {namespace, key}
    :ets.insert(@table, {ets_key, value, meta, timestamp})
    {:noreply, state}
  end

  @impl true
  def handle_cast({:record_response_time, ms}, state) do
    # Keep last 1000 response times for percentile calculations
    times = Enum.take(state.response_times ++ [ms], -1000)

    # Compute stats
    sorted = Enum.sort(times)
    count = length(sorted)
    sum = Enum.sum(sorted)

    perf_stats = %{
      count: count,
      min: List.first(sorted),
      max: List.last(sorted),
      avg: if(count > 0, do: sum / count, else: 0),
      p50: percentile(sorted, 0.50),
      p95: percentile(sorted, 0.95),
      p99: percentile(sorted, 0.99)
    }

    :ets.insert(@table, {{:performance, :response_time}, perf_stats, %{}, System.system_time(:millisecond)})

    {:noreply, %{state | response_times: times}}
  end

  @impl true
  def handle_cast({:record_error, error_type, meta}, state) do
    timestamp = System.system_time(:millisecond)

    # Track error count
    ets_key = {:errors, error_type}
    case :ets.lookup(@table, ets_key) do
      [{^ets_key, count, _meta, _ts}] ->
        :ets.insert(@table, {ets_key, count + 1, meta, timestamp})

      [] ->
        :ets.insert(@table, {ets_key, 1, meta, timestamp})
    end

    # Track total errors
    total_key = {:errors, :total}
    case :ets.lookup(@table, total_key) do
      [{^total_key, total, _, _}] ->
        :ets.insert(@table, {total_key, total + 1, %{}, timestamp})

      [] ->
        :ets.insert(@table, {total_key, 1, %{}, timestamp})
    end

    # Track last error
    :ets.insert(@table, {{:errors, :last_error}, error_type, meta, timestamp})

    {:noreply, state}
  end

  @impl true
  def handle_cast({:record_user_event, user_id, event}, state) do
    timestamp = System.system_time(:millisecond)

    # Track unique user
    user_key = {:users, user_id}
    case :ets.lookup(@table, user_key) do
      [{^user_key, events, _, _}] ->
        :ets.insert(@table, {user_key, [event | events], %{last_event: event}, timestamp})

      [] ->
        :ets.insert(@table, {user_key, [event], %{first_seen: timestamp}, timestamp})
        # Increment new user count
        new_key = {:users, :new_count}
        case :ets.lookup(@table, new_key) do
          [{^new_key, count, _, _}] ->
            :ets.insert(@table, {new_key, count + 1, %{}, timestamp})

          [] ->
            :ets.insert(@table, {new_key, 1, %{}, timestamp})
        end
    end

    # Track active users count (unique users with events in current window)
    active_key = {:users, :active}
    case :ets.lookup(@table, active_key) do
      [{^active_key, active_set, _, _}] when is_map(active_set) ->
        :ets.insert(@table, {active_key, MapSet.put(active_set, user_id), %{}, timestamp})

      [] ->
        :ets.insert(@table, {active_key, MapSet.new([user_id]), %{}, timestamp})
    end

    {:noreply, state}
  end

  @impl true
  def handle_call({:get_stats, namespace}, _from, state) do
    stats = compute_namespace_stats(namespace)
    {:reply, {:ok, stats}, state}
  end

  @impl true
  def handle_call(:get_all_stats, _from, state) do
    all =
      @namespaces
      |> Enum.map(fn ns -> {ns, compute_namespace_stats(ns)} end)
      |> Map.new()

    {:reply, {:ok, all}, state}
  end

  @impl true
  def handle_call({:get_usage_patterns, hours}, _from, state) do
    now = DateTime.utc_now()
    hour_keys =
      0..(hours - 1)
      |> Enum.map(fn h ->
        DateTime.add(now, -h * 3600)
        |> DateTime.to_iso8601()
        |> String.slice(0, 13)
      end)
      |> Enum.reverse()

    patterns =
      Enum.map(hour_keys, fn hk ->
        %{hour: hk, count: Map.get(state.hourly_buckets, hk, 0)}
      end)

    {:reply, {:ok, patterns}, state}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, %{state | response_times: [], hourly_buckets: %{}}}
  end

  @impl true
  def handle_call({:generate_report, window}, _from, state) do
    report = build_report(window, state)
    {:reply, {:ok, report}, state}
  end

  @impl true
  def handle_info(:flush_hourly, state) do
    # Clean up hourly buckets older than 48 hours
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-48 * 3600)
      |> DateTime.to_iso8601()
      |> String.slice(0, 13)

    cleaned =
      state.hourly_buckets
      |> Enum.filter(fn {k, _v} -> k >= cutoff end)
      |> Map.new()

    Process.send_after(self(), :flush_hourly, hour_ms())
    {:noreply, %{state | hourly_buckets: cleaned}}
  end

  # ── Private Helpers ────────────────────────────────────────────────────

  defp validate_namespace!(ns) when ns in @namespaces, do: :ok
  defp validate_namespace!(ns) do
    raise ArgumentError,
      "Invalid namespace #{inspect(ns)}. Must be one of #{inspect(@namespaces)}"
  end

  defp compute_namespace_stats(namespace) do
    metrics =
      :ets.match_object(@table, {{namespace, :_}, :_, :_, :_})
      |> Enum.map(fn {{^namespace, key}, value, meta, ts} ->
        {key, %{value: value, meta: meta, last_updated: ts}}
      end)
      |> Map.new()

    total =
      metrics
      |> Enum.filter(fn {k, _v} -> k != :total end)
      |> Enum.reduce(0, fn {_k, %{value: v}}, acc ->
        if is_number(v), do: acc + v, else: acc
      end)

    %{
      total: total,
      metrics: metrics,
      window: :all,
      computed_at: DateTime.utc_now()
    }
  end

  defp build_report(window, state) do
    hours = window_to_hours(window)

    message_stats = compute_namespace_stats(:messages)
    user_stats = compute_namespace_stats(:users)
    command_stats = compute_namespace_stats(:commands)
    error_stats = compute_namespace_stats(:errors)

    # Active users
    active_count =
      case :ets.lookup(@table, {:users, :active}) do
        [{_, ms, _, _}] when is_struct(ms, MapSet) -> MapSet.size(ms)
        _ -> 0
      end

    # Error rate
    total_errors = get_in(error_stats.metrics, [:total, :value]) || 0
    total_messages = message_stats.total
    error_rate = if total_messages > 0, do: total_errors / total_messages * 100, else: 0.0

    # Performance
    perf =
      case :ets.lookup(@table, {{:performance, :response_time}}) do
        [{_, stats, _, _}] -> stats
        [] -> %{count: 0, min: 0, max: 0, avg: 0, p50: 0, p95: 0, p99: 0}
      end

    # Usage patterns
    {:ok, patterns} = {:ok, state.hourly_buckets
      |> Enum.filter(fn {k, _v} ->
        hour_time = k <> ":00:00Z"
        case DateTime.from_iso8601(hour_time) do
          {:ok, dt, _} ->
            cutoff = DateTime.add(DateTime.utc_now(), -hours * 3600)
            DateTime.compare(dt, cutoff) in [:gt, :eq]
          _ -> true
        end
      end)
      |> Enum.map(fn {hour, count} -> %{hour: hour, count: count} end)
      |> Enum.sort_by(& &1.hour)}

    %{
      window: window,
      generated_at: DateTime.utc_now(),
      uptime_seconds: DateTime.diff(DateTime.utc_now(), state.started_at),
      summary: %{
        total_messages: total_messages,
        active_users: active_count,
        total_errors: total_errors,
        error_rate_percent: Float.round(error_rate, 2)
      },
      messages: message_stats,
      users: Map.put(user_stats, :active_count, active_count),
      commands: command_stats,
      errors: error_stats,
      performance: perf,
      usage_patterns: patterns
    }
  end

  defp window_to_hours(:hour), do: 1
  defp window_to_hours(:day), do: 24
  defp window_to_hours(:week), do: 168
  defp window_to_hours(:all), do: 8760

  defp percentile(sorted_list, p) when length(sorted_list) == 0, do: 0
  defp percentile(sorted_list, p) do
    count = length(sorted_list)
    index = max(0, round(p * count) - 1)
    Enum.at(sorted_list, index, 0)
  end

  defp current_hour_key do
    DateTime.utc_now() |> DateTime.to_iso8601() |> String.slice(0, 13)
  end

  defp hour_ms, do: 3_600_000
end
