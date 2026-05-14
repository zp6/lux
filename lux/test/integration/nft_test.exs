defmodule Lux.Integrations.NFTTest do
  @moduledoc """
  Integration tests for NFT marketplace data aggregation modules.

  These tests verify the NFT integration layer including OpenSea API client,
  Blur API client, Rarity scoring engine, and the Marketplace aggregator.

  ## Running

      # All NFT integration tests
      mix test test/integrations/nft_test.exs

      # With mock HTTP (default in test env)
      OPENSEA_API_KEY=test mix test test/integrations/nft_test.exs
  """

  use ExUnit.Case, async: true

  alias Lux.Integrations.NFT.OpenSea
  alias Lux.Integrations.NFT.Blur
  alias Lux.Integrations.NFT.Rarity
  alias Lux.Integrations.NFT.Marketplace

  describe "Lux.Integrations.NFT.Rarity" do
    @tag :nft
    test "builds trait distribution correctly" do
      tokens = [
        %{id: 1, traits: %{"Background" => "Blue", "Hat" => "Cap"}},
        %{id: 2, traits: %{"Background" => "Blue", "Hat" => "Beanie"}},
        %{id: 3, traits: %{"Background" => "Red", "Hat" => "Cap"}}
      ]

      distribution = Rarity.build_trait_distribution(tokens)

      assert distribution["Background"]["Blue"] == 2
      assert distribution["Background"]["Red"] == 1
      assert distribution["Hat"]["Cap"] == 2
      assert distribution["Hat"]["Beanie"] == 1
    end

    @tag :nft
    test "calculates single trait rarity" do
      distribution = %{"Background" => %{"Blue" => 10, "Red" => 90}}
      total = 100

      # Blue is rarer (10/100 tokens)
      assert Rarity.single_trait_rarity("Background", "Blue", distribution, total) == 10.0
      # Red is common (90/100 tokens)
      assert Rarity.single_trait_rarity("Background", "Red", distribution, total) |> Float.round(2) == 1.11
      # Unknown trait
      assert Rarity.single_trait_rarity("Background", "Green", distribution, total) == 0.0
    end

    @tag :nft
    test "scores collection and assigns ranks" do
      tokens = [
        %{id: 1, traits: %{"Color" => "Rare"}},
        %{id: 2, traits: %{"Color" => "Common"}},
        %{id: 3, traits: %{"Color" => "Rare"}}
      ]

      {:ok, scored} = Rarity.score_collection(tokens)

      # Rarest tokens should be rank 1
      rare_tokens = Enum.filter(scored, fn t -> t.traits["Color"] == "Rare" end)
      common_token = Enum.find(scored, fn t -> t.traits["Color"] == "Common" end)

      assert hd(rare_tokens).rarity_rank == 1
      assert common_token.rarity_rank == 3

      # All scores should be normalized to 0-100
      for token <- scored do
        assert token.normalized_score >= 0.0
        assert token.normalized_score <= 100.0
      end
    end

    @tag :nft
    test "normalizes scores to 0-100 range" do
      tokens = [
        %{id: 1, traits: %{"A" => "x", "B" => "y", "C" => "z"}},
        %{id: 2, traits: %{"A" => "common"}},
        %{id: 3, traits: %{"A" => "common", "B" => "common"}}
      ]

      {:ok, scored} = Rarity.score_collection(tokens)

      scores = Enum.map(scored, & &1.normalized_score)
      assert Enum.max(scores) == 100.0
      assert Enum.min(scores) == 0.0
    end

    @tag :nft
    test "calculates Jaccard similarity" do
      traits_a = %{"Color" => "Blue", "Size" => "Large", "Shape" => "Round"}
      traits_b = %{"Color" => "Blue", "Size" => "Large", "Shape" => "Square"}
      traits_c = %{"Color" => "Red", "Weight" => "Heavy"}

      # 2 out of 4 overlap
      sim_ab = Rarity.jaccard_similarity(traits_a, traits_b)
      assert_in_delta sim_ab, 0.5, 0.01

      # 0 out of 5 overlap
      sim_ac = Rarity.jaccard_similarity(traits_a, traits_c)
      assert_in_delta sim_ac, 0.0, 0.01

      # Self-similarity is 1.0
      sim_aa = Rarity.jaccard_similarity(traits_a, traits_a)
      assert_in_delta sim_aa, 1.0, 0.01
    end

    @tag :nft
    test "finds similar tokens" do
      reference = %{id: 0, traits: %{"Color" => "Blue", "Size" => "Large"}}
      candidates = [
        %{id: 1, traits: %{"Color" => "Blue", "Size" => "Large"}},    # identical
        %{id: 2, traits: %{"Color" => "Blue", "Size" => "Small"}},    # 1/3 overlap
        %{id: 3, traits: %{"Color" => "Red", "Shape" => "Round"}}     # 0 overlap
      ]

      similar = Rarity.find_similar(reference, candidates, limit: 2)

      assert length(similar) == 2
      # Most similar should be first
      assert elem(hd(similar), 0) == 1
      assert elem(hd(similar), 1) > elem(Enum.at(similar, 1), 1)
    end

    @tag :nft
    test "calculates Jaccard similarity matrix" do
      tokens = [
        %{id: 1, traits: %{"A" => "x"}},
        %{id: 2, traits: %{"A" => "y"}},
        %{id: 3, traits: %{"A" => "x"}}
      ]

      matrix = Rarity.jaccard_matrix(tokens)

      assert Map.has_key?(matrix, {1, 2})
      assert Map.has_key?(matrix, {1, 3})
      assert Map.has_key?(matrix, {2, 3})
      assert matrix[{1, 3}] == 1.0
      assert matrix[{1, 2}] == 0.0
    end

    @tag :nft
    test "handles empty traits gracefully" do
      tokens = [
        %{id: 1, traits: %{}},
        %{id: 2, traits: %{}}
      ]

      {:ok, scored} = Rarity.score_collection(tokens)

      assert length(scored) == 2
      for token <- scored do
        assert token.rarity_score == 0.0
      end
    end

    @tag :nft
    test "applies trait weights" do
      tokens = [
        %{id: 1, traits: %{"Rare" => "value", "Common" => "value"}},
        %{id: 2, traits: %{"Rare" => "other", "Common" => "value"}}
      ]

      {:ok, default_scored} = Rarity.score_collection(tokens)
      {:ok, weighted_scored} = Rarity.score_collection(tokens, weights: %{"Rare" => 10.0})

      # With weights, the "Rare" trait contributes more to overall score
      default_scores = Enum.map(default_scored, & &1.rarity_score)
      weighted_scores = Enum.map(weighted_scored, & &1.rarity_score)

      # Weighted scores should be higher in magnitude
      assert Enum.sum(weighted_scores) > Enum.sum(default_scores)
    end
  end

  describe "Lux.Integrations.NFT.OpenSea" do
    @tag :nft
    test "base_url returns configured or default URL" do
      url = OpenSea.base_url()
      assert is_binary(url)
      assert String.starts_with?(url, "https://")
    end

    @tag :nft
    test "headers include content-type and accept" do
      headers = OpenSea.headers()

      assert Enum.any?(headers, fn {k, v} ->
        String.downcase(k) == "accept" and v == "application/json"
      end)
      assert Enum.any?(headers, fn {k, v} ->
        String.downcase(k) == "content-type" and v == "application/json"
      end)
    end

    @tag :nft
    test "headers include API key when configured" do
      # Store original config
      original = Application.get_env(:lux, OpenSea, [])

      Application.put_env(:lux, OpenSea, Keyword.put(original, :api_key, "test-key"))
      headers = OpenSea.headers()

      assert Enum.any?(headers, fn {k, v} ->
        String.downcase(k) == "x-api-key" and v == "test-key"
      end)

      # Restore
      Application.put_env(:lux, OpenSea, original)
    end
  end

  describe "Lux.Integrations.NFT.Blur" do
    @tag :nft
    test "base_url returns configured or default URL" do
      url = Blur.base_url()
      assert is_binary(url)
      assert String.starts_with?(url, "https://")
    end

    @tag :nft
    test "headers include user-agent" do
      headers = Blur.headers()

      assert Enum.any?(headers, fn {k, _} -> String.downcase(k) == "user-agent" end)
    end

    @tag :nft
    test "headers include authorization when token configured" do
      original = Application.get_env(:lux, Blur, [])

      Application.put_env(:lux, Blur, Keyword.put(original, :auth_token, "test-token"))
      headers = Blur.headers()

      assert Enum.any?(headers, fn {k, v} ->
        String.downcase(k) == "authorization" and String.contains?(v, "test-token")
      end)

      Application.put_env(:lux, Blur, original)
    end
  end

  describe "Lux.Integrations.NFT.Marketplace" do
    @tag :nft
    test "calculates rarity through aggregator" do
      tokens = [
        %{id: 1, traits: %{"Color" => "Rare", "Size" => "Big"}},
        %{id: 2, traits: %{"Color" => "Common", "Size" => "Small"}},
        %{id: 3, traits: %{"Color" => "Common", "Size" => "Small"}}
      ]

      {:ok, scored} = Marketplace.calculate_rarity(tokens)

      assert length(scored) == 3
      assert hd(scored).rarity_rank == 1
      assert hd(scored).normalized_score == 100.0
    end
  end
end
