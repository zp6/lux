defmodule Lux.Integrations.Telegram.RateLimiter do
  @moduledoc """
  Rate limiter for Telegram Bot API requests.

  Implements sliding window rate limiting per Telegram's documented limits:
  - 30 messages per second overall
  - 20 messages per minute per group
  - 1 message per second per chat (private)
  - 30 messages per second per channel

  Uses ETS for tracking request timestamps with automatic cleanup.
  """

  use GenServer
  require Logger

  @table :telegram_rate_limiter
  @default_limits %{
    global: {30, 1},              # 30 requests per second
    group: {20, 60},              # 20 requests per minute
    private_chat: {1, 1},        # 1 request per second
    channel: {30, 1}             # 30 requests per second
  }

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Checks if a request is allowed under rate limits.
  Returns {:ok, :allowed} or {:error, :rate_limited, wait_ms}
  """
  def check_rate(chat_id, chat_type \\ nil) do
    GenServer.call(__MODULE__, {:check_rate, chat_id, chat_type})
  end

  @doc """
  Records a successful request for rate tracking.
  """
  def record_request(chat_id, chat_type \\ nil) do
    GenServer.cast(__MODULE__, {:record, chat_id, chat_type})
  end

  @doc """
  Gets current rate limit status for a chat.
  """
  def get_status(chat_id) do
    GenServer.call(__MODULE__, {:get_status, chat_id})
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    schedule_cleanup()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:check_rate, chat_id, chat_type}, _from, state) do
    now = System.system_time(:millisecond)
    limit_key = classify_chat(chat_type)
    {max_requests, window_ms} = Map.get(@default_limits, limit_key, {30, 1000})

    # Check global limit
    global_key = {:global, :global}
    global_allowed = check_window(global_key, max_requests, window_ms, now)

    # Check per-chat limit
    chat_key = {:chat, chat_id}
    chat_allowed = check_window(chat_key, max_requests, window_ms, now)

    cond do
      not global_allowed ->
        wait = calculate_wait(global_key, max_requests, window_ms, now)
        {:reply, {:error, :rate_limited, wait}, state}

      not chat_allowed ->
        wait = calculate_wait(chat_key, max_requests, window_ms, now)
        {:reply, {:error, :rate_limited, wait}, state}

      true ->
        record_timestamp(global_key, now)
        record_timestamp(chat_key, now)
        {:reply, {:ok, :allowed}, state}
    end
  end

  @impl true
  def handle_call({:get_status, chat_id}, _from, state) do
    now = System.system_time(:millisecond)
    chat_key = {:chat, chat_id}

    case :ets.lookup(@table, chat_key) do
      [{^chat_key, timestamps}] ->
        recent = filter_recent(timestamps, 60000, now)
        {:reply, %{chat_id: chat_id, requests_last_minute: length(recent)}, state}

      [] ->
        {:reply, %{chat_id: chat_id, requests_last_minute: 0}, state}
    end
  end

  @impl true
  def handle_cast({:record, _chat_id, _chat_type}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_old_entries()
    schedule_cleanup()
    {:noreply, state}
  end

  # Private functions

  defp classify_chat("group"), do: :group
  defp classify_chat("supergroup"), do: :group
  defp classify_chat("channel"), do: :channel
  defp classify_chat("private"), do: :private_chat
  defp classify_chat(_), do: :group

  defp check_window(key, max_requests, window_ms, now) do
    case :ets.lookup(@table, key) do
      [{^key, timestamps}] ->
        recent = filter_recent(timestamps, window_ms, now)
        length(recent) < max_requests

      [] ->
        true
    end
  end

  defp calculate_wait(key, max_requests, window_ms, now) do
    case :ets.lookup(@table, key) do
      [{^key, timestamps}] ->
        recent = filter_recent(timestamps, window_ms, now)
        if length(recent) >= max_requests do
          oldest = Enum.min(recent)
          oldest + window_ms - now + 1
        else
          0
        end

      [] ->
        0
    end
  end

  defp record_timestamp(key, now) do
    case :ets.lookup(@table, key) do
      [{^key, timestamps}] ->
        :ets.insert(@table, {key, [now | timestamps]})

      [] ->
        :ets.insert(@table, {key, [now]})
    end
  end

  defp filter_recent(timestamps, window_ms, now) do
    cutoff = now - window_ms
    Enum.filter(timestamps, fn ts -> ts > cutoff end)
  end

  defp cleanup_old_entries do
    now = System.system_time(:millisecond)
    cutoff = now - 120_000 # Keep last 2 minutes

    :ets.tab2list(@table)
    |> Enum.each(fn {key, timestamps} ->
      recent = Enum.filter(timestamps, fn ts -> ts > cutoff end)
      if recent == [] do
        :ets.delete(@table, key)
      else
        :ets.insert(@table, {key, recent})
      end
    end)
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, 60_000)
  end
end
