defmodule Lux.LLM.OpenRouter do
  @moduledoc """
  OpenRouter LLM implementation that provides access to hundreds of models
  through a single unified OpenAI-compatible API.

  OpenRouter acts as a meta-provider, routing requests to various LLM providers
  (OpenAI, Anthropic, Google, Meta, Mistral, etc.) with automatic fallback,
  cost optimization, and unified billing.

  ## Features

  - Access to 200+ models from multiple providers
  - OpenAI-compatible API interface
  - Automatic provider fallback and routing
  - Cost tracking and optimization
  - Rate limiting and retry support
  - Tool/function calling support

  ## Configuration

      config :lux, Lux.LLM.OpenRouter,
        endpoint: "https://openrouter.ai/api/v1/chat/completions",
        api_key: System.get_env("OPENROUTER_API_KEY"),
        model: "openai/gpt-4o",
        site_url: "https://your-app.com",
        app_name: "Lux Agent"

  ## Usage

      {:ok, signal} = Lux.LLM.OpenRouter.call("Explain DeFi yield farming", [], %{
        api_key: "sk-or-xxx",
        model: "anthropic/claude-3.5-sonnet"
      })

  ## Available Models (popular examples)

  - `openai/gpt-4o` - OpenAI GPT-4o
  - `anthropic/claude-3.5-sonnet` - Claude 3.5 Sonnet
  - `google/gemini-pro-1.5` - Google Gemini Pro
  - `meta-llama/llama-3.1-70b-instruct` - Llama 3.1 70B
  - `mistralai/mistral-large` - Mistral Large

  See https://openrouter.ai/models for the full list.
  """

  @behaviour Lux.LLM

  alias Lux.Beam
  alias Lux.Lens
  alias Lux.LLM.ResponseSignal
  alias Lux.Prism

  require Beam
  require Lens
  require Logger

  @default_endpoint "https://openrouter.ai/api/v1/chat/completions"
  @default_model "openai/gpt-4o"

  @model_pricing %{
    "openai/gpt-4o" => {2.50, 10.00},
    "openai/gpt-4o-mini" => {0.15, 0.60},
    "openai/gpt-4-turbo" => {10.00, 30.00},
    "openai/gpt-3.5-turbo" => {0.50, 1.50},
    "anthropic/claude-3.5-sonnet" => {3.00, 15.00},
    "anthropic/claude-3-haiku" => {0.25, 1.25},
    "anthropic/claude-3-opus" => {15.00, 75.00},
    "google/gemini-pro-1.5" => {1.25, 5.00},
    "google/gemini-flash-1.5" => {0.075, 0.30},
    "meta-llama/llama-3.1-70b-instruct" => {0.52, 0.75},
    "meta-llama/llama-3.1-8b-instruct" => {0.06, 0.06},
    "mistralai/mistral-large" => {2.00, 6.00},
    "mistralai/mistral-small" => {0.15, 0.45},
    "deepseek/deepseek-chat" => {0.14, 0.28},
    "deepseek/deepseek-coder" => {0.14, 0.28}
  }

  defmodule Config do
    @moduledoc """
    Configuration module for OpenRouter.
    """
    @type t :: %__MODULE__{
            endpoint: String.t(),
            model: String.t(),
            api_key: String.t(),
            temperature: float(),
            top_p: float(),
            max_tokens: integer(),
            frequency_penalty: float(),
            presence_penalty: float(),
            site_url: String.t(),
            app_name: String.t(),
            receive_timeout: integer(),
            json_response: boolean(),
            json_schema: map() | nil,
            tool_choice: map() | String.t() | nil,
            transforms: [String.t()],
            route: String.t(),
            user: String.t(),
            messages: [map()]
          }

    defstruct endpoint: "https://openrouter.ai/api/v1/chat/completions",
              model: "openai/gpt-4o",
              api_key: nil,
              temperature: 0.7,
              top_p: 1.0,
              max_tokens: nil,
              frequency_penalty: 0.0,
              presence_penalty: 0.0,
              site_url: nil,
              app_name: nil,
              receive_timeout: 60_000,
              json_response: true,
              json_schema: nil,
              tool_choice: nil,
              transforms: [],
              route: nil,
              user: nil,
              messages: []
  end

  @impl true
  def call(prompt, tools, config) do
    config =
      struct(
        Config,
        Map.merge(
          %{
            model: Application.get_env(:lux, :openrouter_models)[:default] || @default_model,
            api_key: Application.get_env(:lux, :api_keys)[:openrouter]
          },
          config
        )
      )

    messages = config.messages ++ build_messages(prompt)
    tools_config = build_tools_config(tools)

    body =
      %{
        model: Lux.Config.resolve(config.model),
        messages: messages,
        temperature: config.temperature,
        top_p: config.top_p,
        frequency_penalty: config.frequency_penalty,
        presence_penalty: config.presence_penalty
      }
      |> maybe_add_max_tokens(config.max_tokens)
      |> maybe_add_tools(tools_config, config.tool_choice)
      |> maybe_add_response_format(config)
      |> maybe_add_openrouter_options(config)

    headers =
      [
        {"Authorization", "Bearer #{Lux.Config.resolve(config.api_key)}"},
        {"Content-Type", "application/json"}
      ]
      |> maybe_add_optional_header("HTTP-Referer", config.site_url)
      |> maybe_add_optional_header("X-Title", config.app_name)

    request_opts =
      [
        url: config.endpoint || @default_endpoint,
        json: body,
        headers: headers
      ]
      |> Keyword.merge(Application.get_env(:lux, __MODULE__, []))

    request_opts
    |> Req.new()
    |> Req.post()
    |> case do
      {:ok, %{status: 200} = response} ->
        handle_response(response, config)

      {:ok, %{status: 401}} ->
        {:error, :invalid_api_key}

      {:ok, %{status: 402}} ->
        {:error, :insufficient_credits}

      {:ok, %{status: 429}} ->
        {:error, :rate_limited}

      {:ok, %{status: status, body: %{"error" => %{"message" => message}}}} ->
        {:error, {status, message}}

      {:ok, %{status: status, body: %{"message" => message}}} ->
        {:error, {status, message}}

      {:error, error} ->
        handle_error(error)
    end
  end

  defp build_messages(prompt) do
    [%{role: "user", content: prompt}]
  end

  defp build_tools_config([]), do: []
  defp build_tools_config(tools), do: Enum.map(tools, &tool_to_function/1)

  defp maybe_add_max_tokens(body, nil), do: body
  defp maybe_add_max_tokens(body, max_tokens), do: Map.put(body, :max_tokens, max_tokens)

  defp maybe_add_tools(body, [], _tool_choice), do: body

  defp maybe_add_tools(body, tools, tool_choice) do
    body
    |> Map.put(:tools, tools)
    |> Map.put(:tool_choice, format_tool_choice(tool_choice))
  end

  defp format_tool_choice(:none), do: "none"
  defp format_tool_choice(:auto), do: "auto"
  defp format_tool_choice(:required), do: "required"

  defp format_tool_choice(name) when is_binary(name),
    do: %{"type" => "function", "function" => %{"name" => String.replace(name, ".", "_")}}

  defp format_tool_choice(_), do: "auto"

  defp maybe_add_response_format(body, %Config{json_response: false}) do
    Map.put(body, :response_format, %{type: "text"})
  end

  defp maybe_add_response_format(body, %Config{json_response: true, json_schema: schema})
       when is_map(schema) do
    Map.put(body, :response_format, %{
      type: "json_schema",
      json_schema: schema
    })
  end

  defp maybe_add_response_format(body, %Config{json_response: true, json_schema: nil}) do
    Map.put(
      %{
        body
        | messages:
            Enum.map(body.messages, &%{&1 | content: &1.content <> "\n Reply in json format"})
      },
      :response_format,
      %{type: "json_object"}
    )
  end

  defp maybe_add_response_format(body, %Config{json_response: true, json_schema: schema})
       when is_atom(schema) do
    Map.put(body, :response_format, %{
      type: "json_schema",
      json_schema: %{name: schema.name(), schema: schema.schema()}
    })
  end

  defp maybe_add_response_format(body, _), do: Map.put(body, :response_format, %{type: "text"})

  defp maybe_add_openrouter_options(body, %Config{transforms: [], route: nil}), do: body

  defp maybe_add_openrouter_options(body, %Config{transforms: transforms, route: route}) do
    body
    |> then(fn b -> if transforms != [], do: Map.put(b, :transforms, transforms), else: b end)
    |> then(fn b -> if route, do: Map.put(b, :route, route), else: b end)
  end

  defp maybe_add_optional_header(headers, _key, nil), do: headers
  defp maybe_add_optional_header(headers, key, value), do: headers ++ [{key, value}]

  def tool_to_function({:python, path}) do
    path
    |> Prism.view()
    |> tool_to_function()
  end

  def tool_to_function(tool_module) when is_atom(tool_module) and not is_nil(tool_module) do
    cond do
      Lux.prism?(tool_module) -> tool_to_function(tool_module.view())
      Lux.beam?(tool_module) -> tool_to_function(tool_module.view())
      Lux.lens?(tool_module) -> tool_to_function(tool_module.view())
      true -> raise "Unsupported tool type: #{inspect(tool_module)}"
    end
  end

  def tool_to_function(%Beam{
        module_name: name,
        description: description,
        input_schema: input_schema
      }) do
    %{
      type: "function",
      function: %{
        name: String.replace(name, ".", "_"),
        description: description || "",
        parameters: input_schema
      }
    }
  end

  def tool_to_function(%Prism{
        module_name: name,
        description: description,
        input_schema: input_schema
      }) do
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
    with %{"choices" => [choice | _]} <- body,
         %{"message" => message, "finish_reason" => finish_reason} <- choice,
         {:ok, content} <- parse_content(message["content"]),
         {:ok, tool_calls_results} <- execute_tool_calls(message["tool_calls"]) do
      payload = %{
        content: content,
        model: body["model"],
        finish_reason: finish_reason,
        tool_calls: message["tool_calls"],
        tool_calls_results: tool_calls_results
      }

      metadata = %{
        id: body["id"],
        created: body["created"],
        usage: body["usage"],
        system_fingerprint: body["system_fingerprint"],
        model: body["model"]
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

  def parse_content(content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, structured_output} -> {:ok, structured_output}
      {:error, _} -> {:ok, content}
    end
  end

  def parse_content(_), do: {:ok, nil}

  def execute_tool_calls(tool_calls) when is_list(tool_calls) do
    tool_calls
    |> Enum.map(&execute_tool_call/1)
    |> Enum.reduce({:ok, []}, fn
      {:ok, result}, {:ok, results} -> {:ok, [result | results]}
      error, _ -> error
    end)
  end

  def execute_tool_calls(nil), do: {:ok, nil}

  def execute_tool_call(%{"function" => %{"name" => tool_name, "arguments" => args}}) do
    args = Jason.decode!(args)
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
        {:error, "Failed to load tool module #{tool_name}: not implemented or unreachable"}

      {:error, error} ->
        {:error, "Failed to load tool module #{tool_name}: #{inspect(error)}"}
    end
  end

  def execute_tool(tool_module, args, ctx) when is_atom(tool_module) do
    cond do
      Lux.prism?(tool_module) -> tool_module.handler(args, ctx)
      Lux.beam?(tool_module) -> tool_module.run(args, ctx)
      Lux.lens?(tool_module) -> tool_module.focus(args)
      true -> {:error, "Tool #{tool_module} is not a valid Beam, Prism, or Lens"}
    end
  end

  @doc """
  Estimates the cost of an OpenRouter API request based on token usage and model.

  Returns a map with input_cost, output_cost, total_cost, and token counts.
  Pricing is per 1M tokens in USD.
  """
  def estimate_cost(usage, model) do
    {input_price, output_price} = Map.get(@model_pricing, model, {1.0, 1.0})
    input_tokens = usage["prompt_tokens"] || 0
    output_tokens = usage["completion_tokens"] || 0

    %{
      input_cost: Float.round(input_price * input_tokens / 1_000_000, 6),
      output_cost: Float.round(output_price * output_tokens / 1_000_000, 6),
      total_cost:
        Float.round(
          (input_price * input_tokens + output_price * output_tokens) / 1_000_000,
          6
        ),
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      model: model
    }
  end

  @doc """
  Returns a list of popular models available on OpenRouter with their pricing.
  """
  def available_models do
    @model_pricing
    |> Enum.map(fn {model, {input_price, output_price}} ->
      %{model: model, input_price_per_1m: input_price, output_price_per_1m: output_price}
    end)
    |> Enum.sort_by(& &1.model)
  end

  defp handle_error(error) do
    Logger.error("OpenRouter API error: #{inspect(error)}")
    {:error, "OpenRouter API error: #{inspect(error)}"}
  end
end
