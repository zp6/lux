defmodule Lux.Web3.EventMonitor.Storage do
  @moduledoc """
  ETS-based persistent storage for smart contract events.

  Provides query capabilities by contract address, event name, block range,
  and time range. Handles deduplication based on transaction hash + log index.
  Uses ETS tables for persistence that survives GenServer restarts.

  ## Configuration

      config :lux, Lux.Web3.EventMonitor.Storage,
        max_events: 10_000,
        table_name: :event_monitor_storage

  ## Usage

      {:ok, pid} = Storage.start_link([])

      :ok = Storage.store_event(%{
        contract_address: "0x...",
        event_name: "Transfer",
        block_number: 12345,
        transaction_hash: "0x...",
        log_index: 0,
        params: %{from: "0x...", to: "0x...", value: 1000},
        chain_id: 1
      })

      {:ok, events} = Storage.query_events(
        contract_address: "0x...",
        event_name: "Transfer",
        from_block: 12000,
        to_block: 13000
      )

      # Persist to disk and reload
      :ok = Storage.persist()
      :ok = Storage.load()
  """

  use GenServer

  require Logger

  @type event :: %{
    id: String.t(),
    contract_address: String.t(),
    event_name: String.t(),
    block_number: non_neg_integer(),
    transaction_hash: String.t(),
    log_index: non_neg_integer(),
    params: map(),
    chain_id: non_neg_integer(),
    inserted_at: DateTime.t(),
    raw_log: map() | nil
  }

  @type query_opts :: [
    contract_address: String.t(),
    event_name: String.t(),
    from_block: non_neg_integer(),
    to_block: non_neg_integer(),
    from_time: DateTime.t(),
    to_time: DateTime.t(),
    chain_id: non_neg_integer(),
    limit: pos_integer(),
    offset: non_neg_integer()
  ]

  @table_name :lux_event_monitor_storage
  @dedup_table_name :lux_event_monitor_dedup
  @meta_table_name :lux_event_monitor_meta

  # Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec store_event(event()) :: :ok | {:error, :duplicate}
  def store_event(event) do
    GenServer.call(__MODULE__, {:store_event, event})
  end

  @spec store_events([event()]) :: {:ok, non_neg_integer()}
  def store_events(events) do
    GenServer.call(__MODULE__, {:store_events, events})
  end

  @spec query_events(query_opts()) :: {:ok, [event()]}
  def query_events(opts \\ []) do
    GenServer.call(__MODULE__, {:query_events, opts})
  end

  @spec get_event(String.t()) :: {:ok, event()} | {:error, :not_found}
  def get_event(id) do
    GenServer.call(__MODULE__, {:get_event, id})
  end

  @spec count() :: non_neg_integer()
  def count do
    GenServer.call(__MODULE__, :count)
  end

  @spec count_matching(query_opts()) :: non_neg_integer()
  def count_matching(opts \\ []) do
    GenServer.call(__MODULE__, {:count_matching, opts})
  end

  @spec clear() :: :ok
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  @spec get_last_block(non_neg_integer(), String.t() | nil) :: non_neg_integer()
  def get_last_block(chain_id, contract_address \\ nil) do
    GenServer.call(__MODULE__, {:get_last_block, chain_id, contract_address})
  end

  @spec prune_old_events(non_neg_integer()) :: {:ok, non_neg_integer()}
  def prune_old_events(keep_last_n_blocks) do
    GenServer.call(__MODULE__, {:prune_old_events, keep_last_n_blocks})
  end

  @doc """
  Persists the ETS table contents to disk.
  """
  @spec persist() :: :ok | {:error, term()}
  def persist do
    GenServer.call(__MODULE__, :persist)
  end

  @doc """
  Loads persisted events from disk into the ETS table.
  """
  @spec load() :: :ok | {:error, term()}
  def load do
    GenServer.call(__MODULE__, :load)
  end

  @doc """
  Stores a subscriber config for crash recovery of subscriptions.
  """
  @spec put_subscriber_config(String.t(), map()) :: :ok
  def put_subscriber_config(key, config) do
    :ets.insert(@meta_table_name, {{:subscriber, key}, config})
    :ok
  end

  @spec get_subscriber_config(String.t()) :: map() | nil
  def get_subscriber_config(key) do
    case :ets.lookup(@meta_table_name, {:subscriber, key}) do
      [{{:subscriber, ^key}, config}] -> config
      [] -> nil
    end
  end

  @spec list_subscriber_configs() :: [map()]
  def list_subscriber_configs do
    :ets.match_object(@meta_table_name, {{:subscriber, :_}, :_})
    |> Enum.map(fn {{:subscriber, _key}, config} -> config end)
  end

  @spec delete_subscriber_config(String.t()) :: :ok
  def delete_subscriber_config(key) do
    :ets.delete(@meta_table_name, {:subscriber, key})
    :ok
  end

  # GenServer Callbacks

  @impl true
  def init(opts) do
    max_events = Keyword.get(opts, :max_events, get_config(:max_events, 10_000))

    # Create ETS tables (public for reads, owned by this process)
    :ets.new(@table_name, [:set, :named_table, :public, write_concurrency: true])
    :ets.new(@dedup_table_name, [:set, :named_table, :public, write_concurrency: true])
    :ets.new(@meta_table_name, [:set, :named_table, :public, write_concurrency: true])

    # Try to load persisted data
    case do_load(@table_name) do
      :ok -> Logger.info("Loaded persisted event monitor data")
      {:error, _} -> :ok
    end

    state = %{
      events_table: @table_name,
      dedup_table: @dedup_table_name,
      meta_table: @meta_table_name,
      max_events: max_events
    }

    {:ok, state}
  end

  @impl true
  def terminate(_reason, _state) do
    do_persist()
    :ok
  end

  @impl true
  def handle_call({:store_event, event}, _from, state) do
    dedup_key = {event[:transaction_hash] || event["transaction_hash"],
                  event[:log_index] || event["log_index"]}

    case :ets.lookup(state.dedup_table, dedup_key) do
      [_] ->
        {:reply, {:error, :duplicate}, state}

      [] ->
        event_with_meta = Map.merge(event, %{
          id: generate_id(),
          inserted_at: DateTime.utc_now()
        })

        :ets.insert(state.dedup_table, {dedup_key, true})
        :ets.insert(state.events_table, {event_with_meta.id, event_with_meta})
        enforce_max_events(state)

        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:store_events, events}, _from, state) do
    stored_count = Enum.reduce(events, 0, fn event, acc ->
      case store_event_sync(event, state) do
        :ok -> acc + 1
        {:error, :duplicate} -> acc
      end
    end)

    {:reply, {:ok, stored_count}, state}
  end

  @impl true
  def handle_call({:query_events, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)

    events =
      :ets.tab2list(state.events_table)
      |> Enum.map(fn {_id, event} -> event end)
      |> filter_events(opts)
      |> sort_events()
      |> Enum.drop(offset)
      |> Enum.take(limit)

    {:reply, {:ok, events}, state}
  end

  @impl true
  def handle_call({:get_event, id}, _from, state) do
    result =
      case :ets.lookup(state.events_table, id) do
        [{^id, event}] -> {:ok, event}
        [] -> {:error, :not_found}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call(:count, _from, _state) do
    count = :ets.info(@table_name, :size) || 0
    {:reply, count, %{}}
  end

  @impl true
  def handle_call({:count_matching, opts}, _from, state) do
    count =
      :ets.tab2list(state.events_table)
      |> Enum.map(fn {_id, event} -> event end)
      |> filter_events(opts)
      |> length()

    {:reply, count, state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(state.events_table)
    :ets.delete_all_objects(state.dedup_table)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:get_last_block, chain_id, contract_address}, _from, _state) do
    max_block =
      :ets.tab2list(@table_name)
      |> Enum.map(fn {_id, e} -> e end)
      |> Enum.filter(fn e ->
        e[:chain_id] == chain_id and
        (is_nil(contract_address) or
         String.downcase(e[:contract_address] || "") == String.downcase(contract_address || ""))
      end)
      |> Enum.map(& &1[:block_number])
      |> Enum.max(fn -> 0 end)

    {:reply, max_block, %{}}
  end

  @impl true
  def handle_call({:prune_old_events, keep_last_n_blocks}, _from, state) do
    all_events = :ets.tab2list(state.events_table)

    max_block =
      all_events
      |> Enum.map(fn {_id, e} -> e[:block_number] end)
      |> Enum.max(fn -> 0 end)

    cutoff = max_block - keep_last_n_blocks

    removed =
      all_events
      |> Enum.filter(fn {_id, e} -> e[:block_number] <= cutoff end)

    Enum.each(removed, fn {id, event} ->
      :ets.delete(state.events_table, id)
      dedup_key = {event[:transaction_hash], event[:log_index]}
      :ets.delete(state.dedup_table, dedup_key)
    end)

    {:reply, {:ok, length(removed)}, state}
  end

  @impl true
  def handle_call(:persist, _from, state) do
    result = do_persist()
    {:reply, result, state}
  end

  @impl true
  def handle_call(:load, _from, state) do
    :ets.delete_all_objects(state.events_table)
    :ets.delete_all_objects(state.dedup_table)
    result = do_load(state.events_table)
    {:reply, result, state}
  end

  # Private functions

  defp store_event_sync(event, state) do
    dedup_key = {event[:transaction_hash] || event["transaction_hash"],
                  event[:log_index] || event["log_index"]}

    case :ets.lookup(state.dedup_table, dedup_key) do
      [_] -> {:error, :duplicate}
      [] ->
        event_with_meta = Map.merge(event, %{
          id: generate_id(),
          inserted_at: DateTime.utc_now()
        })
        :ets.insert(state.dedup_table, {dedup_key, true})
        :ets.insert(state.events_table, {event_with_meta.id, event_with_meta})
        :ok
    end
  end

  defp enforce_max_events(state) do
    size = :ets.info(state.events_table, :size) || 0
    if size > state.max_events do
      all = :ets.tab2list(state.events_table)
             |> Enum.map(fn {_id, e} -> e end)
             |> sort_events()

      to_remove = Enum.take(all, size - state.max_events)
      Enum.each(to_remove, fn event ->
        :ets.delete(state.events_table, event.id)
        dedup_key = {event[:transaction_hash], event[:log_index]}
        :ets.delete(state.dedup_table, dedup_key)
      end)
    end
  end

  defp do_persist do
    path = persistence_path()

    try do
      events =
        :ets.tab2list(@table_name)
        |> Enum.map(fn {_id, event} -> event end)

      data = Jason.encode!(events)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, data)
      :ok
    rescue
      e -> {:error, e}
    end
  end

  defp do_load(table) do
    path = persistence_path()

    if File.exists?(path) do
      try do
        data = File.read!(path)
        events = Jason.decode!(data)

        Enum.each(events, fn event ->
          event = atomize_event(event)
          id = event[:id] || generate_id()
          dedup_key = {event[:transaction_hash], event[:log_index]}

          :ets.insert(@dedup_table_name, {dedup_key, true})
          :ets.insert(table, {id, event})
        end)

        :ok
      rescue
        e -> {:error, e}
      end
    else
      :ok
    end
  end

  defp atomize_event(event) when is_map(event) do
    event
    |> Enum.map(fn
      {k, v} when is_binary(k) -> {String.to_atom(k), v}
      {k, v} -> {k, v}
    end)
    |> Map.new()
  end

  defp filter_events(events, opts) do
    Enum.reduce(opts, events, fn
      {:contract_address, addr}, acc ->
        normalized = String.downcase(addr)
        Enum.filter(acc, fn e ->
          String.downcase(e[:contract_address] || "") == normalized
        end)

      {:event_name, name}, acc ->
        Enum.filter(acc, fn e -> e[:event_name] == name end)

      {:from_block, block}, acc ->
        Enum.filter(acc, fn e -> e[:block_number] >= block end)

      {:to_block, block}, acc ->
        Enum.filter(acc, fn e -> e[:block_number] <= block end)

      {:from_time, time}, acc ->
        Enum.filter(acc, fn e ->
          case e[:inserted_at] do
            nil -> true
            t -> DateTime.compare(t, time) in [:gt, :eq]
          end
        end)

      {:to_time, time}, acc ->
        Enum.filter(acc, fn e ->
          case e[:inserted_at] do
            nil -> true
            t -> DateTime.compare(t, time) in [:lt, :eq]
          end
        end)

      {:chain_id, id}, acc ->
        Enum.filter(acc, fn e -> e[:chain_id] == id end)

      _, acc -> acc
    end)
  end

  defp sort_events(events) do
    Enum.sort_by(events, fn e -> {-e[:block_number], -e[:log_index]} end)
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp persistence_path do
    Application.app_dir(:lux, "priv/web3/event_monitor_events.json")
  end

  defp get_config(key, default) do
    :lux
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end
end
