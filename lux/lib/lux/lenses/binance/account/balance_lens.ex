defmodule Lux.Lenses.Binance.Account.BalanceLens do
  @moduledoc """
  A lens for fetching account balances from Binance.

  Requires authenticated API keys with read permissions.
  Returns all asset balances, filtering out zero balances by default.

  ## Examples

      iex> Lux.Lenses.Binance.Account.BalanceLens.focus(%{})
      {:ok, %{total_assets: 5, balances: [%{asset: "BTC", free: 1.5, locked: 0.1}, ...]}}
  """

  use Lux.Lens,
    name: "Binance Account Balance",
    description: "Fetches current account asset balances from Binance",
    url: "https://api.binance.com/api/v3/account",
    method: :get,
    auth: %{
      type: :custom,
      auth_function: &Lux.Integrations.Binance.sign_request/1
    },
    schema: %{
      type: :object,
      properties: %{
        include_zero: %{
          type: :boolean,
          description: "Include assets with zero balance (default: false)",
          default: false
        }
      }
    }

  alias Lux.Integrations.Binance

  def before_focus(params) do
    Map.put(params, :timestamp, System.system_time(:millisecond))
  end

  def after_focus(%{"balances" => balances} = body) do
    include_zero = get_in(body, ["include_zero"]) || false

    filtered_balances =
      balances
      |> Enum.filter(fn b ->
        include_zero or String.to_float(b["free"]) > 0.0 or String.to_float(b["locked"]) > 0.0
      end)
      |> Enum.map(fn %{"asset" => asset, "free" => free, "locked" => locked} ->
        %{
          asset: asset,
          free: String.to_float(free),
          locked: String.to_float(locked),
          total: String.to_float(free) + String.to_float(locked)
        }
      end)

    {:ok, %{
      total_assets: length(filtered_balances),
      balances: filtered_balances,
      raw_data: body
    }}
  end

  def after_focus(body), do: {:ok, body}
end
