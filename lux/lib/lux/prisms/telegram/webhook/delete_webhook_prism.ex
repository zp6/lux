defmodule Lux.Prisms.Telegram.Webhook.DeleteWebhookPrism do
  @moduledoc """
  A prism for removing a Telegram bot webhook.

  ## Examples

      iex> Lux.Prisms.Telegram.Webhook.DeleteWebhookPrism.handler(%{drop_pending_updates: true}, %{})
      {:ok, %{deleted: true, description: "Webhook was deleted"}}
  """

  use Lux.Prism,
    name: "Telegram Delete Webhook",
    description: "Removes webhook integration and switches to getUpdates polling",
    input_schema: %{
      type: :object,
      properties: %{
        drop_pending_updates: %{
          type: :boolean,
          description: "Drop all pending updates",
          default: false
        }
      }
    },
    output_schema: %{
      type: :object,
      properties: %{
        deleted: %{type: :boolean},
        description: %{type: :string}
      },
      required: ["deleted"]
    }

  alias Lux.Integrations.Telegram.Client

  def handler(params, _ctx) do
    request_body = Map.take(params, [:drop_pending_updates])

    case Client.request(:post, "/deleteWebhook", %{json: request_body}) do
      {:ok, %{"ok" => true, "result" => true, "description" => desc}} ->
        {:ok, %{deleted: true, description: desc}}

      {:ok, %{"ok" => true, "result" => true}} ->
        {:ok, %{deleted: true, description: "Webhook was deleted"}}

      {:ok, %{"ok" => false, "description" => desc}} ->
        {:error, "Failed to delete webhook: #{desc}"}

      {:error, error} ->
        {:error, "Delete webhook failed: #{inspect(error)}"}
    end
  end
end
