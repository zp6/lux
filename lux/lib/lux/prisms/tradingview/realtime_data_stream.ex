defmodule Lux.Prisms.TradingView.RealTimeDataStream do
  @moduledoc """
  Prism for managing real-time market data streaming via TradingView.

  Supports:
  - Subscribing/unsubscribing to price tick streams
  - Receiving indicator updates in real-time
  - Streaming candle updates for live charting

  ## Examples

      iex> RealTimeDataStream.handler(%{
      ...>   action: "subscribe",
      ...>   symbol: "BINANCE:BTCUSDT",
      ...>   data_type: "ticks"
      ...> }, %{name: "Agent"})
      {:ok, %{subscribed: true, stream_id: "stream_abc", symbol: "BINANCE:BTCUSDT"}}
  """

  use Lux.Prism,
    name: "TradingView Real-Time Data Stream",
    description: "Manages real-time market data subscriptions",
    input_schema: %{
      type: :object,
      properties: %{
        action: %{
          type: :string,
          description: "Stream action",
          enum: ["subscribe", "unsubscribe", "status", "list"]
        },
        stream_id: %{
          type: :string,
          description: "Stream ID for unsubscribe/status actions"
        },
        symbol: %{
          type: :string,
          description: "Trading symbol to stream"
        },
        data_type: %{
          type: :string,
          description: "Type of data to stream",
          enum: ["ticks", "candles", "indicators", "orderbook"],
          default: "ticks"
        },
        interval: %{
          type: :string,
          description: "Interval for candle/indicator streams"
        },
        callback_url: %{
          type: :string,
          description: "Webhook URL for stream data delivery"
        },
        indicators: %{
          type: :array,
          items: %{type: :string},
          description: "Indicators to include in indicator streams"
        }
      },
      required: ["action"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        action: %{type: :string},
        success: %{type: :boolean},
        stream_id: %{type: :string},
        details: %{type: :object}
      },
      required: ["action", "success"]
    }

  alias Lux.Integrations.TradingView.Client
  require Logger

  def handler(params, agent) do
    agent_name = agent[:name] || "Unknown Agent"
    action = params[:action]

    Logger.info("Agent #{agent_name} stream action: #{action}")

    case action do
      "subscribe" -> subscribe(params, agent_name)
      "unsubscribe" -> unsubscribe(params, agent_name)
      "status" -> status(params, agent_name)
      "list" -> list_streams(params, agent_name)
      _ -> {:error, "Unsupported action: #{action}"}
    end
  end

  defp subscribe(params, agent_name) do
    with {:ok, symbol} <- require_param(params, :symbol),
         {:ok, data_type} <- require_param(params, :data_type) do

      body = %{
        symbol: symbol,
        data_type: data_type,
        interval: params[:interval],
        callback_url: params[:callback_url],
        indicators: params[:indicators]
      }

      case Client.request(:post, "/stream/subscribe", %{json: body}) do
        {:ok, %{"stream_id" => stream_id} = response} ->
          Logger.info("Agent #{agent_name} subscribed to #{data_type} stream for #{symbol} (#{stream_id})")
          {:ok, %{
            action: "subscribe",
            success: true,
            stream_id: stream_id,
            details: Map.take(response, ["symbol", "data_type", "status"])
          }}

        {:error, error} ->
          {:error, "Failed to subscribe: #{inspect(error)}"}
      end
    end
  end

  defp unsubscribe(params, agent_name) do
    with {:ok, stream_id} <- require_param(params, :stream_id) do
      case Client.request(:post, "/stream/unsubscribe", %{json: %{stream_id: stream_id}}) do
        {:ok, _} ->
          Logger.info("Agent #{agent_name} unsubscribed from stream #{stream_id}")
          {:ok, %{action: "unsubscribe", success: true, stream_id: stream_id}}

        {:error, error} ->
          {:error, "Failed to unsubscribe: #{inspect(error)}"}
      end
    end
  end

  defp status(params, agent_name) do
    with {:ok, stream_id} <- require_param(params, :stream_id) do
      case Client.request(:get, "/stream/#{stream_id}/status") do
        {:ok, response} ->
          {:ok, %{action: "status", success: true, stream_id: stream_id, details: response}}

        {:error, error} ->
          {:error, "Failed to get stream status: #{inspect(error)}"}
      end
    end
  end

  defp list_streams(_params, agent_name) do
    case Client.request(:get, "/stream/list") do
      {:ok, %{"streams" => streams}} ->
        Logger.info("Agent #{agent_name} listed #{length(streams)} active streams")
        {:ok, %{action: "list", success: true, details: %{"streams" => streams, "count" => length(streams)}}}

      {:ok, streams} when is_list(streams) ->
        {:ok, %{action: "list", success: true, details: %{"streams" => streams, "count" => length(streams)}}}

      {:error, error} ->
        {:error, "Failed to list streams: #{inspect(error)}"}
    end
  end

  defp require_param(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} when not is_nil(value) -> {:ok, value}
      _ -> {:error, "Missing required parameter: #{key}"}
    end
  end
end
