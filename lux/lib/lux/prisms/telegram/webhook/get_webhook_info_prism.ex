defmodule Lux.Prisms.Telegram.Webhook.GetWebhookInfoPrism do
  @moduledoc """
  A prism for getting current webhook information from Telegram.

  Returns webhook URL, pending update count, last error details, and configuration.

  ## Examples

      iex> Lux.Prisms.Telegram.Webhook.GetWebhookInfoPrism.handler(%{}, %{})
      {:ok, %{url: "https://example.com/webhook", pending_update_count: 0, ...}}
  """

  use Lux.Prism,
    name: "Telegram Get Webhook Info",
    description: "Gets current webhook status and configuration",
    input_schema: %{type: :object, properties: %{}},
    output_schema: %{
      type: :object,
      properties: %{url: %{type: :string}, pending_update_count: %{type: :integer}, max_connections: %{type: :integer}},
      required: ["url", "pending_update_count"]
    }

  alias Lux.Integrations.Telegram.Client

  def handler(_params, _ctx) do
    case Client.request(:get, "/getWebhookInfo") do
      {:ok, %{"ok" => true, "result" => info}} ->
        {:ok, %{
          url: info["url"],
          has_custom_certificate: info["has_custom_certificate"],
          pending_update_count: info["pending_update_count"],
          last_error_date: info["last_error_date"],
          last_error_message: info["last_error_message"],
          max_connections: info["max_connections"],
          allowed_updates: info["allowed_updates"] || []
        }}
      {:error, error} ->
        {:error, "Failed to get webhook info: #{inspect(error)}"}
    end
  end
end
