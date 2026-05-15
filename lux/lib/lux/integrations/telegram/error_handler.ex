defmodule Lux.Integrations.Telegram.ErrorHandler do
  @moduledoc """
  Error handling and retry logic for Telegram Bot API requests.

  Implements exponential backoff with jitter for transient errors,
  handles rate limiting (429 Too Many Requests), and provides
  structured error classification for Telegram API error codes.

  ## Error Categories

  - `:transient` - Network errors, timeouts, 500s (retry with backoff)
  - `:rate_limited` - 429 errors (respect Retry-After header)
  - `:fatal` - Auth errors (401), bad requests (400) (no retry)
  - `:conflict` - 409 Conflict (another bot instance active)

  ## Examples

      iex> Lux.Integrations.Telegram.ErrorHandler.with_retry(fn ->
      ...>   Client.request(:post, "/sendMessage", %{json: %{chat_id: 123, text: "Hi"}})
      ...> end, max_retries: 3)
      {:ok, %{"ok" => true, "result" => %{...}}}
  """

  require Logger

  @default_max_retries 3
  @base_delay_ms 1000
  @max_delay_ms 30_000

  @doc """
  Executes a function with automatic retry on transient errors.

  Options:
  - `:max_retries` - Maximum number of retry attempts (default: 3)
  - `:base_delay` - Base delay in ms for exponential backoff (default: 1000)
  - `:on_retry` - Callback function invoked on each retry
  """
  def with_retry(fun, opts \\ []) when is_function(fun, 0) do
    max_retries = Keyword.get(opts, :max_retries, @default_max_retries)
    base_delay = Keyword.get(opts, :base_delay, @base_delay_ms)

    execute_with_retry(fun, max_retries, base_delay, 0, opts)
  end

  defp execute_with_retry(fun, max_retries, base_delay, attempt, opts) do
    case fun.() do
      {:ok, result} ->
        {:ok, result}

      {:error, :rate_limited, retry_after} when attempt < max_retries ->
        wait_ms = retry_after * 1000
        Logger.warning("Rate limited by Telegram API. Waiting #{wait_ms}ms (attempt #{attempt + 1}/#{max_retries})")
        notify_retry(opts, attempt, :rate_limited, wait_ms)
        Process.sleep(wait_ms)
        execute_with_retry(fun, max_retries, base_delay, attempt + 1, opts)

      {:error, %{"error_code" => 429, "parameters" => %{"retry_after" => retry_after}} = error}
      when attempt < max_retries ->
        wait_ms = retry_after * 1000
        Logger.warning("Telegram 429: waiting #{wait_ms}ms (attempt #{attempt + 1}/#{max_retries})")
        notify_retry(opts, attempt, :rate_limited, wait_ms)
        Process.sleep(wait_ms)
        execute_with_retry(fun, max_retries, base_delay, attempt + 1, opts)

      {:error, %{"error_code" => code}} when code in [401, 403] ->
        Logger.error("Telegram auth error (#{code}): token invalid or unauthorized")
        {:error, {:fatal, :unauthorized}}

      {:error, %{"error_code" => 400} = error} ->
        Logger.warning("Telegram bad request: #{inspect(error)}")
        {:error, {:fatal, :bad_request, error}}

      {:error, %{"error_code" => 409}} ->
        Logger.error("Telegram 409: webhook conflict or duplicate bot instance")
        {:error, {:conflict, :duplicate_instance}}

      {:error, %{"error_code" => code} = error} when code >= 500 and attempt < max_retries ->
        delay = calculate_backoff(base_delay, attempt)
        Logger.warning("Telegram server error #{code}, retrying in #{delay}ms (attempt #{attempt + 1}/#{max_retries})")
        notify_retry(opts, attempt, :transient, delay)
        Process.sleep(delay)
        execute_with_retry(fun, max_retries, base_delay, attempt + 1, opts)

      {:error, :timeout} when attempt < max_retries ->
        delay = calculate_backoff(base_delay, attempt)
        Logger.warning("Telegram request timeout, retrying in #{delay}ms")
        notify_retry(opts, attempt, :timeout, delay)
        Process.sleep(delay)
        execute_with_retry(fun, max_retries, base_delay, attempt + 1, opts)

      {:error, :econnrefused} when attempt < max_retries ->
        delay = calculate_backoff(base_delay, attempt)
        Logger.warning("Telegram connection refused, retrying in #{delay}ms")
        notify_retry(opts, attempt, :connection, delay)
        Process.sleep(delay)
        execute_with_retry(fun, max_retries, base_delay, attempt + 1, opts)

      {:error, reason} ->
        if attempt >= max_retries do
          Logger.error("Telegram request failed after #{max_retries} retries: #{inspect(reason)}")
          {:error, {:max_retries_exceeded, reason}}
        else
          {:error, reason}
        end
    end
  end

  @doc """
  Classifies a Telegram API error into categories.
  """
  def classify_error(%{"error_code" => code}) when code in [401, 403], do: :fatal
  def classify_error(%{"error_code" => 400}), do: :bad_request
  def classify_error(%{"error_code" => 409}), do: :conflict
  def classify_error(%{"error_code" => 429}), do: :rate_limited
  def classify_error(%{"error_code" => code}) when code >= 500, do: :transient
  def classify_error(_), do: :unknown

  @doc """
  Extracts a human-readable error message from Telegram API error.
  """
  def format_error(%{"error_code" => code, "description" => desc}) do
    "[#{code}] #{desc}"
  end
  def format_error(%{"description" => desc}), do: desc
  def format_error(:timeout), do: "Request timed out"
  def format_error(:econnrefused), do: "Connection refused"
  def format_error(reason), do: inspect(reason)

  # Private

  defp calculate_backoff(base_delay, attempt) do
    delay = min(base_delay * :math.pow(2, attempt) |> round(), @max_delay_ms)
    jitter = :rand.uniform(delay) |> div(4)
    delay + jitter
  end

  defp notify_retry(opts, attempt, reason, delay) do
    case Keyword.get(opts, :on_retry) do
      callback when is_function(callback, 3) ->
        callback.(attempt, reason, delay)
      _ ->
        :ok
    end
  end
end
