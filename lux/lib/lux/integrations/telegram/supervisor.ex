defmodule Lux.Integrations.Telegram.Supervisor do
  @moduledoc """
  Supervision tree for Telegram analytics and monitoring processes.

  Starts the following children in order:

  1. `Lux.Integrations.Telegram.Analytics` — ETS-backed metrics collection
  2. `Lux.Integrations.Telegram.Monitor`   — API call wrapper and health checks

  Both children use a `:permanent` restart strategy so they are automatically
  restarted on failure.

  ## Usage

  Add to your application's supervision tree:

      children = [
        {Lux.Integrations.Telegram.Supervisor, []}
      ]

  Or start manually:

      iex> {:ok, pid} = Lux.Integrations.Telegram.Supervisor.start_link([])
  """

  use Supervisor

  @doc """
  Starts the supervisor.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    children = [
      {Lux.Integrations.Telegram.Analytics, []},
      {Lux.Integrations.Telegram.Monitor, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
