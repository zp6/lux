defmodule Lux.Prisms.Discord.Events.ManageGuildEvent do
  @moduledoc """
  A prism for managing Discord guild events (scheduled events).

  Supports creating, updating, deleting, and listing guild events with
  reminder and notification capabilities.

  ## Examples

      iex> ManageGuildEvent.handler(%{
      ...>   action: "create",
      ...>   guild_id: "111222333",
      ...>   name: "Community Game Night",
      ...> description: "Weekly game night",
      ...>   start_time: "2024-06-01T19:00:00Z",
      ...>   end_time: "2024-06-01T22:00:00Z",
      ...>   entity_type: 3
      ...> }, %{name: "Agent"})
      {:ok, %{created: true, event_id: "999", name: "Community Game Night"}}
  """

  use Lux.Prism,
    name: "Manage Discord Guild Event",
    description: "Creates and manages Discord guild scheduled events",
    input_schema: %{
      type: :object,
      properties: %{
        action: %{
          type: :string,
          description: "Event action",
          enum: ["create", "update", "delete", "list", "get"]
        },
        guild_id: %{
          type: :string,
          description: "The ID of the guild",
          pattern: "^[0-9]{17,20}$"
        },
        event_id: %{
          type: :string,
          description: "Event ID for update/delete/get actions"
        },
        name: %{
          type: :string,
          description: "Name of the event (1-100 characters)",
          minLength: 1,
          maxLength: 100
        },
        description: %{
          type: :string,
          description: "Description of the event (0-1000 characters)",
          maxLength: 1000
        },
        start_time: %{
          type: :string,
          description: "Event start time (ISO8601)"
        },
        end_time: %{
          type: :string,
          description: "Event end time (ISO8601)"
        },
        entity_type: %{
          type: :integer,
          description: "1=stage, 2=voice, 3=external",
          enum: [1, 2, 3]
        },
        channel_id: %{
          type: :string,
          description: "Channel ID for stage/voice events"
        },
        entity_metadata: %{
          type: :object,
          description: "Additional metadata (location for external events)"
        },
        image: %{
          type: :string,
          description: "Cover image (base64 encoded)"
        },
        with_user_count: %{
          type: :boolean,
          description: "Include subscriber count in response",
          default: true
        }
      },
      required: ["action", "guild_id"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        action: %{type: :string},
        success: %{type: :boolean},
        event_id: %{type: :string},
        name: %{type: :string},
        details: %{type: :object}
      },
      required: ["action", "success"]
    }

  alias Lux.Integrations.Discord.Client
  require Logger

  def handler(params, agent) do
    agent_name = agent[:name] || "Unknown Agent"
    action = params[:action]

    with {:ok, guild_id} <- validate_param(params, :guild_id) do
      Logger.info("Agent #{agent_name} event action: #{action} in guild #{guild_id}")

      case action do
        "create" -> create_event(guild_id, params, agent_name)
        "update" -> update_event(guild_id, params, agent_name)
        "delete" -> delete_event(guild_id, params, agent_name)
        "list" -> list_events(guild_id, params)
        "get" -> get_event(guild_id, params)
        _ -> {:error, "Unsupported action: #{action}"}
      end
    end
  end

  defp create_event(guild_id, params, agent_name) do
    with {:ok, name} <- validate_param(params, :name),
         {:ok, start_time} <- validate_param(params, :start_time),
         {:ok, entity_type} <- validate_entity_type(params) do

      body = %{
        name: name,
        privacy_level: 2,
        scheduled_start_time: start_time,
        entity_type: entity_type,
        description: params[:description],
        scheduled_end_time: params[:end_time],
        channel_id: params[:channel_id],
        entity_metadata: params[:entity_metadata],
        image: params[:image]
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

      case Client.request(:post, "/guilds/#{guild_id}/scheduled-events", %{json: body}) do
        {:ok, %{"id" => event_id, "name" => event_name}} ->
          Logger.info("Agent #{agent_name} created event '#{event_name}' (#{event_id})")
          {:ok, %{action: "create", success: true, event_id: event_id, name: event_name}}

        {:ok, response} ->
          {:ok, %{action: "create", success: true, details: response}}

        {:error, {status, %{"message" => message}}} ->
          {:error, {status, message}}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  defp update_event(guild_id, params, agent_name) do
    with {:ok, event_id} <- validate_param(params, :event_id) do
      body = params
      |> Map.take([:name, :description, :start_time, :end_time, :entity_type, :entity_metadata, :image])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

      case Client.request(:patch, "/guilds/#{guild_id}/scheduled-events/#{event_id}", %{json: body}) do
        {:ok, %{"id" => ^event_id} = response} ->
          Logger.info("Agent #{agent_name} updated event #{event_id}")
          {:ok, %{action: "update", success: true, event_id: event_id, details: response}}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  defp delete_event(guild_id, params, agent_name) do
    with {:ok, event_id} <- validate_param(params, :event_id) do
      case Client.request(:delete, "/guilds/#{guild_id}/scheduled-events/#{event_id}") do
        {:ok, _} ->
          Logger.info("Agent #{agent_name} deleted event #{event_id}")
          {:ok, %{action: "delete", success: true, event_id: event_id}}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  defp list_events(guild_id, params) do
    with_user_count = params[:with_user_count] != false

    case Client.request(:get, "/guilds/#{guild_id}/scheduled-events?with_user_count=#{with_user_count}") do
      {:ok, events} when is_list(events) ->
        {:ok, %{action: "list", success: true, details: %{"events" => events, "count" => length(events)}}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp get_event(guild_id, params) do
    with {:ok, event_id} <- validate_param(params, :event_id) do
      with_user_count = params[:with_user_count] != false

      case Client.request(:get, "/guilds/#{guild_id}/scheduled-events/#{event_id}?with_user_count=#{with_user_count}") do
        {:ok, event} ->
          {:ok, %{action: "get", success: true, event_id: event_id, details: event}}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  defp validate_entity_type(params) do
    case params[:entity_type] do
      nil -> {:ok, 3}  # Default to external
      type when type in [1, 2, 3] -> {:ok, type}
      _ -> {:error, "Invalid entity_type. Must be 1 (stage), 2 (voice), or 3 (external)"}
    end
  end

  defp validate_param(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "Missing or invalid #{key}"}
    end
  end
end
