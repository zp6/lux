defmodule Lux.Web3.EventMonitor.Webhook do
  @moduledoc """
  Webhook delivery system for smart contract event notifications.

  Provides HTTP POST delivery with configurable retry logic, HMAC-SHA256
  signature headers for verification, and a dead letter queue for failed
  deliveries.

  ## Configuration

      config :lux, Lux.Web3.EventMonitor.Webhook,
        secret: System.get_env("WEBHOOK_SECRET"),
        max_retries: 3,
        retry_backoff_ms: 1_000,
        timeout_ms: 10_000,
        dead_letter_max: 1000

  ## Usage

      {:ok, pid} = Webhook.start_link([])

      {:ok, wh_id} = Webhook.register(%{
        url: "https://example.com/webhook",
        events: ["Transfer", "Approval"],
        contract_address: "0x..."
      })

      :ok = Webhook.deliver(decoded_event)

      {:ok, failed} = Webhook.dead_letter_queue()
      :ok = Webhook.retry_dead_letter()
  """

  use GenServer

  require Logger

  @type webhook :: %{
    id: String.t(),
    url: String.t(),
    events: [String.t()],
    contract_address: String.t() | nil,
    headers: map(),
    created_at: DateTime.t(),
    delivery_count: non_neg_integer(),
    last_delivery_at: DateTime.t() | nil
  }

  @type delivery :: %{
    id: String.t(),
    webhook_id: String.t(),
    url: String.t(),
    payload: map(),
    signature: String.t(),
    status: :pending | :delivered | :failed,
    attempts: non_neg_integer(),
    last_attempt_at: DateTime.t() | nil,
    last_error: String.t() | nil,
    created_at: DateTime.t()
  }

  # Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec register(map()) :: {:ok, String.t()} | {:error, term()}
  def register(attrs) do
    GenServer.call(__MODULE__, {:register, attrs})
  end

  @spec unregister(String.t()) :: :ok | {:error, :not_found}
  def unregister(webhook_id) do
    GenServer.call(__MODULE__, {:unregister, webhook_id})
  end

  @spec list_webhooks() :: {:ok, [webhook()]}
  def list_webhooks do
    GenServer.call(__MODULE__, :list_webhooks)
  end

  @doc """
  Delivers an event to all matching webhook endpoints.
  Delivery is asynchronous with retry on failure.
  """
  @spec deliver(map()) :: :ok
  def deliver(event) do
    GenServer.cast(__MODULE__, {:deliver, event})
  end

  @spec dead_letter_queue() :: {:ok, [delivery()]}
  def dead_letter_queue do
    GenServer.call(__MODULE__, :dead_letter_queue)
  end

  @spec retry_dead_letter() :: :ok
  def retry_dead_letter do
    GenServer.cast(__MODULE__, :retry_dead_letter)
  end

  @spec purge_dead_letter() :: :ok
  def purge_dead_letter do
    GenServer.call(__MODULE__, :purge_dead_letter)
  end

  @doc """
  Generates an HMAC-SHA256 signature for a payload using the configured secret.
  """
  @spec sign_payload(String.t()) :: String.t()
  def sign_payload(payload) do
    secret = get_config(:secret, "")

    if secret != "" do
      :crypto.mac(:hmac, :sha256, secret, payload)
      |> Base.encode16(case: :lower)
    else
      ""
    end
  end

  # GenServer Callbacks

  @impl true
  def init(_opts) do
    webhooks = load_persisted_webhooks()

    state = %{
      webhooks: webhooks,
      dead_letter: [],
      dead_letter_max: get_config(:dead_letter_max, 1000)
    }

    {:ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    persist_webhooks(state.webhooks)
    :ok
  end

  @impl true
  def handle_call({:register, attrs}, _from, state) do
    url = attrs[:url] || attrs["url"]

    if is_nil(url) or url == "" do
      {:reply, {:error, :url_required}, state}
    else
      webhook_id = generate_id()

      webhook = %{
        id: webhook_id,
        url: url,
        events: attrs[:events] || attrs["events"] || [],
        contract_address: attrs[:contract_address] || attrs["contract_address"],
        headers: attrs[:headers] || attrs["headers"] || %{},
        created_at: DateTime.utc_now(),
        delivery_count: 0,
        last_delivery_at: nil
      }

      Logger.info("Webhook registered: #{webhook_id} -> #{url}")
      {:reply, {:ok, webhook_id}, %{state | webhooks: Map.put(state.webhooks, webhook_id, webhook)}}
    end
  end

  @impl true
  def handle_call({:unregister, webhook_id}, _from, state) do
    case Map.pop(state.webhooks, webhook_id) do
      {nil, _} -> {:reply, {:error, :not_found}, state}
      {_wh, remaining} ->
        Logger.info("Webhook unregistered: #{webhook_id}")
        {:reply, :ok, %{state | webhooks: remaining}}
    end
  end

  @impl true
  def handle_call(:list_webhooks, _from, state) do
    {:reply, {:ok, Map.values(state.webhooks)}, state}
  end

  @impl true
  def handle_call(:dead_letter_queue, _from, state) do
    {:reply, {:ok, state.dead_letter}, state}
  end

  @impl true
  def handle_call(:purge_dead_letter, _from, state) do
    Logger.info("Purged dead letter queue (#{length(state.dead_letter)} items)")
    {:reply, :ok, %{state | dead_letter: []}}
  end

  @impl true
  def handle_cast({:deliver, event}, state) do
    event_name = event[:name] || event["name"]
    contract = event[:contract_address] || event["contract_address"]

    matching_webhooks =
      state.webhooks
      |> Map.values()
      |> Enum.filter(fn wh ->
        event_match = wh.events == [] or event_name in wh.events
        contract_match = is_nil(wh.contract_address) or
                         String.downcase(wh.contract_address || "") == String.downcase(contract || "")
        event_match and contract_match
      end)

    new_state =
      Enum.reduce(matching_webhooks, state, fn webhook, acc_state ->
        deliver_webhook(webhook, event, acc_state)
      end)

    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:retry_dead_letter, state) do
    {remaining} =
      Enum.reduce(state.dead_letter, {[]}, fn delivery, {rem} ->
        case do_http_post(delivery) do
          :ok ->
            Logger.info("Dead letter retry succeeded: #{delivery.id}")
            {rem}

          {:error, _reason} ->
            new_attempts = delivery.attempts + 1
            max_retries = get_config(:max_retries, 3)

            if new_attempts >= max_retries do
              Logger.error("Dead letter delivery permanently failed after #{new_attempts} attempts: #{delivery.id}")
              {rem}
            else
              updated = %{delivery | attempts: new_attempts, last_attempt_at: DateTime.utc_now()}
              {[updated | rem]}
            end
        end
      end)

    {:noreply, %{state | dead_letter: remaining}}
  end

  # Private functions

  defp deliver_webhook(webhook, event, state) do
    payload = build_payload(event)
    signature = sign_payload(payload)

    delivery = %{
      id: generate_id(),
      webhook_id: webhook.id,
      url: webhook.url,
      payload: event,
      signature: signature,
      status: :pending,
      attempts: 0,
      last_attempt_at: nil,
      last_error: nil,
      created_at: DateTime.utc_now()
    }

    max_retries = get_config(:max_retries, 3)

    case attempt_delivery(delivery, webhook, payload, signature, max_retries) do
      :ok ->
        updated_wh = %{webhook |
          delivery_count: webhook.delivery_count + 1,
          last_delivery_at: DateTime.utc_now()
        }
        %{state | webhooks: Map.put(state.webhooks, webhook.id, updated_wh)}

      {:error, :scheduled_retry} ->
        state

      {:error, _reason} ->
        new_dl = [delivery | state.dead_letter] |> Enum.take(state.dead_letter_max)
        Logger.warning("Webhook delivery failed, added to dead letter queue: #{delivery.id} -> #{webhook.url}")
        %{state | dead_letter: new_dl}
    end
  end

  defp attempt_delivery(delivery, webhook, payload, signature, max_retries) do
    case do_http_post_with_payload(webhook.url, payload, signature, webhook.headers) do
      :ok -> :ok
      {:error, reason} ->
        schedule_retry(delivery, webhook, payload, signature, max_retries, 0, reason)
    end
  end

  defp schedule_retry(delivery, webhook, payload, signature, max_retries, attempt, _reason) when attempt < max_retries do
    backoff = get_config(:retry_backoff_ms, 1_000) * :math.pow(2, attempt) |> round()
    Process.send_after(self(), {:webhook_retry, attempt + 1, delivery, webhook, payload, signature, max_retries}, backoff)
    {:error, :scheduled_retry}
  end

  defp schedule_retry(_delivery, _webhook, _payload, _signature, _max_retries, attempt, _reason) do
    {:error, :max_retries_exceeded}
  end

  @impl true
  def handle_info({:webhook_retry, attempt, delivery, webhook, payload, signature, max_retries}, state) do
    case do_http_post_with_payload(webhook.url, payload, signature, webhook.headers) do
      :ok ->
        updated_wh = %{webhook | delivery_count: webhook.delivery_count + 1, last_delivery_at: DateTime.utc_now()}
        {:noreply, %{state | webhooks: Map.put(state.webhooks, webhook.id, updated_wh)}}

      {:error, reason} ->
        case schedule_retry(delivery, webhook, payload, signature, max_retries, attempt, reason) do
          {:error, :max_retries_exceeded} ->
            new_dl = [delivery | state.dead_letter] |> Enum.take(state.dead_letter_max)
            Logger.warning("Webhook delivery permanently failed after #{attempt + 1} attempts: #{delivery.id} -> #{webhook.url}")
            {:noreply, %{state | dead_letter: new_dl}}

          {:error, :scheduled_retry} ->
            {:noreply, state}
        end
    end
  end

  defp do_http_post_with_payload(url, payload, signature, extra_headers) do
    headers = [
      {"Content-Type", "application/json"},
      {"X-Lux-Signature", signature},
      {"X-Lux-Timestamp", DateTime.utc_now() |> DateTime.to_iso8601()}
    ]

    custom_headers =
      (extra_headers || %{})
      |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)

    timeout = get_config(:timeout_ms, 10_000)

    case Req.post(url,
      json: payload,
      headers: headers ++ custom_headers,
      receive_timeout: timeout
    ) do
      {:ok, %{status: code}} when code >= 200 and code < 300 -> :ok
      {:ok, %{status: code}} -> {:error, {:http_error, code}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_http_post(delivery) do
    payload = build_payload(delivery.payload)

    headers = [
      {"Content-Type", "application/json"},
      {"X-Lux-Signature", delivery.signature},
      {"X-Lux-Timestamp", DateTime.utc_now() |> DateTime.to_iso8601()},
      {"X-Lux-Delivery-Id", delivery.id}
    ]

    timeout = get_config(:timeout_ms, 10_000)

    case Req.post(delivery.url,
      json: payload,
      headers: headers,
      receive_timeout: timeout
    ) do
      {:ok, %{status: code}} when code >= 200 and code < 300 -> :ok
      {:ok, %{status: code}} -> {:error, {:http_error, code}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_payload(event) do
    event
    |> Enum.map(fn
      {_k, %DateTime{} = dt} -> {:__datetime__, DateTime.to_iso8601(dt)}
      {k, v} -> {k, v}
    end)
    |> Jason.encode!()
  end

  defp get_config(key, default \\ nil) do
    :lux
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  # Persistence

  defp persist_webhooks(webhooks) do
    path = webhook_persistence_path()

    try do
      data =
        webhooks
        |> Map.values()
        |> Enum.map(fn wh ->
          %{
            "id" => wh.id,
            "url" => wh.url,
            "events" => wh.events,
            "contract_address" => wh.contract_address,
            "headers" => wh.headers,
            "created_at" => DateTime.to_iso8601(wh.created_at),
            "delivery_count" => wh.delivery_count
          }
        end)
        |> Jason.encode!()

      File.mkdir_p!(Path.dirname(path))
      File.write!(path, data)
    rescue
      e -> Logger.warning("Failed to persist webhooks: #{inspect(e)}")
    end
  end

  defp load_persisted_webhooks do
    path = webhook_persistence_path()

    if File.exists?(path) do
      try do
        data = File.read!(path)
        wh_list = Jason.decode!(data)

        wh_list
        |> Enum.map(fn wh ->
          created_at = case wh["created_at"] do
            nil -> DateTime.utc_now()
            iso ->
              case DateTime.from_iso8601(iso) do
                {:ok, dt, _} -> dt
                _ -> DateTime.utc_now()
              end
          end

          {wh["id"], %{
            id: wh["id"],
            url: wh["url"],
            events: wh["events"] || [],
            contract_address: wh["contract_address"],
            headers: (wh["headers"] || []) |> Map.new(),
            created_at: created_at,
            delivery_count: wh["delivery_count"] || 0,
            last_delivery_at: nil
          }}
        end)
        |> Map.new()
      rescue
        _ -> %{}
      end
    else
      %{}
    end
  end

  defp webhook_persistence_path do
    Application.app_dir(:lux, "priv/web3/event_monitor_webhooks.json")
  end
end
