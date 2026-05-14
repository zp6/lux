defmodule Lux.Prisms.Discord.Members.GetMember do
  @moduledoc """
  A prism for retrieving information about a Discord guild member.

  This prism provides a simple interface for fetching Discord member details with:
  - Required parameters (guild_id, user_id)
  - Direct Discord API error propagation
  - Simple success/failure response structure

  ## Examples
      iex> GetMember.handler(%{
      ...>   guild_id: "123456789",
      ...>   user_id: "987654321"
      ...> }, %{name: "Agent"})
      {:ok, %{
        retrieved: true,
        user_id: "987654321",
        username: "cooluser",
        nick: "Cool Nick",
        roles: ["111111111111111111"]
      }}
  """

  use Lux.Prism,
    name: "Get Discord Member",
    description: "Retrieves information about a specific member in a Discord guild",
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
          description: "The ID of the user to look up",
          pattern: "^[0-9]{17,20}$"
        }
      },
      required: ["guild_id", "user_id"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        retrieved: %{
          type: :boolean,
          description: "Whether the member was successfully retrieved"
        },
        user_id: %{
          type: :string,
          description: "The ID of the user"
        },
        username: %{
          type: :string,
          description: "The username of the member"
        },
        nick: %{
          type: :string,
          description: "The nickname of the member in the guild"
        },
        roles: %{
          type: :array,
          description: "List of role IDs the member has"
        }
      },
      required: ["retrieved"]
    }

  alias Lux.Integrations.Discord.Client
  require Logger

  @doc """
  Handles the request to retrieve a Discord guild member.

  Returns {:ok, %{retrieved: true, user_id: id, username: name, nick: nick, roles: roles}} on success.
  Returns {:error, {status, message}} on failure.
  """
  @spec handler(map(), map()) :: {:ok, map()} | {:error, term()}
  def handler(params, agent) do
    with {:ok, guild_id} <- validate_param(params, :guild_id),
         {:ok, user_id} <- validate_param(params, :user_id) do
      agent_name = agent[:name] || "Unknown Agent"
      Logger.info("Agent #{agent_name} retrieving member #{user_id} in guild #{guild_id}")

      case Client.request(:get, "/guilds/#{guild_id}/members/#{user_id}") do
        {:ok, %{"user" => %{"id" => id, "username" => username}, "nick" => nick, "roles" => roles}} ->
          Logger.info("Successfully retrieved member #{user_id} in guild #{guild_id}")
          {:ok, %{retrieved: true, user_id: id, username: username, nick: nick, roles: roles}}

        {:error, {status, %{"message" => message}}} ->
          error = {status, message}
          Logger.error("Failed to retrieve member #{user_id} in guild #{guild_id}: #{inspect(error)}")
          {:error, error}

        {:error, error} ->
          Logger.error("Failed to retrieve member #{user_id} in guild #{guild_id}: #{inspect(error)}")
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
