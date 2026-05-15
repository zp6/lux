defmodule Lux.Prisms.Telegram.Chat.GetChatPrism do
  @moduledoc """
  A prism for getting information about a Telegram chat.

  ## Examples

      iex> Lux.Prisms.Telegram.Chat.GetChatPrism.handler(%{chat_id: "@channelname"}, %{})
      {:ok, %{id: -1001234567890, type: "channel", title: "My Channel"}}
  """

  use Lux.Prism,
    name: "Telegram Get Chat",
    description: "Gets information about a Telegram chat",
    input_schema: %{
      type: :object,
      properties: %{
        chat_id: %{
          type: [:string, :integer],
          description: "Unique identifier or username of the target chat"
        }
      },
      required: ["chat_id"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        id: %{type: :integer},
        type: %{type: :string},
        title: %{type: :string},
        username: %{type: :string}
      },
      required: ["id", "type"]
    }

  alias Lux.Integrations.Telegram.Client

  def handler(params, _ctx) do
    chat_id = Map.fetch!(params, :chat_id)

    case Client.request(:post, "/getChat", %{json: %{chat_id: chat_id}}) do
      {:ok, %{"ok" => true, "result" => chat}} ->
        {:ok, %{
          id: chat["id"],
          type: chat["type"],
          title: chat["title"],
          username: chat["username"],
          first_name: chat["first_name"],
          last_name: chat["last_name"],
          description: chat["description"],
          member_count: chat["members_count"] || chat["participant_count"],
          photo: chat["photo"],
          pinned_message: chat["pinned_message"]
        }}

      {:error, error} ->
        {:error, "Failed to get chat info: #{inspect(error)}"}
    end
  end
end
