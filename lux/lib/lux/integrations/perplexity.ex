defmodule Lux.Integrations.Perplexity do
  @moduledoc """
  Integration module for Perplexity AI API.

  Provides a centralized HTTP client and configuration for interacting with
  Perplexity's chat completions API, which combines LLM capabilities with
  real-time web search and citation support.

  ## Configuration

  Add to your `config/runtime.exs`:

      config :lux, Lux.Integrations.Perplexity,
        api_key: System.get_env("PERPLEXITY_API_KEY"),
        endpoint: "https://api.perplexity.ai",
        default_model: "sonar-pro"

  And set the environment variable:

      PERPLEXITY_API_KEY="pplx-xxxx"

  ## Available Models

  - `sonar` — Fast, lightweight model ($1/$1 per 1M tokens)
  - `sonar-pro` — Enhanced reasoning and accuracy ($3/$15 per 1M tokens)
  - `sonar-reasoning` — Step-by-step reasoning ($2/$8 per 1M tokens)
  - `sonar-reasoning-pro` — Advanced reasoning ($2/$8 per 1M tokens)

  ## Usage

      # Make a chat completion request
      {:ok, response} = Lux.Integrations.Perplexity.chat_completion([
        %{role: "user", content: "What is DeFi?"}
      ], %{})

      # Search with domain filtering
      {:ok, response} = Lux.Integrations.Perplexity.chat_completion([
        %{role: "user", content: "Latest ETH price"}
      ], %{
        search_domain_filter: ["coinmarketcap.com"],
        recency_filter: "day"
      })
  """

  require Logger

  @default_endpoint "https://api.perplexity.ai"
  @default_model "sonar-pro"

  @type chat_message :: %{
          required(:role) => String.t(),
          required(:content) => String.t()
        }

  @type completion_opts :: %{
          optional(:model) => String.t(),
          optional(:temperature) => float(),
          optional(:max_tokens) => integer(),
          optional(:return_citations) => boolean(),
          optional(:search_domain_filter) => [String.t()],
          optional(:return_images) => boolean(),
          optional(:recency_filter) => String.t(),
          optional(:stream) => boolean(),
          optional(:plug) => {module(), term()}
        }

  @type completion_response :: %{
          id: String.t(),
          model: String.t(),
          content: String.t(),
          citations: [String.t()],
          search_results: [map()],
          usage: map(),
          cost: map()
        }

  @doc """
  Gets the configured Perplexity API key.
  """
  @spec api_key() :: String.t() | nil
  def api_key do
    :lux
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:api_key)
  end

  @doc """
  Gets the configured Perplexity API endpoint.
  Defaults to "https://api.perplexity.ai".
  """
  @spec endpoint() :: String.t()
  def endpoint do
    :lux
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:endpoint, @default_endpoint)
  end

  @doc """
  Gets the configured default model.
  Defaults to "sonar-pro".
  """
  @spec default_model() :: String.t()
  def default_model do
    :lux
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:default_model, @default_model)
  end

  @doc """
  Returns the list of available Perplexity models with their descriptions.
  """
  @spec available_models() :: [map()]
  def available_models do
    [
      %{
        id: "sonar",
        name: "Sonar",
        description: "Fast, lightweight model optimized for quick searches",
        input_price_per_mtok: 1.0,
        output_price_per_mtok: 1.0,
        max_tokens: 16_384
      },
      %{
        id: "sonar-pro",
        name: "Sonar Pro",
        description: "Enhanced reasoning and accuracy for complex queries",
        input_price_per_mtok: 3.0,
        output_price_per_mtok: 15.0,
        max_tokens: 16_384
      },
      %{
        id: "sonar-reasoning",
        name: "Sonar Reasoning",
        description: "Step-by-step reasoning for analytical tasks",
        input_price_per_mtok: 2.0,
        output_price_per_mtok: 8.0,
        max_tokens: 16_384
      },
      %{
        id: "sonar-reasoning-pro",
        name: "Sonar Reasoning Pro",
        description: "Advanced reasoning with deeper analysis",
        input_price_per_mtok: 2.0,
        output_price_per_mtok: 8.0,
        max_tokens: 16_384
      }
    ]
  end

  @doc """
  Returns authentication headers for Perplexity API requests.
  """
  @spec headers() :: [{String.t(), String.t()}]
  def headers do
    [
      {"Authorization", "Bearer #{api_key()}"},
      {"Content-Type", "application/json"}
    ]
  end

  @doc """
  Sends a chat completion request to the Perplexity API.

  ## Parameters

    * `messages` — List of chat messages with `:role` and `:content`
    * `opts` — Optional configuration (model, temperature, etc.)

  ## Returns

    * `{:ok, response}` — Successful completion with parsed response and cost estimate
    * `{:error, :invalid_api_key}` — Authentication failure
    * `{:error, {status, message}}` — API error with status code and message
    * `{:error, term}` — Network or unexpected error
  """
  @spec chat_completion([chat_message()], completion_opts()) ::
          {:ok, completion_response()} | {:error, term()}
  def chat_completion(messages, opts \\ %{}) do
    model = opts[:model] || default_model()
    temperature = opts[:temperature] || 0.2
    max_tokens = opts[:max_tokens]
    return_citations = opts[:return_citations] || true
    search_domain_filter = opts[:search_domain_filter] || []
    return_images = opts[:return_images] || false
    recency_filter = opts[:recency_filter]

    body = %{
      model: model,
      messages: messages,
      temperature: temperature,
      return_citations: return_citations,
      return_images: return_images
    }

    body =
      body
      |> maybe_put(:max_tokens, max_tokens)
      |> maybe_put(:search_domain_filter, if(search_domain_filter == [], do: nil, else: search_domain_filter))
      |> maybe_put(:recency_filter, recency_filter)

    request_opts = [
      method: :post,
      url: "#{endpoint()}/chat/completions",
      json: body,
      headers: headers()
    ]

    request_opts =
      case opts[:plug] do
        nil -> request_opts
        plug -> Keyword.put(request_opts, :plug, plug)
      end

    request_opts = Keyword.merge(request_opts, Application.get_env(:lux, __MODULE__, []))

    request_opts
    |> Req.new()
    |> Req.request()
    |> case do
      {:ok, %{status: 200} = response} ->
        parse_response(response, model)

      {:ok, %{status: 401}} ->
        {:error, :invalid_api_key}

      {:ok, %{status: status, body: %{"error" => %{"message" => message}}}} ->
        {:error, {status, message}}

      {:ok, %{status: status, body: %{"message" => message}}} ->
        {:error, {status, message}}

      {:error, error} ->
        Logger.error("Perplexity API error: #{inspect(error)}")
        {:error, "Perplexity API error: #{inspect(error)}"}
    end
  end

  @doc """
  Estimates the cost of a Perplexity API request.

  ## Model Pricing (per 1M tokens)
  - sonar: $1.00 input / $1.00 output
  - sonar-pro: $3.00 input / $15.00 output
  - sonar-reasoning: $2.00 input / $8.00 output
  - sonar-reasoning-pro: $2.00 input / $8.00 output
  """
  @spec estimate_cost(map(), String.t()) :: map()
  def estimate_cost(usage, model) do
    {input_price, output_price} = model_pricing(model)
    input_tokens = usage["prompt_tokens"] || 0
    output_tokens = usage["completion_tokens"] || 0

    %{
      input_cost: Float.round(input_price * input_tokens / 1_000_000, 6),
      output_cost: Float.round(output_price * output_tokens / 1_000_000, 6),
      total_cost: Float.round((input_price * input_tokens + output_price * output_tokens) / 1_000_000, 6),
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      model: model
    }
  end

  defp parse_response(%{body: body}, model) do
    with %{"choices" => [choice | _]} <- body,
         %{"message" => %{"content" => content}, "finish_reason" => finish_reason} <- choice do
      usage = body["usage"] || %{}
      cost = estimate_cost(usage, model)

      {:ok, %{
        id: body["id"],
        model: body["model"],
        content: content,
        finish_reason: finish_reason,
        citations: body["citations"] || [],
        search_results: body["search_results"] || [],
        usage: usage,
        cost: cost
      }}
    else
      _ -> {:error, "Unexpected response format from Perplexity API"}
    end
  end

  defp model_pricing("sonar"), do: {1.0, 1.0}
  defp model_pricing("sonar-pro"), do: {3.0, 15.0}
  defp model_pricing("sonar-reasoning"), do: {2.0, 8.0}
  defp model_pricing("sonar-reasoning-pro"), do: {2.0, 8.0}
  defp model_pricing(_), do: {3.0, 15.0}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
