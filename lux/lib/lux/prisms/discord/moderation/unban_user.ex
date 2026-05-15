defmodule Lux.Prisms.Discord.Moderation.UnbanUser do
  @moduledoc """
  A prism for unbanning a user from a Discord guild.

  ## Examples

      iex> UnbanUser.handler(%{
      ...>   guild_id: "111222333",
      ...>   user_id: "444555666",
      ...>   reason: "Appeal accepted"
      ...> }, %{name: "Agent"})
      {:ok, %{unbanned: true, user_id: "444555666", guild_id: "111222333"}}
  """

  use Lux.Prism,
    name: "Unban Discord User",
    description: "Unbans a user from a Discord guild",
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
          description: "The ID of the user to unban",
          pattern: "^[0-9]{17,20}$"
        },
        reason: %{
          type: :string,
          description: "Reason for the unban (shown in audit log)",
          maxLength: 512
        }
      },
      required: ["guild_id", "user_id"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        unbanned: %{type: :boolean},
        user_id: %{type: :string},
        guild_id: %{type: :string}
      },
      required: ["unbanned", "user_id", "guild_id"]
    }

  alias Lux.Integrations.Discord.Client
  require Logger

  def handler(params, agent) do
    agent_name = agent[:name] || "Unknown Agent"

    with {:ok, guild_id} <- validate_param(params, :guild_id),
         {:ok, user_id} <- validate_param(params, :user_id) do

      headers = if params[:reason], do: [{"X-Audit-Log-Reason", params[:reason]}], else: []

      Logger.info("Agent #{agent_name} unbanning user #{user_id} from guild #{guild_id}")

      case Client.request(:delete, "/guilds/#{guild_id}/bans/#{user_id}", %{headers: headers}) do
        {:ok, _} ->
          Logger.info("Successfully unbanned user #{user_id} from guild #{guild_id}")
          {:ok, %{unbanned: true, user_id: user_id, guild_id: guild_id}}

        {:error, {status, %{"message" => message}}} ->
          Logger.error("Failed to unban user: #{status} - #{message}")
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
