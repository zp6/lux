defmodule Lux.Prisms.Discord.Members.ListMembers do
  @moduledoc """
  A prism for listing members in a Discord guild.

  This prism provides a simple interface for listing Discord guild members with:
  - Required parameters (guild_id)
  - Optional pagination parameters (limit, after)
  - Direct Discord API error propagation
  - Simple success/failure response structure

  ## Examples
      iex> ListMembers.handler(%{
      ...>   guild_id: "123456789",
      ...>   limit: 10
      ...> }, %{name: "Agent"})
      {:ok, %{
        retrieved: true,
        members: [
          %{user_id: "111", username: "user1", nick: nil},
          %{user_id: "222", username: "user2", nick: "Nick"}
        ],
        count: 2
      }}
  """

  use Lux.Prism,
    name: "List Discord Members",
    description: "Lists members in a Discord guild",
    input_schema: %{
      type: :object,
      properties: %{
        guild_id: %{
          type: :string,
          description: "The ID of the guild",
          pattern: "^[0-9]{17,20}$"
        },
        limit: %{
          type: :integer,
          description: "Max number of members to return (1-1000, default 1)",
          minimum: 1,
          maximum: 1000
        },
        after: %{
          type: :string,
          description: "The highest user ID in the previous page for pagination",
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
          description: "Whether members were successfully retrieved"
        },
        members: %{
          type: :array,
          description: "List of guild members"
        },
        count: %{
          type: :integer,
          description: "Number of members returned"
        }
      },
      required: ["retrieved"]
    }

  alias Lux.Integrations.Discord.Client
  require Logger

  @doc """
  Handles the request to list members in a Discord guild.

  Returns {:ok, %{retrieved: true, members: [...], count: n}} on success.
  Returns {:error, {status, message}} on failure.
  """
  @spec handler(map(), map()) :: {:ok, map()} | {:error, term()}
  def handler(params, agent) do
    with {:ok, guild_id} <- validate_param(params, :guild_id) do
      agent_name = agent[:name] || "Unknown Agent"
      limit = Map.get(params, :limit, 1)
      after_id = Map.get(params, :after)

      query = build_query(limit, after_id)

      Logger.info("Agent #{agent_name} listing members in guild #{guild_id} (limit: #{limit})")

      case Client.request(:get, "/guilds/#{guild_id}/members?#{query}") do
        {:ok, members} when is_list(members) ->
          formatted = Enum.map(members, &format_member/1)
          Logger.info("Successfully retrieved #{length(members)} members from guild #{guild_id}")
          {:ok, %{retrieved: true, members: formatted, count: length(formatted)}}

        {:error, {status, %{"message" => message}}} ->
          error = {status, message}
          Logger.error("Failed to list members in guild #{guild_id}: #{inspect(error)}")
          {:error, error}

        {:error, error} ->
          Logger.error("Failed to list members in guild #{guild_id}: #{inspect(error)}")
          {:error, error}
      end
    end
  end

  defp build_query(limit, nil), do: "limit=#{limit}"
  defp build_query(limit, after_id), do: "limit=#{limit}&after=#{after_id}"

  defp format_member(%{"user" => %{"id" => id, "username" => username}, "nick" => nick}) do
    %{user_id: id, username: username, nick: nick}
  end

  defp format_member(%{"user" => %{"id" => id, "username" => username}}) do
    %{user_id: id, username: username, nick: nil}
  end

  defp validate_param(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "Missing or invalid #{key}"}
    end
  end
end
