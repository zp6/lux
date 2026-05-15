defmodule Lux.Prisms.Twitter.Auth.RateLimitManager do
  @moduledoc """
  A prism for managing Twitter API rate limits — tracking usage, enforcing
  limits, and providing backoff strategies.

  ## Examples

      iex> RateLimitManager.handler(%{
      ...>   action: "check",
      ...>   endpoint: "/tweets"
      ...> }, %{name: "Agent"})
      {:ok, %{allowed: true, remaining: 900, reset_at: "..."}}
  """

  use Lux.Prism,
    name: "Twitter Rate Limit Manager",
    description: "Tracks and manages Twitter API rate limits with backoff strategies",
    input_schema: %{
      type: :object,
      properties: %{
        action: %{
          type: :string,
          description: "Action: check, record, get_status, reset, wait_if_needed",
          enum: ["check", "record", "get_status", "reset", "wait_if_needed"]
        },
        endpoint: %{
          type: :string,
          description: "API endpoint to check/record (e.g., '/tweets')"
        },
        method: %{
          type: :string,
          description: "HTTP method for the endpoint",
          enum: ["GET", "POST", "PUT", "DELETE"]
        },
        remaining: %{
          type: :integer,
          description: "Remaining calls (from API response header)"
        },
        limit: %{
          type: :integer,
          description: "Rate limit ceiling"
        },
        reset_at: %{
          type: :integer,
          description: "Unix timestamp when limit resets"
        }
      },
      required: ["action"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        allowed: %{type: :boolean},
        remaining: %{type: :integer},
        limit: %{type: :integer},
        reset_at: %{type: :string},
        endpoints: %{type: :object}
      }
    }

  require Logger

  @rate_limits %{
    {"/tweets", "POST"} => {300, 15 * 60},
    {"/tweets", "DELETE"} => {300, 15 * 60},
    {"/tweets", "PUT"} => {300, 15 * 60},
    {"/tweets/:id", "GET"} => {900, 15 * 60},
    {"/users/me", "GET"} => {75, 15 * 60},
    {"/users/:id/followers", "GET"} => {900, 15 * 60},
    {"/users/:id/following", "GET"} => {900, 15 * 60},
    {"/media/upload", "POST"} => {200, 15 * 60}
  }

  @limits_table :lux_twitter_rate_limits

  def handler(params, agent) do
    agent_name = agent[:name] || "Unknown Agent"
    ensure_limits_table()

    case params[:action] do
      "check" -> check_limit(params, agent_name)
      "record" -> record_usage(params, agent_name)
      "get_status" -> get_status(params)
      "reset" -> reset_endpoint(params)
      "wait_if_needed" -> wait_if_needed(params, agent_name)
      _ -> {:error, "Unknown action: #{params[:action]}"}
    end
  end

  defp check_limit(params, agent_name) do
    endpoint = params[:endpoint] || "/tweets"
    method = params[:method] || "GET"

    Logger.debug("Agent #{agent_name} checking rate limit for #{method} #{endpoint}")

    key = rate_limit_key(endpoint, method)
    {default_limit, window_seconds} = Map.get(@rate_limits, key, {900, 15 * 60})

    state = get_endpoint_state(key)
    now = System.system_time(:second)

    # Check if window has reset
    state = if state[:reset_at] && state[:reset_at] <= now do
      %{limit: default_limit, remaining: default_limit, reset_at: now + window_seconds, used: 0}
    else
      state
    end

    remaining = state[:remaining] || default_limit
    limit = state[:limit] || default_limit
    reset_at = state[:reset_at] || now + window_seconds

    allowed = remaining > 0

    {:ok, %{
      allowed: allowed,
      remaining: remaining,
      limit: limit,
      reset_at: DateTime.to_iso8601(DateTime.from_unix!(reset_at)),
      reset_in_seconds: max(0, reset_at - now)
    }}
  end

  defp record_usage(params, agent_name) do
    endpoint = params[:endpoint] || "/tweets"
    method = params[:method] || "GET"

    Logger.debug("Agent #{agent_name} recording usage for #{method} #{endpoint}")

    key = rate_limit_key(endpoint, method)
    state = get_endpoint_state(key)

    # If API provided actual values, use them
    updated = cond do
      params[:remaining] != nil and params[:reset_at] != nil ->
        %{
          limit: params[:limit] || state[:limit],
          remaining: params[:remaining],
          reset_at: params[:reset_at],
          used: (state[:used] || 0) + 1
        }

      true ->
        %{state |
          remaining: max(0, (state[:remaining] || 900) - 1),
          used: (state[:used] || 0) + 1
        }
    end

    :ets.insert(@limits_table, {key, updated})

    {:ok, %{
      recorded: true,
      remaining: updated[:remaining],
      reset_at: updated[:reset_at]
    }}
  end

  defp get_status(params) do
    case params[:endpoint] do
      nil ->
        # Return all endpoint statuses
        all = :ets.tab2list(@limits_table)
        |> Enum.map(fn {key, state} ->
          {endpoint, method} = key
          {endpoint, method, state}
        end)
        |> Map.new(fn {endpoint, method, state} ->
          now = System.system_time(:second)
          {{endpoint, method}, %{
            remaining: state[:remaining],
            limit: state[:limit],
            used: state[:used],
            reset_at: state[:reset_at],
            reset_in_seconds: max(0, (state[:reset_at] || 0) - now)
          }}
        end)

        {:ok, %{endpoints: all}}

      endpoint ->
        method = params[:method] || "GET"
        key = rate_limit_key(endpoint, method)
        state = get_endpoint_state(key)
        {:ok, %{endpoint: endpoint, method: method, state: state}}
    end
  end

  defp reset_endpoint(params) do
    endpoint = params[:endpoint] || "/tweets"
    method = params[:method] || "GET"
    key = rate_limit_key(endpoint, method)

    {default_limit, _} = Map.get(@rate_limits, key, {900, 15 * 60})

    :ets.insert(@limits_table, {key, %{limit: default_limit, remaining: default_limit, used: 0, reset_at: nil}})

    {:ok, %{endpoint: endpoint, method: method, status: "reset"}}
  end

  defp wait_if_needed(params, agent_name) do
    case check_limit(params, agent_name) do
      {:ok, %{allowed: true}} ->
        {:ok, %{waited: false, allowed: true}}

      {:ok, %{reset_in_seconds: seconds}} when seconds > 0 ->
        wait_seconds = min(seconds + 1, 60)  # Cap wait at 60 seconds
        Logger.info("Agent #{agent_name} rate limited, waiting #{wait_seconds}s")

        # In production, this would be handled by a task/process
        {:ok, %{waited: true, wait_seconds: wait_seconds, allowed: false}}

      {:ok, _} ->
        {:ok, %{waited: false, allowed: false}}
    end
  end

  defp rate_limit_key(endpoint, method) do
    # Normalize endpoint patterns
    normalized = endpoint
    |> String.replace(~r/\/\d+/, "/:id")

    {normalized, method}
  end

  defp get_endpoint_state(key) do
    case :ets.lookup(@limits_table, key) do
      [{^key, state}] -> state
      [] -> %{limit: nil, remaining: nil, used: 0, reset_at: nil}
    end
  end

  defp ensure_limits_table do
    case :ets.whereis(@limits_table) do
      :undefined -> :ets.new(@limits_table, [:named_table, :public, :set])
      _ -> :ok
    end
  end
end
