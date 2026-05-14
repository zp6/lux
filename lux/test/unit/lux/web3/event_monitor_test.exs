defmodule Lux.Web3.EventMonitorTest do
  use UnitAPICase, async: true

  alias Lux.Web3.EventMonitor
  alias Lux.Web3.EventMonitor.{Alerts, Decoder, Storage, Subscriber}

  # Transfer event topic: keccak256("Transfer(address,address,uint256)")
  @transfer_topic "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"

  # ApprovalForAll topic: keccak256("ApprovalForAll(address,address,bool)")
  @approval_for_all_topic "0x17307eab39ab6107e8899845ad3d59bd9653f200f220920489ca2b5937616c5b"

  describe "Decoder" do
    test "identifies ERC-20 standard from Transfer event" do
      log = %{
        topics: [@transfer_topic, "0x" <> pad_address("aaa"), "0x" <> pad_address("bbb")],
        data: "0x0000000000000000000000000000000000000000000000000de0b6b3a7640000",
        address: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
        block_number: 18_000_000,
        transaction_hash: "0xabc123",
        log_index: 0
      }

      assert Decoder.identify_standard(log) == :erc20
    end

    test "identifies unknown standard for unrecognized events" do
      log = %{topics: ["0xdeadbeef"], data: "0x", address: "0x0", block_number: 1, transaction_hash: "0x0", log_index: 0}
      assert Decoder.identify_standard(log) == :unknown
    end

    test "returns :unknown for log with no topics" do
      log = %{topics: [], data: "0x"}
      assert Decoder.identify_standard(log) == :unknown
    end

    test "gets event name for Transfer" do
      log = %{topics: [@transfer_topic]}
      assert Decoder.get_event_name(log) == "Transfer"
    end

    test "gets :unknown for unrecognized event" do
      log = %{topics: ["0xunknown"]}
      assert Decoder.get_event_name(log) == :unknown
    end

    test "decodes indexed address parameter" do
      # address left-padded to 32 bytes
      padded = "0x000000000000000000000000aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      decoded = Decoder.decode_indexed_param(padded)
      assert decoded == "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    end

    test "decodes indexed uint256 parameter" do
      # uint256 value
      padded = "0x0000000000000000000000000000000000000000000000000000000000000001"
      decoded = Decoder.decode_indexed_param(padded)
      assert decoded == "1"
    end

    test "decodes data params from hex" do
      data = "000000000000000000000000000000000000000000000000000000000000000a" <>
             "0000000000000000000000000000000000000000000000000000000000000014"
      params = Decoder.decode_data_params(data, ["uint256", "uint256"])
      assert params == [10, 20]
    end

    test "decodes ERC-20 Transfer log" do
      log = %{
        topics: [
          @transfer_topic,
          "0x000000000000000000000000aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "0x000000000000000000000000bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        ],
        data: "0x0000000000000000000000000000000000000000000000000de0b6b3a7640000",
        address: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
        block_number: 18_000_000,
        transaction_hash: "0xabc123def456",
        log_index: 42
      }

      {:ok, decoded} = Decoder.decode_log(log)

      assert decoded.name == "Transfer"
      assert decoded.standard == :erc20
      assert decoded.contract_address == "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
      assert decoded.block_number == 18_000_000
      assert decoded.transaction_hash == "0xabc123def456"
      assert decoded.log_index == 42
      assert decoded.params[:from] == "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      assert decoded.params[:to] == "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      assert is_integer(decoded.params[:value])
    end

    test "returns error for log with no topics" do
      log = %{topics: [], data: "0x"}
      assert {:error, :no_topics} = Decoder.decode_log(log)
    end

    test "returns error for unknown event" do
      log = %{topics: ["0xdeadbeef"], data: "0x"}
      assert {:error, {:unknown_event, _}} = Decoder.decode_log(log)
    end

    test "standard_events returns the events map" do
      events = Decoder.standard_events()
      assert is_map(events)
      assert Map.has_key?(events, String.downcase(@transfer_topic))
    end
  end

  describe "Storage" do
    setup do
      name = :"storage_test_#{System.unique_integer([:positive])}"
      {:ok, _pid} = Storage.start_link(name: name)
      {:ok, storage: name}
    end

    test "stores and retrieves an event", %{storage: storage} do
      event = sample_event()
      assert :ok = Storage.store_event(event, storage)
      {:ok, events} = Storage.query_events([], storage)
      assert length(events) == 1
    end

    test "deduplicates events by tx_hash + log_index", %{storage: storage} do
      event = sample_event()
      :ok = Storage.store_event(event, storage)
      assert {:error, :duplicate} = Storage.store_event(event, storage)
      assert Storage.count(storage) == 1
    end

    test "stores events in batch", %{storage: storage} do
      events = [
        %{sample_event() | transaction_hash: "0xabc1", log_index: 0},
        %{sample_event() | transaction_hash: "0xabc2", log_index: 0},
        %{sample_event() | transaction_hash: "0xabc3", log_index: 0}
      ]

      {:ok, stored} = Storage.store_events(events, storage)
      assert stored == 3
    end

    test "queries events by contract address", %{storage: storage} do
      e1 = %{sample_event() | contract_address: "0xaaa", transaction_hash: "0xtx1"}
      e2 = %{sample_event() | contract_address: "0xbbb", transaction_hash: "0xtx2"}
      :ok = Storage.store_event(e1, storage)
      :ok = Storage.store_event(e2, storage)

      {:ok, results} = Storage.query_events([contract_address: "0xaaa"], storage)
      assert length(results) == 1
      assert hd(results).contract_address == "0xaaa"
    end

    test "queries events by event name", %{storage: storage} do
      e1 = %{sample_event() | event_name: "Transfer", transaction_hash: "0xtx1"}
      e2 = %{sample_event() | event_name: "Approval", transaction_hash: "0xtx2"}
      :ok = Storage.store_event(e1, storage)
      :ok = Storage.store_event(e2, storage)

      {:ok, results} = Storage.query_events([event_name: "Transfer"], storage)
      assert length(results) == 1
    end

    test "queries events by block range", %{storage: storage} do
      e1 = %{sample_event() | block_number: 100, transaction_hash: "0xtx1"}
      e2 = %{sample_event() | block_number: 200, transaction_hash: "0xtx2"}
      e3 = %{sample_event() | block_number: 300, transaction_hash: "0xtx3"}
      :ok = Storage.store_event(e1, storage)
      :ok = Storage.store_event(e2, storage)
      :ok = Storage.store_event(e3, storage)

      {:ok, results} = Storage.query_events([from_block: 150, to_block: 250], storage)
      assert length(results) == 1
      assert hd(results).block_number == 200
    end

    test "respects limit and offset", %{storage: storage} do
      for i <- 1..10 do
        :ok = Storage.store_event(%{sample_event() | transaction_hash: "0xtx#{i}", block_number: i}, storage)
      end

      {:ok, page1} = Storage.query_events([limit: 3, offset: 0], storage)
      assert length(page1) == 3

      {:ok, page2} = Storage.query_events([limit: 3, offset: 3], storage)
      assert length(page2) == 3
    end

    test "gets event by id", %{storage: storage} do
      :ok = Storage.store_event(sample_event(), storage)
      {:ok, events} = Storage.query_events([], storage)
      event_id = hd(events).id

      {:ok, found} = Storage.get_event(event_id, storage)
      assert found.id == event_id
    end

    test "returns not_found for missing event", %{storage: storage} do
      assert {:error, :not_found} = Storage.get_event("nonexistent", storage)
    end

    test "clears all events", %{storage: storage} do
      :ok = Storage.store_event(sample_event(), storage)
      assert :ok = Storage.clear(storage)
      assert Storage.count(storage) == 0
    end

    test "gets last block for a chain", %{storage: storage} do
      :ok = Storage.store_event(%{sample_event() | block_number: 100, chain_id: 1, transaction_hash: "0xtx1"}, storage)
      :ok = Storage.store_event(%{sample_event() | block_number: 200, chain_id: 1, transaction_hash: "0xtx2"}, storage)

      assert Storage.get_last_block(1, nil, storage) == 200
    end

    test "prunes old events", %{storage: storage} do
      for i <- 1..10 do
        :ok = Storage.store_event(%{sample_event() | block_number: i * 100, transaction_hash: "0xtx#{i}"}, storage)
      end

      {:ok, removed} = Storage.prune_old_events(500, storage)
      assert removed == 5  # blocks 100-500 removed
    end
  end

  describe "Subscriber" do
    setup do
      name = :"subscriber_test_#{System.unique_integer([:positive])}"
      # Ensure minimal config
      original = Application.get_env(:lux, Subscriber, [])
      Application.put_env(:lux, Subscriber, Keyword.merge(original,
        chains: %{
          ethereum: %{rpc_url: "https://eth.example.com", chain_id: 1},
          polygon: %{rpc_url: "https://polygon.example.com", chain_id: 137}
        }
      ))

      on_exit(fn ->
        Application.put_env(:lux, Subscriber, original)
      end)

      {:ok, _pid} = Subscriber.start_link(name: name, poll_interval: 60_000)
      {:ok, subscriber: name}
    end

    test "creates a subscription", %{subscriber: subscriber} do
      {:ok, sub_id} = Subscriber.subscribe(%{
        chain: :ethereum,
        contract_address: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
        event_topics: ["Transfer(address,address,uint256)"],
        from_block: 18_000_000
      })

      assert is_binary(sub_id)

      {:ok, subs} = Subscriber.list_subscriptions()
      assert length(subs) == 1
      assert hd(subs).id == sub_id
      assert hd(subs).chain == :ethereum
      assert hd(subs).status == :active
    end

    test "rejects invalid chain" do
      assert {:error, {:invalid_chain, :solana}} = Subscriber.subscribe(%{
        chain: :solana,
        contract_address: "0x0"
      })
    end

    test "unsubscribes", %{subscriber: subscriber} do
      {:ok, sub_id} = Subscriber.subscribe(%{
        chain: :ethereum,
        contract_address: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
      })

      assert :ok = Subscriber.unsubscribe(sub_id)
      assert {:error, :not_found} = Subscriber.unsubscribe("nonexistent")
    end

    test "pauses and resumes subscription" do
      {:ok, sub_id} = Subscriber.subscribe(%{
        chain: :ethereum,
        contract_address: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
      })

      assert :ok = Subscriber.pause(sub_id)
      {:ok, sub} = Subscriber.get_subscription(sub_id)
      assert sub.status == :paused

      assert :ok = Subscriber.resume(sub_id)
      {:ok, sub} = Subscriber.get_subscription(sub_id)
      assert sub.status == :active
    end

    test "returns not_found for missing subscription" do
      assert {:error, :not_found} = Subscriber.get_subscription("nonexistent")
    end

    test "returns RPC URL for chain" do
      assert Subscriber.rpc_url(:ethereum) == "https://eth.example.com"
      assert Subscriber.rpc_url(:unknown) == nil
    end

    test "returns chain ID for chain" do
      assert Subscriber.chain_id(:ethereum) == 1
      assert Subscriber.chain_id(:polygon) == 137
    end
  end

  describe "Alerts" do
    setup do
      name = :"alerts_test_#{System.unique_integer([:positive])}"
      {:ok, _pid} = Alerts.start_link(name: name)
      {:ok, alerts: name}
    end

    test "creates an alert rule" do
      {:ok, rule_id} = Alerts.create_rule(%{
        name: "test_rule",
        event_name: "Transfer",
        conditions: [%{field: "value", operator: :gt, threshold: 1000}],
        channels: [:discord]
      })

      assert is_binary(rule_id)

      {:ok, rules} = Alerts.list_rules()
      assert length(rules) == 1
      assert hd(rules).name == "test_rule"
      assert hd(rules).enabled == true
    end

    test "deletes an alert rule" do
      {:ok, rule_id} = Alerts.create_rule(%{name: "to_delete", event_name: "Transfer"})
      assert :ok = Alerts.delete_rule(rule_id)
      assert {:error, :not_found} = Alerts.delete_rule(rule_id)
    end

    test "enables and disables rules" do
      {:ok, rule_id} = Alerts.create_rule(%{name: "toggle", event_name: "Transfer"})

      assert :ok = Alerts.disable_rule(rule_id)
      {:ok, rule} = Alerts.get_rule(rule_id)
      assert rule.enabled == false

      assert :ok = Alerts.enable_rule(rule_id)
      {:ok, rule} = Alerts.get_rule(rule_id)
      assert rule.enabled == true
    end

    test "processes event and triggers matching rules" do
      {:ok, _rule_id} = Alerts.create_rule(%{
        name: "large_transfer",
        event_name: "Transfer",
        conditions: [%{field: "value", operator: :gt, threshold: 1000}]
      })

      event = %{
        event_name: "Transfer",
        contract_address: "0x0",
        params: %{value: 5000},
        block_number: 100,
        transaction_hash: "0xabc"
      }

      {:ok, triggered} = Alerts.process_event(event)
      assert length(triggered) == 1
      assert hd(triggered).rule_name == "large_transfer"
      assert hd(triggered).message =~ "large_transfer"
    end

    test "does not trigger rules with unmet conditions" do
      {:ok, _rule_id} = Alerts.create_rule(%{
        name: "large_transfer",
        event_name: "Transfer",
        conditions: [%{field: "value", operator: :gt, threshold: 1000}]
      })

      event = %{
        event_name: "Transfer",
        contract_address: "0x0",
        params: %{value: 100},
        block_number: 100,
        transaction_hash: "0xabc"
      }

      {:ok, triggered} = Alerts.process_event(event)
      assert triggered == []
    end

    test "does not trigger rules for different event names" do
      {:ok, _rule_id} = Alerts.create_rule(%{
        name: "transfer_rule",
        event_name: "Transfer"
      })

      event = %{event_name: "Approval", params: %{}, block_number: 1, transaction_hash: "0x0", contract_address: "0x0"}
      {:ok, triggered} = Alerts.process_event(event)
      assert triggered == []
    end

    test "respects contract address filter" do
      {:ok, _rule_id} = Alerts.create_rule(%{
        name: "filtered_rule",
        event_name: "Transfer",
        contract_address: "0xaaa"
      })

      event_matching = %{event_name: "Transfer", contract_address: "0xaaa", params: %{}, block_number: 1, transaction_hash: "0x0"}
      event_not_matching = %{event_name: "Transfer", contract_address: "0xbbb", params: %{}, block_number: 1, transaction_hash: "0x1"}

      {:ok, t1} = Alerts.process_event(event_matching)
      assert length(t1) == 1

      {:ok, t2} = Alerts.process_event(event_not_matching)
      assert t2 == []
    end

    test "creates large transfer alert helper" do
      {:ok, rule_id} = Alerts.create_large_transfer_alert("0xusdc", 1_000_000)
      assert is_binary(rule_id)

      {:ok, rule} = Alerts.get_rule(rule_id)
      assert rule.event_name == "Transfer"
    end
  end

  describe "EventMonitor (main module)" do
    setup do
      storage_name = :"em_storage_#{System.unique_integer([:positive])}"
      alerts_name = :"em_alerts_#{System.unique_integer([:positive])}"
      subscriber_name = :"em_subscriber_#{System.unique_integer([:positive])}"

      {:ok, _} = Storage.start_link(name: storage_name)
      {:ok, _} = Alerts.start_link(name: alerts_name)

      original = Application.get_env(:lux, Subscriber, [])
      Application.put_env(:lux, Subscriber, Keyword.merge(original,
        chains: %{ethereum: %{rpc_url: "https://eth.example.com", chain_id: 1}}
      ))
      {:ok, _} = Subscriber.start_link(name: subscriber_name, poll_interval: 60_000)

      on_exit(fn -> Application.put_env(:lux, Subscriber, original) end)

      {:ok, storage: storage_name, alerts: alerts_name, subscriber: subscriber_name}
    end

    test "status returns system overview" do
      status = EventMonitor.status()
      assert Map.has_key?(status, :storage)
      assert Map.has_key?(status, :subscriptions)
      assert Map.has_key?(status, :alerts)
    end
  end

  # Helpers

  defp sample_event do
    %{
      contract_address: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
      event_name: "Transfer",
      block_number: 18_000_000,
      transaction_hash: "0xabc123",
      log_index: 0,
      params: %{from: "0xaaa", to: "0xbbb", value: 1000},
      chain_id: 1
    }
  end

  defp pad_address(hex) do
    String.downcase(String.pad_leading(hex, 48, "0"))
  end
end
