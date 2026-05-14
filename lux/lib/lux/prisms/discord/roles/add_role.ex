defmodule Lux.Prisms.Discord.Roles.AddRole do
  @moduledoc """
  A prism for adding a role to a Discord guild member.

  This prism provides a simple interface for assigning Discord roles with:
  - Required parameters (guild_id, user_id, role_id)
  - Direct Discord API error propagation
  - Simple success/failure response structure

  ## Examples
      iex> AddRole.handler(%{
      ...>   guild_id: "123456789",
      ...>   user_id: "987654321",
      ...>   role_id: "111111111111111111"
      ...> }, %{name: "Agent"})
      {:ok, %{
        assigned: true,
        user_id: "987654321",
        role_id: "111111111111111111",
        guild_id: "123456789"
      }}
  """

  use Lux.Prism,
    name: "Add Discord Role",
    description: "Adds a role to a member in a Discord guild",
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
          description: "The ID of the user to add the role to",
          pattern: "^[0-9]{17,20}$"
        },
        role_id: %{
          type: :string,
          description: "The ID of the role to add",
          pattern: "^[0-9]{17,20}$"
        }
      },
      required: ["guild_id", "user_id", "role_id"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        assigned: %{
          type: :boolean,
          description: "Whether the role was successfully assigned"
        },
        user_id: %{
          type: :string,
          description: "The ID of the user"
        },
        role_id: %{
          type: :string,
          description: "The ID of the role that was assigned"
        },
        guild_id: %{
          type: :string,
          description: "The ID of the guild"
        }
      },
      required: ["assigned"]
    }

  alias Lux.Integrations.Discord.Client
  require Logger

  @doc """
  Handles the request to add a role to a Discord guild member.

  Returns {:ok, %{assigned: true, user_id: id, role_id: role_id, guild_id: guild_id}} on success.
  Returns {:error, {status, message}} on failure.
  """
  @spec handler(map(), map()) :: {:ok, map()} | {:error, term()}
  def handler(params, agent) do
    with {:ok, guild_id} <- validate_param(params, :guild_id),
         {:ok, user_id} <- validate_param(params, :user_id),
         {:ok, role_id} <- validate_param(params, :role_id) do
      agent_name = agent[:name] || "Unknown Agent"
      Logger.info("Agent #{agent_name} adding role #{role_id} to user #{user_id} in guild #{guild_id}")

      case Client.request(:put, "/guilds/#{guild_id}/members/#{user_id}/roles/#{role_id}") do
        {:ok, _response} ->
          Logger.info("Successfully added role #{role_id} to user #{user_id} in guild #{guild_id}")
          {:ok, %{assigned: true, user_id: user_id, role_id: role_id, guild_id: guild_id}}

        {:error, {status, %{"message" => message}}} ->
          error = {status, message}
          Logger.error("Failed to add role #{role_id} to user #{user_id} in guild #{guild_id}: #{inspect(error)}")
          {:error, error}

        {:error, error} ->
          Logger.error("Failed to add role #{role_id} to user #{user_id} in guild #{guild_id}: #{inspect(error)}")
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
