defmodule Lux.Prisms.Telegram.Chat.LeaveChatPrism do
  @moduledoc """
  A prism for leaving a Telegram chat.

  ## Examples

      iex> Lux.Prisms.Telegram.Chat.LeaveChatPrism.handler(%{chat_id: -1001234567890}, %{})
      {:ok, %{left: true}}
  """

  use Lux.Prism,
    name: "Telegram Leave Chat",
    description: "Leaves a group, supergroup, or channel",
    input_schema: %{
      type: :object,
      properties: %{
        chat_id: %{type: [:string, :integer], description: "Chat identifier to leave"}
      },
      required: ["chat_id"]
    },
    output_schema: %{
      type: :object,
      properties: %{left: %{type: :boolean}},
      required: ["left"]
    }

  alias Lux.Integrations.Telegram.Client

  def handler(params, _ctx) do
    chat_id = Map.fetch!(params, :chat_id)

    case Client.request(:post, "/leaveChat", %{json: %{chat_id: chat_id}}) do
      {:ok, %{"ok" => true, "result" => true}} ->
        {:ok, %{left: true}}

      {:ok, %{"ok" => false, "description" => desc}} ->
        {:error, "Failed to leave chat: #{desc}"}

      {:error, error} ->
        {:error, "Leave chat failed: #{inspect(error)}"}
    end
  end
end
