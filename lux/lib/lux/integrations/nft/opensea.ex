defmodule Lux.Integrations.NFT.OpenSea do
  @moduledoc """
  OpenSea API v2 integration for NFT marketplace data.

  Provides access to collection statistics, active listings, sales events,
  and collection metadata through the OpenSea API.

  ## Configuration

      config :lux, Lux.Integrations.NFT.OpenSea,
        api_key: System.get_env("OPENSEA_API_KEY"),
        base_url: "https://api.opensea.io"

  Environment variables:

      OPENSEA_API_KEY="your-api-key"

  ## Usage

      alias Lux.Integrations.NFT.OpenSea

      # Get collection stats
      {:ok, collection} = OpenSea.get_collection("bored-ape-yacht-club")

      # Get active listings
      {:ok, listings} = OpenSea.get_listings("bored-ape-yacht-club", limit: 10)

      # Get sales events
      {:ok, events} = OpenSea.get_events("bored-ape-yacht-club", type: "sale", limit: 20)
  """

  require Logger

  @default_base_url "https://api.opensea.io"
  @default_timeout 15_000

  @type collection :: %{
    slug: String.t(),
    name: String.t(),
    description: String.t(),
    image_url: String.t(),
    floor_price: float() | nil,
    total_supply: integer(),
    owners_count: integer(),
    total_volume: float(),
    stats: map()
  }

  @type listing :: %{
    token_id: String.t(),
    price: float(),
    currency: String.t(),
    seller: String.t(),
    expires_at: String.t()
  }

  @type sale_event :: %{
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

  @spec api_key() :: String.t() | nil
  def api_key do
    :lux
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:api_key)
  end

  @spec headers() :: [{String.t(), String.t()}]
  def headers do
    base = [
      {"accept", "application/json"},
      {"content-type", "application/json"}
    ]

    case api_key() do
      nil -> base
      key -> [{"x-api-key", key} | base]
    end
  end

  # --- Public API ---

  @doc """
  Fetches collection data including statistics.

  ## Parameters

    * `slug` - The collection slug (e.g., "bored-ape-yacht-club")

  ## Examples

      {:ok, collection} = OpenSea.get_collection("bored-ape-yacht-club")
      # => %{slug: "bored-ape-yacht-club", floor_price: 12.5, ...}
  """
  @spec get_collection(String.t()) :: {:ok, collection()} | {:error, term()}
  def get_collection(slug) do
    "/api/v2/collections/#{URI.encode(slug)}"
    |> request()
    |> case do
      {:ok, body} -> {:ok, parse_collection(body)}
      error -> error
    end
  end

  @doc """
  Fetches active listings for a collection.

  ## Parameters

    * `slug` - The collection slug
    * `opts` - Options (limit: integer, cursor: string)

  ## Examples

      {:ok, listings} = OpenSea.get_listings("bored-ape-yacht-club", limit: 10)
  """
  @spec get_listings(String.t(), keyword()) :: {:ok, [listing()]} | {:error, term()}
  def get_listings(slug, opts \\ []) do
    query = build_query(opts)

    "/api/v2/collections/#{URI.encode(slug)}/listings#{query}"
    |> request()
    |> case do
      {:ok, %{"listings" => listings}} -> {:ok, Enum.map(listings, &parse_listing/1)}
      {:ok, body} when is_list(body) -> {:ok, Enum.map(body, &parse_listing/1)}
      error -> error
    end
  end

  @doc """
  Fetches sales events for a collection.

  ## Parameters

    * `slug` - The collection slug
    * `opts` - Options (type: string, limit: integer, cursor: string,
               after: timestamp, before: timestamp)

  ## Examples

      {:ok, events} = OpenSea.get_events("bored-ape-yacht-club", type: "sale", limit: 20)
  """
  @spec get_events(String.t(), keyword()) :: {:ok, [sale_event()]} | {:error, term()}
  def get_events(slug, opts \\ []) do
    params =
      opts
      |> Enum.into(%{})
      |> Map.put("collection_slug", slug)
      |> build_query_from_map()

    "/api/v2/events#{params}"
    |> request()
    |> case do
      {:ok, %{"asset_events" => events}} -> {:ok, Enum.map(events, &parse_event/1)}
      {:ok, body} when is_list(body) -> {:ok, Enum.map(body, &parse_event/1)}
      error -> error
    end
  end

  @doc """
  Fetches collection statistics (floor price, volume, owners).

  Combines collection data with computed stats.

  ## Examples

      {:ok, stats} = OpenSea.get_collection_stats("bored-ape-yacht-club")
      # => %{floor_price: 12.5, total_volume: 650000.0, owners: 6400, ...}
  """
  @spec get_collection_stats(String.t()) :: {:ok, map()} | {:error, term()}
  def get_collection_stats(slug) do
    with {:ok, collection} <- get_collection(slug) do
      {:ok, %{
        slug: slug,
        floor_price: collection[:floor_price],
        total_volume: get_in(collection, [:stats, :total_volume]) || 0.0,
        owners_count: collection[:owners_count],
        total_supply: collection[:total_supply],
        one_day_volume: get_in(collection, [:stats, :one_day_volume]) || 0.0,
        seven_day_volume: get_in(collection, [:stats, :seven_day_volume]) || 0.0,
        thirty_day_volume: get_in(collection, [:stats, :thirty_day_volume]) || 0.0,
        one_day_change: get_in(collection, [:stats, :one_day_change]) || 0.0,
        seven_day_change: get_in(collection, [:stats, :seven_day_change]) || 0.0,
        thirty_day_change: get_in(collection, [:stats, :thirty_day_change]) || 0.0,
        one_day_sales: get_in(collection, [:stats, :one_day_sales]) || 0,
        seven_day_sales: get_in(collection, [:stats, :seven_day_sales]) || 0,
        thirty_day_sales: get_in(collection, [:stats, :thirty_day_sales]) || 0,
        source: "opensea"
      }}
    end
  end

  # --- HTTP Client ---

  @spec request(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defp request(path, opts \\ []) do
    url = base_url() <> path

    Logger.debug("OpenSea API request: #{url}")

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
      Logger.error("OpenSea API request failed: #{inspect(e)}")
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
    Logger.warning("OpenSea API rate limited")
    {:error, :rate_limited}
  end

  defp handle_response({:ok, %HTTPoison.Response{status_code: 401}}) do
    {:error, :unauthorized}
  end

  defp handle_response({:ok, %HTTPoison.Response{status_code: 404}}) do
    {:error, :not_found}
  end

  defp handle_response({:ok, %HTTPoison.Response{status_code: code, body: body}}) do
    Logger.warning("OpenSea API error: #{code} - #{truncate(body, 200)}")
    {:error, {code, body}}
  end

  defp handle_response({:error, %HTTPoison.Error{reason: reason}}) do
    Logger.error("OpenSea HTTP error: #{inspect(reason)}")
    {:error, reason}
  end

  # --- Parsers ---

  @spec parse_collection(map()) :: collection()
  defp parse_collection(data) do
    %{
      slug: data["collection"] || data["slug"],
      name: data["name"],
      description: data["description"],
      image_url: data["image_url"],
      floor_price: parse_price(data["floor_price"]),
      total_supply: data["total_supply"] || 0,
      owners_count: get_in(data, ["owners", "count"]) || data["owners_count"] || 0,
      total_volume: parse_price(data["total_volume"]),
      stats: parse_stats(data["stats"] || %{})
    }
  end

  @spec parse_stats(map()) :: map()
  defp parse_stats(stats) do
    %{
      total_volume: parse_price(stats["total_volume"]),
      one_day_volume: parse_price(stats["one_day_volume"]),
      seven_day_volume: parse_price(stats["seven_day_volume"]),
      thirty_day_volume: parse_price(stats["thirty_day_volume"]),
      one_day_change: stats["one_day_change"] || 0.0,
      seven_day_change: stats["seven_day_change"] || 0.0,
      thirty_day_change: stats["thirty_day_change"] || 0.0,
      one_day_sales: stats["one_day_sales"] || 0,
      seven_day_sales: stats["seven_day_sales"] || 0,
      thirty_day_sales: stats["thirty_day_sales"] || 0,
      total_sales: stats["total_sales"] || 0,
      num_owners: stats["num_owners"] || 0,
      average_price: parse_price(stats["average_price"]),
      market_cap: parse_price(stats["market_cap"])
    }
  end

  @spec parse_listing(map()) :: listing()
  defp parse_listing(data) do
    %{
      token_id: data["token_id"] || get_in(data, ["protocol_data", "parameters", "token_id"]),
      price: parse_listing_price(data),
      currency: parse_currency(data),
      seller: data["seller"] || get_in(data, ["protocol_data", "parameters", "seller"]),
      expires_at: data["expiration_time"] || data["expires_at"]
    }
  end

  @spec parse_event(map()) :: sale_event()
  defp parse_event(data) do
    %{
      token_id: data["token_id"] || get_in(data, ["nft", "identifier"]),
      price: parse_price(data["total_price"] || data["price"]),
      currency: data["payment_token"] || data["currency"],
      seller: data["seller"] || get_in(data, ["seller", "address"]),
      buyer: data["buyer"] || get_in(data, ["winner_account", "address"]),
      timestamp: data["event_timestamp"] || data["created_date"],
      transaction_hash: data["transaction"] || get_in(data, ["transaction", "hash"])
    }
  end

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

  @spec parse_listing_price(map()) :: float() | nil
  defp parse_listing_price(data) do
    price = data["price"] || data["current_price"] || data["base_price"]
    parse_price(price)
  end

  @spec parse_currency(map()) :: String.t()
  defp parse_currency(data) do
    data["payment_token"] || data["currency"] || "ETH"
  end

  # --- Helpers ---

  @spec build_query(keyword()) :: String.t()
  defp build_query(opts) do
    case URI.encode_query(Enum.into(opts, %{})) do
      "" -> ""
      query -> "?#{query}"
    end
  end

  @spec build_query_from_map(map()) :: String.t()
  defp build_query_from_map(params) do
    filtered = params |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Enum.into(%{})
    case URI.encode_query(filtered) do
      "" -> ""
      query -> "?#{query}"
    end
  end

  @spec truncate(String.t(), integer()) :: String.t()
  defp truncate(str, len) when is_binary(str) do
    if String.length(str) > len, do: String.slice(str, 0, len) <> "...", else: str
  end
  defp truncate(_, _), do: ""

  @spec http_client() :: module()
  defp http_client do
    :lux
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:http_client, HTTPoison)
  end
end
