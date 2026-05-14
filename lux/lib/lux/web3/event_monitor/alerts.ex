defmodule Lux.Web3.EventMonitor.Alerts do
  @moduledoc """
  Alert system for smart contract event monitoring.

  Provides configurable rules for triggering alerts based on event patterns,
  thresholds, and custom conditions. Supports notification via Discord and Telegram.

  ## Configuration

      config :lux, Lux.Web3.EventMonitor.Alerts,
        enabled: true,
        default_channels: [:discord, :telegram],
        discord_webhook_url: System.get_env("DISCORD_ALERT_WEBHOOK_URL"),
        telegram_bot_token: System.get_env("TELEGRAM_ALERT_BOT_TOKEN"),
        telegram_chat_id: System.get_env("TELEGRAM_ALERT_CHAT_ID")

  ## Alert Rules

  Alert rules define conditions that trigger notifications:

      # Large transfer alert
      :ok = Alerts.create_rule(%{
        name: "large_transfer",
        description: "Alert on transfers > 100,000 USDC",
        event_name: "Transfer",
        contract_address: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
        conditions: [
          %{field: "value", operator: :gt, threshold: 100_000_000_000}
        ],
        channels: [:discord],
        cooldown_ms: 60_000
      })

  ## Built-in Alert Templates

    * `:large_transfer` - Triggers on token transfers above a threshold
    * `:large_approval` - Triggers on large token approvals
    * `:nft_floor_sweep` - Triggers on multiple NFT transfers from same address

  ## Usage

      # Start the alerts manager
      {:ok, pid} = Alerts.start_link([])

      # Create a rule
      {:ok, rule_id} = Alerts.create_rule(%{...})

      # Process an event (check against all rules)
      {:ok, triggered} = Alerts.process_event(event)

      # List rules
      {:ok, rules} = Alerts.list_rules()
  """

  use GenServer

  require Logger

  @type condition :: %{
    field: String.t(),
    operator: :eq | :neq | :gt | :gte | :lt | :lte | :contains,
    threshold: term()
  }

  @type rule :: %{
    id: String.t(),
    name: String.t(),
    description: String.t(),
    event_name: String.t(),
    contract_address: String.t() | nil,
    conditions: [condition()],
    channels: [:discord | :telegram],
    cooldown_ms: non_neg_integer(),
    enabled: boolean(),
    last_triggered_at: DateTime.t() | nil,
    trigger_count: non_neg_integer(),
    created_at: DateTime.t()
  }

  @type alert :: %{
    rule_id: String.t(),
    rule_name: String.t(),
    event: map(),
    message: String.t(),
    triggered_at: DateTime.t(),
    channels: [:discord | :telegram]
  }

  # Client API

  @doc """
  Starts the alerts GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Creates a new alert rule.
  """
  @spec create_rule(map()) :: {:ok, String.t()} | {:error, term()}
  def create_rule(rule_attrs) do
    GenServer.call(__MODULE__, {:create_rule, rule_attrs})
  end

  @doc """
  Removes an alert rule.
  """
  @spec delete_rule(String.t()) :: :ok | {:error, :not_found}
  def delete_rule(rule_id) do
    GenServer.call(__MODULE__, {:delete_rule, rule_id})
  end

  @doc """
  Enables a disabled rule.
  """
  @spec enable_rule(String.t()) :: :ok | {:error, :not_found}
  def enable_rule(rule_id) do
    GenServer.call(__MODULE__, {:enable_rule, rule_id})
  end

  @doc """
  Disables a rule.
  """
  @spec disable_rule(String.t()) :: :ok | {:error, :not_found}
  def disable_rule(rule_id) do
    GenServer.call(__MODULE__, {:disable_rule, rule_id})
  end

  @doc """
  Lists all alert rules.
  """
  @spec list_rules() :: {:ok, [rule()]}
  def list_rules do
    GenServer.call(__MODULE__, :list_rules)
  end

  @doc """
  Gets a rule by ID.
  """
  @spec get_rule(String.t()) :: {:ok, rule()} | {:error, :not_found}
  def get_rule(rule_id) do
    GenServer.call(__MODULE__, {:get_rule, rule_id})
  end

  @doc """
  Processes an event against all active rules.
  Returns a list of triggered alerts.
  """
  @spec process_event(map()) :: {:ok, [alert()]}
  def process_event(event) do
    GenServer.call(__MODULE__, {:process_event, event})
  end

  @doc """
  Sends an alert notification to the configured channels.
  """
  @spec send_alert(alert()) :: :ok | {:error, term()}
  def send_alert(alert) do
    GenServer.call(__MODULE__, {:send_alert, alert})
  end

  @doc """
  Creates a built-in large transfer alert rule.
  """
  @spec create_large_transfer_alert(String.t(), non_neg_integer(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def create_large_transfer_alert(contract_address, threshold, opts \\ []) do
    create_rule(%{
      name: Keyword.get(opts, :name, "large_transfer_#{contract_address}"),
      description: "Transfer > #{threshold} detected on #{contract_address}",
      event_name: "Transfer",
      contract_address: contract_address,
      conditions: [
        %{field: "value", operator: :gt, threshold: threshold}
      ],
      channels: Keyword.get(opts, :channels, [:discord]),
      cooldown_ms: Keyword.get(opts, :cooldown_ms, 60_000)
    })
  end

  # GenServer Callbacks

  @impl true
  def init(_opts) do
    state = %{
      rules: %{},
      alert_history: [],
      max_history: 1000
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:create_rule, attrs}, _from, state) do
    rule_id = generate_id()

    rule = %{
      id: rule_id,
      name: attrs[:name] || attrs["name"] || "unnamed_rule",
      description: attrs[:description] || attrs["description"] || "",
      event_name: attrs[:event_name] || attrs["event_name"],
      contract_address: attrs[:contract_address] || attrs["contract_address"],
      conditions: attrs[:conditions] || attrs["conditions"] || [],
      channels: attrs[:channels] || attrs["channels"] || default_channels(),
      cooldown_ms: attrs[:cooldown_ms] || attrs["cooldown_ms"] || 0,
      enabled: true,
      last_triggered_at: nil,
      trigger_count: 0,
      created_at: DateTime.utc_now()
    }

    Logger.info("Alert rule created: #{rule.name} (#{rule_id})")
    {:reply, {:ok, rule_id}, %{state | rules: Map.put(state.rules, rule_id, rule)}}
  end

  @impl true
  def handle_call({:delete_rule, rule_id}, _from, state) do
    case Map.pop(state.rules, rule_id) do
      {nil, _} -> {:reply, {:error, :not_found}, state}
      {_rule, remaining} -> {:reply, :ok, %{state | rules: remaining}}
    end
  end

  @impl true
  def handle_call({:enable_rule, rule_id}, _from, state) do
    update_rule_status(state, rule_id, true)
  end

  @impl true
  def handle_call({:disable_rule, rule_id}, _from, state) do
    update_rule_status(state, rule_id, false)
  end

  @impl true
  def handle_call(:list_rules, _from, state) do
    {:reply, {:ok, Map.values(state.rules)}, state}
  end

  @impl true
  def handle_call({:get_rule, rule_id}, _from, state) do
    case Map.get(state.rules, rule_id) do
      nil -> {:reply, {:error, :not_found}, state}
      rule -> {:reply, {:ok, rule}, state}
    end
  end

  @impl true
  def handle_call({:process_event, event}, _from, state) do
    event_name = event[:event_name] || event["event_name"]
    contract = event[:contract_address] || event["contract_address"]

    triggered_alerts =
      state.rules
      |> Map.values()
      |> Enum.filter(& &1.enabled)
      |> Enum.filter(&matches_rule?(&1, event_name, contract))
      |> Enum.filter(&conditions_met?(&1.conditions, event))
      |> Enum.filter(&cooldown_ok?(&1))
      |> Enum.map(fn rule -> build_alert(rule, event) end)

    # Update rule trigger counts and last_triggered_at
    new_rules =
      Enum.reduce(triggered_alerts, state.rules, fn alert, rules ->
        Map.update!(rules, alert.rule_id, fn rule ->
          %{rule |
            trigger_count: rule.trigger_count + 1,
            last_triggered_at: DateTime.utc_now()
          }
        end)
      end)

    # Send alerts asynchronously
    Enum.each(triggered_alerts, &send_alert_async/1)

    # Update history
    new_history = (triggered_alerts ++ state.alert_history) |> Enum.take(state.max_history)

    {:reply, {:ok, triggered_alerts}, %{state | rules: new_rules, alert_history: new_history}}
  end

  @impl true
  def handle_call({:send_alert, alert}, _from, state) do
    result = do_send_alert(alert)
    {:reply, result, state}
  end

  # Private functions

  defp update_rule_status(state, rule_id, enabled) do
    case Map.get(state.rules, rule_id) do
      nil -> {:reply, {:error, :not_found}, state}
      rule ->
        updated = Map.put(state.rules, rule_id, %{rule | enabled: enabled})
        {:reply, :ok, %{state | rules: updated}}
    end
  end

  defp matches_rule?(rule, event_name, contract) do
    name_match = rule.event_name == event_name
    contract_match = is_nil(rule.contract_address) or
                     String.downcase(rule.contract_address) == String.downcase(contract || "")

    name_match and contract_match
  end

  defp conditions_met?([], _event), do: true

  defp conditions_met?(conditions, event) do
    params = event[:params] || event["params"] || %{}

    Enum.all?(conditions, fn cond ->
      value = get_param_value(params, cond[:field] || cond["field"])
      threshold = cond[:threshold] || cond["threshold"]
      operator = cond[:operator] || cond["operator"]

      compare(value, operator, threshold)
    end)
  end

  defp get_param_value(params, field) when is_map(params) do
    # Try atom and string keys
    Map.get(params, field) || Map.get(params, String.to_atom(field))
  end

  defp compare(nil, _op, _threshold), do: false
  defp compare(value, :eq, threshold), do: value == threshold
  defp compare(value, :neq, threshold), do: value != threshold
  defp compare(value, :gt, threshold) when is_number(value), do: value > threshold
  defp compare(value, :gte, threshold) when is_number(value), do: value >= threshold
  defp compare(value, :lt, threshold) when is_number(value), do: value < threshold
  defp compare(value, :lte, threshold) when is_number(value), do: value <= threshold
  defp compare(value, :contains, threshold) when is_binary(value), do: String.contains?(value, threshold)
  defp compare(_, _, _), do: false

  defp cooldown_ok?(%{cooldown_ms: 0}), do: true
  defp cooldown_ok?(%{last_triggered_at: nil}), do: true
  defp cooldown_ok?(%{last_triggered_at: last, cooldown_ms: cooldown}) do
    now = DateTime.utc_now()
    diff_ms = DateTime.diff(now, last, :millisecond)
    diff_ms >= cooldown
  end

  defp build_alert(rule, event) do
    %{
      rule_id: rule.id,
      rule_name: rule.name,
      event: event,
      message: format_alert_message(rule, event),
      triggered_at: DateTime.utc_now(),
      channels: rule.channels
    }
  end

  defp format_alert_message(rule, event) do
    params = event[:params] || event["params"] || %{}

    "🚨 **#{rule.name}**\n" <>
      "#{rule.description}\n" <>
      "Contract: `#{event[:contract_address] || event["contract_address"]}`\n" <>
      "Event: #{event[:event_name] || event["event_name"]}\n" <>
      "Block: #{event[:block_number] || event["block_number"]}\n" <>
      "TX: `#{event[:transaction_hash] || event["transaction_hash"]}`\n" <>
      format_params(params)
  end

  defp format_params(params) when is_map(params) do
    params
    |> Enum.map(fn {k, v} -> "  #{k}: #{inspect(v)}" end)
    |> Enum.join("\n")
  end

  defp format_params(_), do: ""

  defp send_alert_async(alert) do
    Task.start(fn -> do_send_alert(alert) end)
  end

  defp do_send_alert(alert) do
    results =
      alert.channels
      |> Enum.map(fn channel ->
        case channel do
          :discord -> send_discord_alert(alert)
          :telegram -> send_telegram_alert(alert)
          other -> {:error, {:unsupported_channel, other}}
        end
      end)

    # Return first error if any
    case Enum.find(results, fn {status, _} -> status == :error end) do
      nil -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp send_discord_alert(alert) do
    webhook_url = get_config(:discord_webhook_url)

    if webhook_url do
      body = %{
        content: alert.message,
        username: "Lux Event Monitor"
      }

      case Req.post(webhook_url, json: body) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      Logger.warning("Discord webhook URL not configured, skipping alert: #{alert.rule_name}")
      {:error, :discord_not_configured}
    end
  end

  defp send_telegram_alert(alert) do
    bot_token = get_config(:telegram_bot_token)
    chat_id = get_config(:telegram_chat_id)

    if bot_token && chat_id do
      url = "https://api.telegram.org/bot#{bot_token}/sendMessage"

      body = %{
        chat_id: chat_id,
        text: alert.message,
        parse_mode: "Markdown"
      }

      case Req.post(url, json: body) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      Logger.warning("Telegram not configured, skipping alert: #{alert.rule_name}")
      {:error, :telegram_not_configured}
    end
  end

  defp default_channels do
    get_config(:default_channels, [:discord])
  end

  defp get_config(key, default \\ nil) do
    :lux
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
