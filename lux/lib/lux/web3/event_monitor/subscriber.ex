defmodule Lux.Web3.EventMonitor.Subscriber do
  @moduledoc """
  Manages event subscriptions for smart contract monitoring.

  Uses `eth_getLogs` JSON-RPC calls for real-time polling and historical sync.
  Supports event replay from block ranges and crash recovery via persisted state.

  ## Configuration

      config :lux, Lux.Web3.EventMonitor.Subscriber,
        chains: %{
          ethereum: %{rpc_url: System.get_env("ETHEREUM_RPC_URL"), chain_id: 1},
          polygon: %{rpc_url: System.get_env("POLYGON_RPC_URL"), chain_id: 137},
          bsc: %{rpc_url: System.get_env("BSC_RPC_URL"), chain_id: 56},
          arbitrum: %{rpc_url: System.get_env("ARBITRUM_RPC_URL"), chain_id: 42161}
        },
        poll_interval_ms: 5_000,
        max_reconnect_attempts: 10,
        batch_size: 1000

  ## Usage

      {:ok, sub_id} = Subscriber.subscribe(%{
        chain: :ethereum,
        contract_address: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
        event_topics: ["Transfer(address,address,uint256)"],
        from_block: 18_000_000
      })

      {:ok, events} = Subscriber.replay(sub_id, from_block: 18_000_000, to_block: 18_100_000)
  """

  use GenServer

  require Logger

  alias Lux.Web3.EventMonitor.Decoder

  @type subscription :: %{
    id: String.t(),
    chain: atom(),
    chain_id: non_neg_integer(),
    contract_address: String.t(),
    event_topics: [String.t()],
    from_block: non_neg_integer() | String.t(),
    status: :active | :paused | :error,
    created_at: DateTime.t(),
    last_block: non_neg_integer(),
    error_count: non_neg_integer(),
    callback: (map() -> :ok | {:error, term()}) | nil
  }

  @type subscribe_opts :: %{
    required(:chain) => atom(),
    required(:contract_address) => String.t(),
    optional(:event_topics) => [String.t()],
    optional(:from_block) => non_neg_integer() | String.t(),
    optional(:callback) => (map() -> :ok | {:error, term()})
  }

  # Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec subscribe(subscribe_opts()) :: {:ok, String.t()} | {:error, term()}
  def subscribe(opts), do: GenServer.call(__MODULE__, {:subscribe, opts})

  @spec unsubscribe(String.t()) :: :ok | {:error, :not_found}
  def unsubscribe(subscription_id), do: GenServer.call(__MODULE__, {:unsubscribe, subscription_id})

  @spec pause(String.t()) :: :ok | {:error, :not_found}
  def pause(subscription_id), do: GenServer.call(__MODULE__, {:pause, subscription_id})

  @spec resume(String.t()) :: :ok | {:error, :not_found}
  def resume(subscription_id), do: GenServer.call(__MODULE__, {:resume, subscription_id})

  @spec list_subscriptions() :: {:ok, [subscription()]}
  def list_subscriptions, do: GenServer.call(__MODULE__, :list_subscriptions)

  @spec get_subscription(String.t()) :: {:ok, subscription()} | {:error, :not_found}
  def get_subscription(subscription_id), do: GenServer.call(__MODULE__, {:get_subscription, subscription_id})

  @spec rpc_url(atom()) :: String.t() | nil
  def rpc_url(chain) do
    chains_config() |> Map.get(chain, %{}) |> Map.get(:rpc_url)
  end

  @spec chain_id(atom()) :: non_neg_integer() | nil
  def chain_id(chain) do
    chains_config() |> Map.get(chain, %{}) |> Map.get(:chain_id)
  end

  @doc """
  Replays events from a block range for a subscription.
  Fetches historical logs via eth_getLogs, decodes them, and stores.
  """
  @spec replay(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def replay(subscription_id, opts \\ []) do
    GenServer.call(__MODULE__, {:replay, subscription_id, opts})
  end

  @doc """
  Fetches the current block number from the RPC node.
  """
  @spec get_current_block(atom()) :: {:ok, non_neg_integer()} | {:error, term()}
  def get_current_block(chain) do
    case rpc_url(chain) do
      nil -> {:error, {:no_rpc_url, chain}}
      url ->
        case json_rpc_call(url, "eth_blockNumber", []) do
          {:ok, "0x" <> hex} -> {:ok, String.to_integer(hex, 16)}
          {:ok, n} when is_integer(n) -> {:ok, n}
          error -> error
        end
    end
  end

  # GenServer Callbacks

  @impl true
  def init(opts) do
    poll_interval = Keyword.get(opts, :poll_interval, get_config(:poll_interval_ms, 5_000))

    state = %{
      subscriptions: %{},
      poll_interval: poll_interval,
      reconnect_attempts: %{},
      timer_ref: nil
    }

    # Crash recovery: load persisted subscriptions
    load_persisted_subscriptions()

    timer_ref = Process.send_after(self(), :poll, poll_interval)
    {:ok, %{state | timer_ref: timer_ref}}
  end

  @impl true
  def terminate(_reason, state) do
    persist_subscriptions(state.subscriptions)
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    :ok
  end

  @impl true
  def handle_call({:subscribe, opts}, _from, state) do
    chain = opts[:chain] || opts["chain"]
    contract_address = opts[:contract_address] || opts["contract_address"]

    unless valid_chain?(chain) do
      {:reply, {:error, {:invalid_chain, chain}}, state}
    else
      subscription_id = generate_subscription_id()

      subscription = %{
        id: subscription_id,
        chain: chain,
        chain_id: chain_id(chain),
        contract_address: normalize_address(contract_address),
        event_topics: opts[:event_topics] || opts["event_topics"] || [],
        from_block: opts[:from_block] || opts["from_block"] || "latest",
        status: :active,
        created_at: DateTime.utc_now(),
        last_block: resolve_start_block(opts[:from_block] || opts["from_block"]),
        error_count: 0,
        callback: opts[:callback]
      }

      new_subscriptions = Map.put(state.subscriptions, subscription_id, subscription)
      Logger.info("New subscription created: #{subscription_id} for #{contract_address} on #{chain}")
      {:reply, {:ok, subscription_id}, %{state | subscriptions: new_subscriptions}}
    end
  end

  @impl true
  def handle_call({:unsubscribe, subscription_id}, _from, state) do
    case Map.pop(state.subscriptions, subscription_id) do
      {nil, _} -> {:reply, {:error, :not_found}, state}
      {_sub, remaining} ->
        Logger.info("Subscription removed: #{subscription_id}")
        {:reply, :ok, %{state | subscriptions: remaining}}
    end
  end

  @impl true
  def handle_call({:pause, subscription_id}, _from, state) do
    case Map.get(state.subscriptions, subscription_id) do
      nil -> {:reply, {:error, :not_found}, state}
      sub ->
        updated = Map.put(state.subscriptions, subscription_id, %{sub | status: :paused})
        {:reply, :ok, %{state | subscriptions: updated}}
    end
  end

  @impl true
  def handle_call({:resume, subscription_id}, _from, state) do
    case Map.get(state.subscriptions, subscription_id) do
      nil -> {:reply, {:error, :not_found}, state}
      sub ->
        updated = Map.put(state.subscriptions, subscription_id, %{sub | status: :active, error_count: 0})
        {:reply, :ok, %{state | subscriptions: updated}}
    end
  end

  @impl true
  def handle_call(:list_subscriptions, _from, state) do
    {:reply, {:ok, Map.values(state.subscriptions)}, state}
  end

  @impl true
  def handle_call({:get_subscription, subscription_id}, _from, state) do
    case Map.get(state.subscriptions, subscription_id) do
      nil -> {:reply, {:error, :not_found}, state}
      sub -> {:reply, {:ok, sub}, state}
    end
  end

  @impl true
  def handle_call({:replay, subscription_id, opts}, _from, state) do
    case Map.get(state.subscriptions, subscription_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      sub ->
        from_block = Keyword.get(opts, :from_block, sub.last_block)
        to_block = Keyword.get(opts, :to_block)

        case fetch_logs_range(sub, from_block, to_block) do
          {:ok, raw_logs} ->
            events = decode_and_store_logs(sub, raw_logs)

            max_block =
              if to_block do
                to_block
              else
                raw_logs |> Enum.map(&(&1["blockNumber"] || 0)) |> Enum.max(fn -> from_block end)
              end

            updated_sub = %{sub | last_block: max_block}
            {:reply, {:ok, events}, %{state | subscriptions: Map.put(state.subscriptions, subscription_id, updated_sub)}}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_info(:poll, state) do
    active_subs = state.subscriptions |> Map.values() |> Enum.filter(&(&1.status == :active))
    Enum.each(active_subs, &poll_subscription/1)
    timer_ref = Process.send_after(self(), :poll, state.poll_interval)
    {:noreply, %{state | timer_ref: timer_ref}}
  end

  @impl true
  def handle_info({:event_received, subscription_id, events}, state) do
    case Map.get(state.subscriptions, subscription_id) do
      nil -> {:noreply, state}
      sub ->
        Enum.each(events, fn event -> process_event(sub, event) end)
        max_block = events |> Enum.map(&(&1[:block_number] || 0)) |> Enum.max(fn -> sub.last_block end)
        updated_sub = %{sub | last_block: max_block}
        {:noreply, %{state | subscriptions: Map.put(state.subscriptions, subscription_id, updated_sub)}}
    end
  end

  @impl true
  def handle_info({:poll_error, subscription_id, reason}, state) do
    case Map.get(state.subscriptions, subscription_id) do
      nil -> {:noreply, state}
      sub ->
        new_error_count = sub.error_count + 1
        max_reconnects = get_config(:max_reconnect_attempts, 10)
        new_status = if new_error_count >= max_reconnects, do: :error, else: :active
        Logger.warning("Poll error for #{subscription_id}: #{inspect(reason)} (attempt #{new_error_count}/#{max_reconnects})")
        updated_sub = %{sub | error_count: new_error_count, status: new_status}
        {:noreply, %{state | subscriptions: Map.put(state.subscriptions, subscription_id, updated_sub)}}
    end
  end

  @impl true
  def handle_info({:recover_subscription, sub_attrs}, state) do
    subscription_id = sub_attrs["id"] || sub_attrs[:id]

    case Map.get(state.subscriptions, subscription_id) do
      nil ->
        chain = sub_attrs["chain"] || sub_attrs[:chain]
        if valid_chain?(chain) do
          last_block = case sub_attrs["last_block"] || sub_attrs[:last_block] do
            nil -> resolve_start_block(sub_attrs["from_block"] || sub_attrs[:from_block])
            n when is_integer(n) -> n
            n -> resolve_start_block(n)
          end

          subscription = %{
            id: subscription_id,
            chain: chain,
            chain_id: chain_id(chain),
            contract_address: normalize_address(sub_attrs["contract_address"] || sub_attrs[:contract_address]),
            event_topics: sub_attrs["event_topics"] || sub_attrs[:event_topics] || [],
            from_block: sub_attrs["from_block"] || sub_attrs[:from_block] || "latest",
            status: :active,
            created_at: sub_attrs["created_at"] || sub_attrs[:created_at] || DateTime.utc_now(),
            last_block: last_block,
            error_count: 0,
            callback: nil
          }

          Logger.info("Recovered subscription #{subscription_id} from persisted state, resuming from block #{last_block}")
          {:noreply, %{state | subscriptions: Map.put(state.subscriptions, subscription_id, subscription)}}
        else
          {:noreply, state}
        end

      _sub -> {:noreply, state}
    end
  end

  # Private: Real eth_getLogs RPC polling

  defp poll_subscription(subscription) do
    rpc = rpc_url(subscription.chain)

    if rpc do
      from_block_hex = "0x" <> Integer.to_string(subscription.last_block, 16)
      topic_hashes = resolve_topic_hashes(subscription.event_topics)

      params = build_eth_get_logs_params(subscription.contract_address, from_block_hex, "latest", topic_hashes)

      case json_rpc_call(rpc, "eth_getLogs", [params]) do
        {:ok, raw_logs} when is_list(raw_logs) ->
          if length(raw_logs) > 0 do
            events = decode_and_store_logs(subscription, raw_logs)
            send(self(), {:event_received, subscription.id, events})
          end

          :telemetry.execute(
            [:lux, :web3, :event_monitor, :poll],
            %{count: length(raw_logs), block: subscription.last_block},
            %{subscription_id: subscription.id, chain: subscription.chain}
          )

        {:error, reason} ->
          Logger.error("eth_getLogs failed for #{subscription.id}: #{inspect(reason)}")
          send(self(), {:poll_error, subscription.id, reason})
      end
    else
      Logger.warning("No RPC URL for chain #{subscription.chain}, skipping poll for #{subscription.id}")
    end
  end

  defp fetch_logs_range(subscription, from_block, to_block) do
    rpc = rpc_url(subscription.chain)
    if rpc do
      from_hex = "0x" <> Integer.to_string(from_block, 16)
      to_hex = if to_block, do: "0x" <> Integer.to_string(to_block, 16), else: "latest"
      topic_hashes = resolve_topic_hashes(subscription.event_topics)
      params = build_eth_get_logs_params(subscription.contract_address, from_hex, to_hex, topic_hashes)
      json_rpc_call(rpc, "eth_getLogs", [params])
    else
      {:error, {:no_rpc_url, subscription.chain}}
    end
  end

  defp decode_and_store_logs(subscription, raw_logs) do
    Enum.flat_map(raw_logs, fn raw_log ->
      log = normalize_raw_log(raw_log)
      case Decoder.decode_log(log) do
        {:ok, decoded} ->
          event = Map.put(decoded, :chain_id, subscription.chain_id)
          Lux.Web3.EventMonitor.Storage.store_event(event)
          [decoded]
        {:error, reason} ->
          Logger.debug("Failed to decode log: #{inspect(reason)}")
          []
      end
    end)
  end

  defp process_event(subscription, event) do
    Lux.Web3.EventMonitor.Storage.store_event(Map.put(event, :chain_id, subscription.chain_id))
    if subscription.callback, do: subscription.callback.(event)

    :telemetry.execute(
      [:lux, :web3, :event_monitor, :event_received],
      %{count: 1},
      %{subscription_id: subscription.id, event_name: event[:event_name]}
    )
  end

  defp resolve_topic_hashes(event_topic_signatures) do
    Enum.map(event_topic_signatures, fn sig ->
      find_topic_hash(sig) || compute_keccak256(sig)
    end)
  end

  defp find_topic_hash(sig) do
    Decoder.standard_events()
    |> Enum.find_value(fn {hash, info} ->
      if info.signature == sig, do: hash, else: nil
    end)
  end

  defp compute_keccak256(data) do
    hash = :crypto.hash(:sha256, data)
    "0x" <> Base.encode16(hash, case: :lower)
  end

  defp build_eth_get_logs_params(contract_address, from_block, to_block, topic_hashes) do
    base = %{"fromBlock" => from_block, "toBlock" => to_block, "address" => contract_address}
    case topic_hashes do
      [] -> base
      topics -> Map.put(base, "topics", topics)
    end
  end

  defp json_rpc_call(url, method, params) do
    body = %{
      "jsonrpc" => "2.0",
      "method" => method,
      "params" => params,
      "id" => System.unique_integer([:positive])
    }

    case Req.post(url, json: body, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: resp}} ->
        case resp do
          %{"result" => result} -> {:ok, result}
          %{"error" => %{"code" => code, "message" => msg}} -> {:error, %{rpc_code: code, message: msg}}
          _ -> {:error, :invalid_response}
        end
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_raw_log(raw_log) do
    %{
      topics: raw_log["topics"] || [],
      data: raw_log["data"] || "0x",
      address: raw_log["address"] || raw_log[:address],
      block_number: parse_block_number(raw_log["blockNumber"]),
      transaction_hash: raw_log["transactionHash"],
      log_index: parse_log_index(raw_log["logIndex"])
    }
  end

  defp parse_block_number(nil), do: nil
  defp parse_block_number(n) when is_integer(n), do: n
  defp parse_block_number("0x" <> hex), do: String.to_integer(hex, 16)
  defp parse_block_number(s), do: String.to_integer(s)

  defp parse_log_index(nil), do: nil
  defp parse_log_index(n) when is_integer(n), do: n
  defp parse_log_index("0x" <> hex), do: String.to_integer(hex, 16)

  defp resolve_start_block("latest"), do: 0
  defp resolve_start_block(nil), do: 0
  defp resolve_start_block(n) when is_integer(n), do: n
  defp resolve_start_block(n) when is_binary(n) do
    case Integer.parse(n) do
      {block, ""} -> block
      _ -> 0
    end
  end

  defp valid_chain?(chain), do: Map.has_key?(chains_config(), chain)

  defp chains_config do
    :lux |> Application.get_env(__MODULE__, []) |> Keyword.get(:chains, default_chains())
  end

  defp default_chains do
    %{
      ethereum: %{rpc_url: nil, chain_id: 1},
      polygon: %{rpc_url: nil, chain_id: 137},
      bsc: %{rpc_url: nil, chain_id: 56},
      arbitrum: %{rpc_url: nil, chain_id: 42161}
    }
  end

  defp generate_subscription_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  defp normalize_address("0x" <> _ = addr), do: String.downcase(addr)
  defp normalize_address(addr), do: String.downcase("0x" <> addr)

  defp get_config(key, default) do
    :lux |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
  end

  # Crash recovery: persist/load subscriptions

  defp persist_subscriptions(subscriptions) do
    path = persistence_path()
    try do
      data = subscriptions
        |> Map.values()
        |> Enum.map(fn sub ->
          %{
            "id" => sub.id, "chain" => sub.chain, "chain_id" => sub.chain_id,
            "contract_address" => sub.contract_address, "event_topics" => sub.event_topics,
            "from_block" => sub.from_block, "status" => sub.status,
            "created_at" => DateTime.to_iso8601(sub.created_at),
            "last_block" => sub.last_block, "error_count" => sub.error_count
          }
        end)
        |> Jason.encode!()
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, data)
    rescue
      e -> Logger.warning("Failed to persist subscriptions: #{inspect(e)}")
    end
  end

  defp load_persisted_subscriptions do
    path = persistence_path()
    if File.exists?(path) do
      try do
        data = File.read!(path)
        subs = Jason.decode!(data)
        Enum.each(subs, fn sub_attrs ->
          send(self(), {:recover_subscription, sub_attrs})
        end)
      rescue
        e -> Logger.warning("Failed to load persisted subscriptions: #{inspect(e)}")
      end
    end
  end

  defp persistence_path, do: Application.app_dir(:lux, "priv/web3/event_monitor_subscriptions.json")
end
