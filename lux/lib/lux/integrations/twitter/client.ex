defmodule Lux.Integrations.Twitter.Client do
  @moduledoc """
  HTTP client for Twitter API v2 requests with OAuth 2.0 authentication.

  Handles authentication, rate limiting, and request composition for all Twitter
  API interactions within Lux.
  """

  require Logger

  @base_url "https://api.twitter.com/2"
  @upload_url "https://upload.twitter.com/1.1"

  @type request_opts :: %{
    optional(:token) => String.t(),
    optional(:json) => map(),
    optional(:headers) => [{String.t(), String.t()}],
    optional(:params) => map(),
    optional(:plug) => {module(), term()}
  }

  @doc """
  Makes an authenticated request to the Twitter API v2.

  ## Parameters

    * `method` - HTTP method (:get, :post, :put, :delete)
    * `path` - API endpoint path (e.g. "/tweets")
    * `opts` - Request options

  ## Examples

      iex> Twitter.Client.request(:post, "/tweets", %{
      ...>   json: %{text: "Hello from Lux!"}
      ...> })
      {:ok, %{"data" => %{"id" => "123", "text" => "Hello from Lux!"}}}
  """
  @spec request(atom(), String.t(), request_opts()) :: {:ok, map()} | {:error, term()}
  def request(method, path, opts \\ %{}) do
    token = opts[:token] || get_bearer_token()
    url = @base_url <> path

    headers = [
      {"Content-Type", "application/json"},
      {"Authorization", "Bearer #{token}"}
    ] ++ Keyword.get(opts, :headers, [])

    request_params = [
      method: method,
      url: url,
      headers: headers
    ]

    request_params =
      case opts[:json] do
        nil -> request_params
        body -> Keyword.put(request_params, :json, body)
      end

    request_params =
      case opts[:params] do
        nil -> request_params
        params -> Keyword.put(request_params, :params, params)
      end

    request_params =
      request_params
      |> Keyword.merge(Application.get_env(:lux, __MODULE__, []))
      |> maybe_add_plug(opts[:plug])

    Req.new(request_params)
    |> Req.request()
    |> handle_response()
  end

  @doc """
  Makes a request to the Twitter media upload API.

  Used for uploading images, videos, and GIFs to attach to tweets.
  """
  @spec upload_request(atom(), String.t(), request_opts()) :: {:ok, map()} | {:error, term()}
  def upload_request(method, path, opts \\ %{}) do
    token = opts[:token] || get_bearer_token()
    url = @upload_url <> path

    headers = [
      {"Authorization", "Bearer #{token}"}
    ] ++ Keyword.get(opts, :headers, [])

    request_params = [
      method: method,
      url: url,
      headers: headers
    ]

    request_params =
      case opts[:json] do
        nil -> request_params
        body -> Keyword.put(request_params, :json, body)
      end

    request_params =
      request_params
      |> Keyword.merge(Application.get_env(:lux, __MODULE__, []))
      |> maybe_add_plug(opts[:plug])

    Req.new(request_params)
    |> Req.request()
    |> handle_response()
  end

  defp handle_response(result) do
    case result do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: 429, headers: headers}} ->
        reset = get_rate_limit_reset(headers)
        {:error, {:rate_limited, reset}}

      {:ok, %{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %{status: status, body: %{"errors" => errors}}} ->
        {:error, {status, errors}}

      {:ok, %{status: status, body: body}} ->
        {:error, {status, body}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp get_rate_limit_reset(headers) do
    case List.keyfind(headers, "x-rate-limit-reset", 0) do
      {_, value} -> String.to_integer(value)
      nil -> System.system_time(:second) + 900
    end
  end

  defp get_bearer_token do
    Application.get_env(:lux, :twitter_bearer_token, System.get_env("TWITTER_BEARER_TOKEN", ""))
  end

  defp maybe_add_plug(options, nil), do: options
  defp maybe_add_plug(options, plug), do: Keyword.put(options, :plug, plug)
end
