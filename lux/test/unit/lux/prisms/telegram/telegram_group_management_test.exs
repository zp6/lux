defmodule Lux.Prisms.Telegram.Management.ManageChatMemberTest do
  use ExUnit.Case, async: true
  alias Lux.Prisms.Telegram.Management.ManageChatMember

  describe "handler/2" do
    test "requires action and chat_id" do
      assert {:error, _} = ManageChatMember.handler(%{}, %{name: "Test"})
      assert {:error, msg} = ManageChatMember.handler(%{action: "promote"}, %{name: "Test"})
      assert msg =~ "chat_id"
    end

    test "promote requires user_id" do
      assert {:error, msg} = ManageChatMember.handler(%{action: "promote", chat_id: -100123}, %{name: "Test"})
      assert msg =~ "user_id"
    end

    test "ban requires user_id" do
      assert {:error, msg} = ManageChatMember.handler(%{action: "ban", chat_id: -100123}, %{name: "Test"})
      assert msg =~ "user_id"
    end

    test "get_info requires user_id" do
      assert {:error, msg} = ManageChatMember.handler(%{action: "get_info", chat_id: -100123}, %{name: "Test"})
      assert msg =~ "user_id"
    end

    test "get_admins does not require user_id" do
      result = ManageChatMember.handler(%{action: "get_admins", chat_id: -100123}, %{name: "Test"})
      # Will fail on API but shouldn't fail on validation
      case result do
        {:ok, _} -> :ok
        {:error, msg} -> refute msg =~ "user_id"
      end
    end

    test "rejects unsupported actions" do
      assert {:error, msg} = ManageChatMember.handler(%{action: "invalid", chat_id: -100123}, %{name: "Test"})
      assert msg =~ "Unsupported action"
    end
  end
end

defmodule Lux.Prisms.Telegram.ManageChatSettingsTest do
  use ExUnit.Case, async: true
  alias Lux.Prisms.Telegram.ManageChatSettings

  describe "handler/2" do
    test "requires action and chat_id" do
      assert {:error, _} = ManageChatSettings.handler(%{action: "set_title"}, %{name: "Test"})
    end

    test "set_title requires title" do
      assert {:error, msg} = ManageChatSettings.handler(%{action: "set_title", chat_id: -100123}, %{name: "Test"})
      assert msg =~ "title"
    end

    test "set_permissions requires permissions" do
      assert {:error, msg} = ManageChatSettings.handler(%{action: "set_permissions", chat_id: -100123}, %{name: "Test"})
      assert msg =~ "permissions"
    end

    test "revoke_invite_link requires invite_link" do
      assert {:error, msg} = ManageChatSettings.handler(%{action: "revoke_invite_link", chat_id: -100123}, %{name: "Test"})
      assert msg =~ "invite_link"
    end

    test "approve_join_request requires user_id" do
      assert {:error, msg} = ManageChatSettings.handler(%{action: "approve_join_request", chat_id: -100123}, %{name: "Test"})
      assert msg =~ "user_id"
    end
  end
end

defmodule Lux.Prisms.Telegram.Moderation.ContentModeratorTest do
  use ExUnit.Case, async: true
  alias Lux.Prisms.Telegram.Moderation.ContentModerator

  describe "handler/2" do
    test "check_message with no violations" do
      {:ok, result} = ContentModerator.handler(%{
        action: "check_message",
        chat_id: -100123,
        message_text: "Hello world",
        user_id: 123
      }, %{name: "Test"})

      assert result.allowed == true
      assert result.violations == []
    end

    test "check_message detects blocked words" do
      {:ok, result} = ContentModerator.handler(%{
        action: "check_message",
        chat_id: -100123,
        message_text: "This is spam content",
        user_id: 123,
        blocked_words: ["spam", "bad"]
      }, %{name: "Test"})

      assert result.allowed == false
      assert length(result.violations) > 0
    end

    test "check_message detects links when block_links is true" do
      {:ok, result} = ContentModerator.handler(%{
        action: "check_message",
        chat_id: -100123,
        message_text: "Check out https://example.com",
        user_id: 123,
        block_links: true
      }, %{name: "Test"})

      assert result.allowed == false
    end

    test "check_message allows links when block_links is false" do
      {:ok, result} = ContentModerator.handler(%{
        action: "check_message",
        chat_id: -100123,
        message_text: "Check out https://example.com",
        user_id: 123,
        block_links: false
      }, %{name: "Test"})

      assert result.allowed == true
    end

    test "set_filter_config returns success" do
      {:ok, result} = ContentModerator.handler(%{
        action: "set_filter_config",
        chat_id: -100123,
        blocked_words: ["spam"],
        block_links: true
      }, %{name: "Test"})

      assert result.success == true
      assert result.details.blocked_words == ["spam"]
    end
  end
end

defmodule Lux.Prisms.Telegram.Management.ManageChannelPostsTest do
  use ExUnit.Case, async: true
  alias Lux.Prisms.Telegram.Management.ManageChannelPosts

  describe "handler/2" do
    test "post requires text" do
      assert {:error, msg} = ManageChannelPosts.handler(%{action: "post", chat_id: -100123}, %{name: "Test"})
      assert msg =~ "text"
    end

    test "edit requires text and message_id" do
      assert {:error, msg} = ManageChannelPosts.handler(%{action: "edit", chat_id: -100123}, %{name: "Test"})
      assert msg =~ "text"
    end

    test "delete requires message_id" do
      assert {:error, msg} = ManageChannelPosts.handler(%{action: "delete", chat_id: -100123}, %{name: "Test"})
      assert msg =~ "message_id"
    end

    test "forward requires from_chat_id, to_chat_id, and message_id" do
      assert {:error, msg} = ManageChannelPosts.handler(%{action: "forward", chat_id: -100123}, %{name: "Test"})
      assert msg =~ "from_chat_id"
    end

    test "copy requires from_chat_id, to_chat_id, and message_id" do
      assert {:error, msg} = ManageChannelPosts.handler(%{action: "copy", chat_id: -100123}, %{name: "Test"})
      assert msg =~ "from_chat_id"
    end
  end
end
