defmodule Lux.Integrations.Telegram.SupervisorTest do
  use ExUnit.Case, async: false

  alias Lux.Integrations.Telegram.Supervisor

  test "starts the supervision tree" do
    name = :"telegram_sup_test_#{System.unique_integer([:positive])}"
    {:ok, pid} = Supervisor.start_link(name: name)

    children = Supervisor.which_children(name)
    assert length(children) == 2

    # Verify both children are running
    child_ids = Enum.map(children, fn {id, _, _, _} -> id end)
    assert Lux.Integrations.Telegram.Analytics in child_ids
    assert Lux.Integrations.Telegram.Monitor in child_ids

    # Cleanup
    Supervisor.stop(pid)
  end
end
