defmodule Lux.Integrations.Binance.Client do
  @moduledoc """
  HTTP client for Binance REST API requests.

  Handles authenticated and unauthenticated requests with rate limiting,
  error handling, and automatic signature generation.
  """

  require Logger

  alias Lux.Integrations.Binance

  @type request_opts :: %{
    optional(:signed) => boolean(),
    optional(:params) => map(),
    optional(:method) => atom(),
    optional(:base_url) => String.t()
  }

  @doc """
  Makes a request to the Binance REST API.
  """
  @spec request(atom(), String.t(), request_opts()) :: {:ok, map()} | {:error, term()}
  def request(method, path, opts \\ %{}) do
    base_url = opts[:base_url] || Binance.base_url()
    url = base_url <> path
    signed = opts[:signed] || false
    params = opts[:params] || %{}

    {final_url, final_params} =
      if signed do
        params_with_ts = Map.put(params, :timestamp, System.system_time(:millisecond))
        query_string = URI.encode_query(params_with_ts)
        signature = Binance.sign(query_string)
        signed_params = Map.put(params_with_ts, :signature, signature)
        {url, signed_params}
      else
        {url, params}
      end

    request_config =
      [
        method: method,
        url: final_url,
        headers: Binance.headers(),
        max_retries: 2
      ]
      |> add_params_or_body(method, final_params)
      |> Keyword.merge(Application.get_env(:lux, __MODULE__, []))

    case Req.request(Req.new(request_config)) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: 429, headers: headers}} ->
        retry_after = get_retry_after(headers)
        Logger.warning("Binance rate limit hit, retry after #{retry_after}ms")
        {:error, {:rate_limited, retry_after}}

      {:ok, %{status: 418}} ->
        Logger.error("Binance IP ban - too many requests")
        {:error, :ip_banned}

      {:ok, %{status: 401}} ->
        {:error, :invalid_api_key}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Binance API error: #{status} - #{inspect(body)}")
        {:error, {status, body}}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, {:transport_error, reason}}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Makes a signed GET request to the Binance API.
  """
  @spec signed_get(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def signed_get(path, params \\ %{}) do
    request(:get, path, %{signed: true, params: params})
  end

  @doc """
  Makes a signed POST request to the Binance API.
  """
  @spec signed_post(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def signed_post(path, params \\ %{}) do
    request(:post, path, %{signed: true, params: params})
  end

  @doc """
  Makes a signed DELETE request to the Binance API.
  """
  @spec signed_delete(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def signed_delete(path, params \\ %{}) do
    request(:delete, path, %{signed: true, params: params})
  end

  @doc """
  Makes a request to the Binance Futures API.
  """
  @spec futures_request(atom(), String.t(), request_opts()) :: {:ok, map()} | {:error, term()}
  def futures_request(method, path, opts \\ %{}) do
    opts = Map.put(opts, :base_url, Binance.futures_url())
    request(method, path, opts)
  end

  defp add_params_or_body(config, :get, params) when map_size(params) > 0 do
    Keyword.put(config, :params, params)
  end

  defp add_params_or_body(config, method, params) when method in [:post, :put, :delete] and map_size(params) > 0 do
    Keyword.put(config, :json, params)
  end

  defp add_params_or_body(config, _method, _params), do: config

  defp get_retry_after(headers) do
    case Enum.find(headers, fn {key, _} -> String.downcase(key) == "retry-after" end) do
      {_, value} -> String.to_integer(value) * 1000
      nil -> 60_000
    end
  end
end
