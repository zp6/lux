defmodule Lux.Prisms.Telegram.Bot.GetUpdatesPrism do
  @moduledoc """
  A prism for receiving updates from Telegram via long polling.

  Supports offset-based update tracking, timeout configuration,
  and update type filtering.

  ## Examples

      iex> Lux.Prisms.Telegram.Bot.GetUpdatesPrism.handler(%{
      ...>   offset: 100,
      ...>   limit: 10,
      ...>   timeout: 30
      ...> }, %{})
      {:ok, %{updates: [...], count: 5}}
  """

  use Lux.Prism,
    name: "Telegram Get Updates",
    description: "Receives pending updates from Telegram via long polling",
    input_schema: %{
      type: :object,
      properties: %{
        offset: %{
          type: :integer,
          description: "Identifier of the first update to be returned. Must be one greater than previous."
        },
        limit: %{
          type: :integer,
          description: "Limits the number of updates to be retrieved (1-100, default 100)",
          minimum: 1,
          maximum: 100
        },
        timeout: %{
          type: :integer,
          description: "Timeout in seconds for long polling (default 0, max 120)",
          minimum: 0,
          maximum: 120
        },
        allowed_updates: %{
          type: :array,
          items: %{type: :string},
          description: "List of update types to receive"
        }
      }
    },
    output_schema: %{
      type: :object,
      properties: %{
        updates: %{type: :array},
        count: %{type: :integer}
      },
      required: ["updates", "count"]
    }

  alias Lux.Integrations.Telegram.Client
  require Logger

  def handler(params, _ctx) do
    request_body =
      params
      |> Map.take([:offset, :limit, :timeout, :allowed_updates])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    Logger.debug("Polling for Telegram updates with offset: #{params[:offset] || "none"}")

    case Client.request(:post, "/getUpdates", %{json: request_body}) do
      {:ok, %{"ok" => true, "result" => updates}} when is_list(updates) ->
        {:ok, %{
          updates: updates,
          count: length(updates)
        }}

      {:ok, %{"ok" => true, "result" => []}} ->
        {:ok, %{updates: [], count: 0}}

      {:error, error} ->
        {:error, "Failed to get updates: #{inspect(error)}"}
    end
  end
end
