defmodule CharterAgreementSigner.KeyHandleTest do
  @moduledoc """
  The key-handle contract's closed error set: malformed handles, crashing
  callbacks (raise / exit / throw), bad snapshot shapes, and sign/2 contract
  violations all map to `:invalid_key_handle` or `:signing_failed` — never an
  escape, never key material in the error.
  """

  use ExUnit.Case, async: true

  alias CharterAgreementSigner.{
    ChainFixture,
    Keys.RawKey,
    Keys.RawMLDSA65,
    Keys.RogueKey
  }

  defmodule RaisingIdentity do
    def key_identity(_handle), do: raise("custody exploded")
    def sign(_message, _handle), do: {:ok, <<0::512>>}
  end

  defmodule ExitingSign do
    def key_identity(_handle), do: {:ok, {"key-001", <<0::256>>}}
    def sign(_message, _handle), do: exit(:custody_timeout)
  end

  defmodule ThrowingSign do
    def key_identity(_handle), do: {:ok, {"key-001", <<0::256>>}}
    def sign(_message, _handle), do: throw(:custody_throw)
  end

  defmodule RejectingSign do
    def key_identity(_handle), do: {:ok, {"key-001", <<0::256>>}}
    def sign(_message, _handle), do: {:error, :hsm_refused}
  end

  defmodule ShortSignature do
    def key_identity(_handle), do: {:ok, {"key-001", <<0::256>>}}
    def sign(_message, _handle), do: {:ok, <<0::504>>}
  end

  defmodule BadSnapshots do
    def key_identity(:empty_kid), do: {:ok, {"", <<0::256>>}}
    def key_identity(:short_key), do: {:ok, {"key-001", <<0::248>>}}
    def key_identity(:not_a_tuple), do: {:ok, :nope}
    def key_identity(:crashed), do: raise("snapshot boom")
    def sign(_message, _handle), do: {:ok, <<0::512>>}
  end

  setup do
    %{setup: ChainFixture.base()}
  end

  test "malformed handle shapes are :invalid_key_handle", %{setup: setup} do
    for handle <- [:not_a_tuple, {"StringModule", :ref}, {NoSuchHandleModule, :ref}, nil] do
      assert {:error, :invalid_key_handle} =
               CharterAgreementSigner.sign_descriptor(
                 ChainFixture.mint(setup.issuer.claims),
                 handle
               )
    end
  end

  test "a crashing key_identity/1 is caught, not escaped", %{setup: setup} do
    assert {:error, :invalid_key_handle} =
             CharterAgreementSigner.sign_descriptor(
               ChainFixture.mint(setup.issuer.claims),
               {RaisingIdentity, :ref}
             )
  end

  test "exit/throw/reject/short-signature on the sign path are :signing_failed", %{setup: setup} do
    for module <- [ExitingSign, ThrowingSign, RejectingSign, ShortSignature] do
      assert {:error, :signing_failed} =
               CharterAgreementSigner.sign_descriptor(
                 ChainFixture.mint(setup.issuer.claims),
                 {module, :ref}
               )
    end
  end

  test "bad identity snapshot shapes are :invalid_key_handle", %{setup: setup} do
    for ref <- [:empty_kid, :short_key, :not_a_tuple, :crashed] do
      assert {:error, :invalid_key_handle} =
               CharterAgreementSigner.sign_descriptor(
                 ChainFixture.mint(setup.issuer.claims),
                 {BadSnapshots, ref}
               )
    end
  end

  test "the RawKey reference handle satisfies the full behaviour" do
    handle = RawKey.generate("self-check-key-001", <<3::256>>)

    assert {:ok, signature} = RawKey.sign("reference message", handle)
    assert byte_size(signature) == 64
    assert {:ok, {kid, public}} = RawKey.key_identity(handle)
    assert kid == "self-check-key-001"
    assert {:ok, ^public} = RawKey.public_key(handle)
    assert {:ok, thumbprint} = RawKey.thumbprint(handle)
    assert byte_size(thumbprint) == 32
  end

  test "every reference handle maps a malformed ref to {:error, :invalid_handle}" do
    # The test-only handles mirror the production posture: a malformed ref is
    # a closed atom from every callback, never a crash out of the handle.
    # (A well-shaped 3-tuple with garbage members is NOT this case: the
    # guarded callbacks reject it above, and the unguarded crypto/callback
    # bodies raise or return the garbage — the signer's safe_callback maps
    # that to :signing_failed, pinned by the closed-error tests above.)
    for ref <- [:garbage, "not-a-tuple", 42, {1, 2}] do
      assert {:error, :invalid_handle} = RawKey.sign("m", ref)
      assert {:error, :invalid_handle} = RawKey.key_identity(ref)
      assert {:error, :invalid_handle} = RawKey.public_key(ref)
      assert {:error, :invalid_handle} = RawKey.thumbprint(ref)

      assert {:error, :invalid_handle} = RawMLDSA65.sign("m", ref)
      assert {:error, :invalid_handle} = RawMLDSA65.key_identity(ref)

      assert {:error, :invalid_handle} = RogueKey.sign("m", ref)
      assert {:error, :invalid_handle} = RogueKey.key_identity(ref)
      assert {:error, :invalid_handle} = RogueKey.public_key(ref)
      assert {:error, :invalid_handle} = RogueKey.thumbprint(ref)
    end
  end

  test "RogueKey advertises the victim's key while signing with the rogue key" do
    # The wrong-key probe's non-vacuity semantics, pinned directly: the
    # identity snapshot AND the optional caller self-check surface hand back
    # the ADVERTISED (victim) key, so nothing upstream of verify_signature
    # can distinguish the forgery — the wrong-key gate is the only catcher.
    victim = RawKey.generate("victim-key-001", <<4::256>>)
    {_rogue_public, rogue_private} = :crypto.generate_key(:eddsa, :ed25519, <<9::256>>)

    handle = {"victim-key-001", elem(victim, 1), rogue_private}

    assert {:ok, {"victim-key-001", advertised}} = RogueKey.key_identity(handle)
    assert advertised == elem(victim, 1)
    assert {:ok, ^advertised} = RogueKey.public_key(handle)

    assert {:ok, thumbprint} = RogueKey.thumbprint(handle)
    assert {:ok, ^thumbprint} = RawKey.thumbprint(victim)

    {:ok, rogue_signature} = RogueKey.sign("counterfeit message", handle)

    assert false ==
             :crypto.verify(:eddsa, :none, "counterfeit message", rogue_signature, [
               advertised,
               :ed25519
             ])
  end

  test "error values never carry key material or claims content", %{setup: setup} do
    {:ok, set} = ChainFixture.raw_set(setup, [setup.genesis], [], [])
    private = elem(setup.issuer_handle, 2)

    errors = [
      CharterAgreementSigner.sign_descriptor(
        ChainFixture.mint(setup.issuer.claims),
        :bad_handle
      ),
      CharterAgreementSigner.sign_acceptance(%{}, {RejectingSign, :ref}, set),
      CharterAgreementSigner.sign_receipt(%{}, {RejectingSign, :ref}, :no_context)
    ]

    for error <- errors do
      refute inspect(error) =~ inspect(private)
      refute inspect(error) =~ inspect(setup.issuer.claims)
    end
  end
end
