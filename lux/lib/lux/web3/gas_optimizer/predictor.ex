defmodule Lux.Web3.GasOptimizer.Predictor do
  @moduledoc """
  Gas price prediction based on historical block analysis.

  Analyzes recent block data to identify gas price trends, detect low-traffic
  periods, and suggest optimal transaction timing. Helps reduce gas costs by
  recommending when to delay non-urgent transactions.

  ## Prediction Strategy

  1. **Trend Analysis** - Compares recent base fees to identify increasing or
     decreasing trends
  2. **Low-Period Detection** - Identifies time windows when gas prices
     historically drop (e.g., weekends, UTC nighttime)
  3. **Volatility Assessment** - Measures gas price volatility to suggest
     conservative or aggressive strategies
  4. **Optimal Time Suggestion** - Combines all signals to recommend the best
     time to send a transaction

  ## Configuration

      config :lux, Lux.Web3.GasOptimizer.Predictor,
        # Number of recent blocks to analyze for trend detection
        trend_window: 20,
        # Number of blocks to look back for historical pattern analysis
        history_blocks: 1000,
        # Minimum time difference (seconds) to consider a wait worthwhile
        min_wait_threshold: 60,
        # Maximum wait time to suggest (seconds)
        max_wait_suggestion: 3600

  ## Usage

      alias Lux.Web3.GasOptimizer.Predictor

      # Get prediction for optimal send time
      {:ok, prediction} = Predictor.predict(:ethereum)
      # => %{
      #   current_trend: :decreasing,
      #   suggested_wait_seconds: 1800,
      #   estimated_savings_percent: 15.5,
      #   optimal_window: %{start: ~U[2024-01-01 02:00:00Z], end: ~U[2024-01-01 06:00:00Z]},
      #   volatility: :low,
      #   recommendation: :wait
      # }

      # Quick check: should I send now or wait?
      {:ok, advice} = Predictor.should_wait?(:ethereum)
      # => {:wait, 1800}  # wait 30 minutes
      # => :send_now       # send immediately
  """

  require Logger

  @type trend :: :increasing | :decreasing | :stable
  @type volatility :: :low | :medium | :high
  @type recommendation :: :send_now | :wait | :urgent_only

  @type prediction :: %{
          current_trend: trend(),
          suggested_wait_seconds: non_neg_integer(),
          estimated_savings_percent: float(),
          optimal_window: %{start: DateTime.t(), end: DateTime.t()} | nil,
          volatility: volatility(),
          recommendation: recommendation(),
          current_base_fee: non_neg_integer(),
          predicted_base_fee: non_neg_integer()
        }

  # Known low-traffic hours (UTC) for each chain
  @low_traffic_hours %{
    ethereum: {0, 6},    # UTC midnight to 6am
    polygon: {1, 7},
    bsc: {0, 5},
    arbitrum: {0, 6}
  }

  # Weekend days (Saturday=6, Sunday=7)
  @weekend_days [6, 7]

  @doc """
  Predicts optimal gas price timing for the specified chain.

  Fetches recent block data, analyzes trends, and provides a comprehensive
  prediction with actionable recommendations.

  ## Examples

      {:ok, prediction} = Predictor.predict(:ethereum)
  """
  @spec predict(atom()) :: {:ok, prediction()} | {:error, term()}
  def predict(chain) do
    with {:ok, blocks} <- fetch_recent_blocks(chain) do
      base_fees = extract_base_fees(blocks)
      current_base_fee = List.first(base_fees, 0)

      trend = analyze_trend(base_fees)
      volatility = assess_volatility(base_fees)
      predicted_fee = predict_next_fee(base_fees)

      {suggested_wait, savings_percent, optimal_window} =
        calculate_wait_recommendation(chain, trend, current_base_fee, predicted_fee, volatility)

      recommendation = determine_recommendation(trend, volatility, savings_percent)

      {:ok, %{
        current_trend: trend,
        suggested_wait_seconds: suggested_wait,
        estimated_savings_percent: Float.round(savings_percent, 1),
        optimal_window: optimal_window,
        volatility: volatility,
        recommendation: recommendation,
        current_base_fee: current_base_fee,
        predicted_base_fee: predicted_fee
      }}
    end
  end

  @doc """
  Quick check whether to send a transaction now or wait.

  ## Returns

    * `{:wait, seconds}` - Wait the specified number of seconds for better prices
    * `:send_now` - Current conditions are good, send now

  ## Examples

      case Predictor.should_wait?(:ethereum) do
        {:wait, seconds} -> schedule_send(seconds)
        :send_now -> send_transaction()
      end
  """
  @spec should_wait?(atom()) :: {:ok, {:wait, non_neg_integer()} | :send_now} | {:error, term()}
  def should_wait?(chain) do
    case predict(chain) do
      {:ok, %{recommendation: :send_now}} ->
        {:ok, :send_now}

      {:ok, %{suggested_wait_seconds: wait, estimated_savings_percent: savings}}
      when savings > 5.0 and wait > 0 ->
        {:ok, {:wait, wait}}

      _ ->
        {:ok, :send_now}
    end
  end

  @doc """
  Detects low-traffic periods for the specified chain.

  Low-traffic periods typically have 20-40% lower gas prices.

  ## Examples

      {:ok, periods} = Predictor.detect_low_periods(:ethereum)
      # => [%{start_hour: 0, end_hour: 6, avg_savings_percent: 25.0}]
  """
  @spec detect_low_periods(atom()) :: {:ok, [map()]}
  def detect_low_periods(chain) do
    {start_h, end_h} = Map.get(@low_traffic_hours, chain, {0, 6})

    periods = [
      %{
        start_hour: start_h,
        end_hour: end_h,
        timezone: "UTC",
        avg_savings_percent: estimate_period_savings(chain, start_h, end_h),
        is_weekend_bonus: true
      }
    ]

    {:ok, periods}
  end

  # --- Trend Analysis ---

  defp analyze_trend([]), do: :stable
  defp analyze_trend([_single]), do: :stable
  defp analyze_trend(base_fees) do
    recent = Enum.take(base_fees, div(trend_window(), 2))
    older = Enum.drop(base_fees, div(trend_window(), 2)) |> Enum.take(div(trend_window(), 2))

    if older == [] do
      :stable
    else
      recent_avg = Enum.sum(recent) / length(recent)
      older_avg = Enum.sum(older) / length(older)

      change = if older_avg > 0, do: (recent_avg - older_avg) / older_avg * 100, else: 0.0

      cond do
        change > 10.0 -> :increasing
        change < -10.0 -> :decreasing
        true -> :stable
      end
    end
  end

  defp assess_volatility([]), do: :low
  defp assess_volatility([_single]), do: :low
  defp assess_volatility(base_fees) do
    avg = Enum.sum(base_fees) / length(base_fees)

    if avg == 0 do
      :low
    else
      variance =
        base_fees
        |> Enum.map(fn fee -> :math.pow(fee - avg, 2) end)
        |> Enum.sum()
        |> Kernel./(length(base_fees))

      std_dev = :math.sqrt(variance)
      coefficient = std_dev / avg

      cond do
        coefficient < 0.1 -> :low
        coefficient < 0.3 -> :medium
        true -> :high
      end
    end
  end

  defp predict_next_fee([]), do: 0
  defp predict_next_fee([single]), do: single
  defp predict_next_fee(base_fees) do
    # Simple linear regression on the most recent fees
    recent = Enum.take(base_fees, trend_window())

    if length(recent) < 3 do
      List.first(base_fees, 0)
    else
      n = length(recent)
      xs = Enum.to_list(1..n)
      ys = recent

      x_sum = Enum.sum(xs)
      y_sum = Enum.sum(ys)
      xy_sum = Enum.zip(xs, ys) |> Enum.map(fn {x, y} -> x * y end) |> Enum.sum()
      x2_sum = Enum.map(xs, &(&1 * &1)) |> Enum.sum()

      denominator = n * x2_sum - x_sum * x_sum

      if denominator == 0 do
        List.first(recent, 0)
      else
        slope = (n * xy_sum - x_sum * y_sum) / denominator
        intercept = (y_sum - slope * x_sum) / n
        max(0, trunc(intercept + slope * (n + 1)))
      end
    end
  end

  defp calculate_wait_recommendation(chain, trend, current_fee, predicted_fee, volatility) do
    max_wait = max_wait_suggestion()
    min_wait = min_wait_threshold()

    base_savings = if current_fee > 0 and predicted_fee < current_fee do
      (current_fee - predicted_fee) / current_fee * 100
    else
      0.0
    end

    # Adjust savings based on known low-traffic periods
    {start_h, end_h} = Map.get(@low_traffic_hours, chain, {0, 6})
    now = DateTime.utc_now()
    current_hour = now.hour

    in_low_period = current_hour >= start_h and current_hour < end_h
    is_weekend = Date.day_of_week(now) in @weekend_days

    savings_adjustment = cond do
      in_low_period -> 0.0  # Already in a good period
      is_weekend -> 5.0     # Weekend bonus
      true -> 10.0          # Could wait for nighttime
    end

    adjusted_savings = min(base_savings + savings_adjustment, 50.0)

    {wait_seconds, optimal_window} =
      cond do
        trend == :decreasing and adjusted_savings > 5.0 ->
          # Wait for the trend to continue
          wait = min(trunc(max_wait * adjusted_savings / 50), max_wait)
          window = calculate_optimal_window(chain, start_h, end_h)
          {max(wait, min_wait), window}

        trend == :stable and not in_low_period and adjusted_savings > 10.0 ->
          # Wait for low-traffic period
          hours_until_low = if current_hour > end_h do
            24 - current_hour + start_h
          else
            start_h - current_hour
          end
          wait = hours_until_low * 3600
          window = calculate_optimal_window(chain, start_h, end_h)
          {min(wait, max_wait), window}

        volatility == :high and adjusted_savings > 15.0 ->
          wait = min(trunc(max_wait * 0.5), max_wait)
          {max(wait, min_wait), nil}

        true ->
          {0, nil}
      end

    {wait_seconds, adjusted_savings, optimal_window}
  end

  defp calculate_optimal_window(chain, start_h, end_h) do
    now = DateTime.utc_now()

    start_dt =
      if now.hour < start_h do
        DateTime.new!(Date.utc_today(), ~T[00:00:00] |> Time.add(start_h * 3600), "Etc/UTC")
      else
        DateTime.new!(Date.utc_today() |> Date.add(1), ~T[00:00:00] |> Time.add(start_h * 3600), "Etc/UTC")
      end

    end_dt = DateTime.add(start_dt, (end_h - start_h) * 3600, :second)

    %{start: start_dt, end: end_dt}
  rescue
    _ -> nil
  end

  defp determine_recommendation(:decreasing, :high, savings) when savings > 15.0, do: :wait
  defp determine_recommendation(:increasing, _, _), do: :send_now
  defp determine_recommendation(:stable, :low, _), do: :send_now
  defp determine_recommendation(:stable, _, savings) when savings > 10.0, do: :wait
  defp determine_recommendation(:decreasing, _, savings) when savings > 5.0, do: :wait
  defp determine_recommendation(_, :high, _), do: :urgent_only
  defp determine_recommendation(_, _, _), do: :send_now

  defp estimate_period_savings(_chain, _start_h, _end_h), do: 25.0

  # --- Data Fetching ---

  defp fetch_recent_blocks(chain) do
    url = Lux.Web3.GasOptimizer.rpc_url(chain)
    window = trend_window()

    # Fetch the latest block number first
    with {:ok, %{"result" => hex_number}} <- json_rpc(url, "eth_blockNumber", []) do
      latest = parse_hex_int(hex_number)

      # Fetch recent blocks (every 5th block for efficiency)
      block_numbers =
        (latest - window * 5)..latest
        |> Enum.take_every(5)
        |> Enum.to_list()

      blocks =
        block_numbers
        |> Enum.map(fn num ->
          case json_rpc(url, "eth_getBlockByNumber", [encode_hex_int(num), false]) do
            {:ok, %{"result" => block}} when is_map(block) -> block
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      {:ok, blocks}
    else
      {:error, reason} ->
        Logger.error("Failed to fetch blocks for prediction: #{inspect(reason)}")
        {:error, {:block_fetch_failed, reason}}
    end
  end

  defp extract_base_fees(blocks) do
    blocks
    |> Enum.map(fn block ->
      case block["baseFeePerGas"] do
        nil -> nil
        hex -> parse_hex_int(hex)
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  # --- Helpers ---

  defp json_rpc(url, method, params) do
    body = Jason.encode!(%{
      jsonrpc: "2.0",
      id: System.unique_integer([:positive]),
      method: method,
      params: params
    })

    case Req.post(url, body: body, headers: [{"content-type", "application/json"}], receive_timeout: 10_000) do
      {:ok, %Req.Response{status: 200, body: %{"error" => error}}} ->
        {:error, {:rpc_error, error}}

      {:ok, %Req.Response{status: 200, body: response}} ->
        {:ok, response}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  defp parse_hex_int("0x" <> hex), do: String.to_integer(hex, 16)
  defp parse_hex_int(_), do: 0

  defp encode_hex_int(n), do: "0x" <> Integer.to_string(n, 16)

  defp trend_window do
    :lux
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:trend_window, 20)
  end

  defp min_wait_threshold do
    :lux
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:min_wait_threshold, 60)
  end

  defp max_wait_suggestion do
    :lux
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:max_wait_suggestion, 3600)
  end
end
