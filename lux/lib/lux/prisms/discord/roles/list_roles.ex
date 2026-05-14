defmodule Lux.Prisms.Discord.Roles.ListRoles do
  @moduledoc """
  A prism for listing roles in a Discord guild.

  This prism provides a simple interface for listing Discord guild roles with:
  - Minimal required parameters (guild_id)
  - Direct Discord API error propagation
  - Simple success/failure response structure

  ## Examples
      iex> ListRoles.handler(%{
      ...>   guild_id: "123456789"
      ...> }, %{name: "Agent"})
      {:ok, %{
        retrieved: true,
        roles: [
          %{id: "111111111111111111", name: "@everyone", color: 0},
          %{id: "222222222222222222", name: "Admin", color: 16711669}
        ],
        count: 2
      }}
  """

  use Lux.Prism,
    name: "List Discord Roles",
    description: "Lists roles in a Discord guild",
    input_schema: %{
      type: :object,
      properties: %{
        guild_id: %{
          type: :string,
          description: "The ID of the guild",
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
          description: "Whether roles were successfully retrieved"
        },
        roles: %{
          type: :array,
          description: "List of guild roles"
        },
        count: %{
          type: :integer,
          description: "Number of roles returned"
        }
      },
      required: ["retrieved"]
    }

  alias Lux.Integrations.Discord.Client
  require Logger

  @doc """
  Handles the request to list roles in a Discord guild.

  Returns {:ok, %{retrieved: true, roles: [...], count: n}} on success.
  Returns {:error, {status, message}} on failure.
  """
  @spec handler(map(), map()) :: {:ok, map()} | {:error, term()}
  def handler(params, agent) do
    with {:ok, guild_id} <- validate_param(params, :guild_id) do
      agent_name = agent[:name] || "Unknown Agent"
      Logger.info("Agent #{agent_name} listing roles in guild #{guild_id}")

      case Client.request(:get, "/guilds/#{guild_id}/roles") do
        {:ok, roles} when is_list(roles) ->
          formatted = Enum.map(roles, &format_role/1)
          Logger.info("Successfully retrieved #{length(roles)} roles from guild #{guild_id}")
          {:ok, %{retrieved: true, roles: formatted, count: length(formatted)}}

        {:error, {status, %{"message" => message}}} ->
          error = {status, message}
          Logger.error("Failed to list roles in guild #{guild_id}: #{inspect(error)}")
          {:error, error}

        {:error, error} ->
          Logger.error("Failed to list roles in guild #{guild_id}: #{inspect(error)}")
          {:error, error}
      end
    end
  end

  defp format_role(%{"id" => id, "name" => name, "color" => color}) do
    %{id: id, name: name, color: color}
  end

  defp validate_param(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "Missing or invalid #{key}"}
    end
  end
end
