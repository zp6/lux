defmodule Lux.Prisms.Discord.Roles.RemoveRoleTest do
  @moduledoc """
  Test suite for the RemoveRole module.
  These tests verify the prism's ability to:
  - Remove a role from a Discord guild member
  - Handle Discord API errors appropriately
  """

  use UnitAPICase, async: true
  alias Lux.Prisms.Discord.Roles.RemoveRole

  @guild_id "123456789012345678"
  @user_id "987654321098765432"
  @role_id "111111111111111111"
  @agent_ctx %{agent: %{name: "TestAgent"}}

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  describe "handler/2" do
    test "successfully removes a role" do
      Req.Test.expect(DiscordClientMock, fn conn ->
        assert conn.method == "DELETE"
        assert conn.request_path == "/api/v10/guilds/#{@guild_id}/members/#{@user_id}/roles/#{@role_id}"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bot test-discord-token"]

        conn
        |> Plug.Conn.send_resp(204, "")
      end)

      assert {:ok, %{
        removed: true,
        user_id: @user_id,
        role_id: @role_id,
        guild_id: @guild_id
      }} = RemoveRole.handler(
        %{guild_id: @guild_id, user_id: @user_id, role_id: @role_id, plug: {Req.Test, DiscordClientMock}},
        @agent_ctx
      )
    end

    test "handles Discord API error" do
      Req.Test.expect(DiscordClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(403, Jason.encode!(%{
          "message" => "Missing Permissions"
        }))
      end)

      assert {:error, {403, "Missing Permissions"}} = RemoveRole.handler(
        %{guild_id: @guild_id, user_id: @user_id, role_id: @role_id, plug: {Req.Test, DiscordClientMock}},
        @agent_ctx
      )
    end

    test "handles missing guild_id" do
      assert {:error, "Missing or invalid guild_id"} = RemoveRole.handler(
        %{user_id: @user_id, role_id: @role_id, plug: {Req.Test, DiscordClientMock}},
        @agent_ctx
      )
    end
  end
end
