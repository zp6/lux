defmodule Lux.Web3.EventMonitor.Storage do
  @moduledoc """
  In-memory event storage with optional persistence for smart contract events.

  Provides query capabilities by contract address, event name, block range,
  and time range. Handles deduplication based on transaction hash + log index.

  ## Configuration

      config :lux, Lux.Web3.EventMonitor.Storage,
        max_events: 10_000,
        persistence_enabled: false,
        persistence_path: "priv/web3/events"

  ## Usage

      # Start the storage process (typically in a supervision tree)
      {:ok, pid} = Storage.start_link([])

      # Store an event
      :ok = Storage.store_event(%{
        contract_address: "0x...",
        event_name: "Transfer",
        block_number: 12345,
        transaction_hash: "0x...",
        log_index: 0,
        params: %{from: "0x...", to: "0x...", value: 1000},
        chain_id: 1
      })

      # Query events
      {:ok, events} = Storage.query_events(
        contract_address: "0x...",
        event_name: "Transfer",
        from_block: 12000,
        to_block: 13000
      )
  """

  use Agent

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

  @doc """
  Starts the storage agent.
  """
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    max_events = get_config(:max_events, 10_000)
    Agent.start_link(fn -> %{events: [], max_events: max_events, count: 0} end, name: name)
  end

  @doc """
  Stores a decoded event. Deduplicates by `{transaction_hash, log_index}`.
  """
  @spec store_event(event(), GenServer.server()) :: :ok | {:error, :duplicate}
  def store_event(event, server \\ __MODULE__) do
    Agent.get_and_update(server, fn state ->
      dedup_key = {event[:transaction_hash] || event["transaction_hash"],
                    event[:log_index] || event["log_index"]}

      duplicate? = Enum.any?(state.events, fn e ->
        {e[:transaction_hash], e[:log_index]} == dedup_key
      end)

      if duplicate? do
        {{:error, :duplicate}, state}
      else
        event_with_meta = Map.merge(event, %{
          id: generate_id(),
          inserted_at: DateTime.utc_now()
        })

        new_events = [event_with_meta | state.events]
                      |> Enum.take(state.max_events)

        {:ok, %{state | events: new_events, count: state.count + 1}}
      end
    end)
  end

  @doc """
  Stores multiple events in batch. Skips duplicates.
  """
  @spec store_events([event()], GenServer.server()) :: {:ok, non_neg_integer()}
  def store_events(events, server \\ __MODULE__) do
    stored_count = Enum.reduce(events, 0, fn event, acc ->
      case store_event(event, server) do
        :ok -> acc + 1
        {:error, :duplicate} -> acc
      end
    end)

    {:ok, stored_count}
  end

  @doc """
  Queries events with flexible filtering.

  ## Options

    * `:contract_address` - Filter by contract address
    * `:event_name` - Filter by event name
    * `:from_block` - Minimum block number (inclusive)
    * `:to_block` - Maximum block number (inclusive)
    * `:from_time` - Minimum inserted_at time (inclusive)
    * `:to_time` - Maximum inserted_at time (inclusive)
    * `:chain_id` - Filter by chain ID
    * `:limit` - Maximum number of results (default: 100)
    * `:offset` - Number of results to skip (default: 0)
  """
  @spec query_events(query_opts(), GenServer.server()) :: {:ok, [event()]}
  def query_events(opts \\ [], server \\ __MODULE__) do
    Agent.get(server, fn state ->
      limit = Keyword.get(opts, :limit, 100)
      offset = Keyword.get(opts, :offset, 0)

      events =
        state.events
        |> filter_events(opts)
        |> sort_events()
        |> Enum.drop(offset)
        |> Enum.take(limit)

      {:ok, events}
    end)
  end

  @doc """
  Gets a single event by its ID.
  """
  @spec get_event(String.t(), GenServer.server()) :: {:ok, event()} | {:error, :not_found}
  def get_event(id, server \\ __MODULE__) do
    Agent.get(server, fn state ->
      case Enum.find(state.events, &(&1[:id] == id)) do
        nil -> {:error, :not_found}
        event -> {:ok, event}
      end
    end)
  end

  @doc """
  Returns the total count of stored events.
  """
  @spec count(GenServer.server()) :: non_neg_integer()
  def count(server \\ __MODULE__) do
    Agent.get(server, fn state -> state.count end)
  end

  @doc """
  Returns the count of events matching the given filters.
  """
  @spec count_matching(query_opts(), GenServer.server()) :: non_neg_integer()
  def count_matching(opts \\ [], server \\ __MODULE__) do
    Agent.get(server, fn state ->
      state.events |> filter_events(opts) |> length()
    end)
  end

  @doc """
  Clears all stored events.
  """
  @spec clear(GenServer.server()) :: :ok
  def clear(server \\ __MODULE__) do
    Agent.update(server, fn state ->
      %{state | events: [], count: 0}
    end)
  end

  @doc """
  Gets the last processed block number for a given chain and optional contract.
  """
  @spec get_last_block(non_neg_integer(), String.t() | nil, GenServer.server()) :: non_neg_integer()
  def get_last_block(chain_id, contract_address \\ nil, server \\ __MODULE__) do
    Agent.get(server, fn state ->
      state.events
      |> Enum.filter(fn e ->
        e[:chain_id] == chain_id and
        (is_nil(contract_address) or
         String.downcase(e[:contract_address] || "") == String.downcase(contract_address || ""))
      end)
      |> Enum.map(& &1[:block_number])
      |> Enum.max(fn -> 0 end)
    end)
  end

  @doc """
  Removes events older than the given number of blocks from the latest.
  """
  @spec prune_old_events(non_neg_integer(), GenServer.server()) :: {:ok, non_neg_integer()}
  def prune_old_events(keep_last_n_blocks, server \\ __MODULE__) do
    Agent.get_and_update(server, fn state ->
      max_block = state.events |> Enum.map(& &1[:block_number]) |> Enum.max(fn -> 0 end)
      cutoff = max_block - keep_last_n_blocks

      {kept, removed} = Enum.split_with(state.events, fn e -> e[:block_number] > cutoff end)
      {{:ok, length(removed)}, %{state | events: kept}}
    end)
  end

  # Private

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

  defp get_config(key, default) do
    :lux
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end
end
