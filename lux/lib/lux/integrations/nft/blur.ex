defmodule Lux.Integrations.NFT.Blur do
  @moduledoc """
  Blur API integration for NFT marketplace data.

  Provides access to collection data, price tracking, and sales monitoring
  through the Blur marketplace API.

  ## Configuration

      config :lux, Lux.Integrations.NFT.Blur,
        base_url: "https://api.blur.io",
        auth_token: System.get_env("BLUR_AUTH_TOKEN")

  ## Usage

      alias Lux.Integrations.NFT.Blur

      # Get collection data
      {:ok, collection} = Blur.get_collection("0xBC4CA0EdA7647A8aB7C2061c2E118A18a936f13D")

      # Get price history
      {:ok, prices} = Blur.get_price_history("0xBC4CA0EdA7647A8aB7C2061c2E118A18a936f13D")

      # Get recent sales
      {:ok, sales} = Blur.get_sales("0xBC4CA0EdA7647A8aB7C2061c2E118A18a936f13D", limit: 10)
  """

  require Logger

  @default_base_url "https://api.blur.io"
  @default_timeout 15_000

  @type collection :: %{
    address: String.t(),
    name: String.t(),
    floor_price: float() | nil,
    total_volume: float(),
    total_supply: integer(),
    owners_count: integer(),
    stats: map()
  }

  @type price_point :: %{
    timestamp: String.t(),
    price: float(),
    currency: String.t()
  }

  @type sale :: %{
    token_id: String.t(),
    price: float(),
    currency: String.t(),
    seller: String.t(),
    buyer: String.t(),
    timestamp: String.t(),
    transaction_hash: String.t()
  }

  # --- Configuration ---

  @spec base_url() :: String.t()
  def base_url do
    :lux
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:base_url, @default_base_url)
  end

  @spec auth_token() :: String.t() | nil
  def auth_token do
    :lux
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:auth_token)
  end

  @spec headers() :: [{String.t(), String.t()}]
  def headers do
    base = [
      {"accept", "application/json"},
      {"content-type", "application/json"},
      {"user-agent", "Lux/1.0"}
    ]

    case auth_token() do
      nil -> base
      token -> [{"authorization", "Bearer #{token}"} | base]
    end
  end

  # --- Public API ---

  @doc """
  Fetches collection data from Blur.

  ## Parameters

    * `address` - The collection contract address

  ## Examples

      {:ok, collection} = Blur.get_collection("0xBC4CA0EdA7647A8aB7C2061c2E118A18a936f13D")
  """
  @spec get_collection(String.t()) :: {:ok, collection()} | {:error, term()}
  def get_collection(address) do
    "/api/v1/collections/#{address}"
    |> request()
    |> case do
      {:ok, body} -> {:ok, parse_collection(body)}
      error -> error
    end
  end

  @doc """
  Fetches price history for a collection.

  ## Parameters

    * `address` - The collection contract address
    * `opts` - Options (period: "1d" | "7d" | "30d", interval: "1h" | "1d")

  ## Examples

      {:ok, prices} = Blur.get_price_history("0xBC4CA0Ed...", period: "7d")
  """
  @spec get_price_history(String.t(), keyword()) :: {:ok, [price_point()]} | {:error, term()}
  def get_price_history(address, opts \\ []) do
    query = build_query(opts)

    "/api/v1/collections/#{address}/prices#{query}"
    |> request()
    |> case do
      {:ok, %{"prices" => prices}} -> {:ok, Enum.map(prices, &parse_price_point/1)}
      {:ok, body} when is_list(body) -> {:ok, Enum.map(body, &parse_price_point/1)}
      error -> error
    end
  end

  @doc """
  Fetches recent sales for a collection.

  ## Parameters

    * `address` - The collection contract address
    * `opts` - Options (limit: integer, cursor: string)

  ## Examples

      {:ok, sales} = Blur.get_sales("0xBC4CA0Ed...", limit: 10)
  """
  @spec get_sales(String.t(), keyword()) :: {:ok, [sale()]} | {:error, term()}
  def get_sales(address, opts \\ []) do
    query = build_query(opts)

    "/api/v1/collections/#{address}/sales#{query}"
    |> request()
    |> case do
      {:ok, %{"sales" => sales}} -> {:ok, Enum.map(sales, &parse_sale/1)}
      {:ok, body} when is_list(body) -> {:ok, Enum.map(body, &parse_sale/1)}
      error -> error
    end
  end

  @doc """
  Fetches collection statistics from Blur.

  ## Examples

      {:ok, stats} = Blur.get_collection_stats("0xBC4CA0Ed...")
      # => %{floor_price: 12.5, total_volume: 650000.0, ...}
  """
  @spec get_collection_stats(String.t()) :: {:ok, map()} | {:error, term()}
  def get_collection_stats(address) do
    with {:ok, collection} <- get_collection(address) do
      {:ok, %{
        address: address,
        floor_price: collection[:floor_price],
        total_volume: collection[:total_volume],
        total_supply: collection[:total_supply],
        owners_count: collection[:owners_count],
        source: "blur"
      }}
    end
  end

  # --- HTTP Client ---

  @spec request(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defp request(path, opts \\ []) do
    url = base_url() <> path

    Logger.debug("Blur API request: #{url}")

    http_client().request(
      :get,
      url,
      headers(),
      nil,
      Keyword.merge([recv_timeout: @default_timeout], opts)
    )
    |> handle_response()
  rescue
    e ->
      Logger.error("Blur API request failed: #{inspect(e)}")
      {:error, {:request_failed, Exception.message(e)}}
  end

  @spec handle_response(tuple()) :: {:ok, map()} | {:error, term()}
  defp handle_response({:ok, %HTTPoison.Response{status_code: code, body: body}})
       when code in 200..299 do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> {:ok, %{"raw" => body}}
    end
  end

  defp handle_response({:ok, %HTTPoison.Response{status_code: 429}}) do
    Logger.warning("Blur API rate limited")
    {:error, :rate_limited}
  end

  defp handle_response({:ok, %HTTPoison.Response{status_code: 401}}) do
    {:error, :unauthorized}
  end

  defp handle_response({:ok, %HTTPoison.Response{status_code: code, body: body}}) do
    Logger.warning("Blur API error: #{code}")
    {:error, {code, body}}
  end

  defp handle_response({:error, %HTTPoison.Error{reason: reason}}) do
    Logger.error("Blur HTTP error: #{inspect(reason)}")
    {:error, reason}
  end

  # --- Parsers ---

  @spec parse_collection(map()) :: collection()
  defp parse_collection(data) do
    %{
      address: data["address"],
      name: data["name"],
      floor_price: parse_price(data["floorPrice"] || data["floor_price"]),
      total_volume: parse_price(data["totalVolume"] || data["total_volume"]) || 0.0,
      total_supply: data["totalSupply"] || data["total_supply"] || 0,
      owners_count: data["ownersCount"] || data["owners_count"] || 0,
      stats: %{
        one_day_volume: parse_price(data["oneDayVolume"] || data["one_day_volume"]),
        seven_day_volume: parse_price(data["sevenDayVolume"] || data["seven_day_volume"]),
        thirty_day_volume: parse_price(data["thirtyDayVolume"] || data["thirty_day_volume"]),
        one_day_sales: data["oneDaySales"] || data["one_day_sales"] || 0,
        seven_day_sales: data["sevenDaySales"] || data["seven_day_sales"] || 0,
        thirty_day_sales: data["thirtyDaySales"] || data["thirty_day_sales"] || 0
      }
    }
  end

  @spec parse_price_point(map()) :: price_point()
  defp parse_price_point(data) do
    %{
      timestamp: data["timestamp"] || data["date"],
      price: parse_price(data["price"] || data["value"]) || 0.0,
      currency: data["currency"] || "ETH"
    }
  end

  @spec parse_sale(map()) :: sale()
  defp parse_sale(data) do
    %{
      token_id: data["tokenId"] || data["token_id"],
      price: parse_price(data["price"] || data["salePrice"]) || 0.0,
      currency: data["currency"] || "ETH",
      seller: data["seller"] || data["fromAddress"],
      buyer: data["buyer"] || data["toAddress"],
      timestamp: data["timestamp"] || data["createdAt"],
      transaction_hash: data["txnHash"] || data["transaction_hash"]
    }
  end

  # --- Helpers ---

  @spec parse_price(term()) :: float() | nil
  defp parse_price(nil), do: nil
  defp parse_price(price) when is_number(price), do: price / 1.0
  defp parse_price(price) when is_binary(price) do
    case Float.parse(price) do
      {f, _} -> f
      :error -> nil
    end
  end
  defp parse_price(_), do: nil

  @spec build_query(keyword()) :: String.t()
  defp build_query(opts) do
    filtered = opts |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    case URI.encode_query(Enum.into(filtered, %{})) do
      "" -> ""
      query -> "?#{query}"
    end
  end

  @spec http_client() :: module()
  defp http_client do
    :lux
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:http_client, HTTPoison)
  end
end
