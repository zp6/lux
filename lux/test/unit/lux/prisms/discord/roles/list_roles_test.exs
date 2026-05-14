defmodule Lux.Prisms.Discord.Roles.ListRolesTest do
  @moduledoc """
  Test suite for the ListRoles module.
  These tests verify the prism's ability to:
  - List roles from a Discord guild
  - Handle Discord API errors appropriately
  """

  use UnitAPICase, async: true
  alias Lux.Prisms.Discord.Roles.ListRoles

  @guild_id "123456789012345678"
  @agent_ctx %{agent: %{name: "TestAgent"}}

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  describe "handler/2" do
    test "successfully lists roles" do
      Req.Test.expect(DiscordClientMock, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/api/v10/guilds/#{@guild_id}/roles"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bot test-discord-token"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!([
          %{"id" => @guild_id, "name" => "@everyone", "color" => 0},
          %{"id" => "222222222222222222", "name" => "Admin", "color" => 16711669}
        ]))
      end)

      assert {:ok, %{
        retrieved: true,
        roles: [
          %{id: @guild_id, name: "@everyone", color: 0},
          %{id: "222222222222222222", name: "Admin", color: 16711669}
        ],
        count: 2
      }} = ListRoles.handler(
        %{guild_id: @guild_id, plug: {Req.Test, DiscordClientMock}},
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

      assert {:error, {403, "Missing Permissions"}} = ListRoles.handler(
        %{guild_id: @guild_id, plug: {Req.Test, DiscordClientMock}},
        @agent_ctx
      )
    end
  end
end
