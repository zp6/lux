defmodule Lux.Auth.Web3.Audit do
  @moduledoc """
  Audit logging for Web3 authentication events.

  Tracks authentication successes, failures, session lifecycle events,
  and provides a query interface for audit trails.

  All events are stored in an ETS table with timestamps and structured metadata.

  ## Event Types

    * `:auth_success` - Successful authentication
    * `:auth_failure` - Failed authentication attempt
    * `:session_created` - New session created
    * `:session_refreshed` - Session refreshed
    * `:session_revoked` - Session explicitly revoked
    * `:session_expired` - Session expired naturally
    * `:permission_denied` - Permission check failed

  ## Usage

      # Events are logged automatically by the auth flow
      # Query recent events:
      events = Lux.Auth.Web3.Audit.list_events(limit: 10)

      # Query events for an address:
      events = Lux.Auth.Web3.Audit.events_for_address("0xabc...", limit: 5)

      # Check rate limiting:
      :ok = Lux.Auth.Web3.Audit.check_rate_limit("0xabc...")
  """

  @type event_type ::
          :auth_success
          | :auth_failure
          | :session_created
          | :session_refreshed
          | :session_revoked
          | :session_expired
          | :permission_denied

  @type audit_event :: %{
          id: String.t(),
          type: event_type(),
          timestamp: non_neg_integer(),
          metadata: map()
        }

  @max_failed_attempts 5
  @rate_limit_window_seconds 300

  @doc """
  Logs an audit event.

  Stores the event with a unique ID, timestamp, and provided metadata.
  """
  @spec log_event(event_type(), map()) :: :ok
  def log_event(type, metadata) when is_atom(type) and is_map(metadata) do
    ensure_audit_table()

    event = %{
      id: generate_event_id(),
      type: type,
      timestamp: System.system_time(:millisecond),
      metadata: metadata
    }

    address = Map.get(metadata, :address, "unknown")
    :ets.insert(:web3_audit, {event.id, event})
    :ets.insert(:web3_audit_by_address, {normalize_address(address), event.id, event.timestamp})

    :ok
  end

  @doc """
  Lists recent audit events, ordered by timestamp descending.

  ## Options

    * `:limit` - Maximum number of events to return (default: 50)
    * `:type` - Filter by event type
  """
  @spec list_events(keyword()) :: [audit_event()]
  def list_events(opts \\ []) do
    ensure_audit_table()
    limit = Keyword.get(opts, :limit, 50)
    type_filter = Keyword.get(opts, :type)

    :ets.tab2list(:web3_audit)
    |> Enum.map(fn {_id, event} -> event end)
    |> maybe_filter_by_type(type_filter)
    |> Enum.sort_by(& &1.timestamp, :desc)
    |> Enum.take(limit)
  end

  @doc """
  Returns audit events for a specific address.

  Events are returned in reverse chronological order.
  """
  @spec events_for_address(String.t(), keyword()) :: [audit_event()]
  def events_for_address(address, opts \\ []) do
    ensure_audit_table()
    limit = Keyword.get(opts, :limit, 50)
    normalized = normalize_address(address)

    :ets.lookup(:web3_audit_by_address, normalized)
    |> Enum.sort_by(fn {_addr, _id, ts} -> ts end, :desc)
    |> Enum.take(limit)
    |> Enum.map(fn {_addr, id, _ts} ->
      case :ets.lookup(:web3_audit, id) do
        [{^id, event}] -> event
        [] -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Checks if an address has exceeded the failed authentication rate limit.

  Returns `:ok` if under the limit, `{:error, :rate_limited}` if exceeded.
  The rate limit window is #{@rate_limit_window_seconds} seconds with a
  maximum of #{@max_failed_attempts} failed attempts.
  """
  @spec check_rate_limit(String.t()) :: :ok | {:error, :rate_limited}
  def check_rate_limit(address) do
    ensure_audit_table()
    normalized = normalize_address(address)
    window_start = System.system_time(:millisecond) - @rate_limit_window_seconds * 1000

    failed_count =
      events_for_address(address, limit: @max_failed_attempts + 1)
      |> Enum.filter(fn event -> event.type == :auth_failure end)
      |> Enum.filter(fn event -> event.timestamp > window_start end)
      |> length()

    if failed_count >= @max_failed_attempts do
      {:error, :rate_limited}
    else
      :ok
    end
  end

  @doc """
  Returns the count of failed authentication attempts for an address
  within the rate limit window.
  """
  @spec failed_attempt_count(String.t()) :: non_neg_integer()
  def failed_attempt_count(address) do
    ensure_audit_table()
    window_start = System.system_time(:millisecond) - @rate_limit_window_seconds * 1000

    events_for_address(address, limit: 100)
    |> Enum.filter(fn event -> event.type == :auth_failure end)
    |> Enum.filter(fn event -> event.timestamp > window_start end)
    |> length()
  end

  @doc """
  Clears all audit data. Primarily for testing.
  """
  @spec reset!() :: :ok
  def reset! do
    for table <- [:web3_audit, :web3_audit_by_address] do
      case :ets.whereis(table) do
        :undefined -> :ok
        _ref -> :ets.delete(table)
      end
    end

    :ok
  end

  # --- Private Helpers ---

  defp ensure_audit_table do
    for {table, opts} <- [
          {:web3_audit, [:set, :public, :named_table]},
          {:web3_audit_by_address, [:bag, :public, :named_table]}
        ] do
      case :ets.whereis(table) do
        :undefined -> :ets.new(table, opts)
        _ref -> :ok
      end
    end
  end

  defp generate_event_id do
    Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp normalize_address(address), do: String.downcase(address)

  defp maybe_filter_by_type(events, nil), do: events
  defp maybe_filter_by_type(events, type), do: Enum.filter(events, &(&1.type == type))
end
