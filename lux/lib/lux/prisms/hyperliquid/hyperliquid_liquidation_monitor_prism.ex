defmodule Lux.Prisms.Hyperliquid.HyperliquidLiquidationMonitorPrism do
  @moduledoc """
  A prism for monitoring liquidation risk across Hyperliquid positions.

  Calculates liquidation proximity, health factor, and provides risk alerts.

  ## Examples

      iex> Lux.Prisms.Hyperliquid.HyperliquidLiquidationMonitorPrism.handler(%{
      ...>   address: "0x..."
      ...> }, %{})
      {:ok, %{risk_level: "low", positions_at_risk: 0, alerts: []}}
  """

  use Lux.Prism,
    name: "Hyperliquid Liquidation Monitor",
    description: "Monitors liquidation risk and provides alerts for positions",
    input_schema: %{
      type: :object,
      properties: %{
        address: %{type: :string, description: "Ethereum wallet address", pattern: "^0x[a-fA-F0-9]{40}$"},
        warning_threshold: %{type: :number, description: "Warning threshold % to liquidation (default: 20)", default: 20.0},
        critical_threshold: %{type: :number, description: "Critical threshold % to liquidation (default: 10)", default: 10.0}
      },
      required: ["address"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        risk_level: %{type: :string},
        positions_at_risk: %{type: :integer},
        alerts: %{type: :array}
      },
      required: ["risk_level", "positions_at_risk"]
    }

  require Logger

  def handler(input, _ctx) do
    address = Map.fetch!(input, :address)
    warning_threshold = Map.get(input, :warning_threshold, 20.0)
    critical_threshold = Map.get(input, :critical_threshold, 10.0)
    api_url = Application.get_env(:lux, :accounts, []) |> Keyword.get(:hyperliquid_api_url, "https://api.hyperliquid.xyz")

    with {:ok, user_state} <- fetch_user_state(api_url, address),
         {:ok, positions} <- get_positions(user_state),
         {:ok, prices} <- fetch_mid_prices(api_url) do

      risks = Enum.map(positions, fn pos ->
        calculate_risk(pos, prices, warning_threshold, critical_threshold)
      end)

      risk_level = determine_overall_risk(risks)
      positions_at_risk = Enum.count(risks, fn r -> r.level in [:warning, :critical] end)

      {:ok, %{
        address: address,
        risk_level: risk_level,
        positions_at_risk: positions_at_risk,
        alerts: Enum.filter(risks, fn r -> r.level != :safe end),
        all_positions: risks
      }}
    end
  end

  defp fetch_user_state(api_url, address) do
    case Req.request(Req.new(url: api_url, method: :post, json: %{"type" => "clearinghouseState", "user" => address})) do
      {:ok, %{status: 200, body: state}} -> {:ok, state}
      {:error, reason} -> {:error, "Failed to fetch user state: #{inspect(reason)}"}
    end
  end

  defp fetch_mid_prices(api_url) do
    case Req.request(Req.new(url: api_url, method: :post, json: %{"type" => "allMids"})) do
      {:ok, %{status: 200, body: mids}} -> {:ok, mids}
      {:error, reason} -> {:error, "Failed to fetch prices: #{inspect(reason)}"}
    end
  end

  defp get_positions(%{"assetPositions" => positions}) do
    parsed = Enum.map(positions, fn %{"position" => pos} ->
      size = parse_float(pos["size"])
      %{
        coin: pos["coin"],
        side: if(size < 0, do: "SHORT", else: "LONG"),
        size: abs(size),
        entry_price: parse_float(pos["entryPx"]),
        liquidation_price: parse_float(pos["liquidationPx"]),
        margin_used: parse_float(pos["marginUsed"]),
        leverage: parse_float(pos["leverage"]["value"])
      }
    end)
    {:ok, parsed}
  end

  defp get_positions(_), do: {:ok, []}

  defp calculate_risk(position, prices, warning_threshold, critical_threshold) do
    current_price = get_current_price(position.coin, prices)
    liq_price = position.liquidation_price

    distance_pct = if liq_price > 0 and current_price > 0 do
      abs(current_price - liq_price) / current_price * 100
    else
      100.0
    end

    level = cond do
      distance_pct <= critical_threshold -> :critical
      distance_pct <= warning_threshold -> :warning
      true -> :safe
    end

    Map.merge(position, %{
      current_price: current_price,
      liquidation_distance_pct: Float.round(distance_pct, 2),
      level: level
    })
  end

  defp get_current_price(coin, prices) when is_map(prices) do
    case Map.get(prices, coin) do
      nil -> 0.0
      price -> parse_float(price)
    end
  end

  defp determine_overall_risk(risks) do
    levels = Enum.map(risks, & &1.level)
    cond do
      :critical in levels -> "critical"
      :warning in levels -> "warning"
      true -> "safe"
    end
  end

  defp parse_float(nil), do: 0.0
  defp parse_float(val) when is_number(val), do: val / 1
  defp parse_float(val) when is_binary(val) do
    case Float.parse(val) do
      {f, _} -> f
      :error -> 0.0
    end
  end
end
