defmodule Lux.Web3.EventMonitor do
  @moduledoc """
  Smart contract event monitoring system for EVM-compatible chains.

  Provides real-time monitoring, decoding, storage, and alerting for
  smart contract events across multiple chains (Ethereum, Polygon, BSC, Arbitrum).

  ## Architecture

  The event monitor consists of four main components:

  1. **Subscriber** (`EventMonitor.Subscriber`) - Manages subscriptions to contract events
     with automatic reconnection and block resume support.

  2. **Decoder** (`EventMonitor.Decoder`) - Decodes raw EVM log data into structured
     events, supporting standard ERC-20/721/1155 events and custom ABIs.

  3. **Storage** (`EventMonitor.Storage`) - In-memory event storage with deduplication
     and flexible querying capabilities.

  4. **Alerts** (`EventMonitor.Alerts`) - Rule-based alerting system with threshold
     conditions and Discord/Telegram notification channels.

  ## Configuration

  Add to your `config/runtime.exs`:

      config :lux, Lux.Web3.EventMonitor.Subscriber,
        chains: %{
          ethereum: %{
            rpc_url: System.get_env("ETHEREUM_RPC_URL"),
            chain_id: 1
          },
          polygon: %{
            rpc_url: System.get_env("POLYGON_RPC_URL"),
            chain_id: 137
          },
          bsc: %{
            rpc_url: System.get_env("BSC_RPC_URL"),
            chain_id: 56
          },
          arbitrum: %{
            rpc_url: System.get_env("ARBITRUM_RPC_URL"),
            chain_id: 42161
          }
        },
        poll_interval_ms: 5_000,
        max_reconnect_attempts: 10

      config :lux, Lux.Web3.EventMonitor.Storage,
        max_events: 10_000

      config :lux, Lux.Web3.EventMonitor.Alerts,
        enabled: true,
        discord_webhook_url: System.get_env("DISCORD_ALERT_WEBHOOK_URL"),
        telegram_bot_token: System.get_env("TELEGRAM_ALERT_BOT_TOKEN"),
        telegram_chat_id: System.get_env("TELEGRAM_ALERT_CHAT_ID")

  ## Quick Start

      # 1. Start the event monitor (typically in a supervision tree)
      {:ok, _} = Lux.Web3.EventMonitor.start_link([])

      # 2. Subscribe to events
      {:ok, sub_id} = Lux.Web3.EventMonitor.subscribe(%{
        chain: :ethereum,
        contract_address: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
        event_topics: ["Transfer(address,address,uint256)"],
        from_block: 18_000_000
      })

      # 3. Query stored events
      {:ok, events} = Lux.Web3.EventMonitor.query_events(
        contract_address: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
        event_name: "Transfer",
        limit: 50
      )

      # 4. Set up alerts
      {:ok, rule_id} = Lux.Web3.EventMonitor.create_alert(%{
        name: "large_usdc_transfer",
        event_name: "Transfer",
        contract_address: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
        conditions: [%{field: "value", operator: :gt, threshold: 100_000}],
        channels: [:discord]
      })

  ## Child Spec for Supervision

      children = [
        {Lux.Web3.EventMonitor.Storage, name: Lux.Web3.EventMonitor.Storage},
        {Lux.Web3.EventMonitor.Subscriber, name: Lux.Web3.EventMonitor.Subscriber},
        {Lux.Web3.EventMonitor.Alerts, name: Lux.Web3.EventMonitor.Alerts}
      ]

  ## Environment Variables

  | Variable | Description |
  |----------|-------------|
  | `ETHEREUM_RPC_URL` | Ethereum mainnet JSON-RPC endpoint |
  | `POLYGON_RPC_URL` | Polygon mainnet JSON-RPC endpoint |
  | `BSC_RPC_URL` | BSC mainnet JSON-RPC endpoint |
  | `ARBITRUM_RPC_URL` | Arbitrum mainnet JSON-RPC endpoint |
  | `DISCORD_ALERT_WEBHOOK_URL` | Discord webhook for alert notifications |
  | `TELEGRAM_ALERT_BOT_TOKEN` | Telegram bot token for alerts |
  | `TELEGRAM_ALERT_CHAT_ID` | Telegram chat ID for alerts |
  """

  require Logger

  alias Lux.Web3.EventMonitor.{Alerts, Decoder, Storage, Subscriber}

  @doc """
  Starts all event monitor components.

  This is a convenience function that starts Storage, Subscriber, and Alerts
  in the correct order. For production use, prefer adding child specs to your
  application supervision tree.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    import Supervisor, only: [start_link: 2]

    children = [
      {Storage, Keyword.get(opts, :storage_opts, [])},
      {Subscriber, Keyword.get(opts, :subscriber_opts, [])},
      {Alerts, Keyword.get(opts, :alerts_opts, [])}
    ]

    start_link(children, strategy: :one_for_one, name: Lux.Web3.EventMonitor.Supervisor)
  end

  @doc """
  Returns the child specs for adding to a supervision tree.
  """
  @spec child_spec(keyword()) :: [Supervisor.child_spec()]
  def child_spec(opts \\ []) do
    [
      {Storage, Keyword.get(opts, :storage_opts, [])},
      {Subscriber, Keyword.get(opts, :subscriber_opts, [])},
      {Alerts, Keyword.get(opts, :alerts_opts, [])}
    ]
  end

  # Subscription delegation

  @doc """
  Creates a new event subscription. Delegates to `Subscriber.subscribe/1`.
  """
  @spec subscribe(map()) :: {:ok, String.t()} | {:error, term()}
  defdelegate subscribe(opts), to: Subscriber

  @doc """
  Removes a subscription. Delegates to `Subscriber.unsubscribe/1`.
  """
  @spec unsubscribe(String.t()) :: :ok | {:error, :not_found}
  defdelegate unsubscribe(subscription_id), to: Subscriber

  @doc """
  Lists all active subscriptions. Delegates to `Subscriber.list_subscriptions/0`.
  """
  @spec list_subscriptions() :: {:ok, [map()]}
  defdelegate list_subscriptions, to: Subscriber

  # Decoding delegation

  @doc """
  Decodes a raw log entry. Delegates to `Decoder.decode_log/2`.
  """
  @spec decode_log(map(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate decode_log(log, opts \\ []), to: Decoder

  @doc """
  Identifies the token standard of a log. Delegates to `Decoder.identify_standard/1`.
  """
  @spec identify_standard(map()) :: :erc20 | :erc721 | :erc1155 | :unknown
  defdelegate identify_standard(log), to: Decoder

  # Storage delegation

  @doc """
  Stores a decoded event. Delegates to `Storage.store_event/1`.
  """
  @spec store_event(map()) :: :ok | {:error, :duplicate}
  defdelegate store_event(event), to: Storage

  @doc """
  Queries stored events. Delegates to `Storage.query_events/1`.
  """
  @spec query_events(keyword()) :: {:ok, [map()]}
  defdelegate query_events(opts \\ []), to: Storage

  @doc """
  Gets the total event count. Delegates to `Storage.count/0`.
  """
  @spec event_count() :: non_neg_integer()
  defdelegate event_count, to: Storage, as: :count

  @doc """
  Clears all stored events. Delegates to `Storage.clear/0`.
  """
  @spec clear_events() :: :ok
  defdelegate clear_events, to: Storage, as: :clear

  # Alerts delegation

  @doc """
  Creates an alert rule. Delegates to `Alerts.create_rule/1`.
  """
  @spec create_alert(map()) :: {:ok, String.t()} | {:error, term()}
  defdelegate create_alert(rule_attrs), to: Alerts, as: :create_rule

  @doc """
  Deletes an alert rule. Delegates to `Alerts.delete_rule/1`.
  """
  @spec delete_alert(String.t()) :: :ok | {:error, :not_found}
  defdelegate delete_alert(rule_id), to: Alerts, as: :delete_rule

  @doc """
  Lists all alert rules. Delegates to `Alerts.list_rules/0`.
  """
  @spec list_alerts() :: {:ok, [map()]}
  defdelegate list_alerts, to: Alerts, as: :list_rules

  @doc """
  Processes an event against alert rules. Delegates to `Alerts.process_event/1`.
  """
  @spec process_alerts(map()) :: {:ok, [map()]}
  defdelegate process_alerts(event), to: Alerts, as: :process_event

  # High-level convenience functions

  @doc """
  Subscribes to all Transfer events for a contract and sets up storage + alerts.

  This is a convenience function that:
  1. Creates a subscription for Transfer events
  2. Optionally creates a large transfer alert

  ## Parameters

    * `chain` - Chain atom (`:ethereum`, `:polygon`, `:bsc`, `:arbitrum`)
    * `contract_address` - The contract address to monitor
    * `opts` - Options:
      - `:from_block` - Starting block (default: `"latest"`)
      - `:alert_threshold` - Value threshold for alerts (optional)
      - `:alert_channels` - Channels for alerts (default: `[:discord]`)

  ## Examples

      {:ok, sub_id, _alert_id} = Lux.Web3.EventMonitor.watch_transfers(
        :ethereum,
        "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
        from_block: 18_000_000,
        alert_threshold: 1_000_000
      )
  """
  @spec watch_transfers(atom(), String.t(), keyword()) ::
          {:ok, String.t(), String.t() | nil} | {:error, term()}
  def watch_transfers(chain, contract_address, opts \\ []) do
    with {:ok, sub_id} <- subscribe(%{
      chain: chain,
      contract_address: contract_address,
      event_topics: ["Transfer(address,address,uint256)"],
      from_block: Keyword.get(opts, :from_block, "latest")
    }) do
      alert_id =
        case Keyword.get(opts, :alert_threshold) do
          nil -> nil
          threshold ->
            {:ok, id} = Alerts.create_large_transfer_alert(
              contract_address,
              threshold,
              channels: Keyword.get(opts, :alert_channels, [:discord])
            )
            id
        end

      {:ok, sub_id, alert_id}
    end
  end

  @doc """
  Returns the current status of the event monitor system.
  """
  @spec status() :: map()
  def status do
    %{
      storage: %{
        event_count: Storage.count()
      },
      subscriptions: case Subscriber.list_subscriptions() do
        {:ok, subs} -> %{
          total: length(subs),
          active: Enum.count(subs, &(&1.status == :active)),
          paused: Enum.count(subs, &(&1.status == :paused)),
          error: Enum.count(subs, &(&1.status == :error))
        }
      end,
      alerts: case Alerts.list_rules() do
        {:ok, rules} -> %{
          total: length(rules),
          enabled: Enum.count(rules, & &1.enabled)
        }
      end
    }
  end
end
