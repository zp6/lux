defmodule Lux.Prisms.TradingView.AlertManager do
  @moduledoc """
  Prism for managing TradingView-style price and indicator alerts.

  Supports creating, listing, and deleting alerts based on:
  - Price thresholds (above/below)
  - Indicator crossover signals
  - Pattern detection triggers

  ## Examples

      iex> AlertManager.handler(%{
      ...>   action: "create",
      ...>   symbol: "BINANCE:BTCUSDT",
      ...>   alert_type: "price_above",
      ...>   value: 50000.0,
      ...>   message: "BTC broke 50k!"
      ...> }, %{name: "Agent"})
      {:ok, %{created: true, alert_id: "alert_abc123", symbol: "BINANCE:BTCUSDT"}}
  """

  use Lux.Prism,
    name: "TradingView Alert Manager",
    description: "Creates and manages price and indicator alerts",
    input_schema: %{
      type: :object,
      properties: %{
        action: %{
          type: :string,
          description: "Alert action to perform",
          enum: ["create", "list", "delete", "update"]
        },
        alert_id: %{
          type: :string,
          description: "Alert ID for delete/update actions"
        },
        symbol: %{
          type: :string,
          description: "Trading symbol for the alert"
        },
        alert_type: %{
          type: :string,
          description: "Type of alert condition",
          enum: ["price_above", "price_below", "indicator_cross_above",
                 "indicator_cross_below", "pattern_detected", "volume_spike"]
        },
        value: %{
          type: :number,
          description: "Threshold value for the alert condition"
        },
        indicator: %{
          type: :string,
          description: "Indicator name for indicator-based alerts"
        },
        interval: %{
          type: :string,
          description: "Timeframe for alert monitoring",
          default: "1h"
        },
        message: %{
          type: :string,
          description: "Custom notification message"
        },
        webhook_url: %{
          type: :string,
          description: "Webhook URL for alert notifications"
        },
        enabled: %{
          type: :boolean,
          description: "Whether the alert is active",
          default: true
        }
      },
      required: ["action"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        action: %{type: :string},
        success: %{type: :boolean},
        alert_id: %{type: :string},
        details: %{type: :object}
      },
      required: ["action", "success"]
    }

  alias Lux.Integrations.TradingView.Client
  require Logger

  def handler(params, agent) do
    agent_name = agent[:name] || "Unknown Agent"
    action = params[:action]

    Logger.info("Agent #{agent_name} performing alert action: #{action}")

    case action do
      "create" -> create_alert(params, agent_name)
      "list" -> list_alerts(params, agent_name)
      "delete" -> delete_alert(params, agent_name)
      "update" -> update_alert(params, agent_name)
      _ -> {:error, "Unsupported action: #{action}"}
    end
  end

  defp create_alert(params, agent_name) do
    with {:ok, symbol} <- require_param(params, :symbol),
         {:ok, alert_type} <- require_param(params, :alert_type),
         {:ok, value} <- require_param(params, :value) do

      body = %{
        symbol: symbol,
        alert_type: alert_type,
        value: value,
        indicator: params[:indicator],
        interval: params[:interval] || "1h",
        message: params[:message],
        webhook_url: params[:webhook_url],
        enabled: params[:enabled] != false
      }

      case Client.request(:post, "/alerts", %{json: body}) do
        {:ok, %{"id" => alert_id} = response} ->
          Logger.info("Agent #{agent_name} created alert #{alert_id} for #{symbol}")
          {:ok, %{
            action: "create",
            success: true,
            alert_id: alert_id,
            details: Map.take(response, ["symbol", "alert_type", "value", "enabled"])
          }}

        {:error, error} ->
          Logger.error("Failed to create alert: #{inspect(error)}")
          {:error, "Failed to create alert: #{inspect(error)}"}
      end
    end
  end

  defp list_alerts(params, agent_name) do
    query = Map.take(params, [:symbol])
    opts = if map_size(query) > 0, do: %{params: query}, else: %{}

    case Client.request(:get, "/alerts", opts) do
      {:ok, %{"alerts" => alerts}} ->
        Logger.info("Agent #{agent_name} listed #{length(alerts)} alerts")
        {:ok, %{action: "list", success: true, details: %{"alerts" => alerts, "count" => length(alerts)}}}

      {:ok, alerts} when is_list(alerts) ->
        {:ok, %{action: "list", success: true, details: %{"alerts" => alerts, "count" => length(alerts)}}}

      {:error, error} ->
        {:error, "Failed to list alerts: #{inspect(error)}"}
    end
  end

  defp delete_alert(params, agent_name) do
    with {:ok, alert_id} <- require_param(params, :alert_id) do
      case Client.request(:delete, "/alerts/#{alert_id}") do
        {:ok, _} ->
          Logger.info("Agent #{agent_name} deleted alert #{alert_id}")
          {:ok, %{action: "delete", success: true, alert_id: alert_id}}

        {:error, error} ->
          {:error, "Failed to delete alert: #{inspect(error)}"}
      end
    end
  end

  defp update_alert(params, agent_name) do
    with {:ok, alert_id} <- require_param(params, :alert_id) do
      body = Map.take(params, [:value, :message, :webhook_url, :enabled])

      case Client.request(:put, "/alerts/#{alert_id}", %{json: body}) do
        {:ok, response} ->
          Logger.info("Agent #{agent_name} updated alert #{alert_id}")
          {:ok, %{action: "update", success: true, alert_id: alert_id, details: response}}

        {:error, error} ->
          {:error, "Failed to update alert: #{inspect(error)}"}
      end
    end
  end

  defp require_param(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} when not is_nil(value) -> {:ok, value}
      _ -> {:error, "Missing required parameter: #{key}"}
    end
  end
end
