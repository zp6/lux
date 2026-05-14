defmodule Lux.Auth.Web3Test do
  use UnitCase, async: false

  alias Lux.Auth.Web3
  alias Lux.Auth.Web3.Signature
  alias Lux.Auth.Web3.Session
  alias Lux.Auth.Web3.RBAC
  alias Lux.Auth.Web3.Audit

  @test_address "0x71C7656EC7ab88b098defB751B7401B5f6d8976F"
  @test_domain "example.com"

  setup do
    # Clean up ETS tables before each test
    for table <- [
          :web3_nonces,
          :web3_sessions,
          :web3_rbac,
          :web3_rbac_resources,
          :web3_rbac_gates,
          :web3_audit,
          :web3_audit_by_address
        ] do
      case :ets.whereis(table) do
        :undefined -> :ok
        _ref -> :ets.delete(table)
      end
    end

    :ok
  end

  describe "nonce generation" do
    test "generates a unique nonce" do
      {:ok, nonce1} = Web3.generate_nonce()
      {:ok, nonce2} = Web3.generate_nonce()

      assert is_binary(nonce1)
      assert is_binary(nonce2)
      assert byte_size(nonce1) == 32
      assert nonce1 != nonce2
    end

    test "validates a valid nonce" do
      {:ok, nonce} = Web3.generate_nonce()
      assert :ok = Web3.validate_nonce(nonce)
    end

    test "rejects an already-used nonce" do
      {:ok, nonce} = Web3.generate_nonce()
      :ok = Web3.validate_nonce(nonce)
      assert {:error, :invalid_nonce} = Web3.validate_nonce(nonce)
    end

    test "rejects an unknown nonce" do
      assert {:error, :invalid_nonce} = Web3.validate_nonce("nonexistent")
    end
  end

  describe "SIWE message construction" do
    test "builds a valid SIWE message" do
      message =
        Web3.build_siwe_message(%{
          domain: @test_domain,
          address: @test_address,
          statement: "Sign in to Example",
          nonce: "abc123",
          chain_id: 1
        })

      assert message =~ "example.com wants you to sign in"
      assert message =~ "Sign in to Example"
      assert message =~ "Nonce: abc123"
      assert message =~ "Chain ID: 1"
      assert message =~ "Version: 1"
      assert message =~ "Issued At:"
    end

    test "includes optional fields when provided" do
      message =
        Web3.build_siwe_message(%{
          domain: @test_domain,
          address: @test_address,
          statement: "Test",
          nonce: "test123",
          chain_id: 1,
          expiration_time: "2025-12-31T23:59:59Z",
          not_before: "2025-01-01T00:00:00Z",
          request_id: "req-001",
          resources: ["ipfs://QmExample", "https://example.com/resource"]
        })

      assert message =~ "Expiration Time: 2025-12-31T23:59:59Z"
      assert message =~ "Not Before: 2025-01-01T00:00:00Z"
      assert message =~ "Request ID: req-001"
      assert message =~ "Resource: ipfs://QmExample"
      assert message =~ "Resource: https://example.com/resource"
    end
  end

  describe "SIWE message parsing" do
    test "parses a built SIWE message" do
      original =
        Web3.build_siwe_message(%{
          domain: @test_domain,
          address: @test_address,
          statement: "Sign in to Example",
          nonce: "abc123",
          chain_id: 1
        })

      {:ok, parsed} = Web3.parse_siwe_message(original)

      assert parsed.domain == @test_domain
      assert parsed.nonce == "abc123"
      assert parsed.chain_id == 1
      assert parsed.statement == "Sign in to Example"
    end

    test "returns error for invalid message" do
      assert {:error, :invalid_message} = Web3.parse_siwe_message("not a valid message")
    end
  end

  describe "signature verification" do
    test "hash_message produces consistent keccak256 hash" do
      {:ok, hash1} = Signature.hash_message("hello world")
      {:ok, hash2} = Signature.hash_message("hello world")

      assert hash1 == hash2
      assert byte_size(hash1) == 32
    end

    test "different messages produce different hashes" do
      {:ok, hash1} = Signature.hash_message("hello")
      {:ok, hash2} = Signature.hash_message("world")

      assert hash1 != hash2
    end
  end

  describe "session management" do
    test "creates a session and validates it" do
      {:ok, session} =
        Session.create(%{
          address: @test_address,
          chain_id: 1,
          domain: @test_domain
        })

      assert session.address == String.downcase(@test_address)
      assert session.chain_id == 1
      assert session.domain == @test_domain
      assert is_binary(session.token)

      {:ok, validated} = Session.validate(session.token)
      assert validated.address == session.address
    end

    test "rejects an invalid token" do
      assert {:error, _} = Session.validate("invalid.token.here")
    end

    test "rejects a tampered token" do
      {:ok, session} =
        Session.create(%{
          address: @test_address,
          chain_id: 1,
          domain: @test_domain
        })

      tampered = String.replace(session.token, "a", "b")
      assert {:error, _} = Session.validate(tampered)
    end

    test "revokes a session" do
      {:ok, session} =
        Session.create(%{
          address: @test_address,
          chain_id: 1,
          domain: @test_domain
        })

      :ok = Session.revoke(session.token)
      assert {:error, :session_revoked} = Session.validate(session.token)
    end

    test "refreshes a valid session" do
      {:ok, session} =
        Session.create(%{
          address: @test_address,
          chain_id: 1,
          domain: @test_domain
        })

      {:ok, new_session} = Session.refresh(session.token)

      assert new_session.address == session.address
      assert new_session.token != session.token
      # Old token should be revoked
      assert {:error, :session_revoked} = Session.validate(session.token)
    end

    test "session with custom TTL" do
      {:ok, session} =
        Session.create(
          %{
            address: @test_address,
            chain_id: 1,
            domain: @test_domain
          },
          ttl: 60
        )

      # Session should be valid now
      assert {:ok, _} = Session.validate(session.token)
    end
  end

  describe "RBAC" do
    test "default role is viewer" do
      assert RBAC.get_role(@test_address) == :viewer
    end

    test "assigns and retrieves roles" do
      :ok = RBAC.assign_role(@test_address, :admin)
      assert RBAC.get_role(@test_address) == :admin
    end

    test "role permissions are correct" do
      assert :manage in RBAC.role_permissions(:admin)
      assert :delete in RBAC.role_permissions(:admin)
      assert :write in RBAC.role_permissions(:admin)
      assert :read in RBAC.role_permissions(:admin)

      assert :write in RBAC.role_permissions(:user)
      assert :delete not in RBAC.role_permissions(:user)

      assert RBAC.role_permissions(:viewer) == [:read]
    end

    test "check_permission with role-based access" do
      :ok = RBAC.assign_role(@test_address, :user)

      assert :ok = RBAC.check_permission(@test_address, :read)
      assert :ok = RBAC.check_permission(@test_address, :write)
      assert {:error, :forbidden} = RBAC.check_permission(@test_address, :delete)
    end

    test "check_permission with resource-level override" do
      :ok = RBAC.assign_role(@test_address, :viewer)
      assert {:error, :forbidden} = RBAC.check_permission(@test_address, :write, :special)

      :ok = RBAC.grant_resource_permission(@test_address, :special, :write)
      assert :ok = RBAC.check_permission(@test_address, :write, :special)
    end

    test "revoke_resource_permission removes override" do
      :ok = RBAC.assign_role(@test_address, :viewer)
      :ok = RBAC.grant_resource_permission(@test_address, :resource1, :write)
      assert :ok = RBAC.check_permission(@test_address, :write, :resource1)

      :ok = RBAC.revoke_resource_permission(@test_address, :resource1, :write)
      assert {:error, :forbidden} = RBAC.check_permission(@test_address, :write, :resource1)
    end

    test "role levels are ordered" do
      assert RBAC.role_level(:admin) > RBAC.role_level(:user)
      assert RBAC.role_level(:user) > RBAC.role_level(:viewer)
    end

    test "token gate check" do
      :ok = RBAC.assign_role(@test_address, :admin)
      assert :ok = RBAC.check_token_gate(@test_address, %{min_role_level: 2})

      RBAC.reset!()
      :ok = RBAC.assign_role(@test_address, :viewer)
      assert {:error, :gate_not_met} = RBAC.check_token_gate(@test_address, %{min_role_level: 3})
    end

    test "reset! clears all RBAC data" do
      :ok = RBAC.assign_role(@test_address, :admin)
      assert RBAC.get_role(@test_address) == :admin

      :ok = RBAC.reset!()
      assert RBAC.get_role(@test_address) == :viewer
    end
  end

  describe "audit logging" do
    test "logs and retrieves events" do
      :ok = Audit.log_event(:auth_success, %{address: @test_address})
      :ok = Audit.log_event(:auth_failure, %{address: @test_address, reason: :invalid_nonce})

      events = Audit.list_events()
      assert length(events) == 2
    end

    test "filters events by type" do
      :ok = Audit.log_event(:auth_success, %{address: @test_address})
      :ok = Audit.log_event(:auth_failure, %{address: @test_address, reason: :invalid_nonce})

      success_events = Audit.list_events(type: :auth_success)
      assert length(success_events) == 1
      assert hd(success_events).type == :auth_success
    end

    test "queries events by address" do
      other_address = "0xOtherAddress"
      :ok = Audit.log_event(:auth_success, %{address: @test_address})
      :ok = Audit.log_event(:auth_failure, %{address: other_address})

      events = Audit.events_for_address(@test_address)
      assert length(events) == 1
      assert hd(events).type == :auth_success
    end

    test "rate limiting tracks failures" do
      for _ <- 1..3 do
        :ok = Audit.log_event(:auth_failure, %{address: @test_address, reason: :bad_sig})
      end

      assert Audit.failed_attempt_count(@test_address) == 3
      assert :ok = Audit.check_rate_limit(@test_address)
    end

    test "rate limiting triggers after max failures" do
      for _ <- 1..5 do
        :ok = Audit.log_event(:auth_failure, %{address: @test_address, reason: :bad_sig})
      end

      assert {:error, :rate_limited} = Audit.check_rate_limit(@test_address)
    end

    test "reset! clears all audit data" do
      :ok = Audit.log_event(:auth_success, %{address: @test_address})
      assert length(Audit.list_events()) == 1

      :ok = Audit.reset!()
      assert length(Audit.list_events()) == 0
    end

    test "events contain required fields" do
      :ok = Audit.log_event(:auth_success, %{address: @test_address, domain: @test_domain})

      [event] = Audit.list_events()
      assert is_binary(event.id)
      assert event.type == :auth_success
      assert is_integer(event.timestamp)
      assert event.metadata.address == @test_address
    end
  end
end
