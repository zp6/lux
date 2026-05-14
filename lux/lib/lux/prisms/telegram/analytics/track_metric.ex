defmodule Lux.Prisms.Telegram.Analytics.TrackMetric do
  @moduledoc """
  A prism for tracking custom metrics in the Telegram analytics engine.

  This prism allows agents to record arbitrary metrics for monitoring
  and analysis. Supports both counter-style increments and gauge-style
  absolute values.

  ## Implementation Details

  - Delegates to `Lux.Integrations.Telegram.Analytics` for storage
  - Supports counter increments and gauge sets
  - Optional metadata can be attached to any metric

  ## Examples

      # Increment a counter
      iex> TrackMetric.handler(%{
      ...>   namespace: "custom",
      ...>   key: "webhook_events",
      ...>   value: 1,
      ...>   type: "counter"
      ...> }, %{name: "Agent"})
      {:ok, %{tracked: true, namespace: "custom", key: "webhook_events"}}

      # Set a gauge
      iex> TrackMetric.handler(%{
      ...>   namespace: "custom",
      ...>   key: "queue_size",
      ...>   value: 42,
      ...>   type: "gauge"
      ...> }, %{name: "Agent"})
      {:ok, %{tracked: true, namespace: "custom", key: "queue_size"}}
  """

  use Lux.Prism,
    name: "Track Telegram Metric",
    description: "Tracks a custom metric in the Telegram analytics engine",
    input_schema: %{
      type: :object,
      properties: %{
        namespace: %{
          type: :string,
          description: "Metric namespace: messages, users, commands, errors, performance, or custom",
          enum: ["messages", "users", "commands", "errors", "performance", "custom"]
        },
        key: %{
          type: :string,
          description: "The metric identifier"
        },
        value: %{
          type: :number,
          description: "The metric value to record (default: 1)"
        },
        type: %{
          type: :string,
          description: "Tracking type: counter (increment) or gauge (absolute value)",
          enum: ["counter", "gauge"],
          default: "counter"
        },
        meta: %{
          type: :object,
          description: "Optional metadata to attach to the metric"
        }
      },
      required: ["namespace", "key"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        tracked: %{
          type: :boolean,
          description: "Whether the metric was successfully tracked"
        },
        namespace: %{
          type: :string,
          description: "The namespace the metric was tracked under"
        },
        key: %{
          type: :string,
          description: "The metric key that was tracked"
        }
      },
      required: ["tracked", "namespace", "key"]
    }

  require Logger

  @doc """
  Handles the request to track a custom metric.
  """
  def handler(params, agent) do
    agent_name = agent[:name] || "Unknown Agent"
    namespace_str = params[:namespace]
    key_str = params[:key]
    value = Map.get(params, :value, 1)
    type = Map.get(params, :type, "counter")
    meta = Map.get(params, :meta, %{})

    Logger.info("Agent #{agent_name} tracking metric #{namespace_str}.#{key_str} = #{value} (#{type})")

    namespace = String.to_existing_atom(namespace_str)
    key = if is_binary(key_str), do: String.to_atom(key_str), else: key_str
    opts = [meta: meta]

    case type do
      "counter" ->
        Analytics().track(namespace, key, value, opts)

      "gauge" ->
        Analytics().set_gauge(namespace, key, value, opts)
    end

    {:ok, %{tracked: true, namespace: namespace_str, key: key_str}}
  rescue
    ArgumentError ->
      {:error, "Invalid namespace: #{namespace_str}"}
  end

  defp Analytics, do: Lux.Integrations.Telegram.Analytics
end
