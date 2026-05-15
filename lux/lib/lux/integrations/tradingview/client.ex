defmodule Lux.Integrations.TradingView.Client do
  @moduledoc """
  HTTP client for TradingView technical analysis and market data.

  Provides a unified interface to:
  - Fetch candlestick/OHLCV chart data
  - Calculate technical indicators (RSI, MACD, Bollinger Bands, etc.)
  - Manage alerts and signals
  - Stream real-time market data
  - Run strategy backtests

  ## Configuration

  Add to your config:

      config :lux, Lux.Integrations.TradingView.Client,
        api_key: System.get_env("TRADINGVIEW_API_KEY"),
        base_url: "https://api.tradingview.com/v1"

  ## Examples

      iex> Client.request(:get, "/chart/BINANCE:BTCUSDT/candles", %{interval: "1h", limit: 100})
      {:ok, [%{"open" => 42000.0, "high" => 42500.0, ...}, ...]}
  """

  require Logger

  @default_base_url "https://api.tradingview.com/v1"

  @type request_opts :: %{
          optional(:token) => String.t(),
          optional(:json) => map(),
          optional(:params) => map(),
          optional(:headers) => [{String.t(), String.t()}],
          optional(:plug) => {module(), term()}
        }

  @doc """
  Makes a request to the TradingView API.

  ## Parameters

    * `method` - HTTP method (:get, :post, :put, :delete)
    * `path` - API endpoint path (e.g. "/chart/BINANCE:BTCUSDT/candles")
    * `opts` - Request options

  ## Options

    * `:token` - TradingView API key (falls back to config)
    * `:json` - Request body for POST/PUT requests
    * `:params` - Query parameters for GET requests
    * `:headers` - Additional headers
    * `:plug` - Test plug override
  """
  @spec request(atom(), String.t(), request_opts()) :: {:ok, map() | list()} | {:error, term()}
  def request(method, path, opts \\ %{}) do
    config = Application.get_env(:lux, __MODULE__, [])
    base_url = Keyword.get(config, :base_url, @default_base_url)
    token = opts[:token] || Keyword.get(config, :api_key) || System.get_env("TRADINGVIEW_API_KEY")

    request_config = [
      method: method,
      url: base_url <> path,
      headers: build_headers(token) ++ (opts[:headers] || []),
      json: opts[:json],
      params: opts[:params]
    ]
    |> Keyword.merge(config)
    |> maybe_add_plug(opts[:plug])
    |> Req.new()
    |> Req.request()

    case request_config do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: 401}} ->
        Logger.error("TradingView API: Unauthorized - check API key")
        {:error, :unauthorized}

      {:ok, %{status: 429}} ->
        Logger.warning("TradingView API: Rate limited")
        {:error, :rate_limited}

      {:ok, %{status: status, body: %{"error" => error}}} ->
        Logger.error("TradingView API error: #{status} - #{error}")
        {:error, {status, error}}

      {:ok, %{status: status, body: body}} ->
        Logger.error("TradingView API error: #{status} - #{inspect(body)}")
        {:error, {status, body}}

      {:error, error} ->
        Logger.error("TradingView API request failed: #{inspect(error)}")
        {:error, error}
    end
  end

  defp build_headers(nil), do: [{"Content-Type", "application/json"}]
  defp build_headers(token) do
    [
      {"Authorization", "Bearer #{token}"},
      {"Content-Type", "application/json"}
    ]
  end

  defp maybe_add_plug(options, nil), do: options
  defp maybe_add_plug(options, plug), do: Keyword.put(options, :plug, plug)
end
