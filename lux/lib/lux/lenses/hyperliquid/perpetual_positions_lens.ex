defmodule Lux.Lenses.Hyperliquid.PerpetualPositionsLens do
  @moduledoc """
  A lens for fetching open perpetual positions from Hyperliquid.

  Retrieves detailed position data including entry price, leverage,
  unrealized PnL, liquidation price, and margin information.

  ## Examples

      iex> Lux.Lenses.Hyperliquid.PerpetualPositionsLens.focus(%{address: "0x..."})
      {:ok, %{positions: [%{coin: "ETH", size: "1.0", unrealized_pnl: "150.0", ...}]}}
  """

  use Lux.Lens,
    name: "Hyperliquid Perpetual Positions",
    description: "Fetches open perpetual positions with PnL and liquidation data",
    url: "https://api.hyperliquid.xyz/info",
    method: :post,
    schema: %{
      type: :object,
      properties: %{
        address: %{
          type: :string,
          description: "Ethereum wallet address",
          pattern: "^0x[a-fA-F0-9]{40}$"
        }
      },
      required: ["address"]
    }

  def before_focus(params) do
    address = Map.get(params, :address, "")
    Map.put(params, :body, %{"type" => "clearinghouseState", "user" => address})
  end

  def after_focus(%{"assetPositions" => positions}) do
    parsed_positions = Enum.map(positions, &parse_position/1)

    {:ok, %{
      position_count: length(parsed_positions),
      total_unrealized_pnl: calculate_total_pnl(parsed_positions),
      positions: parsed_positions
    }}
  end

  def after_focus(body), do: {:ok, body}

  defp parse_position(%{"position" => pos} = asset_pos) do
    %{
      coin: pos["coin"],
      entry_price: parse_float(pos["entryPx"]),
      leverage: parse_float(pos["leverage"]["value"]),
      liquidation_price: parse_float(pos["liquidationPx"]),
      margin_used: parse_float(pos["marginUsed"]),
      position_value: parse_float(pos["positionValue"]),
      unrealized_pnl: parse_float(pos["unrealizedPnl"]),
      return_on_equity: parse_float(pos["returnOnEquity"]),
      size: pos["size"],
      side: if(String.contains?(pos["size"], "-"), do: "SHORT", else: "LONG"),
      cumulative_funding: parse_float(asset_pos["cumulativeFunding"]["payment"])
    }
  end

  defp parse_float(nil), do: 0.0
  defp parse_float(val) when is_float(val), do: val
  defp parse_float(val) when is_binary(val) do
    case Float.parse(val) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp calculate_total_pnl(positions) do
    Enum.reduce(positions, 0.0, fn pos, acc -> acc + pos.unrealized_pnl end)
  end
end
