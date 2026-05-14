defmodule Lux.Prisms.Perplexity.AskTest do
  @moduledoc """
  Test suite for the Perplexity Ask prism.
  """

  use UnitAPICase, async: true

  alias Lux.Prisms.Perplexity.Ask

  @agent_ctx %{name: "TestAgent"}

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  describe "handler/2" do
    test "successfully asks a question" do
      Req.Test.expect(PerplexityMock, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["model"] == "sonar-reasoning"
        assert decoded["temperature"] == 0.3

        msg_content = hd(decoded["messages"])["content"]
        assert String.contains?(msg_content, "How does Uniswap v3 work?")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{
          "id" => "ask-123",
          "model" => "sonar-reasoning",
          "created" => 1_700_000_000,
          "usage" => %{"prompt_tokens" => 200, "completion_tokens" => 300},
          "citations" => ["https://uniswap.org/whitepaper-v3.pdf"],
          "choices" => [%{
            "index" => 0,
            "finish_reason" => "stop",
            "message" => %{"role" => "assistant", "content" => "Uniswap v3 uses concentrated liquidity..."}
          }]
        }))
      end)

      assert {:ok, result} = Ask.handler(%{
        question: "How does Uniswap v3 work?",
        model: "sonar-reasoning",
        plug: {Req.Test, PerplexityMock}
      }, @agent_ctx)

      assert result.content == "Uniswap v3 uses concentrated liquidity..."
      assert result.citations == ["https://uniswap.org/whitepaper-v3.pdf"]
      assert result.model == "sonar-reasoning"
    end

    test "includes context in the request when provided" do
      Req.Test.expect(PerplexityMock, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        msg_content = hd(decoded["messages"])["content"]
        assert String.contains?(msg_content, "Context:")
        assert String.contains?(msg_content, "I am researching DeFi")
        assert String.contains?(msg_content, "What is yield farming?")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{
          "id" => "test-id",
          "model" => "sonar-pro",
          "created" => 1_700_000_000,
          "usage" => %{"prompt_tokens" => 50, "completion_tokens" => 25},
          "choices" => [%{
            "index" => 0,
            "finish_reason" => "stop",
            "message" => %{"role" => "assistant", "content" => "result"}
          }]
        }))
      end)

      assert {:ok, _} = Ask.handler(%{
        question: "What is yield farming?",
        context: "I am researching DeFi",
        plug: {Req.Test, PerplexityMock}
      }, @agent_ctx)
    end

    test "uses default model and temperature" do
      Req.Test.expect(PerplexityMock, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["model"] == "sonar-pro"
        assert decoded["temperature"] == 0.3

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{
          "id" => "test-id",
          "model" => "sonar-pro",
          "created" => 1_700_000_000,
          "usage" => %{"prompt_tokens" => 50, "completion_tokens" => 25},
          "choices" => [%{
            "index" => 0,
            "finish_reason" => "stop",
            "message" => %{"role" => "assistant", "content" => "result"}
          }]
        }))
      end)

      assert {:ok, _} = Ask.handler(%{
        question: "test question",
        plug: {Req.Test, PerplexityMock}
      }, @agent_ctx)
    end

    test "handles API error" do
      Req.Test.expect(PerplexityMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => %{"message" => "Invalid API key"}}))
      end)

      assert {:error, "Perplexity API key is invalid or not configured"} = Ask.handler(%{
        question: "test",
        plug: {Req.Test, PerplexityMock}
      }, @agent_ctx)
    end
  end

  describe "schema validation" do
    test "validates input schema" do
      prism = Ask.view()
      assert prism.input_schema.required == ["question"]
      assert Map.has_key?(prism.input_schema.properties, :question)
      assert Map.has_key?(prism.input_schema.properties, :context)
      assert Map.has_key?(prism.input_schema.properties, :model)
      assert Map.has_key?(prism.input_schema.properties, :temperature)
    end

    test "validates output schema" do
      prism = Ask.view()
      assert prism.output_schema.required == ["content"]
      assert Map.has_key?(prism.output_schema.properties, :content)
      assert Map.has_key?(prism.output_schema.properties, :citations)
      assert Map.has_key?(prism.output_schema.properties, :cost)
    end
  end
end
