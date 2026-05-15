defmodule Lux.Lenses.TradingView.ChartData do
  @moduledoc """
  Lens for retrieving OHLCV candlestick chart data from TradingView.

  Fetches historical candle data for any supported trading pair across
  multiple timeframes (1m, 5m, 15m, 1h, 4h, 1D, 1W, 1M).

  ## Examples

      iex> ChartData.handler(%{
      ...>   symbol: "BINANCE:BTCUSDT",
      ...>   interval: "1h",
      ...>   limit: 100
      ...> }, %{name: "Agent"})
      {:ok, %{
        symbol: "BINANCE:BTCUSDT",
        interval: "1h",
        candles: [
          %{"time" => 1700000000, "open" => 42000.0, "high" => 42500.0,
            "low" => 41800.0, "close" => 42300.0, "volume" => 1234.5},
          ...
        ],
        count: 100
      }}
  """

  use Lux.Lens,
    name: "TradingView Chart Data",
    description: "Retrieves OHLCV candlestick data for a trading symbol",
    input_schema: %{
      type: :object,
      properties: %{
        symbol: %{
          type: :string,
          description: "Trading symbol (e.g. BINANCE:BTCUSDT, NYSE:AAPL)"
        },
        interval: %{
          type: :string,
          description: "Candle interval",
          enum: ["1m", "5m", "15m", "30m", "1h", "4h", "1D", "1W", "1M"],
          default: "1h"
        },
        limit: %{
          type: :integer,
          description: "Number of candles to retrieve (1-5000)",
          minimum: 1,
          maximum: 5000,
          default: 100
        },
        start_time: %{
          type: :integer,
          description: "Start timestamp in seconds (Unix epoch)"
        },
        end_time: %{
          type: :integer,
          description: "End timestamp in seconds (Unix epoch)"
        }
      },
      required: ["symbol"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        symbol: %{type: :string},
        interval: %{type: :string},
        candles: %{
          type: :array,
          items: %{
            type: :object,
            properties: %{
              time: %{type: :integer},
              open: %{type: :number},
              high: %{type: :number},
              low: %{type: :number},
              close: %{type: :number},
              volume: %{type: :number}
            }
          }
        },
        count: %{type: :integer}
      },
      required: ["symbol", "interval", "candles"]
    }

  alias Lux.Integrations.TradingView.Client
  require Logger

  @valid_intervals ~w(1m 5m 15m 30m 1h 4h 1D 1W 1M)

  def handler(params, agent) do
    agent_name = agent[:name] || "Unknown Agent"
    symbol = params[:symbol]
    interval = params[:interval] || "1h"
    limit = params[:limit] || 100

    with :ok <- validate_interval(interval),
         :ok <- validate_limit(limit) do

      Logger.info("Agent #{agent_name} fetching chart data for #{symbol} (#{interval}, #{limit} candles)")

      query_params = build_query_params(symbol, interval, limit, params)

      case Client.request(:get, "/chart/#{URI.encode(symbol)}/candles", %{params: query_params}) do
        {:ok, candles} when is_list(candles) ->
          Logger.info("Retrieved #{length(candles)} candles for #{symbol}")
          {:ok, %{
            symbol: symbol,
            interval: interval,
            candles: candles,
            count: length(candles)
          }}

        {:ok, body} ->
          Logger.warning("Unexpected response format for #{symbol}: #{inspect(body)}")
          {:ok, %{
            symbol: symbol,
            interval: interval,
            candles: [],
            count: 0,
            raw: body
          }}

        {:error, error} ->
          Logger.error("Failed to fetch chart data for #{symbol}: #{inspect(error)}")
          {:error, "Failed to fetch chart data: #{inspect(error)}"}
      end
    end
  end

  defp validate_interval(interval) when interval in @valid_intervals, do: :ok
  defp validate_interval(interval), do: {:error, "Invalid interval: #{interval}. Must be one of #{Enum.join(@valid_intervals, ", ")}"}

  defp validate_limit(limit) when is_integer(limit) and limit > 0 and limit <= 5000, do: :ok
  defp validate_limit(limit), do: {:error, "Invalid limit: #{limit}. Must be between 1 and 5000"}

  defp build_query_params(symbol, interval, limit, params) do
    base = %{symbol: symbol, interval: interval, limit: limit}

    params
    |> Map.take([:start_time, :end_time])
    |> Map.merge(base)
  end
end
