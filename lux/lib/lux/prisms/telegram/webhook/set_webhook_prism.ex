defmodule Lux.Prisms.Telegram.Webhook.SetWebhookPrism do
  @moduledoc """
  A prism for setting up a Telegram bot webhook.

  Configures the webhook URL for receiving updates via HTTP POST callbacks,
  with support for custom certificates, allowed updates, and drop pending updates.

  ## Examples

      iex> Lux.Prisms.Telegram.Webhook.SetWebhookPrism.handler(%{
      ...>   url: "https://example.com/webhook/bot123",
      ...>   allowed_updates: ["message", "callback_query"],
      ...>   max_connections: 40
      ...> }, %{})
      {:ok, %{set: true, url: "https://example.com/webhook/bot123"}}
  """

  use Lux.Prism,
    name: "Telegram Set Webhook",
    description: "Sets up a webhook URL for receiving Telegram bot updates",
    input_schema: %{
      type: :object,
      properties: %{
        url: %{
          type: :string,
          description: "HTTPS URL to send updates to. Use empty string to remove webhook."
        },
        certificate: %{
          type: :string,
          description: "Public key certificate for self-signed URL (upload)"
        },
        ip_address: %{
          type: :string,
          description: "Fixed IP address for DNS resolution"
        },
        max_connections: %{
          type: :integer,
          description: "Maximum allowed simultaneous connections (1-100, default 40)",
          minimum: 1,
          maximum: 100
        },
        allowed_updates: %{
          type: :array,
          items: %{type: :string},
          description: "List of update types to receive (e.g., ['message', 'callback_query'])"
        },
        drop_pending_updates: %{
          type: :boolean,
          description: "Drop all pending updates before setting the webhook",
          default: false
        },
        secret_token: %{
          type: :string,
          description: "Secret token for webhook verification (X-Telegram-Bot-Api-Secret-Token header)"
        }
      },
      required: ["url"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        set: %{type: :boolean},
        url: %{type: :string},
        description: %{type: :string}
      },
      required: ["set", "url"]
    }

  alias Lux.Integrations.Telegram.Client
  require Logger

  def handler(params, _ctx) do
    url = Map.fetch!(params, :url)

    Logger.info("Setting Telegram webhook to: #{url}")

    request_body =
      params
      |> Map.take([:url, :ip_address, :max_connections, :allowed_updates,
                   :drop_pending_updates, :secret_token])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    case Client.request(:post, "/setWebhook", %{json: request_body}) do
      {:ok, %{"ok" => true, "result" => true, "description" => description}} ->
        Logger.info("Webhook set successfully: #{description}")
        {:ok, %{set: true, url: url, description: description}}

      {:ok, %{"ok" => true, "result" => true}} ->
        {:ok, %{set: true, url: url, description: "Webhook was set"}}

      {:ok, %{"ok" => false, "description" => description}} ->
        {:error, "Failed to set webhook: #{description}"}

      {:error, error} ->
        {:error, "Webhook request failed: #{inspect(error)}"}
    end
  end
end
