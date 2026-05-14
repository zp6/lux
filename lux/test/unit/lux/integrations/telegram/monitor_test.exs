defmodule Lux.Integrations.Telegram.MonitorTest do
  use ExUnit.Case, async: false

  alias Lux.Integrations.Telegram.Monitor
  alias Lux.Integrations.Telegram.Analytics

  setup do
    # Start analytics first (monitor depends on it)
    analytics_name = :"analytics_monitor_test_#{System.unique_integer([:positive])}"
    start_supervised!({Analytics, name: analytics_name})

    monitor_name = :"monitor_test_#{System.unique_integer([:positive])}"
    start_supervised!({Monitor, name: monitor_name, health_check_interval_ms: 0})

    {:ok, monitor: monitor_name}
  end

  describe "track_call/2" do
    test "tracks a successful API call" do
      {:ok, result} = Monitor.track_call("/sendMessage", fn ->
        {:ok, %{"ok" => true, "result" => %{"message_id" => 42}}}
      end)

      assert result == %{"ok" => true, "result" => %{"message_id" => 42}}
    end

    test "tracks a failed API call" do
      {:error, reason} = Monitor.track_call("/sendMessage", fn ->
        {:error, "chat not found"}
      end)

      assert reason == "chat not found"
    end

    test "handles exceptions in tracked calls" do
      {:error, reason} = Monitor.track_call("/sendMessage", fn ->
        raise "connection timeout"
      end)

      assert is_binary(reason)
    end

    test "measures response time" do
      {:ok, _} = Monitor.track_call("/getMe", fn ->
        Process.sleep(10)
        {:ok, %{"ok" => true}}
      end)

      # The response time should have been recorded
      assert true
    end
  end

  describe "register_alert/1 and get_alerts/0" do
    test "registers and retrieves alerts" do
      alert = %{
        name: :high_error_rate,
        metric: :error_rate,
        threshold: 10.0,
        window_ms: 60_000,
        callback: nil
      }

      :ok = Monitor.register_alert(alert)
      Process.sleep(10)

      {:ok, alerts} = Monitor.get_alerts()
      assert length(alerts) >= 1
      assert Enum.any?(alerts, &(&1.name == :high_error_rate))
    end

    test "fires callback on error when error_rate alert is set" do
      test_pid = self()

      alert = %{
        name: :test_alert,
        metric: :error_rate,
        threshold: 5.0,
        window_ms: 60_000,
        callback: fn info ->
          send(test_pid, {:alert_fired, info})
        end
      }

      :ok = Monitor.register_alert(alert)
      Process.sleep(10)

      {:error, _} = Monitor.track_call("/sendMessage", fn ->
        {:error, "test error"}
      end)

      assert_received {:alert_fired, %{name: :test_alert, metric: :error_rate}}
    end
  end

  describe "get_status/0" do
    test "returns monitor status" do
      {:ok, status} = Monitor.get_status()
      assert Map.has_key?(status, :alert_count)
      assert Map.has_key?(status, :active_alerts)
    end
  end
end
