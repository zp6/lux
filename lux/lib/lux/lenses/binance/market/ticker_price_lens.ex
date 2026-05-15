defmodule Lux.Lenses.Binance.Market.TickerPriceLens do
  @moduledoc """
  A lens for fetching current price ticker data from Binance.

  ## Examples

      iex> Lux.Lenses.Binance.Market.TickerPriceLens.focus(%{symbol: "BTCUSDT"})
      {:ok, %{"symbol" => "BTCUSDT", "price" => "50000.00"}}
  """

  use Lux.Lens,
    name: "Binance Ticker Price",
    description: "Fetches current price for one or all symbols from Binance",
    url: "https://api.binance.com/api/v3/ticker/price",
    method: :get,
    schema: %{
      type: :object,
      properties: %{
        symbol: %{
          type: :string,
          description: "Trading pair symbol (e.g., 'BTCUSDT'). Omit for all symbols."
        }
      }
    }

  def after_focus(%{"symbol" => symbol, "price" => _price} = body) do
    {:ok, %{
      symbol: body["symbol"],
      price: String.to_float(body["price"]),
      raw_data: body
    }}
  end

  def after_focus(body) when is_list(body) do
    prices = Enum.map(body, fn %{"symbol" => s, "price" => p} ->
      %{symbol: s, price: String.to_float(p)}
    end)
    {:ok, %{symbols: length(prices), prices: prices}}
  end

  def after_focus(body), do: {:ok, body}
end
