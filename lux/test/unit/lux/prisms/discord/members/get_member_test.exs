defmodule Lux.Prisms.Discord.Members.GetMemberTest do
  @moduledoc """
  Test suite for the GetMember module.
  These tests verify the prism's ability to:
  - Retrieve member information from Discord
  - Handle Discord API errors appropriately
  """

  use UnitAPICase, async: true
  alias Lux.Prisms.Discord.Members.GetMember

  @guild_id "123456789012345678"
  @user_id "987654321098765432"
  @agent_ctx %{agent: %{name: "TestAgent"}}

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  describe "handler/2" do
    test "successfully retrieves a member" do
      Req.Test.expect(DiscordClientMock, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/api/v10/guilds/#{@guild_id}/members/#{@user_id}"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bot test-discord-token"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{
          "user" => %{"id" => @user_id, "username" => "cooluser"},
          "nick" => "Cool Nick",
          "roles" => ["111111111111111111"]
        }))
      end)

      assert {:ok, %{
        retrieved: true,
        user_id: @user_id,
        username: "cooluser",
        nick: "Cool Nick",
        roles: ["111111111111111111"]
      }} = GetMember.handler(
        %{guild_id: @guild_id, user_id: @user_id, plug: {Req.Test, DiscordClientMock}},
        @agent_ctx
      )
    end

    test "handles Discord API error" do
      Req.Test.expect(DiscordClientMock, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/api/v10/guilds/#{@guild_id}/members/#{@user_id}"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(404, Jason.encode!(%{
          "message" => "Unknown Member"
        }))
      end)

      assert {:error, {404, "Unknown Member"}} = GetMember.handler(
        %{guild_id: @guild_id, user_id: @user_id, plug: {Req.Test, DiscordClientMock}},
        @agent_ctx
      )
    end

    test "handles missing user_id" do
      assert {:error, "Missing or invalid user_id"} = GetMember.handler(
        %{guild_id: @guild_id, plug: {Req.Test, DiscordClientMock}},
        @agent_ctx
      )
    end
  end
end
