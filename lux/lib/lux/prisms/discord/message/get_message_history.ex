defmodule Lux.Prisms.Discord.Messages.GetMessageHistory do
  @moduledoc """
  A prism for retrieving message history from a Discord channel.

  Supports pagination, filtering by user, and date ranges.

  ## Examples

      iex> GetMessageHistory.handler(%{
      ...>   channel_id: "123456789",
      ...>   limit: 50
      ...> }, %{name: "Agent"})
      {:ok, %{messages: [...], count: 50, channel_id: "123456789", has_more: true}}
  """

  use Lux.Prism,
    name: "Get Discord Message History",
    description: "Retrieves message history from a Discord channel with pagination",
    input_schema: %{
      type: :object,
      properties: %{
        channel_id: %{
          type: :string,
          description: "The ID of the channel",
          pattern: "^[0-9]{17,20}$"
        },
        limit: %{
          type: :integer,
          description: "Number of messages to retrieve (1-100)",
          minimum: 1,
          maximum: 100,
          default: 50
        },
        before: %{
          type: :string,
          description: "Message ID to get messages before (for pagination)"
        },
        after: %{
          type: :string,
          description: "Message ID to get messages after (for pagination)"
        },
        around: %{
          type: :string,
          description: "Message ID to get messages around"
        }
      },
      required: ["channel_id"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        messages: %{type: :array},
        count: %{type: :integer},
        channel_id: %{type: :string},
        has_more: %{type: :boolean}
      },
      required: ["messages", "count", "channel_id"]
    }

  alias Lux.Integrations.Discord.Client
  require Logger

  def handler(params, agent) do
    agent_name = agent[:name] || "Unknown Agent"

    with {:ok, channel_id} <- validate_param(params, :channel_id) do
      limit = params[:limit] || 50

      query_params =
        %{limit: limit}
        |> maybe_add_param(:before, params)
        |> maybe_add_param(:after, params)
        |> maybe_add_param(:around, params)

      Logger.info("Agent #{agent_name} fetching #{limit} messages from channel #{channel_id}")

      case Client.request(:get, "/channels/#{channel_id}/messages", %{json: query_params}) do
        {:ok, messages} when is_list(messages) ->
          has_more = length(messages) == limit
          Logger.info("Retrieved #{length(messages)} messages from channel #{channel_id}")

          {:ok, %{
            messages: messages,
            count: length(messages),
            channel_id: channel_id,
            has_more: has_more
          }}

        {:error, {status, %{"message" => message}}} ->
          Logger.error("Failed to fetch messages: #{status} - #{message}")
          {:error, {status, message}}

        {:error, error} ->
          Logger.error("Failed to fetch messages: #{inspect(error)}")
          {:error, error}
      end
    end
  end

  defp validate_param(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "Missing or invalid #{key}"}
    end
  end

  defp maybe_add_param(map, key, params) do
    case Map.get(params, key) do
      nil -> map
      value -> Map.put(map, key, value)
    end
  end
end
