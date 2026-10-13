defmodule CharterAgreementSignerTest do
  @moduledoc """
  Round-trips for all four signing surfaces: each sign path produces a
  compact that CAP's own public verify functions accept, the protected
  header's kid is ALWAYS the handle snapshot's, and the post-sign verify
  catches a snapshot key the party descriptor does not pin.
  """

  use ExUnit.Case, async: true

  alias CharterAgreementProtocol, as: CAP
  alias CharterAgreementProtocol.{ArtifactSet, Limits}
  alias CharterAgreementSigner.Keys.{RawKey, RawMLDSA65}

  alias CharterAgreementSigner.{
    AcceptanceFixture,
    ChainFixture,
    CharterRevisionFixture,
    DescriptorFixture,
    ReceiptFixture,
    TerminationFixture
  }

  # Substrate note: minting ML-DSA-65 keys needs the OTP runtime linked
  # against OpenSSL >= 3.5 (Ubuntu 24.04's system OpenSSL is 3.0.x); every
  # Linux CI lane runs it, and a local OTP linked against an older OpenSSL
  # can exclude the tag.
  @tag :requires_mldsa_substrate
  test "sign_descriptor mints ML-DSA-65 at revision 3 end-to-end" do
    {kid, mldsa_public, mldsa_private} = RawMLDSA65.generate("mldsa-key-001")
    handle = {RawMLDSA65, {kid, mldsa_public, mldsa_private}}

    claims = %{
      "protocol_revision" => 3,
      "descriptor_number" => 1,
      "verification_keys" => [
        %{
          "key_id" => kid,
          "algorithm" => "ML-DSA-65",
          "public_key" => Base.url_encode64(mldsa_public, padding: false),
          "status" => "active"
        }
      ],
      "attestation_hints" => [],
      "extensions" => %{"critical" => %{}, "optional" => %{}},
      "effective_from" => "2026-08-25T10:00:00Z"
    }

    assert {:ok, %{descriptor: compact}} =
             CharterAgreementSigner.sign_descriptor(claims, handle, %{algorithm: "ML-DSA-65"})

    assert {:ok, facts} = CAP.verify_descriptor(compact, nil, Limits.default())
    assert facts.descriptor.protocol_revision == 3
    assert header_kid(compact) == "mldsa-key-001"

    assert {:error, {:invalid_input, :algorithm_unsupported}} =
             CharterAgreementSigner.sign_descriptor(claims, handle, %{algorithm: "ML-DSA-87"})

    # an Ed25519 handle cannot satisfy the ML-DSA signature length
    classical = {RawKey, RawKey.generate("classical", :binary.copy(<<1>>, 32))}

    assert {:error, :signing_failed} =
             CharterAgreementSigner.sign_descriptor(claims, classical, %{algorithm: "ML-DSA-65"})
  end

  test "sign_descriptor round-trips through CAP verify with the snapshot kid" do
    setup = ChainFixture.base()
    handle = {RawKey, setup.issuer_handle}

    assert {:ok, %{descriptor: compact}} =
             CharterAgreementSigner.sign_descriptor(
               ChainFixture.mint(setup.issuer.claims),
               handle
             )

    assert {:ok, _facts} = CAP.verify_descriptor(compact, nil, Limits.default())

    assert header_kid(compact) == "issuer-key-001"
  end

  test "sign_acceptance round-trips through CAP verify against the retained view" do
    setup = ChainFixture.base()
    {:ok, set} = ChainFixture.raw_set(setup, [setup.genesis], [], [])
    claims = ChainFixture.mint(AcceptanceFixture.claims(setup.genesis, setup.issuer, "issuer"))

    assert {:ok, %{acceptance: compact}} =
             CharterAgreementSigner.sign_acceptance(claims, {RawKey, setup.issuer_handle}, set)

    {:ok, revision} = CAP.decode_charter_revision(setup.genesis.bytes, Limits.default())
    {:ok, chain} = CAP.verify_descriptor_chain([setup.issuer.compact], Limits.default())

    assert {:ok, _facts} = CAP.verify_acceptance(compact, revision, chain, Limits.default())
  end

  test "sign_termination round-trips through CAP verify against the accepted view" do
    setup = ChainFixture.base()
    acceptances = ChainFixture.dual_acceptances(setup.genesis, setup)
    {:ok, set} = ChainFixture.raw_set(setup, [setup.genesis], acceptances, [])
    claims = ChainFixture.mint(TerminationFixture.claims(setup.genesis, setup.issuer, "issuer"))

    assert {:ok, %{termination: compact}} =
             CharterAgreementSigner.sign_termination(claims, {RawKey, setup.issuer_handle}, set)

    {:ok, revision} = CAP.decode_charter_revision(setup.genesis.bytes, Limits.default())
    {:ok, chain} = CAP.verify_descriptor_chain([setup.issuer.compact], Limits.default())

    assert {:ok, _facts} = CAP.verify_termination(compact, revision, chain, Limits.default())
  end

  test "sign_receipt round-trips through CAP verify against the revision context" do
    setup = ChainFixture.base()
    {:ok, revision} = CAP.decode_charter_revision(setup.genesis.bytes, Limits.default())
    claims = ChainFixture.mint(ReceiptFixture.claims(setup.genesis))

    assert {:ok, %{receipt: compact}} =
             CharterAgreementSigner.sign_receipt(claims, {RawKey, setup.issuer_handle}, revision)

    assert {:ok, _facts} = CAP.verify_receipt(compact, revision, Limits.default())
  end

  test "the post-sign verify rejects a snapshot key the descriptor does not pin" do
    setup = ChainFixture.base()
    # A handle whose key is NOT the descriptor's pinned key: the producer and
    # the crypto guard both pass (the handle signs with exactly the key it
    # advertises), but CAP's descriptor verify fails — so the signer must
    # refuse to return the artifact.
    stranger = RawKey.generate("stranger-key-001", <<7::256>>)

    assert {:error, :verification_failed} =
             CharterAgreementSigner.sign_descriptor(
               ChainFixture.mint(setup.issuer.claims),
               {RawKey, stranger}
             )
  end

  test "a successor descriptor requires predecessor facts for the post-sign verify" do
    setup = ChainFixture.base()
    # Signing the SAME genesis claims while claiming descriptor_number 2 via
    # claims override: CAP's producer accepts the claims shape, the signature
    # verifies, but verify_descriptor with a nil predecessor cannot verify a
    # non-genesis descriptor — surfaced here as :verification_failed, never a
    # silent success.
    successor_claims =
      Map.merge(ChainFixture.mint(setup.issuer.claims), %{
        "descriptor_number" => 2,
        "party_id" => setup.issuer.party_id,
        "prev_descriptor_digest" => setup.issuer.digest
      })

    assert {:error, :verification_failed} =
             CharterAgreementSigner.sign_descriptor(
               successor_claims,
               {RawKey, setup.issuer_handle}
             )
  end

  test "invalid limits are rejected as input, not as verification failures" do
    setup = ChainFixture.base()

    assert {:error, {:invalid_input, :invalid_limits}} =
             CharterAgreementSigner.sign_descriptor(
               ChainFixture.mint(setup.issuer.claims),
               {RawKey, setup.issuer_handle},
               %{
                 limits: :not_limits
               }
             )
  end

  test "caller limits too narrow to decode the retained revision are :verification_failed" do
    # The producer verifies the set on DEFAULT limits; only the post-sign
    # verify runs on the caller's. Limits that cannot decode the retained
    # revision reject the just-signed artifact — never a silent success.
    setup = ChainFixture.base()
    {:ok, set} = ChainFixture.raw_set(setup, [setup.genesis], [], [])
    claims = ChainFixture.mint(AcceptanceFixture.claims(setup.genesis, setup.issuer, "issuer"))

    assert {:error, :verification_failed} =
             CharterAgreementSigner.sign_acceptance(claims, {RawKey, setup.issuer_handle}, set, %{
               limits: %{Limits.default() | max_bytes: 200}
             })
  end

  test "caller limits too narrow to decode the party descriptor are :verification_failed" do
    # A fat descriptor (a padded optional extension plus float/boolean flag
    # values) bound as the issuer party of its own genesis: the producer, on
    # defaults, accepts it; caller max_bytes between the two artifact sizes
    # decodes the revision but halts on the descriptor.
    setup = ChainFixture.base()
    {kid, _public, private} = setup.issuer_handle

    fat_claims =
      Map.merge(setup.issuer.claims, %{
        "extensions" => %{
          "critical" => %{},
          "optional" => %{
            "com.example/pad" => String.duplicate("x", 3_000),
            "com.example/flags" => %{"ratio" => 0.5, "enabled" => true}
          }
        }
      })

    fat = DescriptorFixture.compact(fat_claims, kid, private)

    genesis =
      CharterRevisionFixture.genesis(
        claims: %{
          "parties" => [
            %{"party_descriptor_digest" => fat.digest, "role" => "issuer"},
            %{"party_descriptor_digest" => setup.acceptor.digest, "role" => "acceptor"}
          ],
          "extensions" => %{"critical" => %{}, "optional" => %{"com.example/flags" => true}}
        }
      )

    mid = div(byte_size(genesis.bytes) + byte_size(fat.compact), 2)

    {:ok, set} =
      ArtifactSet.build([genesis.bytes], [], [], [fat.compact, setup.acceptor.compact])

    claims = ChainFixture.mint(AcceptanceFixture.claims(genesis, fat, "issuer"))

    assert {:error, :verification_failed} =
             CharterAgreementSigner.sign_acceptance(claims, {RawKey, setup.issuer_handle}, set, %{
               limits: %{Limits.default() | max_bytes: mid}
             })
  end

  test "a termination over an already-terminated charter is refused before the key is used" do
    # The bilateral endgame is ONE notice per charter: the acceptor's notice
    # in the retained set terminates it, and CAP's honest-signer rules refuse
    # the issuer's own second notice (an equivocation over a settled
    # charter) BEFORE the key is touched.
    setup = ChainFixture.base()
    acceptances = ChainFixture.dual_acceptances(setup.genesis, setup)

    {_, acceptor_termination} =
      ChainFixture.termination(setup.genesis, setup.acceptor, setup.acceptor_handle, "acceptor")

    {:ok, set} = ChainFixture.raw_set(setup, [setup.genesis], acceptances, [acceptor_termination])
    claims = ChainFixture.mint(TerminationFixture.claims(setup.genesis, setup.issuer, "issuer"))

    assert {:error, {:refused, :signing_refused}} =
             CharterAgreementSigner.sign_termination(claims, {RawKey, setup.issuer_handle}, set)
  end

  test "a revision party with no descriptor in the set is :verification_failed, never a crash" do
    setup = ChainFixture.base()
    second_handle = RawKey.generate("issuer-key-002", <<3::256>>)
    third_handle = RawKey.generate("issuer-key-003", <<4::256>>)

    second_claims =
      Map.merge(setup.issuer.claims, %{
        "descriptor_number" => 2,
        "party_id" => setup.issuer.digest,
        "prev_descriptor_digest" => setup.issuer.digest,
        "verification_keys" => [DescriptorFixture.key(second_handle)],
        "effective_from" => "2026-08-25T10:01:00Z"
      })

    second =
      DescriptorFixture.compact(second_claims, setup.issuer.kid, elem(setup.issuer_handle, 2))

    third_claims =
      Map.merge(second_claims, %{
        "descriptor_number" => 3,
        "prev_descriptor_digest" => second.digest,
        "verification_keys" => [DescriptorFixture.key(third_handle)],
        "effective_from" => "2026-08-25T10:02:00Z"
      })

    third =
      DescriptorFixture.compact(third_claims, elem(second_handle, 0), elem(second_handle, 2))

    revision_claims =
      Map.merge(setup.genesis.claims, %{
        "revision_number" => 2,
        "charter_id" => setup.genesis.charter_id,
        "prev_revision_digest" => setup.genesis.digest,
        "effective_from" => "2026-08-25T12:01:00Z",
        "parties" => [
          %{"party_descriptor_digest" => third.digest, "role" => "issuer"},
          %{"party_descriptor_digest" => setup.acceptor.digest, "role" => "acceptor"}
        ]
      })

    revision =
      CharterRevisionFixture.from_claims(revision_claims, setup.genesis.legal_text,
        charter_id: setup.genesis.charter_id
      )

    # The genesis names both held histories. Revision 2 names descriptor 3,
    # while the issuer history in this view stops at descriptor 2.
    descriptors = [setup.issuer.compact, second.compact, setup.acceptor.compact]
    revisions = [setup.genesis.bytes, revision.bytes]
    {:ok, set} = ArtifactSet.build(revisions, [], [], descriptors)
    claims = ChainFixture.mint(AcceptanceFixture.claims(revision, third, "issuer"))
    handle = {RawKey, third_handle}

    assert {:ok, _input} =
             CAP.acceptance_signing_input(
               %{"kid" => elem(third_handle, 0), "claims" => claims},
               set
             )

    assert {:error, :verification_failed} =
             CharterAgreementSigner.sign_acceptance(claims, handle, set)

    # Holding descriptor 3 makes the same request succeed.
    {:ok, complete} = ArtifactSet.build(revisions, [], [], descriptors ++ [third.compact])

    assert {:ok, %{acceptance: _compact}} =
             CharterAgreementSigner.sign_acceptance(claims, handle, complete)
  end

  test "keyword-list options work and malformed options return the closed error" do
    setup = ChainFixture.base()
    handle = {RawKey, setup.issuer_handle}

    assert {:ok, %{descriptor: _compact}} =
             CharterAgreementSigner.sign_descriptor(
               ChainFixture.mint(setup.issuer.claims),
               handle,
               []
             )

    for bad_opts <- [:atom, "string", {1, 2}, 42] do
      assert {:error, {:invalid_input, :invalid_type}} =
               CharterAgreementSigner.sign_descriptor(
                 ChainFixture.mint(setup.issuer.claims),
                 handle,
                 bad_opts
               )
    end
  end

  defp header_kid(compact) do
    [protected_segment, _payload_segment, _signature] = String.split(compact, ".")

    {:ok, protected_bytes} = CharterAgreementProtocol.Base64Url.decode(protected_segment)
    %{"kid" => kid} = JSON.decode!(protected_bytes)
    kid
  end
end
