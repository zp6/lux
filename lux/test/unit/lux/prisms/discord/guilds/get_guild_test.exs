defmodule Lux.Prisms.Discord.Guilds.GetGuildTest do
  @moduledoc """
  Test suite for the GetGuild module.
  These tests verify the prism's ability to:
  - Retrieve guild information from Discord
  - Handle Discord API errors appropriately
  """

  use UnitAPICase, async: true
  alias Lux.Prisms.Discord.Guilds.GetGuild

  @guild_id "123456789012345678"
  @agent_ctx %{agent: %{name: "TestAgent"}}

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  describe "handler/2" do
    test "successfully retrieves a guild" do
      Req.Test.expect(DiscordClientMock, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/api/v10/guilds/#{@guild_id}"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bot test-discord-token"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{
          "id" => @guild_id,
          "name" => "Test Server",
          "owner_id" => "987654321098765432",
          "member_count" => 42
        }))
      end)

      assert {:ok, %{
        retrieved: true,
        guild_id: @guild_id,
        name: "Test Server",
        owner_id: "987654321098765432",
        member_count: 42
      }} = GetGuild.handler(
        %{guild_id: @guild_id, plug: {Req.Test, DiscordClientMock}},
        @agent_ctx
      )
    end

    test "handles Discord API error" do
      Req.Test.expect(DiscordClientMock, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/api/v10/guilds/#{@guild_id}"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(404, Jason.encode!(%{
          "message" => "Unknown Guild"
        }))
      end)

      assert {:error, {404, "Unknown Guild"}} = GetGuild.handler(
        %{guild_id: @guild_id, plug: {Req.Test, DiscordClientMock}},
        @agent_ctx
      )
    end

    test "handles missing guild_id" do
      assert {:error, "Missing or invalid guild_id"} = GetGuild.handler(
        %{plug: {Req.Test, DiscordClientMock}},
        @agent_ctx
      )
    end
  end
end
