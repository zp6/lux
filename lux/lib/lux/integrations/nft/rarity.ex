defmodule Lux.Integrations.NFT.Rarity do
  @moduledoc """
  Rarity scoring engine for NFT collections.

  Provides trait-based rarity calculation, Jaccard similarity scoring,
  and normalized score generation for NFT tokens within a collection.

  ## Rarity Calculation Methods

  1. **Trait-based rarity** - Scores based on the statistical rarity of individual traits.
  2. **Jaccard similarity** - Measures overlap between token trait sets.
  3. **Normalized scoring** - All scores mapped to 0-100 range.

  ## Usage

      alias Lux.Integrations.NFT.Rarity

      # Token traits: %{trait_type => value}
      tokens = [
        %{id: 1, traits: %{"Background" => "Blue", "Hat" => "Cap", "Eyes" => "Laser"}},
        %{id: 2, traits: %{"Background" => "Red", "Hat" => "Beanie", "Eyes" => "Normal"}},
        # ...
      ]

      # Build rarity table and score each token
      {:ok, scored} = Rarity.score_collection(tokens)
      # => [
      #   %{id: 1, rarity_score: 85.3, rarity_rank: 1, normalized_score: 100.0},
      #   %{id: 2, rarity_score: 42.1, rarity_rank: 5, normalized_score: 60.5},
      #   ...
      # ]
  """

  @type trait_distribution :: %{String.t() => %{String.t() => non_neg_integer()}}
  @type token_traits :: %{required(:id) => term(), required(:traits) => map()}
  @type scored_token :: %{
    id: term(),
    traits: map(),
    rarity_score: float(),
    rarity_rank: pos_integer(),
    normalized_score: float(),
    trait_scores: %{String.t() => float()}
  }

  # --- Public API ---

  @doc """
  Scores an entire collection of NFT tokens by trait rarity.

  Returns tokens sorted by rarity rank (most rare first).

  ## Parameters

    * `tokens` - List of maps with `:id` and `:traits` keys
    * `opts` - Options (:weights - trait type weights map)

  ## Examples

      {:ok, scored} = Rarity.score_collection(tokens)
  """
  @spec score_collection([token_traits()], keyword()) :: {:ok, [scored_token()]}
  def score_collection(tokens, opts \\ []) do
    total = length(tokens)
    distribution = build_trait_distribution(tokens)
    weights = Keyword.get(opts, :weights, %{})

    scored =
      tokens
      |> Enum.map(fn token ->
        score = calculate_token_rarity(token, distribution, total, weights)
        trait_scores = calculate_individual_trait_scores(token, distribution, total)
        %{
          id: token.id,
          traits: token.traits,
          rarity_score: score,
          trait_scores: trait_scores
        }
      end)
      |> Enum.sort_by(& &1.rarity_score, :desc)
      |> add_ranks()
      |> normalize_scores()

    {:ok, scored}
  end

  @doc """
  Calculates rarity score for a single token.

  ## Parameters

    * `token` - Map with `:id` and `:traits` keys
    * `distribution` - Trait distribution from `build_trait_distribution/1`
    * `total` - Total number of tokens in collection
    * `weights` - Optional trait type weights

  ## Examples

      score = Rarity.calculate_token_rarity(token, distribution, 10000, %{})
      # => 85.3
  """
  @spec calculate_token_rarity(token_traits(), trait_distribution(), non_neg_integer(), map()) ::
          float()
  def calculate_token_rarity(token, distribution, total, weights \\ %{}) do
    token.traits
    |> Enum.map(fn {trait_type, value} ->
      trait_weight = Map.get(weights, trait_type, 1.0)
      trait_rarity = single_trait_rarity(trait_type, value, distribution, total)
      trait_rarity * trait_weight
    end)
    |> Enum.sum()
  end

  @doc """
  Builds a trait distribution map showing how many tokens have each trait value.

  ## Parameters

    * `tokens` - List of token maps

  ## Examples

      distribution = Rarity.build_trait_distribution(tokens)
      # => %{"Background" => %{"Blue" => 500, "Red" => 200}, "Hat" => %{"Cap" => 100, ...}}
  """
  @spec build_trait_distribution([token_traits()]) :: trait_distribution()
  def build_trait_distribution(tokens) do
    tokens
    |> Enum.reduce(%{}, fn token, acc ->
      Enum.reduce(token.traits, acc, fn {trait_type, value}, type_acc ->
        update_in(type_acc, [Access.key(trait_type, %{}), Access.key(value, 0)], &(&1 + 1))
      end)
    end)
  end

  @doc """
  Calculates the rarity of a single trait value.

  Uses the formula: `total / count` (higher = rarer).
  Returns 0.0 for unknown traits.

  ## Examples

      iex> Rarity.single_trait_rarity("Background", "Blue", %{"Background" => %{"Blue" => 10}}, 1000)
      100.0
  """
  @spec single_trait_rarity(String.t(), String.t(), trait_distribution(), non_neg_integer()) ::
          float()
  def single_trait_rarity(trait_type, value, distribution, total) do
    count = get_in(distribution, [trait_type, value]) || 0

    case count do
      0 -> 0.0
      _ -> total / count
    end
  end

  @doc """
  Calculates Jaccard similarity between two tokens based on their traits.

  Jaccard similarity = |intersection| / |union| of trait values.

  Returns a value between 0.0 (no overlap) and 1.0 (identical traits).

  ## Examples

      similarity = Rarity.jaccard_similarity(token1.traits, token2.traits)
      # => 0.33
  """
  @spec jaccard_similarity(map(), map()) :: float()
  def jaccard_similarity(traits_a, traits_b) do
    set_a = traits_a |> MapSet.new(fn {k, v} -> {k, v} end)
    set_b = traits_b |> MapSet.new(fn {k, v} -> {k, v} end)

    intersection_size = MapSet.intersection(set_a, set_b) |> MapSet.size()
    union_size = MapSet.union(set_a, set_b) |> MapSet.size()

    case union_size do
      0 -> 0.0
      _ -> intersection_size / union_size
    end
  end

  @doc """
  Calculates Jaccard similarity matrix for a list of tokens.

  Returns a map of `{id_a, id_b}` pairs to similarity scores.

  ## Examples

      matrix = Rarity.jaccard_matrix(tokens)
      # => %{{1, 2} => 0.33, {1, 3} => 0.5, ...}
  """
  @spec jaccard_matrix([token_traits()]) :: %{{term(), term()} => float()}
  def jaccard_matrix(tokens) do
    for a <- tokens, b <- tokens, a.id < b.id, into: %{} do
      similarity = jaccard_similarity(a.traits, b.traits)
      {{a.id, b.id}, Float.round(similarity, 4)}
    end
  end

  @doc """
  Finds the most similar tokens to a given reference token.

  ## Parameters

    * `reference` - The reference token
    * `candidates` - List of candidate tokens
    * `opts` - Options (limit: integer, default 10)

  ## Examples

      similar = Rarity.find_similar(token, tokens, limit: 5)
  """
  @spec find_similar(token_traits(), [token_traits()], keyword()) :: [{term(), float()}]
  def find_similar(reference, candidates, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)

    candidates
    |> Enum.reject(fn t -> t.id == reference.id end)
    |> Enum.map(fn t -> {t.id, jaccard_similarity(reference.traits, t.traits)} end)
    |> Enum.sort_by(&elem(&1, 1), :desc)
    |> Enum.take(limit)
  end

  @doc """
  Normalizes scores to a 0-100 range.

  The highest-scoring token gets 100, the lowest gets 0 (or close to it).

  ## Examples

      normalized = Rarity.normalize_scores(scored_tokens)
  """
  @spec normalize_scores([map()]) :: [map()]
  def normalize_scores(scored_tokens) do
    scores = Enum.map(scored_tokens, & &1.rarity_score)
    min_score = Enum.min(scores, fn -> 0 end)
    max_score = Enum.max(scores, fn -> 1 end)
    range = max_score - min_score

    Enum.map(scored_tokens, fn token ->
      normalized =
        case range do
          0.0 -> 50.0
          _ -> (token.rarity_score - min_score) / range * 100.0
        end

      Map.put(token, :normalized_score, Float.round(normalized, 2))
    end)
  end

  # --- Private ---

  @spec calculate_individual_trait_scores(token_traits(), trait_distribution(), non_neg_integer()) ::
          %{String.t() => float()}
  defp calculate_individual_trait_scores(token, distribution, total) do
    Enum.map(token.traits, fn {trait_type, value} ->
      {trait_type, single_trait_rarity(trait_type, value, distribution, total)}
    end)
    |> Enum.into(%{})
  end

  @spec add_ranks([map()]) :: [map()]
  defp add_ranks(scored_tokens) do
    scored_tokens
    |> Enum.with_index(1)
    |> Enum.map(fn {token, rank} -> Map.put(token, :rarity_rank, rank) end)
  end
end
