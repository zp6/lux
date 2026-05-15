defmodule Lux.Prisms.Discord.Messages.BulkDeleteMessagesTest do
  use ExUnit.Case, async: true
  alias Lux.Prisms.Discord.Messages.BulkDeleteMessages

  describe "handler/2" do
    test "requires channel_id" do
      assert {:error, msg} = BulkDeleteMessages.handler(%{message_ids: ["1", "2"]}, %{name: "Test"})
      assert msg =~ "channel_id"
    end

    test "requires at least 2 message IDs" do
      assert {:error, msg} = BulkDeleteMessages.handler(%{channel_id: "123", message_ids: ["1"]}, %{name: "Test"})
      assert msg =~ "2"
    end

    test "rejects more than 100 message IDs" do
      ids = Enum.map(1..101, &Integer.to_string/1)
      assert {:error, msg} = BulkDeleteMessages.handler(%{channel_id: "123", message_ids: ids}, %{name: "Test"})
      assert msg =~ "100"
    end
  end
end

defmodule Lux.Prisms.Discord.Channels.UpdateChannelTest do
  use ExUnit.Case, async: true
  alias Lux.Prisms.Discord.Channels.UpdateChannel

  describe "handler/2" do
    test "requires channel_id" do
      assert {:error, msg} = UpdateChannel.handler(%{name: "test"}, %{name: "Test"})
      assert msg =~ "channel_id"
    end

    test "requires at least one update field" do
      assert {:error, msg} = UpdateChannel.handler(%{channel_id: "123"}, %{name: "Test"})
      assert msg =~ "No fields to update"
    end
  end
end

defmodule Lux.Prisms.Discord.Moderation.TimeoutUserTest do
  use ExUnit.Case, async: true
  alias Lux.Prisms.Discord.Moderation.TimeoutUser

  describe "handler/2" do
    test "requires guild_id and user_id" do
      assert {:error, _} = TimeoutUser.handler(%{guild_id: "123"}, %{name: "Test"})
      assert {:error, _} = TimeoutUser.handler(%{user_id: "456"}, %{name: "Test"})
    end
  end
end

defmodule Lux.Prisms.Discord.Moderation.BanUserTest do
  use ExUnit.Case, async: true
  alias Lux.Prisms.Discord.Moderation.BanUser

  describe "handler/2" do
    test "requires guild_id and user_id" do
      assert {:error, msg} = BanUser.handler(%{}, %{name: "Test"})
      assert msg =~ "guild_id"
    end
  end
end

defmodule Lux.Prisms.Discord.Moderation.WarningSystemTest do
  use ExUnit.Case, async: true
  alias Lux.Prisms.Discord.Moderation.WarningSystem

  describe "handler/2" do
    test "requires action, guild_id, and user_id" do
      assert {:error, _} = WarningSystem.handler(%{action: "warn"}, %{name: "Test"})
    end

    test "remove action requires warning_id" do
      assert {:error, msg} = WarningSystem.handler(%{action: "remove", guild_id: "123", user_id: "456"}, %{name: "Test"})
      assert msg =~ "warning_id"
    end

    test "rejects unsupported actions" do
      assert {:error, msg} = WarningSystem.handler(%{action: "invalid", guild_id: "123", user_id: "456"}, %{name: "Test"})
      assert msg =~ "Unsupported action"
    end
  end
end

defmodule Lux.Prisms.Discord.Events.ManageGuildEventTest do
  use ExUnit.Case, async: true
  alias Lux.Prisms.Discord.Events.ManageGuildEvent

  describe "handler/2" do
    test "requires guild_id" do
      assert {:error, msg} = ManageGuildEvent.handler(%{action: "list"}, %{name: "Test"})
      assert msg =~ "guild_id"
    end

    test "create requires name and start_time" do
      assert {:error, msg} = ManageGuildEvent.handler(%{action: "create", guild_id: "123"}, %{name: "Test"})
      assert msg =~ "name"
    end

    test "update requires event_id" do
      assert {:error, msg} = ManageGuildEvent.handler(%{action: "update", guild_id: "123", name: "New"}, %{name: "Test"})
      assert msg =~ "event_id"
    end
  end
end
