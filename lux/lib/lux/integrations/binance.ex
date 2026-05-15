defmodule Lux.Integrations.Binance do
  @moduledoc """
  Common settings and functions for Binance API integration.

  Provides shared configuration for both REST API and WebSocket connections,
  including authentication, rate limiting, and endpoint management.
  """

  @doc """
  Common request headers for Binance REST API calls.
  """
  def headers do
    [{"Content-Type", "application/json"}, {"X-MBX-APIKEY", api_key()}]
  end

  @doc """
  Authentication configuration for Binance lenses.
  Uses HMAC-SHA256 signed requests for authenticated endpoints.
  """
  def auth do
    %{
      type: :custom,
      auth_function: &__MODULE__.sign_request/1
    }
  end

  @doc """
  Returns the base URL for Binance REST API.
  Can be configured to use testnet via application config.
  """
  @spec base_url() :: String.t()
  def base_url do
    Application.get_env(:lux, :binance, [])
    |> Keyword.get(:base_url, "https://api.binance.com")
  end

  @doc """
  Returns the base URL for Binance Futures REST API.
  """
  @spec futures_url() :: String.t()
  def futures_url do
    Application.get_env(:lux, :binance, [])
    |> Keyword.get(:futures_url, "https://fapi.binance.com")
  end

  @doc """
  Returns the WebSocket base URL for Binance streams.
  """
  @spec ws_url() :: String.t()
  def ws_url do
    Application.get_env(:lux, :binance, [])
    |> Keyword.get(:ws_url, "wss://stream.binance.com:9443/ws")
  end

  @doc """
  Returns the WebSocket base URL for Binance Futures streams.
  """
  @spec futures_ws_url() :: String.t()
  def futures_ws_url do
    Application.get_env(:lux, :binance, [])
    |> Keyword.get(:futures_ws_url, "wss://fstream.binance.com/ws")
  end

  @doc """
  Signs a request with HMAC-SHA256 signature for authenticated Binance endpoints.
  Appends the `signature` parameter and the API key header.
  """
  @spec sign_request(map()) :: map()
  def sign_request(%{params: params} = lens) do
    timestamp = System.system_time(:millisecond)
    params_with_ts = Map.put(params, :timestamp, timestamp)
    query_string = URI.encode_query(params_with_ts)
    signature = sign(query_string)
    signed_params = Map.put(params_with_ts, :signature, signature)
    %{lens | params: signed_params, headers: headers()}
  end

  def sign_request(lens), do: lens

  @doc """
  Creates an HMAC-SHA256 signature for the given query string.
  """
  @spec sign(String.t()) :: String.t()
  def sign(query_string) do
    :crypto.mac(:hmac, :sha256, secret_key(), query_string)
    |> Base.encode16(case: :LOWER)
  end

  @doc """
  Rate limit configuration for Binance API.
  Returns the minimum interval between requests in milliseconds.
  """
  @spec rate_limit() :: pos_integer()
  def rate_limit do
    Application.get_env(:lux, :binance, [])
    |> Keyword.get(:rate_limit_ms, 100)
  end

  defp api_key do
    Application.fetch_env!(:lux, :api_keys)
    |> Keyword.get(:binance_api_key)
  end

  defp secret_key do
    Application.fetch_env!(:lux, :api_keys)
    |> Keyword.get(:binance_secret_key)
  end
end
