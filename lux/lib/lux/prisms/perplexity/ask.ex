defmodule Lux.Prisms.Perplexity.Ask do
  @moduledoc """
  A prism for asking knowledge-intensive questions using Perplexity AI.

  Optimized for complex Q&A scenarios where depth of reasoning matters.
  Uses higher temperature and reasoning-capable models by default to
  provide thorough, well-sourced answers.

  ## Examples

      iex> Ask.handler(%{
      ...>   question: "Explain the mechanics of Uniswap v3 concentrated liquidity",
      ...>   model: "sonar-reasoning"
      ...> }, %{name: "Agent"})
      {:ok, %{
        content: "Uniswap v3 introduced concentrated liquidity...",
        citations: ["https://uniswap.org/whitepaper-v3.pdf"],
        model: "sonar-reasoning",
        cost: %{total_cost: 0.008, ...}
      }}
  """

  use Lux.Prism,
    name: "Perplexity Ask",
    description: "Asks knowledge-intensive questions to Perplexity AI with reasoning and citations",
    input_schema: %{
      type: :object,
      properties: %{
        question: %{
          type: :string,
          description: "The question to ask Perplexity AI",
          minLength: 1,
          maxLength: 4000
        },
        context: %{
          type: :string,
          description: "Additional context to provide before the question",
          maxLength: 8000
        },
        model: %{
          type: :string,
          description: "Perplexity model to use (default: sonar-pro)",
          enum: ["sonar", "sonar-pro", "sonar-reasoning", "sonar-reasoning-pro"]
        },
        temperature: %{
          type: :number,
          description: "Response creativity (0.0 = precise, 1.0 = creative)",
          minimum: 0.0,
          maximum: 1.0,
          default: 0.3
        },
        search_domain_filter: %{
          type: :array,
          description: "List of domains to restrict search to",
          items: %{type: :string}
        },
        return_citations: %{
          type: :boolean,
          description: "Whether to include citations in the response",
          default: true
        },
        max_tokens: %{
          type: :integer,
          description: "Maximum tokens in the response",
          minimum: 1,
          maximum: 16384
        }
      },
      required: ["question"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        content: %{
          type: :string,
          description: "The answer from Perplexity AI"
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
          description: "The Perplexity model used"
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
  Handles a Q&A request via Perplexity AI.

  Returns `{:ok, %{content: ..., citations: ..., ...}}` on success.
  Returns `{:error, term}` on failure.
  """
  def handler(params, agent) do
    question = Map.get(params, :question)
    context = Map.get(params, :context)
    model = Map.get(params, :model, "sonar-pro")
    temperature = Map.get(params, :temperature, 0.3)
    search_domain_filter = Map.get(params, :search_domain_filter)
    return_citations = Map.get(params, :return_citations, true)
    max_tokens = Map.get(params, :max_tokens)

    agent_name = agent[:name] || "Unknown Agent"
    Logger.info("Agent #{agent_name} asking Perplexity: #{truncate(question, 100)}")

    content = build_content(question, context)
    messages = [%{role: "user", content: content}]

    opts = %{
      model: model,
      temperature: temperature,
      return_citations: return_citations,
      search_domain_filter: search_domain_filter
    }
    |> maybe_put(:max_tokens, max_tokens)
    |> maybe_put(:plug, Map.get(params, :plug))

    case Perplexity.chat_completion(messages, opts) do
      {:ok, response} ->
        Logger.info("Perplexity Q&A completed for agent #{agent_name}")
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
        Logger.error("Perplexity Q&A failed: #{status} - #{message}")
        {:error, "Perplexity Q&A failed: #{status} - #{message}"}

      {:error, error} ->
        Logger.error("Perplexity Q&A error: #{inspect(error)}")
        {:error, "Perplexity Q&A error: #{inspect(error)}"}
    end
  end

  defp build_content(question, nil), do: question
  defp build_content(question, context) do
    "Context:\n#{context}\n\nQuestion:\n#{question}"
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
