defmodule Lux.Prisms.Hyperliquid.HyperliquidPnLTrackerPrism do
  @moduledoc """
  A prism for tracking PnL (Profit and Loss) across Hyperliquid positions.

  Provides realized and unrealized PnL calculations, funding cost tracking,
  and portfolio performance metrics.

  ## Examples

      iex> Lux.Prisms.Hyperliquid.HyperliquidPnLTrackerPrism.handler(%{
      ...>   address: "0x0403369c02199a0cb827f4d6492927e9fa5668d5"
      ...> }, %{})
      {:ok, %{total_unrealized_pnl: 150.0, positions: [...], funding_costs: 12.5}}
  """

  use Lux.Prism,
    name: "Hyperliquid PnL Tracker",
    description: "Tracks realized and unrealized PnL for Hyperliquid positions",
    input_schema: %{
      type: :object,
      properties: %{
        address: %{type: :string, description: "Ethereum wallet address", pattern: "^0x[a-fA-F0-9]{40}$"}
      },
      required: ["address"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        total_unrealized_pnl: %{type: :number},
        total_funding_costs: %{type: :number},
        positions: %{type: :array},
        position_count: %{type: :integer}
      },
      required: ["total_unrealized_pnl", "positions"]
    }

  require Logger

  def handler(input, _ctx) do
    address = Map.fetch!(input, :address)
    api_url = Application.get_env(:lux, :accounts, []) |> Keyword.get(:hyperliquid_api_url, "https://api.hyperliquid.xyz")

    with {:ok, user_state} <- fetch_user_state(api_url, address),
         {:ok, positions} <- parse_positions(user_state) do

      total_unrealized_pnl = Enum.reduce(positions, 0.0, fn p, acc -> acc + p.unrealized_pnl end)
      total_funding = Enum.reduce(positions, 0.0, fn p, acc -> acc + p.cumulative_funding end)
      total_margin = Enum.reduce(positions, 0.0, fn p, acc -> acc + p.margin_used end)
      total_value = Enum.reduce(positions, 0.0, fn p, acc -> acc + p.position_value end)

      {:ok, %{
        address: address,
        position_count: length(positions),
        total_unrealized_pnl: total_unrealized_pnl,
        total_funding_costs: total_funding,
        total_margin_used: total_margin,
        total_position_value: total_value,
        roi: if(total_margin > 0, do: total_unrealized_pnl / total_margin * 100, else: 0.0),
        positions: positions
      }}
    end
  end

  defp fetch_user_state(api_url, address) do
    case Req.request(Req.new(url: api_url, method: :post, json: %{"type" => "clearinghouseState", "user" => address})) do
      {:ok, %{status: 200, body: state}} -> {:ok, state}
      {:ok, %{status: status, body: error}} -> {:error, "API error #{status}: #{inspect(error)}"}
      {:error, reason} -> {:error, "Request failed: #{inspect(reason)}"}
    end
  end

  defp parse_positions(%{"assetPositions" => positions}) do
    parsed = Enum.map(positions, fn %{"position" => pos} = asset ->
      size = parse_float(pos["size"])
      %{
        coin: pos["coin"],
        side: if(size < 0, do: "SHORT", else: "LONG"),
        size: abs(size),
        entry_price: parse_float(pos["entryPx"]),
        position_value: parse_float(pos["positionValue"]),
        unrealized_pnl: parse_float(pos["unrealizedPnl"]),
        return_on_equity: parse_float(pos["returnOnEquity"]),
        leverage: parse_float(pos["leverage"]["value"]),
        liquidation_price: parse_float(pos["liquidationPx"]),
        margin_used: parse_float(pos["marginUsed"]),
        cumulative_funding: parse_float(asset["cumulativeFunding"]["payment"])
      }
    end)
    {:ok, parsed}
  end

  defp parse_positions(_), do: {:ok, []}

  defp parse_float(nil), do: 0.0
  defp parse_float(val) when is_number(val), do: val / 1
  defp parse_float(val) when is_binary(val) do
    case Float.parse(val) do
      {f, _} -> f
      :error -> 0.0
    end
  end
end
