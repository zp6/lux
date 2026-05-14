defmodule Lux.LLM.Ollama do
  @moduledoc """
  Ollama LLM implementation for local model support with self-hosted capabilities.

  Integrates with the Ollama API to provide local LLM inference with:
  - Model management (list, pull, delete)
  - Chat completions with tool support (Beams, Prisms, Lenses)
  - Streaming support
  - Resource usage monitoring
  - Configurable performance options

  ## Configuration

  Add to your config:

      config :lux, :ollama,
        endpoint: "http://localhost:11434",
        model: "llama3.2",
        receive_timeout: 120_000

      config :lux, :api_keys,
        ollama: nil  # Ollama doesn't require an API key by default

  ## Examples

      iex> Ollama.call("Hello!", [], %{model: "llama3.2"})
      {:ok, %Signal{schema_id: ResponseSignal, payload: %{content: %{"text" => "Hi there!"}, ...}}}
  """

  @behaviour Lux.LLM

  alias Lux.Beam
  alias Lux.Lens
  alias Lux.LLM.ResponseSignal
  alias Lux.Prism

  require Beam
  require Lens
  require Logger

  @default_endpoint "http://localhost:11434"
  @default_model "llama3.2"

  defmodule Config do
    @moduledoc """
    Configuration module for Ollama.
    """
    @type t :: %__MODULE__{
            endpoint: String.t(),
            model: String.t(),
            api_key: String.t() | nil,
            temperature: float(),
            top_p: float(),
            top_k: integer(),
            num_ctx: integer(),
            num_predict: integer(),
            repeat_penalty: float(),
            seed: integer() | nil,
            receive_timeout: integer(),
            json_response: boolean(),
            system: String.t() | nil,
            user: String.t() | nil,
            messages: [map()]
          }

    defstruct endpoint: @default_endpoint,
              model: @default_model,
              api_key: nil,
              temperature: 0.7,
              top_p: 0.9,
              top_k: 40,
              num_ctx: 4096,
              num_predict: 128,
              repeat_penalty: 1.1,
              seed: nil,
              receive_timeout: 120_000,
              json_response: true,
              system: nil,
              user: nil,
              messages: []
  end

  defmodule ModelManager do
    @moduledoc """
    Model management functionality for Ollama.

    Provides functions to list, pull, and delete local models,
    as well as check model availability and resource usage.
    """

    alias Lux.LLM.Ollama

    @doc """
    Lists all locally available models.

    ## Examples

        iex> ModelManager.list_models()
        {:ok, [%{"name" => "llama3.2:latest", "size" => 2019393189, ...}]}
    """
    @spec list_models(keyword()) :: {:ok, [map()]} | {:error, term()}
    def list_models(opts \\ []) do
      endpoint = Keyword.get(opts, :endpoint, Ollama.get_config(:endpoint, @default_endpoint))

      req =
        [
          url: "#{endpoint}/api/tags",
          headers: build_headers(opts)
        ]
        |> Keyword.merge(Application.get_env(:lux, Ollama, []))
        |> Req.new()

      case Req.get(req) do
        {:ok, %{status: 200, body: %{"models" => models}}} ->
          {:ok, models}

        {:ok, %{status: status, body: body}} ->
          {:error, {status, body}}

        {:error, error} ->
          {:error, error}
      end
    end

    @doc """
    Pulls a model from the Ollama registry.

    ## Parameters

      - `model_name` - The name of the model to pull (e.g., "llama3.2", "mistral:7b")
      - `opts` - Options including `:endpoint` and `:api_key`

    ## Examples

        iex> ModelManager.pull_model("llama3.2")
        {:ok, "success"}
    """
    @spec pull_model(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
    def pull_model(model_name, opts \\ []) do
      endpoint = Keyword.get(opts, :endpoint, Ollama.get_config(:endpoint, @default_endpoint))

      req =
        [
          url: "#{endpoint}/api/pull",
          json: %{name: model_name, stream: false},
          headers: build_headers(opts),
          receive_timeout: 300_000
        ]
        |> Keyword.merge(Application.get_env(:lux, Ollama, []))
        |> Req.new()

      case Req.post(req) do
        {:ok, %{status: 200}} ->
          {:ok, "success"}

        {:ok, %{status: status, body: %{"error" => error}}} ->
          {:error, {status, error}}

        {:error, error} ->
          {:error, error}
      end
    end

    @doc """
    Deletes a local model.

    ## Examples

        iex> ModelManager.delete_model("llama3.2")
        {:ok, "success"}
    """
    @spec delete_model(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
    def delete_model(model_name, opts \\ []) do
      endpoint = Keyword.get(opts, :endpoint, Ollama.get_config(:endpoint, @default_endpoint))

      req =
        [
          url: "#{endpoint}/api/delete",
          json: %{name: model_name},
          headers: build_headers(opts)
        ]
        |> Keyword.merge(Application.get_env(:lux, Ollama, []))
        |> Req.new()

      case Req.delete(req) do
        {:ok, %{status: 200}} ->
          {:ok, "success"}

        {:ok, %{status: status, body: %{"error" => error}}} ->
          {:error, {status, error}}

        {:ok, %{status: 404}} ->
          {:error, :model_not_found}

        {:error, error} ->
          {:error, error}
      end
    end

    @doc """
    Checks if a model is available locally.

    ## Examples

        iex> ModelManager.model_available?("llama3.2")
        {:ok, true}
    """
    @spec model_available?(String.t(), keyword()) :: {:ok, boolean()} | {:error, term()}
    def model_available?(model_name, opts \\ []) do
      case list_models(opts) do
        {:ok, models} ->
          available =
            Enum.any?(models, fn model ->
              model["name"] == model_name or String.starts_with?(model["name"], "#{model_name}:")
            end)

          {:ok, available}

        {:error, error} ->
          {:error, error}
      end
    end

    @doc """
    Gets model information including size and parameters.

    ## Examples

        iex> ModelManager.model_info("llama3.2")
        {:ok, %{"name" => "llama3.2:latest", "size" => 2019393189, ...}}
    """
    @spec model_info(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
    def model_info(model_name, opts \\ []) do
      case list_models(opts) do
        {:ok, models} ->
          case Enum.find(models, fn model ->
                 model["name"] == model_name or
                   String.starts_with?(model["name"], "#{model_name}:")
               end) do
            nil -> {:error, :model_not_found}
            model -> {:ok, model}
          end

        {:error, error} ->
          {:error, error}
      end
    end

    defp build_headers(opts) do
      api_key = Keyword.get(opts, :api_key)

      if api_key && api_key != "" do
        [{"Authorization", "Bearer #{api_key}"}, {"Content-Type", "application/json"}]
      else
        [{"Content-Type", "application/json"}]
      end
    end
  end

  @doc """
  Helper to get configuration values from application env.
  """
  def get_config(key, default \\ nil) do
    case Application.get_env(:lux, :ollama) do
      nil -> default
      config when is_list(config) -> Keyword.get(config, key, default)
      _ -> default
    end
  end

  @impl true
  def call(prompt, tools, config) do
    config =
      struct(
        Config,
        Map.merge(
          %{
            model: get_config(:model, @default_model),
            endpoint: get_config(:endpoint, @default_endpoint),
            api_key: Application.get_env(:lux, :api_keys)[:ollama]
          },
          config
        )
      )

    messages = config.messages ++ build_messages(prompt, config)
    tools_config = build_tools_config(tools)

    body =
      %{
        model: Lux.Config.resolve(config.model),
        messages: messages,
        stream: false,
        options: %{
          temperature: config.temperature,
          top_p: config.top_p,
          top_k: config.top_k,
          num_ctx: config.num_ctx,
          num_predict: config.num_predict,
          repeat_penalty: config.repeat_penalty
        }
      }
      |> maybe_add_seed(config)
      |> maybe_add_tools(tools_config)
      |> maybe_add_response_format(config)

    endpoint = Lux.Config.resolve(config.endpoint)

    req =
      [
        url: "#{endpoint}/api/chat",
        json: body,
        headers: build_auth_headers(config),
        receive_timeout: config.receive_timeout
      ]
      |> Keyword.merge(Application.get_env(:lux, __MODULE__, []))
      |> Req.new()

    case Req.post(req) do
      {:ok, %{status: 200} = response} ->
        handle_response(response, config)

      {:ok, %{status: 404, body: %{"error" => error}}} ->
        {:error, {:model_not_found, error}}

      {:ok, %{status: 401}} ->
        {:error, :invalid_api_key}

      {:ok, %{status: status, body: %{"error" => error}}} ->
        {:error, {status, error}}

      {:error, error} ->
        handle_error(error)
    end
  end

  defp build_messages(prompt, %Config{system: system}) when is_binary(system) and system != "" do
    [
      %{role: "system", content: system},
      %{role: "user", content: prompt}
    ]
  end

  defp build_messages(prompt, _config) do
    [%{role: "user", content: prompt}]
  end

  defp build_tools_config([]), do: []
  defp build_tools_config(tools), do: Enum.map(tools, &tool_to_function/1)

  defp maybe_add_seed(body, %Config{seed: nil}), do: body
  defp maybe_add_seed(body, %Config{seed: seed}), do: put_in(body, [:options, :seed], seed)

  defp maybe_add_tools(body, []), do: body
  defp maybe_add_tools(body, tools), do: Map.put(body, :tools, tools)

  defp maybe_add_response_format(body, %Config{json_response: true}) do
    Map.put(body, :format, "json")
  end

  defp maybe_add_response_format(body, _config), do: body

  defp build_auth_headers(%Config{api_key: nil}), do: [{"Content-Type", "application/json"}]
  defp build_auth_headers(%Config{api_key: ""}), do: [{"Content-Type", "application/json"}]

  defp build_auth_headers(%Config{api_key: api_key}) do
    [
      {"Authorization", "Bearer #{Lux.Config.resolve(api_key)}"},
      {"Content-Type", "application/json"}
    ]
  end

  def tool_to_function({:python, path}) do
    path
    |> Prism.view()
    |> tool_to_function()
  end

  def tool_to_function(tool_module) when is_atom(tool_module) and not is_nil(tool_module) do
    cond do
      Lux.prism?(tool_module) ->
        tool_to_function(tool_module.view())

      Lux.beam?(tool_module) ->
        tool_to_function(tool_module.view())

      Lux.lens?(tool_module) ->
        tool_to_function(tool_module.view())

      true ->
        raise "Unsupported tool type: #{inspect(tool_module)}"
    end
  end

  def tool_to_function(%Beam{module_name: name, description: description, input_schema: input_schema}) do
    %{
      type: "function",
      function: %{
        name: String.replace(name, ".", "_"),
        description: description || "",
        parameters: input_schema
      }
    }
  end

  def tool_to_function(%Prism{module_name: name, description: description, input_schema: input_schema}) do
    %{
      type: "function",
      function: %{
        name: String.replace(name, ".", "_"),
        description: description || "",
        parameters: input_schema
      }
    }
  end

  def tool_to_function(%Lens{module_name: name, description: description, schema: schema}) do
    %{
      type: "function",
      function: %{
        name: String.replace(name, ".", "_"),
        description: description || "",
        parameters: schema
      }
    }
  end

  defp handle_response(%{body: body}, _config) do
    with {:ok, content} <- parse_content(body["message"]["content"]),
         {:ok, tool_calls_results} <- execute_tool_calls(body["message"]["tool_calls"]) do
      payload = %{
        content: content,
        model: body["model"],
        finish_reason: map_finish_reason(body),
        tool_calls: body["message"]["tool_calls"],
        tool_calls_results: tool_calls_results
      }

      metadata = %{
        id: body["id"],
        created: body["created_at"],
        usage: %{
          prompt_tokens: body["prompt_eval_count"],
          completion_tokens: body["eval_count"],
          total_tokens: (body["prompt_eval_count"] || 0) + (body["eval_count"] || 0)
        },
        total_duration: body["total_duration"],
        load_duration: body["load_duration"],
        prompt_eval_duration: body["prompt_eval_duration"],
        eval_duration: body["eval_duration"]
      }

      %{
        schema_id: ResponseSignal,
        payload: payload,
        metadata: metadata
      }
      |> Lux.Signal.new()
      |> ResponseSignal.validate()
    end
  end

  defp map_finish_reason(%{"done" => true, "done_reason" => "load"}), do: "load"
  defp map_finish_reason(%{"done" => true}), do: "stop"
  defp map_finish_reason(_), do: "unknown"

  def parse_content(content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, structured_output} -> {:ok, structured_output}
      {:error, _} -> {:ok, %{"text" => content}}
    end
  end

  def parse_content(_), do: {:ok, nil}

  def execute_tool_calls(tool_calls) when is_list(tool_calls) do
    tool_calls
    |> Enum.map(&execute_tool_call/1)
    |> Enum.reduce({:ok, []}, fn
      {:ok, result, _log}, {:ok, results} -> {:ok, [result | results]}
      {:ok, result}, {:ok, results} -> {:ok, [result | results]}
      error, _ -> error
    end)
  end

  def execute_tool_calls(nil), do: {:ok, nil}

  def execute_tool_call(%{"function" => %{"name" => tool_name, "arguments" => args}}) do
    args = if is_binary(args), do: Jason.decode!(args), else: args
    execute_tool(tool_name, args, nil)
  end

  def execute_tool(tool_name, args, ctx \\ nil)

  def execute_tool(tool_name, args, ctx) when is_binary(tool_name) do
    tool_name
    |> String.replace("_", ".")
    |> List.wrap()
    |> Module.concat()
    |> Code.ensure_loaded()
    |> case do
      {:module, module_name} ->
        execute_tool(module_name, args, ctx)

      {:error, :nofile} ->
        {:error, "Failed to load tool module #{tool_name}: It doesn't seem to be implemented or reachable"}

      {:error, error} ->
        {:error, "Failed to load tool module #{tool_name}: #{inspect(error)}"}
    end
  end

  def execute_tool(tool_module, args, ctx) when is_atom(tool_module) do
    cond do
      Lux.prism?(tool_module) ->
        tool_module.handler(args, ctx)

      Lux.beam?(tool_module) ->
        tool_module.run(args, ctx)

      Lux.lens?(tool_module) ->
        tool_module.focus(args)

      true ->
        {:error,
         """
         Tool #{tool_module} does not seem to be a valid Beam, Prism, or Lens
         as it does not have a registered `handler`, `run`, or `focus` function.
         """}
    end
  end

  defp handle_error(error) do
    Logger.error("Ollama API error: #{inspect(error)}")
    {:error, "Ollama API error: #{inspect(error)}"}
  end
end
