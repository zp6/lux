defmodule Lux.Prisms.Discord.Roles.AddRoleTest do
  @moduledoc """
  Test suite for the AddRole module.
  These tests verify the prism's ability to:
  - Add a role to a Discord guild member
  - Handle Discord API errors appropriately
  """

  use UnitAPICase, async: true
  alias Lux.Prisms.Discord.Roles.AddRole

  @guild_id "123456789012345678"
  @user_id "987654321098765432"
  @role_id "111111111111111111"
  @agent_ctx %{agent: %{name: "TestAgent"}}

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  describe "handler/2" do
    test "successfully adds a role" do
      Req.Test.expect(DiscordClientMock, fn conn ->
        assert conn.method == "PUT"
        assert conn.request_path == "/api/v10/guilds/#{@guild_id}/members/#{@user_id}/roles/#{@role_id}"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bot test-discord-token"]

        conn
        |> Plug.Conn.send_resp(204, "")
      end)

      assert {:ok, %{
        assigned: true,
        user_id: @user_id,
        role_id: @role_id,
        guild_id: @guild_id
      }} = AddRole.handler(
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

      assert {:error, {403, "Missing Permissions"}} = AddRole.handler(
        %{guild_id: @guild_id, user_id: @user_id, role_id: @role_id, plug: {Req.Test, DiscordClientMock}},
        @agent_ctx
      )
    end

    test "handles missing role_id" do
      assert {:error, "Missing or invalid role_id"} = AddRole.handler(
        %{guild_id: @guild_id, user_id: @user_id, plug: {Req.Test, DiscordClientMock}},
        @agent_ctx
      )
    end
  end
end
