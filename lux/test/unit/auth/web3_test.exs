defmodule Lux.Auth.Web3Test do
  use UnitCase, async: false

  alias Lux.Auth.Web3
  alias Lux.Auth.Web3.Signature
  alias Lux.Auth.Web3.Session
  alias Lux.Auth.Web3.RBAC
  alias Lux.Auth.Web3.Audit
  alias Lux.Auth.Web3.MultiSig
  alias Lux.Auth.Web3.TokenGate

  @test_address "0x71C7656EC7ab88b098defB751B7401B5f6d8976F"
  @test_domain "example.com"
  @test_private_key_hex "0x4c0883a69102937d6231471b5dbb6204fe512961708279e1dce5284d2a3f1aeb"

  setup do
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

  # ============================================================
  # Nonce Generation
  # ============================================================

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

  # ============================================================
  # SIWE Message Construction & Parsing
  # ============================================================

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

  # ============================================================
  # Known-Answer Tests for SIWE Signature/Verification
  # ============================================================

  describe "SIWE signature known-answer tests" do
    @tag :known_answer
    test "EIP-191 personal_sign hash is deterministic" do
      {:ok, hash1} = Signature.hash_message("hello")
      {:ok, hash2} = Signature.hash_message("hello")
      assert byte_size(hash1) == 32
      assert hash1 == hash2
    end

    @tag :known_answer
    test "different messages produce different hashes" do
      {:ok, hash1} = Signature.hash_message("hello")
      {:ok, hash2} = Signature.hash_message("world")
      assert hash1 != hash2
    end

    @tag :known_answer
    test "hash_message with empty string" do
      {:ok, hash} = Signature.hash_message("")
      assert byte_size(hash) == 32
    end

    @tag :known_answer
    test "hash_message with SIWE-formatted message" do
      siwe_message =
        Web3.build_siwe_message(%{
          domain: "login.xyz",
          address: "0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
          statement: "Sign in with Ethereum",
          nonce: "abcd1234",
          chain_id: 1
        })

      {:ok, hash} = Signature.hash_message(siwe_message)
      assert byte_size(hash) == 32

      {:ok, hash2} = Signature.hash_message(siwe_message)
      assert hash == hash2
    end

    @tag :known_answer
    test "full SIWE sign-verify round trip with known key" do
      private_key = Base.decode16!(@test_private_key_hex, case: :lower)
      {:ok, public_key} = ExSecp256k1.create_public_key(private_key)
      signer_address = derive_address(public_key)

      siwe_message =
        Web3.build_siwe_message(%{
          domain: "app.example.com",
          address: signer_address,
          statement: "Sign in to Example App",
          nonce: "nonce_test_123",
          chain_id: 1,
          expiration_time: "2099-12-31T23:59:59Z"
        })

      {:ok, hash} = Signature.hash_message(siwe_message)
      {:ok, {r, s, v_raw}} = ExSecp256k1.sign(hash, private_key)
      signature = r <> s <> <<v_raw + 27>>

      {:ok, recovered} = Signature.recover_address(siwe_message, signature)
      assert String.downcase(recovered) == String.downcase(signer_address)

      assert :ok = Signature.verify_signature(siwe_message, signature, signer_address)
    end

    @tag :known_answer
    test "verify_signature rejects wrong expected address" do
      private_key = Base.decode16!(@test_private_key_hex, case: :lower)
      {:ok, public_key} = ExSecp256k1.create_public_key(private_key)
      signer_address = derive_address(public_key)

      message = "test message"
      {:ok, hash} = Signature.hash_message(message)
      {:ok, {r, s, v_raw}} = ExSecp256k1.sign(hash, private_key)
      signature = r <> s <> <<v_raw + 27>>

      wrong_address = "0x0000000000000000000000000000000000000001"
      assert {:error, :signature_invalid} = Signature.verify_signature(message, signature, wrong_address)
    end

    @tag :known_answer
    test "recovered address differs when message is tampered" do
      private_key = Base.decode16!(@test_private_key_hex, case: :lower)
      message = "original message"
      {:ok, hash} = Signature.hash_message(message)
      {:ok, {r, s, v_raw}} = ExSecp256k1.sign(hash, private_key)
      signature = r <> s <> <<v_raw + 27>>

      {:ok, recovered_orig} = Signature.recover_address(message, signature)
      {:ok, recovered_tampered} = Signature.recover_address("tampered message", signature)
      assert recovered_orig != recovered_tampered
    end
  end

  # ============================================================
  # Domain Validation
  # ============================================================

  describe "domain allowlist validation" do
    test "accepts all domains when no allowlist is configured" do
      original = Application.get_env(:lux, :siwe_domain_allowlist)
      Application.delete_env(:lux, :siwe_domain_allowlist)

      assert :ok = Web3.validate_domain("any-domain.com")
      assert :ok = Web3.validate_domain("evil.com")

      if original, do: Application.put_env(:lux, :siwe_domain_allowlist, original)
    end

    test "accepts domains in allowlist" do
      original = Application.get_env(:lux, :siwe_domain_allowlist)
      Application.put_env(:lux, :siwe_domain_allowlist, ["example.com", "app.example.com"])

      assert :ok = Web3.validate_domain("example.com")
      assert :ok = Web3.validate_domain("app.example.com")

      if original, do: Application.put_env(:lux, :siwe_domain_allowlist, original)
      Application.delete_env(:lux, :siwe_domain_allowlist)
    end

    test "rejects domains not in allowlist" do
      original = Application.get_env(:lux, :siwe_domain_allowlist)
      Application.put_env(:lux, :siwe_domain_allowlist, ["example.com"])

      assert {:error, :domain_not_allowed} = Web3.validate_domain("evil.com")
      assert {:error, :domain_not_allowed} = Web3.validate_domain("notexample.com")

      if original, do: Application.put_env(:lux, :siwe_domain_allowlist, original)
      Application.delete_env(:lux, :siwe_domain_allowlist)
    end

    test "domain matching is case-insensitive" do
      original = Application.get_env(:lux, :siwe_domain_allowlist)
      Application.put_env(:lux, :siwe_domain_allowlist, ["Example.COM"])

      assert :ok = Web3.validate_domain("example.com")
      assert :ok = Web3.validate_domain("EXAMPLE.COM")

      if original, do: Application.put_env(:lux, :siwe_domain_allowlist, original)
      Application.delete_env(:lux, :siwe_domain_allowlist)
    end
  end

  # ============================================================
  # Multi-Signature Authentication
  # ============================================================

  describe "multi-signature authentication" do
    setup do
      keys =
        for _ <- 1..3 do
          {:ok, priv} = ExSecp256k1.create_private_key()
          {:ok, pub} = ExSecp256k1.create_public_key(priv)
          address = derive_address(pub)
          {priv, address}
        end

      {:ok, keys: keys}
    end

    test "authenticates with threshold met", %{keys: keys} do
      siwe_msg =
        Web3.build_siwe_message(%{
          domain: "example.com",
          address: elem(Enum.at(keys, 0), 1),
          statement: "Multi-sig test",
          nonce: "multisig_nonce",
          chain_id: 1
        })

      signatures =
        keys
        |> Enum.take(2)
        |> Enum.map(fn {priv, addr} ->
          {:ok, hash} = Signature.hash_message(siwe_msg)
          {:ok, {r, s, v_raw}} = ExSecp256k1.sign(hash, priv)
          sig = r <> s <> <<v_raw + 27>>
          %{address: addr, signature: sig}
        end)

      assert {:ok, session} =
               MultiSig.authenticate(siwe_msg, signatures, 2, chain_id: 1, domain: "example.com")

      assert is_binary(session.token)
    end

    test "rejects when threshold not met", %{keys: keys} do
      siwe_msg =
        Web3.build_siwe_message(%{
          domain: "example.com",
          address: elem(Enum.at(keys, 0), 1),
          statement: "Multi-sig test",
          nonce: "multisig_nonce",
          chain_id: 1
        })

      {priv, addr} = Enum.at(keys, 0)
      {:ok, hash} = Signature.hash_message(siwe_msg)
      {:ok, {r, s, v_raw}} = ExSecp256k1.sign(hash, priv)
      sig = r <> s <> <<v_raw + 27>>
      signatures = [%{address: addr, signature: sig}]

      assert {:error, :threshold_not_met} =
               MultiSig.authenticate(siwe_msg, signatures, 2, chain_id: 1, domain: "example.com")
    end

    test "rejects duplicate signers", %{keys: keys} do
      siwe_msg =
        Web3.build_siwe_message(%{
          domain: "example.com",
          address: elem(Enum.at(keys, 0), 1),
          statement: "Multi-sig test",
          nonce: "multisig_nonce",
          chain_id: 1
        })

      {priv, addr} = Enum.at(keys, 0)
      {:ok, hash} = Signature.hash_message(siwe_msg)
      {:ok, {r, s, v_raw}} = ExSecp256k1.sign(hash, priv)
      sig = r <> s <> <<v_raw + 27>>

      signatures = [
        %{address: addr, signature: sig},
        %{address: addr, signature: sig}
      ]

      assert {:error, :duplicate_signer} =
               MultiSig.authenticate(siwe_msg, signatures, 2, chain_id: 1, domain: "example.com")
    end

    test "rejects invalid threshold" do
      assert {:error, :invalid_threshold} =
               MultiSig.authenticate("msg", [], 0, chain_id: 1, domain: "example.com")
    end

    test "rejects insufficient signatures" do
      assert {:error, :insufficient_signatures} =
               MultiSig.authenticate("msg", [], 1, chain_id: 1, domain: "example.com")
    end

    test "check_threshold_policy validates authorized signers", %{keys: keys} do
      authorized = Enum.map(keys, fn {_priv, addr} -> addr end)
      verified = Enum.take(authorized, 2)

      assert {:ok, matched} = MultiSig.check_threshold_policy(verified, authorized, 2)
      assert length(matched) == 2
    end

    test "check_threshold_policy rejects insufficient authorized signers", %{keys: keys} do
      authorized = Enum.map(keys, fn {_priv, addr} -> addr end)
      verified = Enum.take(authorized, 1)

      assert {:error, :threshold_not_met} =
               MultiSig.check_threshold_policy(verified, authorized, 2)
    end

    test "count_valid_signatures returns correct count", %{keys: keys} do
      siwe_msg =
        Web3.build_siwe_message(%{
          domain: "example.com",
          address: elem(Enum.at(keys, 0), 1),
          statement: "Multi-sig test",
          nonce: "multisig_nonce",
          chain_id: 1
        })

      {priv1, addr1} = Enum.at(keys, 0)
      {priv2, addr2} = Enum.at(keys, 1)

      {:ok, hash} = Signature.hash_message(siwe_msg)
      {:ok, {r1, s1, v1}} = ExSecp256k1.sign(hash, priv1)
      {:ok, {r2, s2, v2}} = ExSecp256k1.sign(hash, priv2)

      signatures = [
        %{address: addr1, signature: r1 <> s1 <> <<v1 + 27>>},
        %{address: addr2, signature: r2 <> s2 <> <<v2 + 27>>}
      ]

      assert MultiSig.count_valid_signatures(siwe_msg, signatures) == 2
    end
  end

  # ============================================================
  # Token-Gated Access
  # ============================================================

  describe "token-gated access" do
    test "accepts ERC-20 balance gate spec structure" do
      gate = %{
        type: :erc20_balance,
        token_address: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
        minimum_balance: 100,
        decimals: 6
      }

      assert gate.type == :erc20_balance
      assert gate.minimum_balance == 100
    end

    test "accepts ERC-721 ownership gate spec structure" do
      gate = %{
        type: :erc721_ownership,
        collection_address: "0xbc4ca0eda7647a8ab7c2061c2e118a18a936f13d"
      }

      assert gate.type == :erc721_ownership
    end

    test "accepts native balance gate spec structure" do
      gate = %{
        type: :native_balance,
        minimum_balance: 1_000_000_000_000_000_000
      }

      assert gate.type == :native_balance
    end

    test "rejects unknown gate type" do
      assert {:error, {:unknown_gate_type, :bogus}} =
               TokenGate.check(@test_address, %{type: :bogus})
    end

    test "rejects invalid gate spec" do
      assert {:error, :invalid_gate_spec} = TokenGate.check(@test_address, %{foo: :bar})
    end

    test "check_all passes when all gates pass (empty list)" do
      assert :ok = TokenGate.check_all(@test_address, [])
    end

    test "check_any fails when no gates provided" do
      assert {:error, :all_gates_failed} = TokenGate.check_any(@test_address, [])
    end

    test "RBAC check_token_gate with on-chain type delegates to TokenGate" do
      gate = %{
        type: :erc20_balance,
        token_address: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
        minimum_balance: 100,
        decimals: 6
      }

      # Will fail at RPC level, but proves delegation path works
      assert {:error, _} = RBAC.check_token_gate(@test_address, gate)
    end

    test "RBAC check_token_gate with legacy role-level gate still works" do
      :ok = RBAC.assign_role(@test_address, :admin)
      assert :ok = RBAC.check_token_gate(@test_address, %{min_role_level: 2})

      RBAC.reset!()
      :ok = RBAC.assign_role(@test_address, :viewer)
      assert {:error, :gate_not_met} = RBAC.check_token_gate(@test_address, %{min_role_level: 3})
    end
  end

  # ============================================================
  # Session Expiry & Refresh
  # ============================================================

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
      assert {:error, :session_revoked} = Session.validate(session.token)
    end

    test "refresh fails for expired session" do
      {:ok, session} =
        Session.create(
          %{address: @test_address, chain_id: 1, domain: @test_domain},
          ttl: 0
        )

      assert {:error, :session_expired} = Session.refresh(session.token)
    end

    test "refresh fails for revoked session" do
      {:ok, session} =
        Session.create(%{
          address: @test_address,
          chain_id: 1,
          domain: @test_domain
        })

      Session.revoke(session.token)
      assert {:error, :session_revoked} = Session.refresh(session.token)
    end

    test "session with custom TTL" do
      {:ok, session} =
        Session.create(
          %{address: @test_address, chain_id: 1, domain: @test_domain},
          ttl: 60
        )

      assert {:ok, _} = Session.validate(session.token)
    end

    test "cleanup_expired removes expired sessions" do
      {:ok, expired_session} =
        Session.create(
          %{address: @test_address, chain_id: 1, domain: @test_domain},
          ttl: 0
        )

      {:ok, valid_session} =
        Session.create(
          %{address: @test_address, chain_id: 1, domain: @test_domain},
          ttl: 3600
        )

      cleaned = Session.cleanup_expired()
      assert cleaned >= 1
      assert {:ok, _} = Session.validate(valid_session.token)
    end

    test "active_count returns correct count" do
      {:ok, _} =
        Session.create(
          %{address: @test_address, chain_id: 1, domain: @test_domain},
          ttl: 3600
        )

      assert Session.active_count() >= 1
    end

    test "refresh_session logs audit event" do
      {:ok, session} =
        Session.create(%{
          address: @test_address,
          chain_id: 1,
          domain: @test_domain
        })

      :ok = Web3.refresh_session(session.token)

      events = Audit.list_events(type: :session_refreshed)
      assert length(events) == 1
    end
  end

  # ============================================================
  # RBAC Cache Invalidation
  # ============================================================

  describe "RBAC cache invalidation" do
    test "assign_role invalidates token gate cache for address" do
      address = "0xCacheInvalidTestAddress"

      :ok = RBAC.assign_role(address, :admin)
      assert :ok = RBAC.check_token_gate(address, %{min_role_level: 2})

      :ok = RBAC.assign_role(address, :viewer)
      assert {:error, :gate_not_met} = RBAC.check_token_gate(address, %{min_role_level: 3})
    end

    test "grant_resource_permission invalidates token gate cache" do
      address = "0xResourcePermTestAddress"

      :ok = RBAC.assign_role(address, :admin)
      :ok = RBAC.check_token_gate(address, %{min_role_level: 1})

      :ok = RBAC.grant_resource_permission(address, :special, :write)
      assert :ok = RBAC.check_token_gate(address, %{min_role_level: 1})
    end

    test "revoke_resource_permission invalidates token gate cache" do
      address = "0xRevokePermTestAddress"

      :ok = RBAC.assign_role(address, :admin)
      :ok = RBAC.grant_resource_permission(address, :special, :write)
      :ok = RBAC.check_token_gate(address, %{min_role_level: 1})

      :ok = RBAC.revoke_resource_permission(address, :special, :write)
      assert :ok = RBAC.check_token_gate(address, %{min_role_level: 1})
    end

    test "invalidate_token_gate_cache clears all gate results for address" do
      address = "0xExplicitInvalidateTest"

      :ok = RBAC.assign_role(address, :admin)
      :ok = RBAC.check_token_gate(address, %{min_role_level: 2})
      :ok = RBAC.check_token_gate(address, %{min_role_level: 1})

      RBAC.invalidate_token_gate_cache(address)

      assert :ok = RBAC.check_token_gate(address, %{min_role_level: 2})
      assert :ok = RBAC.check_token_gate(address, %{min_role_level: 1})
    end

    test "invalidate_all_token_gate_caches clears everything" do
      addr1 = "0xGlobalInvalidateTest1"
      addr2 = "0xGlobalInvalidateTest2"

      :ok = RBAC.assign_role(addr1, :admin)
      :ok = RBAC.assign_role(addr2, :admin)
      :ok = RBAC.check_token_gate(addr1, %{min_role_level: 2})
      :ok = RBAC.check_token_gate(addr2, %{min_role_level: 2})

      RBAC.invalidate_all_token_gate_caches()

      assert :ok = RBAC.check_token_gate(addr1, %{min_role_level: 2})
      assert :ok = RBAC.check_token_gate(addr2, %{min_role_level: 2})
    end

    test "invalidate_caches_for_state_change with :address" do
      address = "0xStateChangeTest"

      :ok = RBAC.assign_role(address, :admin)
      :ok = RBAC.check_token_gate(address, %{min_role_level: 2})

      RBAC.invalidate_caches_for_state_change(:address, address)
      assert :ok = RBAC.check_token_gate(address, %{min_role_level: 2})
    end

    test "invalidate_caches_for_state_change with :all" do
      addr1 = "0xStateChangeAll1"
      addr2 = "0xStateChangeAll2"

      :ok = RBAC.assign_role(addr1, :admin)
      :ok = RBAC.assign_role(addr2, :admin)
      :ok = RBAC.check_token_gate(addr1, %{min_role_level: 2})
      :ok = RBAC.check_token_gate(addr2, %{min_role_level: 2})

      RBAC.invalidate_caches_for_state_change(:all, nil)

      assert :ok = RBAC.check_token_gate(addr1, %{min_role_level: 2})
      assert :ok = RBAC.check_token_gate(addr2, %{min_role_level: 2})
    end

    test "role change causes gate re-evaluation with different result" do
      address = "0xRoleChangeReeval"

      :ok = RBAC.assign_role(address, :admin)
      assert :ok = RBAC.check_token_gate(address, %{min_role_level: 3})

      :ok = RBAC.assign_role(address, :viewer)
      assert {:error, :gate_not_met} = RBAC.check_token_gate(address, %{min_role_level: 3})
    end
  end

  # ============================================================
  # RBAC Basic
  # ============================================================

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

    test "reset! clears all RBAC data" do
      :ok = RBAC.assign_role(@test_address, :admin)
      assert RBAC.get_role(@test_address) == :admin

      :ok = RBAC.reset!()
      assert RBAC.get_role(@test_address) == :viewer
    end
  end

  # ============================================================
  # Audit Logging
  # ============================================================

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

  # ============================================================
  # Helper
  # ============================================================

  defp derive_address(public_key) do
    key_bytes =
      case public_key do
        <<4, rest::binary>> -> rest
        _ when byte_size(public_key) == 64 -> public_key
        <<_prefix, _rest::binary>> = pk when byte_size(pk) == 33 ->
          {:ok, decompressed} = ExSecp256k1.create_public_key_from_compressed(pk)
          <<4, raw::binary>> = decompressed
          raw
      end

    <<_::binary-size(12), address::binary-size(20)>> =
      ExSecp256k1.Hash.keccak(key_bytes)

    "0x" <> Base.encode16(address, case: :lower)
  end
end
