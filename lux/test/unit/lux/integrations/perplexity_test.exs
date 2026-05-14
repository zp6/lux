defmodule Lux.Integrations.PerplexityTest do
  @moduledoc """
  Test suite for the Perplexity integration module.

  Verifies:
  - Chat completion requests
  - Response parsing with citations
  - Cost estimation
  - Error handling (auth, rate limit, network)
  - Configuration helpers
  """

  use UnitAPICase, async: true

  alias Lux.Integrations.Perplexity

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  describe "configuration" do
    test "available_models/0 returns list of models" do
      models = Perplexity.available_models()
      assert is_list(models)
      assert length(models) == 4

      ids = Enum.map(models, & &1.id)
      assert "sonar" in ids
      assert "sonar-pro" in ids
      assert "sonar-reasoning" in ids
      assert "sonar-reasoning-pro" in ids
    end

    test "available_models/0 models have required fields" do
      for model <- Perplexity.available_models() do
        assert Map.has_key?(model, :id)
        assert Map.has_key?(model, :name)
        assert Map.has_key?(model, :description)
        assert Map.has_key?(model, :input_price_per_mtok)
        assert Map.has_key?(model, :output_price_per_mtok)
      end
    end
  end

  describe "chat_completion/2" do
    test "successfully gets a chat completion with citations" do
      Req.Test.expect(PerplexityMock, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/chat/completions"

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["model"] == "sonar-pro"
        assert decoded["temperature"] == 0.2
        assert decoded["return_citations"] == true

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{
          "id" => "perplexity-test-123",
          "model" => "sonar-pro",
          "created" => 1_700_000_000,
          "usage" => %{
            "prompt_tokens" => 100,
            "completion_tokens" => 50,
            "total_tokens" => 150
          },
          "citations" => ["https://example.com/source1", "https://example.com/source2"],
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
        }))
      end)

      assert {:ok, response} = Perplexity.chat_completion(
        [%{role: "user", content: "Explain DeFi yield farming"}],
        %{plug: {Req.Test, PerplexityMock}}
      )

      assert response.content == "DeFi yield farming involves providing liquidity..."
      assert response.citations == ["https://example.com/source1", "https://example.com/source2"]
      assert response.model == "sonar-pro"
      assert response.cost.total_cost > 0
    end

    test "handles 401 unauthorized" do
      Req.Test.expect(PerplexityMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => %{"message" => "Invalid API key"}}))
      end)

      assert {:error, :invalid_api_key} = Perplexity.chat_completion(
        [%{role: "user", content: "test"}],
        %{plug: {Req.Test, PerplexityMock}}
      )
    end

    test "handles API error with error object" do
      Req.Test.expect(PerplexityMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(429, Jason.encode!(%{
          "error" => %{"message" => "Rate limit exceeded"}
        }))
      end)

      assert {:error, {429, "Rate limit exceeded"}} = Perplexity.chat_completion(
        [%{role: "user", content: "test"}],
        %{plug: {Req.Test, PerplexityMock}}
      )
    end

    test "handles network error" do
      Req.Test.expect(PerplexityMock, fn _conn ->
        {:error, %Req.TransportError{reason: :econnrefused}}
      end)

      assert {:error, _} = Perplexity.chat_completion(
        [%{role: "user", content: "test"}],
        %{plug: {Req.Test, PerplexityMock}}
      )
    end

    test "sends search domain filter when configured" do
      Req.Test.expect(PerplexityMock, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["search_domain_filter"] == ["docs.ethers.org"]

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

      assert {:ok, _} = Perplexity.chat_completion(
        [%{role: "user", content: "test"}],
        %{
          plug: {Req.Test, PerplexityMock},
          search_domain_filter: ["docs.ethers.org"]
        }
      )
    end

    test "sends recency filter when configured" do
      Req.Test.expect(PerplexityMock, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["recency_filter"] == "day"

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
            "message" => %{"role" => "assistant", "content" => "recent result"}
          }]
        }))
      end)

      assert {:ok, _} = Perplexity.chat_completion(
        [%{role: "user", content: "latest news"}],
        %{
          plug: {Req.Test, PerplexityMock},
          recency_filter: "day"
        }
      )
    end
  end

  describe "estimate_cost/2" do
    test "estimates cost for sonar model" do
      usage = %{"prompt_tokens" => 1000, "completion_tokens" => 500}
      result = Perplexity.estimate_cost(usage, "sonar")

      assert result.input_cost == 0.001
      assert result.output_cost == 0.0005
      assert result.total_cost == 0.0015
      assert result.model == "sonar"
    end

    test "estimates cost for sonar-pro model" do
      usage = %{"prompt_tokens" => 1000, "completion_tokens" => 500}
      result = Perplexity.estimate_cost(usage, "sonar-pro")

      assert result.input_cost == 0.003
      assert result.output_cost == 0.0075
      assert result.total_cost == 0.0105
    end

    test "estimates cost for sonar-reasoning model" do
      usage = %{"prompt_tokens" => 2000, "completion_tokens" => 1000}
      result = Perplexity.estimate_cost(usage, "sonar-reasoning")

      assert result.input_cost == 0.004
      assert result.output_cost == 0.008
      assert result.total_cost == 0.012
    end

    test "defaults to sonar-pro pricing for unknown models" do
      usage = %{"prompt_tokens" => 1000, "completion_tokens" => 500}
      result = Perplexity.estimate_cost(usage, "unknown-model")

      assert result.input_cost == 0.003
      assert result.output_cost == 0.0075
    end
  end
end
