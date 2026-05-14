defmodule Lux.Integrations.Telegram.Monitor do
  @moduledoc """
  Performance monitor for the Telegram bot integration.

  Wraps Telegram API calls with automatic metric collection:

  - **Response times** — measured per-call and aggregated as p50/p95/p99
  - **Error rates** — tracked per endpoint and globally
  - **Health checks** — periodic `getMe` probes to verify bot connectivity
  - **Alerts** — configurable thresholds that fire callback functions

  The monitor is started under `Lux.Integrations.Telegram.Supervisor` and
  registers itself as `__MODULE__`.

  ## Quick Start

      # Wrap a Telegram API call
      {:ok, result} = Monitor.track_call("/sendMessage", fn ->
        Client.request(:post, "/sendMessage", %{json: %{chat_id: 123, text: "hi"}})
      end)

      # Check bot health
      {:ok, health} = Monitor.health_check()

      # Get alert configuration
      {:ok, alerts} = Monitor.get_alerts()
  """

  use GenServer

  require Logger

  alias Lux.Integrations.Telegram.Analytics

  # ── Types ──────────────────────────────────────────────────────────────

  @type alert_config :: %{
          name: atom(),
          metric: atom(),
          threshold: number(),
          window_ms: pos_integer(),
          callback: (map() -> any()) | nil
        }

  @type health_status :: %{
          status: :healthy | :degraded | :unhealthy,
          bot_connected: boolean(),
          last_check: DateTime.t(),
          response_time_ms: non_neg_integer() | nil,
          error_rate_percent: float(),
          active_alerts: [map()]
        }

  # ── Client API ─────────────────────────────────────────────────────────

  @doc """
  Starts the monitor process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Wraps a function call with automatic metric collection.

  Measures the execution time, records success/failure, and pushes
  the data into the analytics engine.

  ## Parameters

    * `endpoint` — Telegram API endpoint (e.g. `"/sendMessage"`)
    * `fun`      — zero-arity function that performs the API call

  ## Examples

      iex> {:ok, result} = Monitor.track_call("/sendMessage", fn ->
      ...>   Client.request(:post, "/sendMessage", %{json: %{chat_id: 123, text: "hi"}})
      ...> end)
  """
  @spec track_call(String.t(), (-> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def track_call(endpoint, fun) when is_function(fun, 0) do
    GenServer.call(__MODULE__, {:track_call, endpoint, fun}, :infinity)
  end

  @doc """
  Runs a health check against the Telegram Bot API using `getMe`.

  Returns a map with connection status, response time, error rate,
  and any active alerts.
  """
  @spec health_check() :: {:ok, health_status()}
  def health_check do
    GenServer.call(__MODULE__, :health_check, 30_000)
  end

  @doc """
  Registers an alert configuration.

  ## Parameters

    * `config` — map with `:name`, `:metric`, `:threshold`, `:window_ms`,
                 and optional `:callback`

  ## Examples

      iex> :ok = Monitor.register_alert(%{
      ...>   name: :high_error_rate,
      ...>   metric: :error_rate,
      ...   threshold: 10.0,
      ...   window_ms: 60_000,
      ...   callback: &MyApp.notify_ops/1
      ... })
  """
  @spec register_alert(alert_config()) :: :ok
  def register_alert(config) do
    GenServer.cast(__MODULE__, {:register_alert, config})
  end

  @doc """
  Returns the list of registered alert configurations.
  """
  @spec get_alerts() :: {:ok, [alert_config()]}
  def get_alerts do
    GenServer.call(__MODULE__, :get_alerts)
  end

  @doc """
  Returns the current monitor state summary for diagnostics.
  """
  @spec get_status() :: {:ok, map()}
  def get_status do
    GenServer.call(__MODULE__, :get_status)
  end

  # ── GenServer Callbacks ────────────────────────────────────────────────

  @impl true
  def init(opts) do
    health_interval = Keyword.get(opts, :health_check_interval_ms, 60_000)

    state = %{
      alerts: [],
      health_interval: health_interval,
      call_log: [],
      active_alerts: []
    }

    # Schedule periodic health check
    if health_interval > 0 do
      Process.send_after(self(), :periodic_health_check, health_interval)
    end

    {:ok, state}
  end

  @impl true
  def handle_call({:track_call, endpoint, fun}, _from, state) do
    start = System.monotonic_time(:millisecond)

    result =
      try do
        fun.()
      rescue
        e -> {:error, Exception.message(e)}
      end

    elapsed = System.monotonic_time(:millisecond) - start

    case result do
      {:ok, data} ->
        Analytics.track(:messages, :sent, 1)
        Analytics.record_response_time(elapsed)
        Analytics.track(:performance, String.to_atom("endpoint_#{endpoint}"), 1,
          meta: %{response_time: elapsed, status: :success}
        )
        Logger.debug("Telegram API call to #{endpoint} succeeded in #{elapsed}ms")
        {:reply, {:ok, data}, state}

      {:error, reason} ->
        Analytics.record_error(endpoint, %{reason: inspect(reason), response_time: elapsed})
        Analytics.track(:performance, String.to_atom("endpoint_#{endpoint}"), 1,
          meta: %{response_time: elapsed, status: :error}
        )
        Logger.warning("Telegram API call to #{endpoint} failed: #{inspect(reason)}")

        new_state = check_alerts(state, endpoint, elapsed, reason)
        {:reply, {:error, reason}, new_state}
    end
  end

  @impl true
  def handle_call(:health_check, _from, state) do
    start = System.monotonic_time(:millisecond)

    {bot_connected, response_time} =
      try do
        result = Lux.Integrations.Telegram.Client.request(:get, "/getMe", %{})
        elapsed = System.monotonic_time(:millisecond) - start

        connected =
          case result do
            {:ok, %{"ok" => true}} -> true
            _ -> false
          end

        {connected, elapsed}
      rescue
        _ -> {false, nil}
      end

    # Get error rate from analytics
    {:ok, error_stats} = Analytics.get_stats(:errors)
    {:ok, msg_stats} = Analytics.get_stats(:messages)

    total_errors = get_in(error_stats.metrics, [:total, :value]) || 0
    total_messages = msg_stats.total
    error_rate = if total_messages > 0, do: total_errors / total_messages * 100, else: 0.0

    status =
      cond do
        not bot_connected -> :unhealthy
        error_rate > 10.0 -> :degraded
        true -> :healthy
      end

    health = %{
      status: status,
      bot_connected: bot_connected,
      last_check: DateTime.utc_now(),
      response_time_ms: response_time,
      error_rate_percent: Float.round(error_rate, 2),
      active_alerts: state.active_alerts
    }

    {:reply, {:ok, health}, state}
  end

  @impl true
  def handle_call(:get_alerts, _from, state) do
    {:reply, {:ok, state.alerts}, state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    {:reply, {:ok, %{alert_count: length(state.alerts), active_alerts: state.active_alerts}}, state}
  end

  @impl true
  def handle_cast({:register_alert, config}, state) do
    {:noreply, %{state | alerts: [config | state.alerts]}}
  end

  @impl true
  def handle_info(:periodic_health_check, state) do
    case health_check_sync() do
      {:healthy, _} ->
        :ok

      {:unhealthy, details} ->
        Logger.warning("Telegram bot health check failed: #{inspect(details)}")
        Analytics.record_error("health_check_failed", details)

      {:degraded, details} ->
        Logger.warning("Telegram bot health check degraded: #{inspect(details)}")
    end

    Process.send_after(self(), :periodic_health_check, state.health_interval)
    {:noreply, state}
  end

  # ── Private Helpers ────────────────────────────────────────────────────

  defp health_check_sync do
    start = System.monotonic_time(:millisecond)

    try do
      result = Lux.Integrations.Telegram.Client.request(:get, "/getMe", %{})
      elapsed = System.monotonic_time(:millisecond) - start

      case result do
        {:ok, %{"ok" => true}} ->
          Analytics.record_response_time(elapsed)
          {:healthy, %{response_time_ms: elapsed}}

        error ->
          {:unhealthy, %{error: error, response_time_ms: elapsed}}
      end
    rescue
      e ->
        {:unhealthy, %{error: Exception.message(e)}}
    end
  end

  defp check_alerts(state, endpoint, elapsed, reason) do
    active =
      Enum.flat_map(state.alerts, fn alert ->
        triggered =
          case alert.metric do
            :error_rate -> true  # we're in an error path already
            :response_time -> elapsed > alert.threshold
            :error_count -> true
            _ -> false
          end

        if triggered do
          alert_info = %{
            name: alert.name,
            metric: alert.metric,
            value: %{endpoint: endpoint, elapsed: elapsed, reason: inspect(reason)},
            threshold: alert.threshold,
            triggered_at: DateTime.utc_now()
          }

          if alert.callback do
            try do
              alert.callback.(alert_info)
            rescue
              e -> Logger.error("Alert callback failed: #{Exception.message(e)}")
            end
          end

          [alert_info]
        else
          []
        end
      end)

    %{state | active_alerts: active}
  end
end
