defmodule Lux.Lenses.Binance.Market.OrderBookLens do
  @moduledoc """
  A lens for fetching order book depth from Binance.

  ## Examples

      iex> Lux.Lenses.Binance.Market.OrderBookLens.focus(%{symbol: "BTCUSDT", limit: 10})
      {:ok, %{bids: [...], asks: [...], last_update_id: 12345}}
  """

  use Lux.Lens,
    name: "Binance Order Book",
    description: "Fetches order book depth for a given symbol from Binance",
    url: "https://api.binance.com/api/v3/depth",
    method: :get,
    schema: %{
      type: :object,
      properties: %{
        symbol: %{type: :string, description: "Trading pair symbol"},
        limit: %{type: :integer, description: "Depth entries (5,10,20,50,100,500,1000,5000)", enum: [5, 10, 20, 50, 100, 500, 1000, 5000], default: 100}
      },
      required: ["symbol"]
    }

  def after_focus(%{"bids" => bids, "asks" => asks, "lastUpdateId" => last_update_id}) do
    {:ok, %{
      last_update_id: last_update_id,
      bids: parse_orders(bids),
      asks: parse_orders(asks),
      spread: calculate_spread(bids, asks)
    }}
  end

  def after_focus(body), do: {:ok, body}

  defp parse_orders(orders) do
    Enum.map(orders, fn [price, qty] ->
      %{price: String.to_float(price), quantity: String.to_float(qty)}
    end)
  end

  defp calculate_spread([[bid_price, _] | _], [[ask_price, _] | _]) do
    String.to_float(ask_price) - String.to_float(bid_price)
  end

  defp calculate_spread(_, _), do: nil
end
