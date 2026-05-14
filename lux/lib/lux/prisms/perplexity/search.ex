defmodule Lux.Prisms.Perplexity.Search do
  @moduledoc """
  A prism for performing web searches using Perplexity AI.

  Leverages Perplexity's online models to search the web and return
  sourced answers with citations. Supports domain filtering and
  recency constraints for targeted searches.

  ## Examples

      iex> Search.handler(%{
      ...>   query: "What is the current ETH price?",
      ...   recency_filter: "day"
      ...> }, %{name: "Agent"})
      {:ok, %{
        content: "As of today, ETH is trading at...",
        citations: ["https://coinmarketcap.com/..."],
        search_results: [...],
        model: "sonar-pro",
        cost: %{total_cost: 0.0015, ...}
      }}
  """

  use Lux.Prism,
    name: "Perplexity Web Search",
    description: "Searches the web using Perplexity AI and returns sourced answers with citations",
    input_schema: %{
      type: :object,
      properties: %{
        query: %{
          type: :string,
          description: "The search query to send to Perplexity",
          minLength: 1,
          maxLength: 4000
        },
        model: %{
          type: :string,
          description: "Perplexity model to use (sonar, sonar-pro, sonar-reasoning, sonar-reasoning-pro)",
          enum: ["sonar", "sonar-pro", "sonar-reasoning", "sonar-reasoning-pro"]
        },
        search_domain_filter: %{
          type: :array,
          description: "List of domains to restrict search to (e.g. [\"docs.ethers.org\"])",
          items: %{type: :string}
        },
        recency_filter: %{
          type: :string,
          description: "Time constraint for search results (month, week, day, hour)",
          enum: ["month", "week", "day", "hour"]
        },
        return_images: %{
          type: :boolean,
          description: "Whether to include images in the response",
          default: false
        },
        max_tokens: %{
          type: :integer,
          description: "Maximum tokens in the response",
          minimum: 1,
          maximum: 16384
        }
      },
      required: ["query"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        content: %{
          type: :string,
          description: "The search result content with sourced information"
        },
        citations: %{
          type: :array,
          description: "List of source URLs referenced in the answer",
          items: %{type: :string}
        },
        search_results: %{
          type: :array,
          description: "Detailed search results from Perplexity",
          items: %{type: :object}
        },
        model: %{
          type: :string,
          description: "The Perplexity model used for the search"
        },
        cost: %{
          type: :object,
          description: "Cost breakdown for the API call",
          properties: %{
            input_cost: %{type: :number},
            output_cost: %{type: :number},
            total_cost: %{type: :number}
          }
        }
      },
      required: ["content"]
    }

  alias Lux.Integrations.Perplexity
  require Logger

  @doc """
  Handles the web search request via Perplexity AI.

  Returns `{:ok, %{content: ..., citations: ..., ...}}` on success.
  Returns `{:error, term}` on failure.
  """
  def handler(params, agent) do
    query = Map.get(params, :query)
    model = Map.get(params, :model)
    search_domain_filter = Map.get(params, :search_domain_filter)
    recency_filter = Map.get(params, :recency_filter)
    return_images = Map.get(params, :return_images, false)
    max_tokens = Map.get(params, :max_tokens)

    agent_name = agent[:name] || "Unknown Agent"
    Logger.info("Agent #{agent_name} searching via Perplexity: #{truncate(query, 100)}")

    messages = [%{role: "user", content: query}]

    opts = %{
      model: model,
      search_domain_filter: search_domain_filter,
      recency_filter: recency_filter,
      return_images: return_images,
      temperature: 0.0
    }
    |> maybe_put(:max_tokens, max_tokens)
    |> maybe_put(:plug, Map.get(params, :plug))

    case Perplexity.chat_completion(messages, opts) do
      {:ok, response} ->
        Logger.info("Perplexity search completed for agent #{agent_name}")
        {:ok, %{
          content: response.content,
          citations: response.citations,
          search_results: response.search_results,
          model: response.model,
          cost: response.cost
        }}

      {:error, :invalid_api_key} ->
        Logger.error("Perplexity API key is invalid or not configured")
        {:error, "Perplexity API key is invalid or not configured"}

      {:error, {status, message}} ->
        Logger.error("Perplexity search failed: #{status} - #{message}")
        {:error, "Perplexity search failed: #{status} - #{message}"}

      {:error, error} ->
        Logger.error("Perplexity search error: #{inspect(error)}")
        {:error, "Perplexity search error: #{inspect(error)}"}
    end
  end

  defp truncate(string, max_length) when is_binary(string) do
    if String.length(string) > max_length do
      String.slice(string, 0, max_length) <> "..."
    else
      string
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
