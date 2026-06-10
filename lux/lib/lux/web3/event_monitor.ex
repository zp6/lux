defmodule Lux.Web3.EventMonitor do
  @moduledoc """
  Smart contract event monitoring system for EVM-compatible chains.

  Provides real-time monitoring via eth_getLogs polling, decoding, ETS-based
  persistent storage, rule-based alerting, and webhook delivery with retry
  and dead letter queue support.

  ## Architecture

  1. **Subscriber** - eth_getLogs RPC polling, event replay, crash recovery
  2. **Decoder** - ABI log decoding (ERC-20/721/1155 + custom)
  3. **Storage** - ETS-based persistent storage with deduplication
  4. **Alerts** - Rule-based alerting (Discord, Telegram)
  5. **Webhook** - HTTP POST delivery with retry, HMAC signature, dead letter queue

  ## Child Spec for Supervision

      children = [
        {Lux.Web3.EventMonitor.Storage, name: Lux.Web3.EventMonitor.Storage},
        {Lux.Web3.EventMonitor.Webhook, name: Lux.Web3.EventMonitor.Webhook},
        {Lux.Web3.EventMonitor.Subscriber, name: Lux.Web3.EventMonitor.Subscriber},
        {Lux.Web3.EventMonitor.Alerts, name: Lux.Web3.EventMonitor.Alerts}
      ]
  """

  require Logger

  alias Lux.Web3.EventMonitor.{Alerts, Decoder, Storage, Subscriber, Webhook}

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    import Supervisor, only: [start_link: 2]

    children = [
      {Storage, Keyword.get(opts, :storage_opts, [])},
      {Webhook, Keyword.get(opts, :webhook_opts, [])},
      {Subscriber, Keyword.get(opts, :subscriber_opts, [])},
      {Alerts, Keyword.get(opts, :alerts_opts, [])}
    ]

    start_link(children, strategy: :one_for_one, name: Lux.Web3.EventMonitor.Supervisor)
  end

  @spec child_spec(keyword()) :: [Supervisor.child_spec()]
  def child_spec(opts \\ []) do
    [
      {Storage, Keyword.get(opts, :storage_opts, [])},
      {Webhook, Keyword.get(opts, :webhook_opts, [])},
      {Subscriber, Keyword.get(opts, :subscriber_opts, [])},
      {Alerts, Keyword.get(opts, :alerts_opts, [])}
    ]
  end

  # Subscription delegation

  @spec subscribe(map()) :: {:ok, String.t()} | {:error, term()}
  defdelegate subscribe(opts), to: Subscriber

  @spec unsubscribe(String.t()) :: :ok | {:error, :not_found}
  defdelegate unsubscribe(subscription_id), to: Subscriber

  @spec list_subscriptions() :: {:ok, [map()]}
  defdelegate list_subscriptions, to: Subscriber

  @spec replay(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  defdelegate replay(subscription_id, opts \\ []), to: Subscriber

  # Decoding delegation

  @spec decode_log(map(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate decode_log(log, opts \\ []), to: Decoder

  @spec identify_standard(map()) :: :erc20 | :erc721 | :erc1155 | :unknown
  defdelegate identify_standard(log), to: Decoder

  # Storage delegation

  @spec store_event(map()) :: :ok | {:error, :duplicate}
  defdelegate store_event(event), to: Storage

  @spec query_events(keyword()) :: {:ok, [map()]}
  defdelegate query_events(opts \\ []), to: Storage

  @spec event_count() :: non_neg_integer()
  defdelegate event_count, to: Storage, as: :count

  @spec clear_events() :: :ok
  defdelegate clear_events, to: Storage, as: :clear

  # Alerts delegation

  @spec create_alert(map()) :: {:ok, String.t()} | {:error, term()}
  defdelegate create_alert(rule_attrs), to: Alerts, as: :create_rule

  @spec delete_alert(String.t()) :: :ok | {:error, :not_found}
  defdelegate delete_alert(rule_id), to: Alerts, as: :delete_rule

  @spec list_alerts() :: {:ok, [map()]}
  defdelegate list_alerts, to: Alerts, as: :list_rules

  @spec process_alerts(map()) :: {:ok, [map()]}
  defdelegate process_event(event), to: Alerts, as: :process_event

  # Webhook delegation

  @spec register_webhook(map()) :: {:ok, String.t()} | {:error, term()}
  defdelegate register_webhook(attrs), to: Webhook, as: :register

  @spec unregister_webhook(String.t()) :: :ok | {:error, :not_found}
  defdelegate unregister_webhook(webhook_id), to: Webhook, as: :unregister

  @spec list_webhooks() :: {:ok, [map()]}
  defdelegate list_webhooks, to: Webhook

  @spec deliver_webhook(map()) :: :ok
  defdelegate deliver_webhook(event), to: Webhook, as: :deliver

  @spec dead_letter_queue() :: {:ok, [map()]}
  defdelegate dead_letter_queue, to: Webhook

  @spec retry_dead_letter() :: :ok
  defdelegate retry_dead_letter, to: Webhook

  # Convenience

  @spec watch_transfers(atom(), String.t(), keyword()) ::
          {:ok, String.t(), String.t() | nil, String.t() | nil} | {:error, term()}
  def watch_transfers(chain, contract_address, opts \\ []) do
    with {:ok, sub_id} <- subscribe(%{
      chain: chain,
      contract_address: contract_address,
      event_topics: ["Transfer(address,address,uint256)"],
      from_block: Keyword.get(opts, :from_block, "latest")
    }) do
      alert_id = case Keyword.get(opts, :alert_threshold) do
        nil -> nil
        threshold ->
          {:ok, id} = Alerts.create_large_transfer_alert(
            contract_address, threshold,
            channels: Keyword.get(opts, :alert_channels, [:discord]))
          id
      end

      webhook_id = case Keyword.get(opts, :webhook_url) do
        nil -> nil
        url ->
          {:ok, id} = Webhook.register(%{
            url: url, events: ["Transfer"], contract_address: contract_address})
          id
      end

      {:ok, sub_id, alert_id, webhook_id}
    end
  end

  @spec status() :: map()
  def status do
    %{
      storage: %{event_count: Storage.count()},
      subscriptions: case Subscriber.list_subscriptions() do
        {:ok, subs} -> %{
          total: length(subs),
          active: Enum.count(subs, &(&1.status == :active)),
          paused: Enum.count(subs, &(&1.status == :paused)),
          error: Enum.count(subs, &(&1.status == :error))
        }
      end,
      alerts: case Alerts.list_rules() do
        {:ok, rules} -> %{total: length(rules), enabled: Enum.count(rules, & &1.enabled)}
      end,
      webhooks: case Webhook.list_webhooks() do
        {:ok, whs} -> %{total: length(whs)}
      end
    }
  end
end
