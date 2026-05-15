defmodule Lux.Lenses.TradingView.MultiTimeframeAnalysis do
  @moduledoc """
  Lens for performing multi-timeframe technical analysis.

  Analyzes a symbol across multiple timeframes simultaneously to identify
  trend alignment, divergence, and confluent signals. This is essential
  for confirming trade setups across different scales.

  ## Examples

      iex> MultiTimeframeAnalysis.handler(%{
      ...>   symbol: "BINANCE:BTCUSDT",
      ...>   timeframes: ["1h", "4h", "1D"],
      ...>   indicators: ["rsi", "macd", "ema"]
      ...> }, %{name: "Agent"})
      {:ok, %{
        symbol: "BINANCE:BTCUSDT",
        analysis: %{
          "1h" => %{"rsi" => 62.1, "trend" => "bullish"},
          "4h" => %{"rsi" => 58.7, "trend" => "bullish"},
          "1D" => %{"rsi" => 55.3, "trend" => "neutral"}
        },
        consensus: "bullish",
        confluence_score: 0.78
      }}
  """

  use Lux.Lens,
    name: "TradingView Multi-Timeframe Analysis",
    description: "Performs technical analysis across multiple timeframes",
    input_schema: %{
      type: :object,
      properties: %{
        symbol: %{
          type: :string,
          description: "Trading symbol"
        },
        timeframes: %{
          type: :array,
          items: %{type: :string},
          description: "Timeframes to analyze",
          default: ["1h", "4h", "1D"]
        },
        indicators: %{
          type: :array,
          items: %{type: :string},
          description: "Indicators to calculate per timeframe",
          default: ["rsi", "macd", "ema"]
        }
      },
      required: ["symbol"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        symbol: %{type: :string},
        analysis: %{type: :object},
        consensus: %{type: :string},
        confluence_score: %{type: :number}
      },
      required: ["symbol", "analysis"]
    }

  alias Lux.Integrations.TradingView.Client
  require Logger

  def handler(params, agent) do
    agent_name = agent[:name] || "Unknown Agent"
    symbol = params[:symbol]
    timeframes = params[:timeframes] || ["1h", "4h", "1D"]
    indicators = params[:indicators] || ["rsi", "macd", "ema"]

    Logger.info("Agent #{agent_name} running multi-timeframe analysis for #{symbol} on #{length(timeframes)} timeframes")

    request_body = %{
      symbol: symbol,
      timeframes: timeframes,
      indicators: indicators
    }

    case Client.request(:post, "/analysis/multi-timeframe", %{json: request_body}) do
      {:ok, %{"analysis" => analysis} = body} ->
        consensus = Map.get(body, "consensus", determine_consensus(analysis))
        confluence = Map.get(body, "confluence_score", calculate_confluence(analysis))

        Logger.info("Multi-timeframe analysis complete for #{symbol}: #{consensus} (#{confluence})")

        {:ok, %{
          symbol: symbol,
          analysis: analysis,
          consensus: consensus,
          confluence_score: confluence
        }}

      {:ok, body} when is_map(body) ->
        {:ok, %{
          symbol: symbol,
          analysis: body,
          consensus: "unknown",
          confluence_score: 0.0
        }}

      {:error, error} ->
        Logger.error("Multi-timeframe analysis failed for #{symbol}: #{inspect(error)}")
        {:error, "Multi-timeframe analysis failed: #{inspect(error)}"}
    end
  end

  # Determines overall consensus from multi-timeframe analysis
  defp determine_consensus(analysis) when is_map(analysis) do
    trends = for {_tf, data} <- analysis, data["trend"] != nil, do: data["trend"]

    cond do
      Enum.empty?(trends) -> "neutral"
      Enum.all?(trends, &(&1 == "bullish")) -> "strongly_bullish"
      Enum.all?(trends, &(&1 == "bearish")) -> "strongly_bearish"
      Enum.count(trends, &(&1 == "bullish")) > Enum.count(trends, &(&1 == "bearish")) -> "bullish"
      Enum.count(trends, &(&1 == "bearish")) > Enum.count(trends, &(&1 == "bullish")) -> "bearish"
      true -> "neutral"
    end
  end
  defp determine_consensus(_), do: "neutral"

  # Calculates confluence score (0.0 to 1.0) based on trend agreement
  defp calculate_confluence(analysis) when is_map(analysis) do
    total = map_size(analysis)
    if total == 0, do: 0.0, else: 1.0 - (trend_variance(analysis) / total)
  end
  defp calculate_confluence(_), do: 0.0

  defp trend_variance(analysis) do
    trends = for {_tf, data} <- analysis, data["trend"] != nil, do: data["trend"]
    if Enum.empty?(trends) do
      0
    else
      most_common = trends |> Enum.frequencies() |> Map.values() |> Enum.max()
      length(trends) - most_common
    end
  end
end
