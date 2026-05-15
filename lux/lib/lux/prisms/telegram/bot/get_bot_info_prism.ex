defmodule Lux.Prisms.Telegram.Bot.GetBotInfoPrism do
  @moduledoc """
  A prism for getting Telegram bot information.

  Returns bot ID, name, username, and other details for verification
  and bot management purposes.

  ## Examples

      iex> Lux.Prisms.Telegram.Bot.GetBotInfoPrism.handler(%{}, %{})
      {:ok, %{id: 123456789, is_bot: true, first_name: "MyBot", username: "my_bot"}}
  """

  use Lux.Prism,
    name: "Telegram Get Bot Info",
    description: "Gets information about the authenticated bot",
    input_schema: %{type: :object, properties: %{}},
    output_schema: %{
      type: :object,
      properties: %{
        id: %{type: :integer},
        is_bot: %{type: :boolean},
        first_name: %{type: :string},
        username: %{type: :string},
        can_join_groups: %{type: :boolean},
        can_read_all_group_messages: %{type: :boolean},
        supports_inline_queries: %{type: :boolean}
      },
      required: ["id", "is_bot", "first_name"]
    }

  alias Lux.Integrations.Telegram.Client
  require Logger

  def handler(_params, _ctx) do
    case Client.request(:get, "/getMe") do
      {:ok, %{"ok" => true, "result" => bot}} ->
        Logger.info("Bot info retrieved: @#{bot["username"]}")
        {:ok, %{
          id: bot["id"],
          is_bot: bot["is_bot"],
          first_name: bot["first_name"],
          last_name: bot["last_name"],
          username: bot["username"],
          language_code: bot["language_code"],
          can_join_groups: bot["can_join_groups"],
          can_read_all_group_messages: bot["can_read_all_group_messages"],
          supports_inline_queries: bot["supports_inline_queries"]
        }}

      {:error, :invalid_token} ->
        {:error, "Invalid bot token - authentication failed"}

      {:error, error} ->
        {:error, "Failed to get bot info: #{inspect(error)}"}
    end
  end
end
