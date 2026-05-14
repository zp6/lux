defmodule Lux.Web3.EventMonitor.Subscriber do
  @moduledoc """
  Manages event subscriptions for smart contract monitoring.

  Handles subscription lifecycle including creation, filtering by event topics,
  automatic reconnection with resume from last processed block, and graceful
  teardown.

  ## Configuration

      config :lux, Lux.Web3.EventMonitor.Subscriber,
        chains: %{
          ethereum: %{
            rpc_url: "https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY",
            chain_id: 1,
            ws_url: "wss://eth-mainnet.g.alchemy.com/v2/YOUR_KEY"
          },
          polygon: %{
            rpc_url: "https://polygon-mainnet.g.alchemy.com/v2/YOUR_KEY",
            chain_id: 137
          },
          bsc: %{
            rpc_url: "https://bsc-dataseed.binance.org",
            chain_id: 56
          },
          arbitrum: %{
            rpc_url: "https://arb-mainnet.g.alchemy.com/v2/YOUR_KEY",
            chain_id: 42161
          }
        },
        poll_interval_ms: 5_000,
        max_reconnect_attempts: 10,
        reconnect_backoff_ms: 1_000

  ## Usage

      # Start the subscriber
      {:ok, pid} = Subscriber.start_link([])

      # Subscribe to ERC-20 Transfer events on a contract
      :ok = Subscriber.subscribe(%{
        chain: :ethereum,
        contract_address: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
        event_topics: ["Transfer(address,address,uint256)"],
        from_block: 18_000_000
      })

      # Subscribe to all events from a contract
      :ok = Subscriber.subscribe(%{
        chain: :ethereum,
        contract_address: "0x...",
        from_block: "latest"
      })

      # Unsubscribe
      :ok = Subscriber.unsubscribe(subscription_id)

      # List active subscriptions
      {:ok, subs} = Subscriber.list_subscriptions()
  """

  use GenServer

  require Logger

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

  @doc """
  Starts the subscriber GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Creates a new event subscription.

  ## Parameters

    * `opts` - A map with subscription options:
      - `:chain` - Chain atom (`:ethereum`, `:polygon`, `:bsc`, `:arbitrum`)
      - `:contract_address` - Contract address to monitor
      - `:event_topics` - List of event topic hashes to filter (optional)
      - `:from_block` - Block number to start from (default: `"latest"`)
      - `:callback` - Optional callback function for event processing

  Returns `{:ok, subscription_id}` or `{:error, reason}`.
  """
  @spec subscribe(subscribe_opts()) :: {:ok, String.t()} | {:error, term()}
  def subscribe(opts) do
    GenServer.call(__MODULE__, {:subscribe, opts})
  end

  @doc """
  Removes a subscription by ID.
  """
  @spec unsubscribe(String.t()) :: :ok | {:error, :not_found}
  def unsubscribe(subscription_id) do
    GenServer.call(__MODULE__, {:unsubscribe, subscription_id})
  end

  @doc """
  Pauses a subscription.
  """
  @spec pause(String.t()) :: :ok | {:error, :not_found}
  def pause(subscription_id) do
    GenServer.call(__MODULE__, {:pause, subscription_id})
  end

  @doc """
  Resumes a paused subscription.
  """
  @spec resume(String.t()) :: :ok | {:error, :not_found}
  def resume(subscription_id) do
    GenServer.call(__MODULE__, {:resume, subscription_id})
  end

  @doc """
  Lists all subscriptions.
  """
  @spec list_subscriptions() :: {:ok, [subscription()]}
  def list_subscriptions do
    GenServer.call(__MODULE__, :list_subscriptions)
  end

  @doc """
  Gets a subscription by ID.
  """
  @spec get_subscription(String.t()) :: {:ok, subscription()} | {:error, :not_found}
  def get_subscription(subscription_id) do
    GenServer.call(__MODULE__, {:get_subscription, subscription_id})
  end

  @doc """
  Returns the RPC URL for a given chain.
  """
  @spec rpc_url(atom()) :: String.t() | nil
  def rpc_url(chain) do
    chains_config()
    |> Map.get(chain, %{})
    |> Map.get(:rpc_url)
  end

  @doc """
  Returns the chain ID for a given chain atom.
  """
  @spec chain_id(atom()) :: non_neg_integer() | nil
  def chain_id(chain) do
    chains_config()
    |> Map.get(chain, %{})
    |> Map.get(:chain_id)
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

    # Start polling timer
    timer_ref = Process.send_after(self(), :poll, poll_interval)

    {:ok, %{state | timer_ref: timer_ref}}
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
      {nil, _} ->
        {:reply, {:error, :not_found}, state}

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
  def handle_info(:poll, state) do
    active_subs = state.subscriptions
                  |> Map.values()
                  |> Enum.filter(&(&1.status == :active))

    # Poll each active subscription
    Enum.each(active_subs, fn sub ->
      poll_subscription(sub)
    end)

    # Schedule next poll
    timer_ref = Process.send_after(self(), :poll, state.poll_interval)
    {:noreply, %{state | timer_ref: timer_ref}}
  end

  @impl true
  def handle_info({:event_received, subscription_id, events}, state) do
    case Map.get(state.subscriptions, subscription_id) do
      nil ->
        {:noreply, state}

      sub ->
        # Process events through callback or emit to storage
        Enum.each(events, fn event ->
          process_event(sub, event)
        end)

        # Update last processed block
        max_block = events
                    |> Enum.map(&(&1[:block_number] || 0))
                    |> Enum.max(fn -> sub.last_block end)

        updated_sub = %{sub | last_block: max_block}
        {:noreply, %{state | subscriptions: Map.put(state.subscriptions, subscription_id, updated_sub)}}
    end
  end

  @impl true
  def handle_info({:poll_error, subscription_id, reason}, state) do
    case Map.get(state.subscriptions, subscription_id) do
      nil ->
        {:noreply, state}

      sub ->
        new_error_count = sub.error_count + 1
        max_reconnects = get_config(:max_reconnect_attempts, 10)

        new_status =
          if new_error_count >= max_reconnects do
            Logger.error("Subscription #{subscription_id} exceeded max reconnect attempts")
            :error
          else
            :active
          end

        updated_sub = %{sub | error_count: new_error_count, status: new_status}
        Logger.warning("Poll error for #{subscription_id}: #{inspect(reason)} (attempt #{new_error_count})")

        {:noreply, %{state | subscriptions: Map.put(state.subscriptions, subscription_id, updated_sub)}}
    end
  end

  # Private functions

  defp poll_subscription(subscription) do
    Logger.debug("Polling subscription #{subscription.id} from block #{subscription.last_block}")

    # In production, this would make JSON-RPC eth_getLogs calls to the RPC node
    # For now, we emit a telemetry event that can be hooked into
    :telemetry.execute(
      [:lux, :web3, :event_monitor, :poll],
      %{block: subscription.last_block},
      %{subscription_id: subscription.id, chain: subscription.chain, contract: subscription.contract_address}
    )
  end

  defp process_event(subscription, event) do
    # Store the event
    Lux.Web3.EventMonitor.Storage.store_event(Map.put(event, :chain_id, subscription.chain_id))

    # Call the callback if provided
    if subscription.callback do
      subscription.callback.(event)
    end

    # Emit telemetry
    :telemetry.execute(
      [:lux, :web3, :event_monitor, :event_received],
      %{count: 1},
      %{subscription_id: subscription.id, event_name: event[:event_name]}
    )
  end

  defp resolve_start_block("latest"), do: 0
  defp resolve_start_block(nil), do: 0
  defp resolve_start_block(n) when is_integer(n), do: n
  defp resolve_start_block(n) when is_binary(n) do
    case Integer.parse(n) do
      {block, ""} -> block
      _ -> 0
    end
  end

  defp valid_chain?(chain) do
    Map.has_key?(chains_config(), chain)
  end

  defp chains_config do
    :lux
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:chains, default_chains())
  end

  defp default_chains do
    %{
      ethereum: %{rpc_url: nil, chain_id: 1},
      polygon: %{rpc_url: nil, chain_id: 137},
      bsc: %{rpc_url: nil, chain_id: 56},
      arbitrum: %{rpc_url: nil, chain_id: 42161}
    }
  end

  defp generate_subscription_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp normalize_address("0x" <> _ = addr), do: String.downcase(addr)
  defp normalize_address(addr), do: String.downcase("0x" <> addr)

  defp get_config(key, default) do
    :lux
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end
end
