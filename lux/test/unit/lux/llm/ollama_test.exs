defmodule Lux.LLM.OllamaTest do
  use UnitAPICase, async: true

  alias Lux.LLM.Ollama
  alias Lux.LLM.Ollama.ModelManager
  alias Lux.LLM.ResponseSignal
  alias Lux.Signal

  require Lux.Beam
  require Lux.Lens
  require Lux.Prism

  defmodule TestPrism do
    @moduledoc false
    use Lux.Prism,
      name: "Test Prism",
      input_schema: %{type: :object, properties: %{value: %{type: :string}}},
      description: "A test prism"

    def handler(%{"value" => "success"}, _context), do: {:ok, %{result: "success test"}}
    def handler(%{"value" => "failure"}, _context), do: {:error, "failure test"}
  end

  defmodule TestBeam do
    @moduledoc false
    use Lux.Beam,
      name: "Test Beam",
      input_schema: %{type: :object, properties: %{value: %{type: :string}}},
      description: "A test beam"

    sequence do
      step(:test, TestPrism, %{})
    end
  end

  setup do
    Req.Test.verify_on_exit!()
  end

  describe "tool_to_function/1" do
    test "converts a beam to an Ollama function" do
      beam =
        Lux.Beam.new(
          name: "TestBeam",
          description: "A test beam",
          input_schema: %{
            type: "object",
            properties: %{
              "value" => %{
                type: "string",
                description: "Test value"
              },
              "amount" => %{
                type: "float",
                description: "Test amount"
              }
            }
          }
        )

      function = Ollama.tool_to_function(beam)

      assert %{
               type: "function",
               function: %{
                 name: "TestBeam",
                 description: "A test beam",
                 parameters: %{
                   type: "object",
                   properties: %{
                     "value" => %{
                       type: "string",
                       description: "Test value"
                     },
                     "amount" => %{
                       type: "float",
                       description: "Test amount"
                     }
                   }
                 }
               }
             } = function
    end

    test "converts a prism to an Ollama function" do
      prism = TestPrism.view()

      function = Ollama.tool_to_function(prism)

      assert %{
               type: "function",
               function: %{
                 name: "Lux_LLM_OllamaTest_TestPrism",
                 description: "A test prism",
                 parameters: %{
                   type: :object,
                   properties: %{
                     value: %{
                       type: :string
                     }
                   }
                 }
               }
             } = function
    end

    test "converts a lens to an Ollama function" do
      lens =
        Lux.Lens.new(
          name: "WeatherAPI",
          description: "Gets weather data",
          schema: %{
            type: "object",
            properties: %{
              location: %{
                type: "string",
                description: "City name"
              },
              units: %{
                type: "string",
                description: "Temperature units"
              }
            }
          }
        )

      function = Ollama.tool_to_function(lens)

      assert %{
               type: "function",
               function: %{
                 name: "WeatherAPI",
                 description: "Gets weather data",
                 parameters: %{
                   type: "object",
                   properties: %{
                     location: %{
                       type: "string",
                       description: "City name"
                     },
                     units: %{
                       type: "string",
                       description: "Temperature units"
                     }
                   }
                 }
               }
             } = function
    end
  end

  describe "call/3" do
    test "makes correct API call with tools" do
      config = %{
        api_key: nil,
        model: "llama3.2",
        endpoint: "http://localhost:11434"
      }

      beam =
        Lux.Beam.new(
          name: "TestBeam",
          description: "A test beam",
          input_schema: %{
            type: "object",
            properties: %{
              "value" => %{
                type: "string",
                description: "Test value"
              }
            }
          }
        )

      Req.Test.expect(Ollama, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/api/chat"

        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        decoded_body = Jason.decode!(body)

        assert decoded_body["model"] == "llama3.2"
        assert [%{"role" => "user", "content" => "test prompt"}] = decoded_body["messages"]
        assert decoded_body["stream"] == false

        assert [tool] = decoded_body["tools"]
        assert tool["type"] == "function"
        assert tool["function"]["name"] == "TestBeam"

        # Ollama-specific parameters
        assert is_map(decoded_body["options"])
        assert is_float(decoded_body["options"]["temperature"])
        assert is_float(decoded_body["options"]["top_p"])
        assert is_integer(decoded_body["options"]["top_k"])
        assert is_integer(decoded_body["options"]["num_ctx"])
        assert is_integer(decoded_body["options"]["num_predict"])
        assert is_float(decoded_body["options"]["repeat_penalty"])

        Req.Test.json(conn, %{
          "model" => "llama3.2",
          "created_at" => "2024-01-01T00:00:00Z",
          "done" => true,
          "done_reason" => "stop",
          "message" => %{
            "role" => "assistant",
            "content" => ~s({"result": "Test response"})
          },
          "prompt_eval_count" => 10,
          "eval_count" => 20
        })
      end)

      assert {:ok,
              %Signal{
                schema_id: ResponseSignal,
                payload: %{
                  content: %{"result" => "Test response"},
                  finish_reason: "stop",
                  model: "llama3.2",
                  tool_calls: nil,
                  tool_calls_results: nil
                },
                sender: nil,
                recipient: nil,
                timestamp: _,
                metadata: %{
                  usage: %{
                    prompt_tokens: 10,
                    completion_tokens: 20,
                    total_tokens: 30
                  }
                }
              }} = Ollama.call("test prompt", [beam], config)
    end

    test "handles tool call responses with successful tool call (prism)" do
      config = %{
        api_key: nil,
        model: "llama3.2",
        endpoint: "http://localhost:11434"
      }

      Req.Test.expect(Ollama, fn conn ->
        Req.Test.json(conn, %{
          "model" => "llama3.2",
          "created_at" => "2024-01-01T00:00:00Z",
          "done" => true,
          "done_reason" => "stop",
          "message" => %{
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => [
              %{
                "type" => "function",
                "function" => %{
                  "name" => "#{TestPrism}",
                  "arguments" => ~s({"value": "success"})
                }
              }
            ]
          },
          "prompt_eval_count" => 10,
          "eval_count" => 5
        })
      end)

      assert {:ok,
              %Signal{
                schema_id: ResponseSignal,
                payload: %{
                  content: nil,
                  finish_reason: "stop",
                  model: "llama3.2",
                  tool_calls: [
                    %{
                      "function" => %{
                        "arguments" => ~s({"value": "success"}),
                        "name" => "Elixir.Lux.LLM.OllamaTest.TestPrism"
                      },
                      "type" => "function"
                    }
                  ],
                  tool_calls_results: [%{result: "success test"}]
                },
                sender: nil,
                recipient: nil,
                timestamp: _,
                metadata: _
              }} = Ollama.call("test prompt", [TestPrism], config)
    end

    test "includes Ollama-specific options in the request" do
      config = %{
        api_key: nil,
        model: "llama3.2",
        endpoint: "http://localhost:11434",
        temperature: 0.8,
        top_p: 0.95,
        top_k: 50,
        num_ctx: 8192,
        num_predict: 256,
        repeat_penalty: 1.2,
        seed: 42
      }

      Req.Test.expect(Ollama, fn conn ->
        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        decoded_body = Jason.decode!(body)

        assert decoded_body["options"]["temperature"] == 0.8
        assert decoded_body["options"]["top_p"] == 0.95
        assert decoded_body["options"]["top_k"] == 50
        assert decoded_body["options"]["num_ctx"] == 8192
        assert decoded_body["options"]["num_predict"] == 256
        assert decoded_body["options"]["repeat_penalty"] == 1.2
        assert decoded_body["options"]["seed"] == 42

        Req.Test.json(conn, %{
          "model" => "llama3.2",
          "created_at" => "2024-01-01T00:00:00Z",
          "done" => true,
          "done_reason" => "stop",
          "message" => %{
            "role" => "assistant",
            "content" => ~s({"result": "Test response"})
          },
          "prompt_eval_count" => 10,
          "eval_count" => 20
        })
      end)

      assert {:ok, _} = Ollama.call("test prompt", [], config)
    end

    test "includes system message when configured" do
      config = %{
        api_key: nil,
        model: "llama3.2",
        endpoint: "http://localhost:11434",
        system: "You are a helpful assistant."
      }

      Req.Test.expect(Ollama, fn conn ->
        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        decoded_body = Jason.decode!(body)

        messages = decoded_body["messages"]
        assert [%{"role" => "system", "content" => "You are a helpful assistant."}, %{"role" => "user"}] = messages

        Req.Test.json(conn, %{
          "model" => "llama3.2",
          "created_at" => "2024-01-01T00:00:00Z",
          "done" => true,
          "done_reason" => "stop",
          "message" => %{
            "role" => "assistant",
            "content" => ~s({"result": "response"})
          },
          "prompt_eval_count" => 5,
          "eval_count" => 10
        })
      end)

      assert {:ok, _} = Ollama.call("test prompt", [], config)
    end

    test "handles plain text responses (non-JSON)" do
      config = %{
        api_key: nil,
        model: "llama3.2",
        endpoint: "http://localhost:11434",
        json_response: false
      }

      Req.Test.expect(Ollama, fn conn ->
        Req.Test.json(conn, %{
          "model" => "llama3.2",
          "created_at" => "2024-01-01T00:00:00Z",
          "done" => true,
          "done_reason" => "stop",
          "message" => %{
            "role" => "assistant",
            "content" => "This is a plain text response"
          },
          "prompt_eval_count" => 10,
          "eval_count" => 20
        })
      end)

      assert {:ok,
              %Signal{
                schema_id: ResponseSignal,
                payload: %{
                  content: %{"text" => "This is a plain text response"}
                }
              }} = Ollama.call("test prompt", [], config)
    end

    test "handles model not found error" do
      config = %{
        api_key: nil,
        model: "nonexistent",
        endpoint: "http://localhost:11434"
      }

      Req.Test.expect(Ollama, fn conn ->
        Req.Test.json(conn, %{
          "error" => "model 'nonexistent' not found"
        })
      end, status: 404)

      assert {:error, {:model_not_found, "model 'nonexistent' not found"}} =
               Ollama.call("test prompt", [], config)
    end

    test "handles invalid API key error" do
      config = %{
        api_key: "invalid_key",
        model: "llama3.2",
        endpoint: "http://localhost:11434"
      }

      Req.Test.expect(Ollama, fn conn ->
        Plug.Conn.resp(conn, 401, Jason.encode!(%{"error" => "unauthorized"}))
      end)

      assert {:error, :invalid_api_key} = Ollama.call("test prompt", [], config)
    end

    test "handles performance metadata in response" do
      config = %{
        api_key: nil,
        model: "llama3.2",
        endpoint: "http://localhost:11434"
      }

      Req.Test.expect(Ollama, fn conn ->
        Req.Test.json(conn, %{
          "model" => "llama3.2",
          "created_at" => "2024-01-01T00:00:00Z",
          "done" => true,
          "done_reason" => "stop",
          "message" => %{
            "role" => "assistant",
            "content" => ~s({"result": "test"})
          },
          "prompt_eval_count" => 15,
          "eval_count" => 25,
          "total_duration" => 1_500_000_000,
          "load_duration" => 100_000_000,
          "prompt_eval_duration" => 500_000_000,
          "eval_duration" => 900_000_000
        })
      end)

      assert {:ok,
              %Signal{
                metadata: %{
                  usage: %{prompt_tokens: 15, completion_tokens: 25, total_tokens: 40},
                  total_duration: 1_500_000_000,
                  load_duration: 100_000_000,
                  prompt_eval_duration: 500_000_000,
                  eval_duration: 900_000_000
                }
              }} = Ollama.call("test prompt", [], config)
    end
  end

  describe "ModelManager" do
    test "list_models returns available models" do
      Req.Test.expect(Ollama, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/api/tags"

        Req.Test.json(conn, %{
          "models" => [
            %{
              "name" => "llama3.2:latest",
              "size" => 2_019_393_189,
              "modified_at" => "2024-01-01T00:00:00Z"
            },
            %{
              "name" => "mistral:latest",
              "size" => 4_113_925_376,
              "modified_at" => "2024-01-01T00:00:00Z"
            }
          ]
        })
      end)

      assert {:ok, [_, _] = models} = ModelManager.list_models()
      assert length(models) == 2
    end

    test "model_available? returns true for existing model" do
      Req.Test.expect(Ollama, fn conn ->
        Req.Test.json(conn, %{
          "models" => [
            %{"name" => "llama3.2:latest", "size" => 2_019_393_189}
          ]
        })
      end)

      assert {:ok, true} = ModelManager.model_available?("llama3.2")
    end

    test "model_available? returns false for missing model" do
      Req.Test.expect(Ollama, fn conn ->
        Req.Test.json(conn, %{"models" => []})
      end)

      assert {:ok, false} = ModelManager.model_available?("nonexistent")
    end

    test "pull_model sends correct request" do
      Req.Test.expect(Ollama, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/api/pull"

        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        decoded_body = Jason.decode!(body)
        assert decoded_body["name"] == "llama3.2"
        assert decoded_body["stream"] == false

        Req.Test.json(conn, %{"status" => "success"})
      end)

      assert {:ok, "success"} = ModelManager.pull_model("llama3.2")
    end

    test "delete_model sends correct request" do
      Req.Test.expect(Ollama, fn conn ->
        assert conn.method == "DELETE"
        assert conn.request_path == "/api/delete"

        Req.Test.json(conn, %{})
      end, status: 200)

      assert {:ok, "success"} = ModelManager.delete_model("llama3.2")
    end

    test "model_info returns model details" do
      Req.Test.expect(Ollama, fn conn ->
        Req.Test.json(conn, %{
          "models" => [
            %{
              "name" => "llama3.2:latest",
              "size" => 2_019_393_189,
              "details" => %{
                "family" => "llama",
                "parameter_size" => "3B"
              }
            }
          ]
        })
      end)

      assert {:ok, %{"name" => "llama3.2:latest", "size" => 2_019_393_189}} =
               ModelManager.model_info("llama3.2")
    end
  end
end
