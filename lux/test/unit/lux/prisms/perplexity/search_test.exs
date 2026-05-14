defmodule Lux.Prisms.Perplexity.SearchTest do
  @moduledoc """
  Test suite for the Perplexity Search prism.
  """

  use UnitAPICase, async: true

  alias Lux.Prisms.Perplexity.Search

  @agent_ctx %{name: "TestAgent"}

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  describe "handler/2" do
    test "successfully performs a web search" do
      Req.Test.expect(PerplexityMock, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["model"] == "sonar"
        assert decoded["temperature"] == 0.0
        assert hd(decoded["messages"])["content"] == "What is the current ETH price?"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{
          "id" => "search-123",
          "model" => "sonar",
          "created" => 1_700_000_000,
          "usage" => %{"prompt_tokens" => 50, "completion_tokens" => 100},
          "citations" => ["https://coinmarketcap.com/eth"],
          "search_results" => [%{"title" => "ETH Price", "url" => "https://coinmarketcap.com/eth"}],
          "choices" => [%{
            "index" => 0,
            "finish_reason" => "stop",
            "message" => %{"role" => "assistant", "content" => "ETH is trading at $3,500"}
          }]
        }))
      end)

      assert {:ok, result} = Search.handler(%{
        query: "What is the current ETH price?",
        model: "sonar",
        recency_filter: "day",
        plug: {Req.Test, PerplexityMock}
      }, @agent_ctx)

      assert result.content == "ETH is trading at $3,500"
      assert result.citations == ["https://coinmarketcap.com/eth"]
      assert result.model == "sonar"
      assert result.cost.total_cost > 0
    end

    test "uses default model when not specified" do
      Req.Test.expect(PerplexityMock, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["model"] == "sonar-pro"

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

      assert {:ok, result} = Search.handler(%{
        query: "test query",
        plug: {Req.Test, PerplexityMock}
      }, @agent_ctx)

      assert result.model == "sonar-pro"
    end

    test "handles API error" do
      Req.Test.expect(PerplexityMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => %{"message" => "Invalid API key"}}))
      end)

      assert {:error, "Perplexity API key is invalid or not configured"} = Search.handler(%{
        query: "test",
        plug: {Req.Test, PerplexityMock}
      }, @agent_ctx)
    end

    test "handles rate limit error" do
      Req.Test.expect(PerplexityMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(429, Jason.encode!(%{"error" => %{"message" => "Rate limit exceeded"}}))
      end)

      assert {:error, "Perplexity search failed: 429 - Rate limit exceeded"} = Search.handler(%{
        query: "test",
        plug: {Req.Test, PerplexityMock}
      }, @agent_ctx)
    end
  end

  describe "schema validation" do
    test "validates input schema" do
      prism = Search.view()
      assert prism.input_schema.required == ["query"]
      assert Map.has_key?(prism.input_schema.properties, :query)
      assert Map.has_key?(prism.input_schema.properties, :model)
      assert Map.has_key?(prism.input_schema.properties, :search_domain_filter)
      assert Map.has_key?(prism.input_schema.properties, :recency_filter)
    end

    test "validates output schema" do
      prism = Search.view()
      assert prism.output_schema.required == ["content"]
      assert Map.has_key?(prism.output_schema.properties, :content)
      assert Map.has_key?(prism.output_schema.properties, :citations)
      assert Map.has_key?(prism.output_schema.properties, :model)
      assert Map.has_key?(prism.output_schema.properties, :cost)
    end
  end
end
