defmodule Lux.Prisms.Perplexity.ModelInfo do
  @moduledoc """
  A prism for retrieving available Perplexity AI models and their capabilities.

  Returns model metadata including pricing, descriptions, and recommended
  use cases to help agents select the optimal model for their task.

  ## Examples

      iex> ModelInfo.handler(%{}, %{name: "Agent"})
      {:ok, %{
        models: [
          %{
            id: "sonar",
            name: "Sonar",
            description: "Fast, lightweight model...",
            input_price_per_mtok: 1.0,
            output_price_per_mtok: 1.0
          },
          ...
        ],
        default_model: "sonar-pro"
      }}
  """

  use Lux.Prism,
    name: "Perplexity Model Info",
    description: "Returns available Perplexity AI models with pricing and capabilities",
    input_schema: %{
      type: :object,
      properties: %{
        filter: %{
          type: :string,
          description: "Optional filter: 'reasoning' for reasoning models, 'fast' for lightweight models",
          enum: ["reasoning", "fast", "all"]
        }
      }
    },
    output_schema: %{
      type: :object,
      properties: %{
        models: %{
          type: :array,
          description: "List of available Perplexity models",
          items: %{type: :object}
        },
        default_model: %{
          type: :string,
          description: "The configured default model"
        },
        total_count: %{
          type: :integer,
          description: "Total number of available models"
        }
      },
      required: ["models", "default_model"]
    }

  alias Lux.Integrations.Perplexity

  @doc """
  Returns available Perplexity models filtered by the given criteria.
  """
  def handler(params, _agent) do
    filter = Map.get(params, :filter, "all")
    all_models = Perplexity.available_models()
    default = Perplexity.default_model()

    filtered = case filter do
      "reasoning" -> Enum.filter(all_models, &String.contains?(&1.id, "reasoning"))
      "fast" -> Enum.filter(all_models, &(!String.contains?(&1.id, "reasoning")))
      _ -> all_models
    end

    {:ok, %{
      models: filtered,
      default_model: default,
      total_count: length(filtered)
    }}
  end
end
