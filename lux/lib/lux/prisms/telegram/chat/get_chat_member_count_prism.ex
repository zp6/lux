defmodule Lux.Prisms.Telegram.Chat.GetChatMemberCountPrism do
  @moduledoc """
  A prism for getting the member count of a Telegram chat.

  ## Examples

      iex> Lux.Prisms.Telegram.Chat.GetChatMemberCountPrism.handler(%{chat_id: "@channelname"}, %{})
      {:ok, %{chat_id: "@channelname", member_count: 5420}}
  """

  use Lux.Prism,
    name: "Telegram Get Chat Member Count",
    description: "Gets the number of members in a chat",
    input_schema: %{
      type: :object,
      properties: %{
        chat_id: %{type: [:string, :integer], description: "Chat identifier"}
      },
      required: ["chat_id"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        chat_id: %{type: [:string, :integer]},
        member_count: %{type: :integer}
      },
      required: ["chat_id", "member_count"]
    }

  alias Lux.Integrations.Telegram.Client

  def handler(params, _ctx) do
    chat_id = Map.fetch!(params, :chat_id)

    case Client.request(:post, "/getChatMemberCount", %{json: %{chat_id: chat_id}}) do
      {:ok, %{"ok" => true, "result" => count}} ->
        {:ok, %{chat_id: chat_id, member_count: count}}

      {:error, error} ->
        {:error, "Failed to get member count: #{inspect(error)}"}
    end
  end
end
