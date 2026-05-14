defmodule Lux.Prisms.Perplexity.ModelInfoTest do
  @moduledoc """
  Test suite for the Perplexity Model Info prism.
  """

  use UnitAPICase, async: true

  alias Lux.Prisms.Perplexity.ModelInfo

  @agent_ctx %{name: "TestAgent"}

  describe "handler/2" do
    test "returns all models when no filter specified" do
      assert {:ok, result} = ModelInfo.handler(%{}, @agent_ctx)
      assert length(result.models) == 4
      assert result.default_model == "sonar-pro"
      assert result.total_count == 4
    end

    test "returns all models with 'all' filter" do
      assert {:ok, result} = ModelInfo.handler(%{filter: "all"}, @agent_ctx)
      assert length(result.models) == 4
    end

    test "filters to reasoning models" do
      assert {:ok, result} = ModelInfo.handler(%{filter: "reasoning"}, @agent_ctx)
      assert length(result.models) == 2
      ids = Enum.map(result.models, & &1.id)
      assert "sonar-reasoning" in ids
      assert "sonar-reasoning-pro" in ids
    end

    test "filters to fast models" do
      assert {:ok, result} = ModelInfo.handler(%{filter: "fast"}, @agent_ctx)
      assert length(result.models) == 2
      ids = Enum.map(result.models, & &1.id)
      assert "sonar" in ids
      assert "sonar-pro" in ids
    end
  end

  describe "schema validation" do
    test "validates input schema" do
      prism = ModelInfo.view()
      assert Map.has_key?(prism.input_schema.properties, :filter)
    end

    test "validates output schema" do
      prism = ModelInfo.view()
      assert "models" in prism.output_schema.required
      assert "default_model" in prism.output_schema.required
      assert Map.has_key?(prism.output_schema.properties, :models)
      assert Map.has_key?(prism.output_schema.properties, :default_model)
      assert Map.has_key?(prism.output_schema.properties, :total_count)
    end
  end
end
