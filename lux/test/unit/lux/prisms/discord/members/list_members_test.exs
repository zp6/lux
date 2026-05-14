defmodule Lux.Prisms.Discord.Members.ListMembersTest do
  @moduledoc """
  Test suite for the ListMembers module.
  These tests verify the prism's ability to:
  - List members from a Discord guild
  - Handle pagination parameters
  - Handle Discord API errors appropriately
  """

  use UnitAPICase, async: true
  alias Lux.Prisms.Discord.Members.ListMembers

  @guild_id "123456789012345678"
  @agent_ctx %{agent: %{name: "TestAgent"}}

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  describe "handler/2" do
    test "successfully lists members" do
      Req.Test.expect(DiscordClientMock, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/api/v10/guilds/#{@guild_id}/members"
        assert conn.query_string == "limit=2"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bot test-discord-token"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!([
          %{"user" => %{"id" => "111", "username" => "user1"}, "nick" => nil},
          %{"user" => %{"id" => "222", "username" => "user2"}, "nick" => "Nick"}
        ]))
      end)

      assert {:ok, %{
        retrieved: true,
        members: [
          %{user_id: "111", username: "user1", nick: nil},
          %{user_id: "222", username: "user2", nick: "Nick"}
        ],
        count: 2
      }} = ListMembers.handler(
        %{guild_id: @guild_id, limit: 2, plug: {Req.Test, DiscordClientMock}},
        @agent_ctx
      )
    end

    test "successfully lists members with pagination" do
      Req.Test.expect(DiscordClientMock, fn conn ->
        assert conn.query_string == "limit=5&after=999999999999999999"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!([
          %{"user" => %{"id" => "333", "username" => "user3"}, "nick" => nil}
        ]))
      end)

      assert {:ok, %{retrieved: true, count: 1}} = ListMembers.handler(
        %{guild_id: @guild_id, limit: 5, after: "999999999999999999", plug: {Req.Test, DiscordClientMock}},
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

      assert {:error, {403, "Missing Permissions"}} = ListMembers.handler(
        %{guild_id: @guild_id, plug: {Req.Test, DiscordClientMock}},
        @agent_ctx
      )
    end
  end
end
