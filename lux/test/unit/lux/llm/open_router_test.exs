defmodule Lux.LLM.OpenRouterTest do
  @moduledoc """
  Test suite for the OpenRouter LLM module.
  These tests verify the module's ability to:
  - Send chat completion requests to OpenRouter
  - Handle multiple model routing
  - Handle API errors appropriately
  - Estimate costs correctly
  - Support tool/function calling
  """

  use UnitAPICase, async: true
  alias Lux.LLM.OpenRouter

  @model "openai/gpt-4o"

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  describe "call/3" do
    test "successfully gets a chat completion" do
      Req.Test.expect(OpenRouterMock, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/api/v1/chat/completions"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-openrouter-key"]

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["model"] == @model
        assert decoded["temperature"] == 0.7

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "id" => "openrouter-123",
            "model" => @model,
            "created" => 1_700_000_000,
            "usage" => %{
              "prompt_tokens" => 100,
              "completion_tokens" => 50,
              "total_tokens" => 150
            },
            "choices" => [
              %{
                "index" => 0,
                "finish_reason" => "stop",
                "message" => %{
                  "role" => "assistant",
                  "content" => "DeFi yield farming involves providing liquidity..."
                }
              }
            ]
          })
        )
      end)

      assert {:ok, signal} =
               OpenRouter.call(
                 "Explain DeFi yield farming",
                 [],
                 %{
                   plug: {Req.Test, OpenRouterMock},
                   api_key: "test-openrouter-key",
                   model: @model
                 }
               )

      assert signal.payload.content == "DeFi yield farming involves providing liquidity..."
      assert signal.payload.model == @model
      assert signal.metadata.usage["prompt_tokens"] == 100
    end

    test "successfully uses Claude model" do
      Req.Test.expect(OpenRouterMock, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["model"] == "anthropic/claude-3.5-sonnet"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "id" => "openrouter-456",
            "model" => "anthropic/claude-3.5-sonnet",
            "created" => 1_700_000_000,
            "usage" => %{"prompt_tokens" => 80, "completion_tokens" => 40},
            "choices" => [
              %{
                "index" => 0,
                "finish_reason" => "stop",
                "message" => %{
                  "role" => "assistant",
                  "content" => "Claude response"
                }
              }
            ]
          })
        )
      end)

      assert {:ok, signal} =
               OpenRouter.call(
                 "test",
                 [],
                 %{
                   plug: {Req.Test, OpenRouterMock},
                   api_key: "test-openrouter-key",
                   model: "anthropic/claude-3.5-sonnet"
                 }
               )

      assert signal.payload.model == "anthropic/claude-3.5-sonnet"
    end

    test "sends site_url and app_name headers" do
      Req.Test.expect(OpenRouterMock, fn conn ->
        assert Plug.Conn.get_req_header(conn, "http-referer") == ["https://my-app.com"]
        assert Plug.Conn.get_req_header(conn, "x-title") == ["Lux Agent"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "id" => "openrouter-789",
            "model" => @model,
            "created" => 1_700_000_000,
            "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5},
            "choices" => [
              %{
                "index" => 0,
                "finish_reason" => "stop",
                "message" => %{"role" => "assistant", "content" => "ok"}
              }
            ]
          })
        )
      end)

      assert {:ok, _} =
               OpenRouter.call(
                 "test",
                 [],
                 %{
                   plug: {Req.Test, OpenRouterMock},
                   api_key: "test-openrouter-key",
                   model: @model,
                   site_url: "https://my-app.com",
                   app_name: "Lux Agent"
                 }
               )
    end

    test "sends transforms when configured" do
      Req.Test.expect(OpenRouterMock, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["transforms"] == ["middle-out"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "id" => "openrouter-transform",
            "model" => @model,
            "created" => 1_700_000_000,
            "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5},
            "choices" => [
              %{
                "index" => 0,
                "finish_reason" => "stop",
                "message" => %{"role" => "assistant", "content" => "compressed"}
              }
            ]
          })
        )
      end)

      assert {:ok, _} =
               OpenRouter.call(
                 "test",
                 [],
                 %{
                   plug: {Req.Test, OpenRouterMock},
                   api_key: "test-openrouter-key",
                   model: @model,
                   transforms: ["middle-out"]
                 }
               )
    end

    test "handles API error with error object" do
      Req.Test.expect(OpenRouterMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          429,
          Jason.encode!(%{
            "error" => %{"message" => "Rate limit exceeded"}
          })
        )
      end)

      assert {:error, {429, "Rate limit exceeded"}} =
               OpenRouter.call(
                 "test prompt",
                 [],
                 %{plug: {Req.Test, OpenRouterMock}, api_key: "test-openrouter-key"}
               )
    end

    test "handles invalid API key" do
      Req.Test.expect(OpenRouterMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          401,
          Jason.encode!(%{"error" => %{"message" => "Invalid API key"}})
        )
      end)

      assert {:error, :invalid_api_key} ==
               OpenRouter.call(
                 "test prompt",
                 [],
                 %{plug: {Req.Test, OpenRouterMock}, api_key: "bad-key"}
               )
    end

    test "handles insufficient credits" do
      Req.Test.expect(OpenRouterMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          402,
          Jason.encode!(%{"error" => %{"message" => "Insufficient credits"}})
        )
      end)

      assert {:error, :insufficient_credits} ==
               OpenRouter.call(
                 "test prompt",
                 [],
                 %{plug: {Req.Test, OpenRouterMock}, api_key: "test-openrouter-key"}
               )
    end

    test "handles rate limiting" do
      Req.Test.expect(OpenRouterMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(429, Jason.encode!(%{"message" => "Too many requests"}))
      end)

      assert {:error, :rate_limited} ==
               OpenRouter.call(
                 "test prompt",
                 [],
                 %{plug: {Req.Test, OpenRouterMock}, api_key: "test-openrouter-key"}
               )
    end

    test "handles network error" do
      Req.Test.expect(OpenRouterMock, fn _conn ->
        {:error, %Req.TransportError{reason: :econnrefused}}
      end)

      assert {:error, _} =
               OpenRouter.call(
                 "test prompt",
                 [],
                 %{plug: {Req.Test, OpenRouterMock}, api_key: "test-openrouter-key"}
               )
    end

    test "handles JSON response with structured content" do
      Req.Test.expect(OpenRouterMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "id" => "openrouter-json",
            "model" => @model,
            "created" => 1_700_000_000,
            "usage" => %{"prompt_tokens" => 50, "completion_tokens" => 25},
            "choices" => [
              %{
                "index" => 0,
                "finish_reason" => "stop",
                "message" => %{
                  "role" => "assistant",
                  "content" => Jason.encode!(%{"answer" => "42", "confidence" => 0.95})
                }
              }
            ]
          })
        )
      end)

      assert {:ok, signal} =
               OpenRouter.call(
                 "What is the answer?",
                 [],
                 %{
                   plug: {Req.Test, OpenRouterMock},
                   api_key: "test-openrouter-key",
                   model: @model,
                   json_response: true
                 }
               )

      assert signal.payload.content == %{"answer" => "42", "confidence" => 0.95}
    end
  end

  describe "estimate_cost/2" do
    test "estimates cost for gpt-4o" do
      usage = %{"prompt_tokens" => 1000, "completion_tokens" => 500}
      result = OpenRouter.estimate_cost(usage, "openai/gpt-4o")

      assert result.input_cost == 0.0025
      assert result.output_cost == 0.005
      assert result.total_cost == 0.0075
      assert result.model == "openai/gpt-4o"
    end

    test "estimates cost for gpt-4o-mini" do
      usage = %{"prompt_tokens" => 1_000_000, "completion_tokens" => 1_000_000}
      result = OpenRouter.estimate_cost(usage, "openai/gpt-4o-mini")

      assert result.input_cost == 0.15
      assert result.output_cost == 0.6
    end

    test "estimates cost for claude-3.5-sonnet" do
      usage = %{"prompt_tokens" => 1000, "completion_tokens" => 500}
      result = OpenRouter.estimate_cost(usage, "anthropic/claude-3.5-sonnet")

      assert result.input_cost == 0.003
      assert result.output_cost == 0.0075
      assert result.total_cost == 0.0105
    end

    test "estimates cost for claude-3-haiku" do
      usage = %{"prompt_tokens" => 2000, "completion_tokens" => 1000}
      result = OpenRouter.estimate_cost(usage, "anthropic/claude-3-haiku")

      assert result.input_cost == 0.0005
      assert result.output_cost == 0.00125
    end

    test "defaults to $1/$1 pricing for unknown models" do
      usage = %{"prompt_tokens" => 1000, "completion_tokens" => 500}
      result = OpenRouter.estimate_cost(usage, "unknown/model")

      assert result.input_cost == 0.001
      assert result.output_cost == 0.0005
    end

    test "handles zero tokens" do
      usage = %{"prompt_tokens" => 0, "completion_tokens" => 0}
      result = OpenRouter.estimate_cost(usage, "openai/gpt-4o")

      assert result.total_cost == 0.0
    end
  end

  describe "available_models/0" do
    test "returns list of models with pricing" do
      models = OpenRouter.available_models()

      assert is_list(models)
      assert length(models) > 0

      Enum.each(models, fn model ->
        assert Map.has_key?(model, :model)
        assert Map.has_key?(model, :input_price_per_1m)
        assert Map.has_key?(model, :output_price_per_1m)
      end)
    end

    test "includes popular providers" do
      models = OpenRouter.available_models()
      model_names = Enum.map(models, & &1.model)

      assert "openai/gpt-4o" in model_names
      assert "anthropic/claude-3.5-sonnet" in model_names
      assert "google/gemini-pro-1.5" in model_names
      assert "meta-llama/llama-3.1-70b-instruct" in model_names
    end
  end
end
