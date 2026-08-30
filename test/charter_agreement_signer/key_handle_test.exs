defmodule CharterAgreementSigner.KeyHandleTest do
  @moduledoc """
  The key-handle contract's closed error set: malformed handles, crashing
  callbacks (raise / exit / throw), bad snapshot shapes, and sign/2 contract
  violations all map to `:invalid_key_handle` or `:signing_failed` — never an
  escape, never key material in the error.
  """

  use ExUnit.Case, async: true

  alias CharterAgreementSigner.{ChainFixture, Keys.RawKey}

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
