defmodule Lux.Prisms.Discord.Channels.ManagePermissions do
  @moduledoc """
  A prism for managing channel permission overwrites in Discord.

  Supports setting, updating, and deleting permission overwrites for
  roles and users on specific channels.

  ## Examples

      iex> ManagePermissions.handler(%{
      ...>   channel_id: "123456789",
      ...>   overwrite_id: "987654321",
      ...>   overwrite_type: "role",
      ...>   allow: "2048",
      ...>   deny: "0"
      ...> }, %{name: "Agent"})
      {:ok, %{updated: true, channel_id: "123456789"}}
  """

  use Lux.Prism,
    name: "Manage Discord Channel Permissions",
    description: "Sets permission overwrites for a Discord channel",
    input_schema: %{
      type: :object,
      properties: %{
        channel_id: %{
          type: :string,
          description: "The ID of the channel",
          pattern: "^[0-9]{17,20}$"
        },
        overwrite_id: %{
          type: :string,
          description: "The ID of the role or user to set permissions for"
        },
        overwrite_type: %{
          type: :integer,
          description: "0 for role, 1 for member",
          enum: [0, 1]
        },
        allow: %{
          type: :string,
          description: "Permission bitfield for allowed permissions"
        },
        deny: %{
          type: :string,
          description: "Permission bitfield for denied permissions"
        },
        action: %{
          type: :string,
          description: "Permission action",
          enum: ["set", "delete"],
          default: "set"
        }
      },
      required: ["channel_id", "overwrite_id"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        updated: %{type: :boolean},
        channel_id: %{type: :string},
        overwrite_id: %{type: :string}
      },
      required: ["updated", "channel_id"]
    }

  alias Lux.Integrations.Discord.Client
  require Logger

  def handler(params, agent) do
    agent_name = agent[:name] || "Unknown Agent"
    action = params[:action] || "set"

    with {:ok, channel_id} <- validate_param(params, :channel_id),
         {:ok, overwrite_id} <- validate_param(params, :overwrite_id) do

      Logger.info("Agent #{agent_name} #{action}ting permissions for #{overwrite_id} in channel #{channel_id}")

      case action do
        "set" -> set_permissions(channel_id, overwrite_id, params)
        "delete" -> delete_permissions(channel_id, overwrite_id, agent_name)
      end
    end
  end

  defp set_permissions(channel_id, overwrite_id, params) do
    body = %{
      id: overwrite_id,
      type: params[:overwrite_type] || 0,
      allow: params[:allow] || "0",
      deny: params[:deny] || "0"
    }

    case Client.request(:put, "/channels/#{channel_id}/permissions/#{overwrite_id}", %{json: body}) do
      {:ok, _} ->
        {:ok, %{updated: true, channel_id: channel_id, overwrite_id: overwrite_id}}

      {:error, {status, %{"message" => message}}} ->
        {:error, {status, message}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp delete_permissions(channel_id, overwrite_id, agent_name) do
    case Client.request(:delete, "/channels/#{channel_id}/permissions/#{overwrite_id}") do
      {:ok, _} ->
        Logger.info("Agent #{agent_name} deleted permissions for #{overwrite_id} in channel #{channel_id}")
        {:ok, %{updated: true, channel_id: channel_id, overwrite_id: overwrite_id}}

      {:error, {status, %{"message" => message}}} ->
        {:error, {status, message}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp validate_param(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "Missing or invalid #{key}"}
    end
  end
end
