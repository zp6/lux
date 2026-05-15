defmodule Lux.Prisms.Discord.Moderation.WarningSystem do
  @moduledoc """
  A prism for managing a warning system in Discord guilds.

  Tracks user warnings with configurable thresholds for automatic actions.
  Warnings expire after a configurable period.

  ## Features
  - Add/remove warnings for users
  - List warnings for a user
  - Configure auto-action thresholds (timeout, kick, ban)
  - Warning expiration support

  ## Examples

      iex> WarningSystem.handler(%{
      ...>   action: "warn",
      ...>   guild_id: "111222333",
      ...>   user_id: "444555666",
      ...>   reason: "Inappropriate language",
      ...>   expires_hours: 168
      ...> }, %{name: "Agent"})
      {:ok, %{warned: true, user_id: "444555666", total_warnings: 3, action_taken: "timeout"}}
  """

  use Lux.Prism,
    name: "Discord Warning System",
    description: "Manages a configurable warning system for Discord guild members",
    input_schema: %{
      type: :object,
      properties: %{
        action: %{
          type: :string,
          description: "Warning action to perform",
          enum: ["warn", "list", "remove", "clear"]
        },
        guild_id: %{
          type: :string,
          description: "The ID of the guild",
          pattern: "^[0-9]{17,20}$"
        },
        user_id: %{
          type: :string,
          description: "The ID of the user",
          pattern: "^[0-9]{17,20}$"
        },
        reason: %{
          type: :string,
          description: "Reason for the warning",
          maxLength: 1024
        },
        warning_id: %{
          type: :string,
          description: "Warning ID for remove action"
        },
        expires_hours: %{
          type: :integer,
          description: "Hours until warning expires (default: 168 = 7 days)",
          default: 168
        },
        auto_actions: %{
          type: :object,
          description: "Thresholds for automatic actions: %{3 => :timeout, 5 => :kick, 10 => :ban}"
        }
      },
      required: ["action", "guild_id", "user_id"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        action: %{type: :string},
        success: %{type: :boolean},
        user_id: %{type: :string},
        total_warnings: %{type: :integer},
        action_taken: %{type: :string},
        warnings: %{type: :array}
      },
      required: ["action", "success"]
    }

  alias Lux.Integrations.Discord.Client
  require Logger

  # Default auto-action thresholds: warnings => action
  @default_thresholds %{3 => "timeout", 5 => "kick", 10 => "ban"}

  def handler(params, agent) do
    agent_name = agent[:name] || "Unknown Agent"
    action = params[:action]

    with {:ok, guild_id} <- validate_param(params, :guild_id),
         {:ok, user_id} <- validate_param(params, :user_id) do

      Logger.info("Agent #{agent_name} warning action #{action} for user #{user_id} in guild #{guild_id}")

      case action do
        "warn" -> add_warning(guild_id, user_id, params, agent_name)
        "list" -> list_warnings(guild_id, user_id)
        "remove" -> remove_warning(guild_id, user_id, params)
        "clear" -> clear_warnings(guild_id, user_id, agent_name)
        _ -> {:error, "Unsupported action: #{action}"}
      end
    end
  end

  defp add_warning(guild_id, user_id, params, agent_name) do
    reason = params[:reason] || "No reason provided"
    expires_hours = params[:expires_hours] || 168
    thresholds = params[:auto_actions] || @default_thresholds

    body = %{
      guild_id: guild_id,
      user_id: user_id,
      reason: reason,
      expires_at: DateTime.add(DateTime.utc_now(), expires_hours * 3600, :second) |> DateTime.to_iso8601(),
      issued_by: agent_name
    }

    case Client.request(:post, "/guilds/#{guild_id}/members/#{user_id}/warnings", %{json: body}) do
      {:ok, %{"total_warnings" => total} = response} ->
        action_taken = determine_auto_action(total, thresholds)

        if action_taken do
          Logger.info("Auto-action triggered: #{action_taken} for user #{user_id}")
        end

        {:ok, %{
          action: "warn",
          success: true,
          user_id: user_id,
          total_warnings: total,
          action_taken: action_taken,
          warnings: Map.get(response, "warnings", [])
        }}

      {:ok, response} ->
        {:ok, %{
          action: "warn",
          success: true,
          user_id: user_id,
          total_warnings: Map.get(response, "total", 1),
          action_taken: nil,
          warnings: Map.get(response, "warnings", [])
        }}

      {:error, error} ->
        {:error, "Failed to add warning: #{inspect(error)}"}
    end
  end

  defp list_warnings(guild_id, user_id) do
    case Client.request(:get, "/guilds/#{guild_id}/members/#{user_id}/warnings") do
      {:ok, %{"warnings" => warnings}} ->
        {:ok, %{
          action: "list",
          success: true,
          user_id: user_id,
          total_warnings: length(warnings),
          warnings: warnings
        }}

      {:error, error} ->
        {:error, "Failed to list warnings: #{inspect(error)}"}
    end
  end

  defp remove_warning(guild_id, user_id, params) do
    case Map.get(params, :warning_id) do
      nil -> {:error, "warning_id is required for remove action"}
      warning_id ->
        case Client.request(:delete, "/guilds/#{guild_id}/members/#{user_id}/warnings/#{warning_id}") do
          {:ok, _} ->
            {:ok, %{action: "remove", success: true, user_id: user_id, warning_id: warning_id}}
          {:error, error} ->
            {:error, "Failed to remove warning: #{inspect(error)}"}
        end
    end
  end

  defp clear_warnings(guild_id, user_id, agent_name) do
    Logger.info("Agent #{agent_name} clearing all warnings for user #{user_id}")

    case Client.request(:delete, "/guilds/#{guild_id}/members/#{user_id}/warnings") do
      {:ok, _} ->
        {:ok, %{action: "clear", success: true, user_id: user_id, total_warnings: 0}}
      {:error, error} ->
        {:error, "Failed to clear warnings: #{inspect(error)}"}
    end
  end

  defp determine_auto_action(total_warnings, thresholds) do
    thresholds
    |> Enum.filter(fn {threshold, _} -> total_warnings >= threshold end)
    |> Enum.max_by(fn {threshold, _} -> threshold end, fn -> nil end)
    |> case do
      {_, action} -> action
      nil -> nil
    end
  end

  defp validate_param(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "Missing or invalid #{key}"}
    end
  end
end
