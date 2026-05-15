defmodule Lux.Prisms.TradingView.PineScriptExecutor do
  @moduledoc """
  Prism for executing custom Pine Script strategies and indicators on TradingView.

  Allows running user-defined Pine Script code for:
  - Custom indicator calculations
  - Strategy signal generation
  - Alert condition evaluation

  ## Examples

      iex> PineScriptExecutor.handler(%{
      ...>   action: "execute",
      ...>   script: "//@version=5\\nindicator(\\"My RSI\\")\\nplot(ta.rsi(close, 14))",
      ...>   symbol: "BINANCE:BTCUSDT",
      ...>   interval: "1h"
      ...> }, %{name: "Agent"})
      {:ok, %{executed: true, output: %{plots: [%{name: "My RSI", values: [65.4, ...]}]}}}
  """

  use Lux.Prism,
    name: "TradingView Pine Script Executor",
    description: "Executes custom Pine Script strategies and indicators",
    input_schema: %{
      type: :object,
      properties: %{
        action: %{
          type: :string,
          description: "Execution action",
          enum: ["execute", "validate", "list_scripts", "save_script"]
        },
        script: %{
          type: :string,
          description: "Pine Script source code to execute"
        },
        script_id: %{
          type: :string,
          description: "Saved script ID for execution"
        },
        script_name: %{
          type: :string,
          description: "Name to save the script as"
        },
        symbol: %{
          type: :string,
          description: "Trading symbol to run the script on"
        },
        interval: %{
          type: :string,
          description: "Timeframe for execution",
          default: "1h"
        },
        limit: %{
          type: :integer,
          description: "Number of bars to calculate",
          default: 100,
          minimum: 1,
          maximum: 5000
        }
      },
      required: ["action"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        action: %{type: :string},
        success: %{type: :boolean},
        output: %{type: :object},
        errors: %{type: :array, items: %{type: :string}}
      },
      required: ["action", "success"]
    }

  alias Lux.Integrations.TradingView.Client
  require Logger

  def handler(params, agent) do
    agent_name = agent[:name] || "Unknown Agent"
    action = params[:action]

    Logger.info("Agent #{agent_name} Pine Script action: #{action}")

    case action do
      "execute" -> execute_script(params, agent_name)
      "validate" -> validate_script(params, agent_name)
      "list_scripts" -> list_scripts(agent_name)
      "save_script" -> save_script(params, agent_name)
      _ -> {:error, "Unsupported action: #{action}"}
    end
  end

  defp execute_script(params, agent_name) do
    script = get_script_source(params)

    with {:ok, script_code} <- script,
         {:ok, symbol} <- require_param(params, :symbol) do

      body = %{
        script: script_code,
        symbol: symbol,
        interval: params[:interval] || "1h",
        limit: params[:limit] || 100
      }

      case Client.request(:post, "/pine/execute", %{json: body}) do
        {:ok, %{"plots" => _} = output} ->
          Logger.info("Agent #{agent_name} executed Pine Script on #{symbol}")
          {:ok, %{action: "execute", success: true, output: output}}

        {:ok, %{"errors" => errors}} ->
          Logger.warning("Pine Script execution had errors: #{inspect(errors)}")
          {:ok, %{action: "execute", success: false, errors: errors}}

        {:ok, output} ->
          {:ok, %{action: "execute", success: true, output: output}}

        {:error, error} ->
          {:error, "Script execution failed: #{inspect(error)}"}
      end
    end
  end

  defp validate_script(params, _agent_name) do
    case get_script_source(params) do
      {:ok, script_code} ->
        case Client.request(:post, "/pine/validate", %{json: %{script: script_code}}) do
          {:ok, %{"valid" => true} = output} ->
            {:ok, %{action: "validate", success: true, output: output}}

          {:ok, %{"valid" => false, "errors" => errors}} ->
            {:ok, %{action: "validate", success: false, errors: errors}}

          {:error, error} ->
            {:error, "Validation failed: #{inspect(error)}"}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp list_scripts(agent_name) do
    case Client.request(:get, "/pine/scripts") do
      {:ok, %{"scripts" => scripts}} ->
        Logger.info("Agent #{agent_name} listed #{length(scripts)} saved scripts")
        {:ok, %{action: "list_scripts", success: true, output: %{"scripts" => scripts}}}

      {:error, error} ->
        {:error, "Failed to list scripts: #{inspect(error)}"}
    end
  end

  defp save_script(params, agent_name) do
    with {:ok, script_code} <- require_param(params, :script),
         {:ok, script_name} <- require_param(params, :script_name) do

      body = %{script: script_code, name: script_name}

      case Client.request(:post, "/pine/scripts", %{json: body}) do
        {:ok, %{"id" => script_id}} ->
          Logger.info("Agent #{agent_name} saved Pine Script: #{script_name} (#{script_id})")
          {:ok, %{action: "save_script", success: true, output: %{"script_id" => script_id, "name" => script_name}}}

        {:error, error} ->
          {:error, "Failed to save script: #{inspect(error)}"}
      end
    end
  end

  defp get_script_source(%{script: script}) when is_binary(script) and byte_size(script) > 0, do: {:ok, script}
  defp get_script_source(%{script_id: id}) when is_binary(id), do: {:ok, {:ref, id}}
  defp get_script_source(_), do: {:error, "Either 'script' or 'script_id' is required"}

  defp require_param(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _ -> {:error, "Missing required parameter: #{key}"}
    end
  end
end
