defmodule Lux.Prisms.Discord.Moderation.BanUser do
  @moduledoc """
  A prism for banning a user from a Discord guild.

  Supports deleting the user's recent messages and providing a reason
  for the audit log.

  ## Examples

      iex> BanUser.handler(%{
      ...>   guild_id: "111222333",
      ...>   user_id: "444555666",
      ...>   delete_message_days: 1,
      ...>   reason: "Violating community guidelines"
      ...> }, %{name: "Agent"})
      {:ok, %{banned: true, user_id: "444555666", guild_id: "111222333"}}
  """

  use Lux.Prism,
    name: "Ban Discord User",
    description: "Bans a user from a Discord guild",
    input_schema: %{
      type: :object,
      properties: %{
        guild_id: %{
          type: :string,
          description: "The ID of the guild",
          pattern: "^[0-9]{17,20}$"
        },
        user_id: %{
          type: :string,
          description: "The ID of the user to ban",
          pattern: "^[0-9]{17,20}$"
        },
        delete_message_days: %{
          type: :integer,
          description: "Number of days to delete messages for (0-7)",
          minimum: 0,
          maximum: 7,
          default: 0
        },
        reason: %{
          type: :string,
          description: "Reason for the ban (shown in audit log)",
          maxLength: 512
        }
      },
      required: ["guild_id", "user_id"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        banned: %{type: :boolean},
        user_id: %{type: :string},
        guild_id: %{type: :string}
      },
      required: ["banned", "user_id", "guild_id"]
    }

  alias Lux.Integrations.Discord.Client
  require Logger

  def handler(params, agent) do
    agent_name = agent[:name] || "Unknown Agent"

    with {:ok, guild_id} <- validate_param(params, :guild_id),
         {:ok, user_id} <- validate_param(params, :user_id) do

      delete_days = params[:delete_message_days] || 0
      headers = if params[:reason], do: [{"X-Audit-Log-Reason", params[:reason]}], else: []

      Logger.info("Agent #{agent_name} banning user #{user_id} from guild #{guild_id}")

      query = if delete_days > 0, do: %{delete_message_days: delete_days}, else: %{}

      case Client.request(:put, "/guilds/#{guild_id}/bans/#{user_id}", %{json: query, headers: headers}) do
        {:ok, _} ->
          Logger.info("Successfully banned user #{user_id} from guild #{guild_id}")
          {:ok, %{banned: true, user_id: user_id, guild_id: guild_id}}

        {:error, {status, %{"message" => message}}} ->
          Logger.error("Failed to ban user: #{status} - #{message}")
          {:error, {status, message}}

        {:error, error} ->
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
end
