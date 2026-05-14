defmodule Lux.Prisms.Discord.Guilds.GetGuild do
  @moduledoc """
  A prism for retrieving information about a Discord guild.

  This prism provides a simple interface for fetching Discord guild details with:
  - Minimal required parameters (guild_id)
  - Direct Discord API error propagation
  - Simple success/failure response structure

  ## Examples
      iex> GetGuild.handler(%{
      ...>   guild_id: "123456789"
      ...> }, %{name: "Agent"})
      {:ok, %{
        retrieved: true,
        guild_id: "123456789",
        name: "My Server",
        owner_id: "987654321",
        member_count: 42
      }}
  """

  use Lux.Prism,
    name: "Get Discord Guild",
    description: "Retrieves information about a Discord guild",
    input_schema: %{
      type: :object,
      properties: %{
        guild_id: %{
          type: :string,
          description: "The ID of the guild to retrieve",
          pattern: "^[0-9]{17,20}$"
        }
      },
      required: ["guild_id"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        retrieved: %{
          type: :boolean,
          description: "Whether the guild was successfully retrieved"
        },
        guild_id: %{
          type: :string,
          description: "The ID of the guild"
        },
        name: %{
          type: :string,
          description: "The name of the guild"
        },
        owner_id: %{
          type: :string,
          description: "The ID of the guild owner"
        },
        member_count: %{
          type: :integer,
          description: "The number of members in the guild"
        }
      },
      required: ["retrieved"]
    }

  alias Lux.Integrations.Discord.Client
  require Logger

  @doc """
  Handles the request to retrieve a Discord guild.

  Returns {:ok, %{retrieved: true, guild_id: id, name: name, owner_id: owner_id, member_count: count}} on success.
  Returns {:error, {status, message}} on failure.
  """
  @spec handler(map(), map()) :: {:ok, map()} | {:error, term()}
  def handler(params, agent) do
    with {:ok, guild_id} <- validate_param(params, :guild_id) do
      agent_name = agent[:name] || "Unknown Agent"
      Logger.info("Agent #{agent_name} retrieving guild #{guild_id}")

      case Client.request(:get, "/guilds/#{guild_id}") do
        {:ok, %{"id" => id, "name" => name, "owner_id" => owner_id, "member_count" => member_count}} ->
          Logger.info("Successfully retrieved guild #{guild_id}")
          {:ok, %{retrieved: true, guild_id: id, name: name, owner_id: owner_id, member_count: member_count}}

        {:error, {status, %{"message" => message}}} ->
          error = {status, message}
          Logger.error("Failed to retrieve guild #{guild_id}: #{inspect(error)}")
          {:error, error}

        {:error, error} ->
          Logger.error("Failed to retrieve guild #{guild_id}: #{inspect(error)}")
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
