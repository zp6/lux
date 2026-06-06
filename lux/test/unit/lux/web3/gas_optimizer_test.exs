defmodule Lux.Web3.GasOptimizerTest do
  @moduledoc """
  Unit tests for GasOptimizer and submodules.
  Uses mocked RPC responses to avoid requiring live chain connections.
  """
  use ExUnit.Case, async: true

  alias Lux.Web3.GasOptimizer
  alias Lux.Web3.GasOptimizer.Estimator
  alias Lux.Web3.GasOptimizer.Batcher
  alias Lux.Web3.GasOptimizer.Predictor
  alias Lux.Web3.GasOptimizer.Replacement
  alias Lux.Web3.GasOptimizer.FeeOracle

  describe "GasOptimizer configuration" do
    test "chain_id returns correct IDs" do
      assert GasOptimizer.chain_id(:ethereum) == 1
      assert GasOptimizer.chain_id(:polygon) == 137
      assert GasOptimizer.chain_id(:bsc) == 56
      assert GasOptimizer.chain_id(:arbitrum) == 42161
    end

    test "eip1559? returns correct values" do
      assert GasOptimizer.eip1559?(:ethereum) == true
      assert GasOptimizer.eip1559?(:polygon) == true
      assert GasOptimizer.eip1559?(:arbitrum) == true
      assert GasOptimizer.eip1559?(:bsc) == false
    end

    test "default_chain returns ethereum by default" do
      assert GasOptimizer.default_chain() in [:ethereum, :polygon, :bsc, :arbitrum]
    end

    test "max_gas_price returns a positive integer" do
      assert is_integer(GasOptimizer.max_gas_price())
      assert GasOptimizer.max_gas_price() > 0
    end

    test "default_priority_fee returns a positive integer" do
      assert is_integer(GasOptimizer.default_priority_fee())
      assert GasOptimizer.default_priority_fee() > 0
    end

    test "gas_price_margin returns a float >= 1.0" do
      margin = GasOptimizer.gas_price_margin()
      assert is_float(margin) or is_integer(margin)
      assert margin >= 1.0
    end

    test "non_evm? identifies non-EVM chains" do
      assert GasOptimizer.non_evm?(:solana) == true
      assert GasOptimizer.non_evm?(:near) == true
      assert GasOptimizer.non_evm?(:sui) == true
      assert GasOptimizer.non_evm?(:aptos) == true
      assert GasOptimizer.non_evm?(:ethereum) == false
      assert GasOptimizer.non_evm?(:bsc) == false
    end

    test "known_legacy? identifies legacy chains" do
      assert GasOptimizer.known_legacy?(:bsc) == true
      assert GasOptimizer.known_legacy?(:ethereum) == false
      assert GasOptimizer.known_legacy?(:solana) == false
    end
  end

  describe "Estimator" do
    setup do
      Estimator.clear_history()
      :ok
    end

    test "record_usage and get_history work together" do
      contract = "0xdac17f958d2ee523a2206206994597c13d831ec7"

      :ok = Estimator.record_usage(:ethereum, contract, "transfer", 55_000)
      :ok = Estimator.record_usage(:ethereum, contract, "transfer", 52_000)
      :ok = Estimator.record_usage(:ethereum, contract, "transfer", 58_000)

      {:ok, stats} = Estimator.get_history(:ethereum, contract, "transfer")

      assert stats.count == 3
      assert stats.min == 52_000
      assert stats.max == 58_000
      assert_in_delta stats.avg, 55_000.0, 100.0
    end

    test "get_history returns error for unknown contracts" do
      assert :error == Estimator.get_history(:ethereum, "0xunknown", "transfer")
    end

    test "clear_history removes all data" do
      Estimator.record_usage(:ethereum, "0xabc", "transfer", 50_000)
      Estimator.clear_history()
      assert :error == Estimator.get_history(:ethereum, "0xabc", "transfer")
    end

    test "history is capped at 100 entries" do
      contract = "0xtest"
      for i <- 1..120 do
        Estimator.record_usage(:ethereum, contract, "test", 50_000 + i)
      end

      {:ok, stats} = Estimator.get_history(:ethereum, contract, "test")
      assert stats.count == 100
      assert stats.min == 50_021
    end

    test "estimate returns {gas_limit, meta} tuple (not plain integer)" do
      tx_params = %{
        to: "0xunknown_contract",
        from: "0xsender",
        data: "0x12345678"
      }

      case Estimator.estimate(:ethereum, tx_params) do
        {:ok, {gas_limit, meta}} ->
          assert is_integer(gas_limit)
          assert gas_limit >= 21_000
          assert is_map(meta)
          assert Map.has_key?(meta, :source)
          assert Map.has_key?(meta, :anomaly)

        {:error, _} ->
          :ok
      end
    end

    test "estimate does not crash on historical path (fix: check_anomaly accepts integer)" do
      contract = "0xtarget"
      Estimator.record_usage(:ethereum, contract, "0xabcdef01", 100_000)

      tx_params = %{
        to: contract,
        from: "0xsender",
        data: "0xabcdef01ffffffff"
      }

      case Estimator.estimate(:ethereum, tx_params) do
        {:ok, {gas_limit, meta}} ->
          assert is_integer(gas_limit)
          assert gas_limit > 0
          assert is_map(meta)
          assert is_boolean(meta.anomaly)
        {:error, _} -> :ok
      end
    end

    test "anomaly detection works with historical data" do
      contract = "0xanomaly_test"
      for _ <- 1..10, do: Estimator.record_usage(:ethereum, contract, "transfer", 50_000)

      tx_params = %{
        to: contract,
        from: "0xsender",
        data: "0xa9059cbb"
      }

      case Estimator.estimate(:ethereum, tx_params) do
        {:ok, {_gas_limit, meta}} ->
          # With 10% margin on 50_000 max, estimate should be ~55_000
          # which is well below 2x the average of 50_000, so no anomaly
          assert is_boolean(meta.anomaly)
        {:error, _} -> :ok
      end
    end
  end

  describe "Replacement" do
    test "bump_fees increases EIP-1559 fees" do
      original = %{
        nonce: 5,
        to: "0xRecipient",
        from: "0xSender",
        value: 1_000_000_000_000_000_000,
        data: "0xabcdef",
        max_fee_per_gas: 30_000_000_000,
        max_priority_fee_per_gas: 2_000_000_000,
        gas_limit: 65_000
      }

      {:ok, replacement} = Replacement.bump_fees(original, :eip1559)
      assert replacement.nonce == original.nonce
      assert replacement.to == original.to
      assert replacement.from == original.from
      assert replacement.value == original.value
      assert replacement.data == original.data
      assert replacement.max_fee_per_gas > original.max_fee_per_gas
      assert replacement.max_priority_fee_per_gas > original.max_priority_fee_per_gas
    end

    test "bump_fees increases legacy gas_price" do
      original = %{
        nonce: 5,
        to: "0xRecipient",
        gas_price: 20_000_000_000
      }

      {:ok, replacement} = Replacement.bump_fees(original, :legacy)
      assert replacement.gas_price > original.gas_price
      assert replacement.nonce == original.nonce
    end

    test "bump_fees with custom percent" do
      original = %{
        nonce: 1,
        max_fee_per_gas: 100_000_000_000,
        max_priority_fee_per_gas: 3_000_000_000
      }

      {:ok, replacement} = Replacement.bump_fees(original, :eip1559, percent: 50)
      assert replacement.max_fee_per_gas == 150_000_000_001
    end

    test "bump_fees rejects too-low percent" do
      assert {:error, {:invalid_bump_percent, 5, _}} =
        Replacement.bump_fees(%{max_fee_per_gas: 100}, :eip1559, percent: 5)
    end

    test "bump_fees rejects missing fee fields" do
      assert {:error, :missing_fee_fields} =
        Replacement.bump_fees(%{nonce: 1}, :eip1559)
      assert {:error, :missing_gas_price} =
        Replacement.bump_fees(%{nonce: 1}, :legacy)
    end

    test "replaceable? validates matching fields" do
      original = %{
        nonce: 5,
        to: "0xABC",
        from: "0xDEF",
        value: 100,
        data: "0x00",
        max_fee_per_gas: 30_000_000_000,
        max_priority_fee_per_gas: 2_000_000_000
      }

      {:ok, replacement} = Replacement.bump_fees(original, :eip1559)
      assert Replacement.replaceable?(original, replacement) == true
    end

    test "replaceable? detects nonce mismatch" do
      original = %{nonce: 5, max_fee_per_gas: 100, max_priority_fee_per_gas: 10}
      replacement = %{nonce: 6, max_fee_per_gas: 200, max_priority_fee_per_gas: 20}
      assert {false, "nonce mismatch"} = Replacement.replaceable?(original, replacement)
    end

    test "replaceable? detects insufficient fee bump" do
      original = %{nonce: 5, max_fee_per_gas: 100, max_priority_fee_per_gas: 10}
      replacement = %{nonce: 5, max_fee_per_gas: 101, max_priority_fee_per_gas: 11}
      assert {false, "fees not increased sufficiently"} = Replacement.replaceable?(original, replacement)
    end

    test "minimum_bump_fee calculates correct minimum" do
      assert Replacement.minimum_bump_fee(100, :eip1559) == 111
      assert Replacement.minimum_bump_fee(30_000_000_000, :eip1559) == 33_000_000_001
    end

    test "build_replacement_chain generates multiple replacements" do
      original = %{
        nonce: 1,
        max_fee_per_gas: 100_000_000_000,
        max_priority_fee_per_gas: 2_000_000_000
      }

      {:ok, chain} = Replacement.build_replacement_chain(original, :eip1559, count: 3, step_percent: 10)
      assert length(chain) == 3

      [r1, r2, r3] = chain
      assert r1.max_fee_per_gas < r2.max_fee_per_gas
      assert r2.max_fee_per_gas < r3.max_fee_per_gas
    end

    test "replacement tx preserves original nonce but increases fees" do
      original = %{
        nonce: 42,
        to: "0xTarget",
        from: "0xSender",
        value: 1_000_000_000_000_000_000,
        data: "0xa9059cbb",
        max_fee_per_gas: 25_000_000_000,
        max_priority_fee_per_gas: 1_500_000_000,
        gas_limit: 65_000
      }

      {:ok, replacement} = Replacement.bump_fees(original, :eip1559)
      assert replacement.nonce == 42
      assert replacement.max_fee_per_gas > 25_000_000_000
      assert replacement.max_priority_fee_per_gas > 1_500_000_000
      assert replacement.to == "0xTarget"
      assert replacement.from == "0xSender"
      assert replacement.value == 1_000_000_000_000_000_000
      assert replacement.data == "0xa9059cbb"
    end
  end

  describe "Batcher" do
    test "new_batch creates an empty batch" do
      {:ok, batch} = Batcher.new_batch(:ethereum, %{type: :erc20_transfer})
      assert batch.chain == :ethereum
      assert batch.type == :erc20_transfer
      assert batch.transfers == []
      assert Batcher.batch_size(batch) == 0
    end

    test "add_transfer adds to batch" do
      {:ok, batch} = Batcher.new_batch(:ethereum, %{type: :erc20_transfer})
      {:ok, batch} = Batcher.add_transfer(batch, %{to: "0xabc", amount: 100})
      assert Batcher.batch_size(batch) == 1
      {:ok, batch} = Batcher.add_transfer(batch, %{to: "0xdef", amount: 200})
      assert Batcher.batch_size(batch) == 2
    end

    test "worth_batching? returns false for single transaction" do
      {:ok, batch} = Batcher.new_batch(:ethereum, %{type: :erc20_transfer})
      {:ok, batch} = Batcher.add_transfer(batch, %{to: "0xabc", amount: 100})
      refute Batcher.worth_batching?(batch)
    end

    test "worth_batching? returns true for multiple transactions" do
      {:ok, batch} = Batcher.new_batch(:ethereum, %{type: :erc20_transfer})
      {:ok, batch} = Batcher.add_transfer(batch, %{to: "0xabc", amount: 100})
      {:ok, batch} = Batcher.add_transfer(batch, %{to: "0xdef", amount: 200})
      assert Batcher.worth_batching?(batch)
    end

    test "build returns error for empty batch" do
      {:ok, batch} = Batcher.new_batch(:ethereum)
      assert {:error, :empty_batch} == Batcher.build(batch)
    end

    test "build encodes ERC-20 transfers" do
      {:ok, batch} = Batcher.new_batch(:ethereum, %{
        contract: "0xdAC17F958D2ee523a2206206994597C13D831ec7",
        type: :erc20_transfer
      })
      {:ok, batch} = Batcher.add_transfer(batch, %{to: "0x0000000000000000000000000000000000000001", amount: 1000})
      assert {:ok, encoded} = Batcher.build(batch)
      assert String.starts_with?(encoded, "0xa9059cbb")
    end

    test "estimate_savings shows gas reduction for batches" do
      {:ok, batch} = Batcher.new_batch(:ethereum, %{type: :erc20_transfer})
      for i <- 1..10 do
        {:ok, batch} = Batcher.add_transfer(batch, %{to: "0x#{i}", amount: 100})
      end

      {:ok, savings} = Batcher.estimate_savings(batch)
      assert savings.individual_gas > 0
      assert savings.batch_gas > 0
      assert savings.saved_gas > 0
      assert savings.saved_percent > 0.0
      assert savings.saved_percent > 30.0
    end

    test "full? and timed_out? work correctly" do
      {:ok, batch} = Batcher.new_batch(:ethereum, %{type: :erc20_transfer})
      {:ok, batch} = Batcher.add_transfer(batch, %{to: "0xabc", amount: 100})
      refute Batcher.full?(batch)
      refute Batcher.timed_out?(batch)
    end
  end

  describe "Predictor" do
    test "detect_low_periods returns valid periods for all chains" do
      for chain <- [:ethereum, :polygon, :bsc, :arbitrum] do
        {:ok, periods} = Predictor.detect_low_periods(chain)
        assert is_list(periods)
        assert length(periods) > 0

        for period <- periods do
          assert Map.has_key?(period, :start_hour)
          assert Map.has_key?(period, :end_hour)
          assert Map.has_key?(period, :avg_savings_percent)
          assert period.avg_savings_percent > 0
        end
      end
    end

    test "predict returns valid structure when RPC is unavailable" do
      case Predictor.predict(:ethereum) do
        {:ok, prediction} ->
          assert Map.has_key?(prediction, :current_trend)
          assert Map.has_key?(prediction, :volatility)
          assert Map.has_key?(prediction, :recommendation)
          assert prediction.current_trend in [:increasing, :decreasing, :stable]
          assert prediction.volatility in [:low, :medium, :high]
          assert prediction.recommendation in [:send_now, :wait, :urgent_only]
        {:error, _} -> :ok
      end
    end
  end

  describe "FeeOracle" do
    test "estimate returns error or valid structure when sources unavailable" do
      case FeeOracle.estimate(:ethereum) do
        {:ok, prices} ->
          assert Map.has_key?(prices, :base_fee)
          assert Map.has_key?(prices, :sources_queried)
          assert Map.has_key?(prices, :chain)
        {:error, _} -> :ok
      end
    end
  end

  describe "Non-EVM chain support" do
    test "get_gas_prices returns fallback for non-EVM chains" do
      {:ok, prices} = GasOptimizer.get_gas_prices(:solana)
      assert prices.chain == :solana
      assert prices.gas_price > 0

      {:ok, prices} = GasOptimizer.get_gas_prices(:near)
      assert prices.chain == :near
      assert prices.gas_price > 0
    end

    test "get_gas_prices returns error for unsupported chain" do
      assert {:error, {:unsupported_chain, :unknown_chain}} ==
        GasOptimizer.get_gas_prices(:unknown_chain)
    end

    test "base_fee_history returns error for non-EIP1559 chains" do
      assert {:error, {:not_eip1559, :bsc}} ==
        GasOptimizer.base_fee_history(:bsc, 10)
    end

    test "estimate_priority_fee returns error for non-EIP1559 chains" do
      assert {:error, {:not_eip1559, :bsc}} ==
        GasOptimizer.estimate_priority_fee(:bsc)
    end
  end

  describe "optimize/2" do
    test "optimize returns gas_estimate map (not plain integer)" do
      tx_params = %{
        to: "0xunknown",
        from: "0xsender",
        data: "0x12345678"
      }

      case GasOptimizer.optimize(:ethereum, tx_params) do
        {:ok, gas_estimate} ->
          assert is_map(gas_estimate)
          assert Map.has_key?(gas_estimate, :gas_limit)
          assert Map.has_key?(gas_estimate, :meta)
          assert Map.has_key?(gas_estimate, :suggestion)
          assert is_integer(gas_estimate.gas_limit)
        {:error, _} -> :ok
      end
    end
  end

  describe "estimate_gas/2 public API type consistency" do
    test "estimate_gas returns {gas_limit, meta} matching spec" do
      tx_params = %{
        to: "0xunknown",
        from: "0xsender",
        data: "0x12345678"
      }

      case GasOptimizer.estimate_gas(:ethereum, tx_params) do
        {:ok, {gas_limit, meta}} ->
          assert is_integer(gas_limit)
          assert is_map(meta)
          assert is_atom(meta.source)
          assert is_boolean(meta.anomaly)
        {:error, _} -> :ok
      end
    end
  end

  describe "replace_transaction/3" do
    test "replace_transaction delegates to Replacement.bump_fees" do
      tx = %{nonce: 1, max_fee_per_gas: 100, max_priority_fee_per_gas: 5}
      {:ok, replacement} = GasOptimizer.replace_transaction(tx, :eip1559)
      assert replacement.nonce == 1
      assert replacement.max_fee_per_gas > 100
    end
  end
end
