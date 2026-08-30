# Charter-artifact fixtures, ported from the protocol package's own
# test/support builders (read first-hand; Apache-2.0, same portfolio). They
# exercise ONLY the public CAP surface plus :crypto, so the signer's test
# suite builds its own verified views exactly the way a host would.

defmodule CharterAgreementSigner.DescriptorFixture do
  @moduledoc false

  alias CharterAgreementProtocol.{Base64Url, Canonicalization, Digest}

  def key({kid, public, _private}) do
    %{
      "key_id" => kid,
      "algorithm" => "Ed25519",
      "public_key" => Base64Url.encode(public),
      "status" => "active"
    }
  end

  def genesis(options \\ []) do
    {key_entry, private} = Keyword.fetch!(options, :key)
    kid = Keyword.get(options, :kid, key_entry["key_id"])

    claims =
      %{
        "protocol_revision" => 1,
        "descriptor_number" => 1,
        "verification_keys" => [key_entry],
        "attestation_hints" => [],
        "extensions" => %{"critical" => %{}, "optional" => %{}},
        "effective_from" => "2026-08-25T10:00:00Z"
      }
      |> Map.merge(Keyword.get(options, :claims, %{}))

    compact(claims, kid, private, options)
  end

  def compact(claims, kid, signing_private, options \\ []) do
    protected =
      Keyword.get(options, :protected, %{"alg" => "EdDSA", "typ" => "cap+party", "kid" => kid})

    payload_bytes = canonical!(claims)
    protected_bytes = canonical!(protected)
    protected_segment = Base64Url.encode(protected_bytes)
    payload_segment = Base64Url.encode(payload_bytes)
    message = protected_segment <> "." <> payload_segment
    signature = :crypto.sign(:eddsa, :none, message, [signing_private, :ed25519])
    compact = message <> "." <> Base64Url.encode(signature)
    digest = :party_descriptor_content |> Digest.hash(payload_bytes) |> Digest.to_tagged()

    %{
      compact: compact,
      claims: claims,
      digest: digest,
      party_id: digest,
      kid: kid,
      private: signing_private
    }
  end

  defp canonical!(plain) do
    {:ok, bytes} = Canonicalization.encode(tagged(plain))
    bytes
  end

  defp tagged(value) when is_map(value),
    do: {:object, Enum.map(value, fn {name, item} -> {name, tagged(item)} end)}

  defp tagged(value) when is_list(value), do: {:array, Enum.map(value, &tagged/1)}
  defp tagged(value) when is_binary(value), do: {:string, value}
  defp tagged(value) when is_integer(value), do: {:integer, value}
  defp tagged(value) when is_float(value), do: {:float, value}
  defp tagged(value) when is_boolean(value), do: {:boolean, value}
end

defmodule CharterAgreementSigner.CharterRevisionFixture do
  @moduledoc false

  alias CharterAgreementProtocol.{Canonicalization, Digest}

  @abp_content_digest "sha-256:b1Aw4cU5AbV9k8bdbZkRCsySDHGpTAwB-aQm57Wh7B8"
  @abp_deployment_digest "sha-256:tWFr0caS0AWFJd2UcB9gZv3kNjIUP8xZ08WWM_h8xgo"

  def abp_deployment_digest, do: @abp_deployment_digest

  def genesis(options \\ []) do
    legal_text = Keyword.get(options, :legal_text, "Example charter terms\n")

    claims =
      base_claims(legal_text)
      |> Map.merge(Keyword.get(options, :claims, %{}))

    from_claims(claims, legal_text)
  end

  def from_claims(claims, legal_text, options \\ []) do
    bytes = canonical!(claims)
    digest = tagged(:charter_revision_content, bytes)

    %{
      bytes: bytes,
      claims: claims,
      digest: digest,
      charter_id: Keyword.get(options, :charter_id, digest),
      legal_text: legal_text
    }
  end

  def base_claims(legal_text) do
    %{
      "protocol_revision" => 1,
      "revision_number" => 1,
      "parties" => [party("issuer"), party("acceptor")],
      "legal_text" => %{
        "content_digest" => tagged(:legal_text, legal_text),
        "media_type" => "text/plain",
        "uri_hint" => "https://example.com/charter.txt"
      },
      "precedence_declaration" => "legal_text_governs",
      "attribution_declaration" => %{"basis" => "bound_deployments"},
      "effective_from" => "2026-08-25T12:00:00Z",
      "termination_rules" => %{"reason_codes" => ["mutual", "breach"]},
      "abp_bindings" => [abp_binding("issuer")],
      "receipt_profile" => "com.example.charter/default",
      "extensions" => %{"critical" => %{}, "optional" => %{}}
    }
  end

  def party(role) do
    %{
      "party_descriptor_digest" => tagged(:party_descriptor_content, "party:" <> role),
      "role" => role
    }
  end

  defp abp_binding(role) do
    %{
      "party_role" => role,
      "blueprint_id" => "example.demo/echo",
      "release_number" => 1,
      "content_digest" => @abp_content_digest,
      "deployment_digest" => @abp_deployment_digest
    }
  end

  def tagged(domain, bytes), do: domain |> Digest.hash(bytes) |> Digest.to_tagged()

  defp canonical!(plain) do
    {:ok, bytes} = Canonicalization.encode(tagged_value(plain))
    bytes
  end

  defp tagged_value(value) when is_map(value),
    do: {:object, Enum.map(value, fn {name, item} -> {name, tagged_value(item)} end)}

  defp tagged_value(value) when is_list(value), do: {:array, Enum.map(value, &tagged_value/1)}
  defp tagged_value(value) when is_binary(value), do: {:string, value}
  defp tagged_value(value) when is_integer(value), do: {:integer, value}
  defp tagged_value(value) when is_boolean(value), do: {:boolean, value}
end

defmodule CharterAgreementSigner.AcceptanceFixture do
  @moduledoc false

  def claims(revision, descriptor, role, overrides \\ %{}) do
    revision_number = revision.claims["revision_number"]

    %{
      "protocol_revision" => 1,
      "charter_id" => revision.charter_id,
      "revision_number" => revision_number,
      "revision_digest" => revision.digest,
      "party_descriptor_digest" => descriptor.digest,
      "party_role" => role,
      "accepted_at" => "2026-08-25T13:00:00Z"
    }
    |> maybe_previous(revision_number, revision.claims["prev_revision_digest"])
    |> Map.merge(overrides)
  end

  defp maybe_previous(claims, 1, _previous), do: claims

  defp maybe_previous(claims, _number, previous),
    do: Map.put(claims, "prev_revision_digest", previous)
end

defmodule CharterAgreementSigner.TerminationFixture do
  @moduledoc false

  def claims(revision, descriptor, role, overrides \\ %{}) do
    %{
      "protocol_revision" => 1,
      "charter_id" => revision.charter_id,
      "governing_revision_digest" => revision.digest,
      "party_descriptor_digest" => descriptor.digest,
      "party_role" => role,
      "reason_code" => "mutual",
      "effective_at" => "2026-08-26T13:00:00Z",
      "issued_at" => "2026-08-25T13:00:00Z"
    }
    |> Map.merge(overrides)
  end
end

defmodule CharterAgreementSigner.ReceiptFixture do
  @moduledoc false

  alias CharterAgreementSigner.CharterRevisionFixture

  @grant_ath "5k224cZ_lMI9VoUZ_fYM31ZJAcnJiht0GYEpnhes_ZI"

  def claims(revision, overrides \\ %{}) do
    %{
      "protocol_revision" => 1,
      "charter_id" => revision.charter_id,
      "revision_number" => revision.claims["revision_number"],
      "revision_digest" => revision.digest,
      "issuing_party_role" => "issuer",
      "agent_party_role" => "issuer",
      "deployment_digest" => CharterRevisionFixture.abp_deployment_digest(),
      "grant" => %{
        "scheme" => "bap",
        "id" => "grant-2026-07-27-001",
        "grant_digest" => "sha-256:" <> @grant_ath
      },
      "invocation_id" => "123e4567-e89b-42d3-a456-426614174000",
      "decision" => "accepted",
      "outcome" => "effect_committed",
      "occurred_at" => "2026-08-25T12:00:00Z",
      "recorded_at" => "2026-08-25T12:00:01Z",
      "extensions" => %{"critical" => %{}, "optional" => %{}}
    }
    |> Map.merge(overrides)
  end
end

defmodule CharterAgreementSigner.ChainFixture do
  @moduledoc false

  alias CharterAgreementProtocol.{ArtifactSet, Base64Url, Canonicalization}

  alias CharterAgreementSigner.{
    AcceptanceFixture,
    CharterRevisionFixture,
    DescriptorFixture,
    Keys.RawKey,
    TerminationFixture
  }

  # The base bilateral setup: two party descriptors (issuer + acceptor),
  # each keyed by a test RawKey handle, plus the genesis revision binding
  # both parties by their descriptor digests.
  def base do
    issuer_handle = RawKey.generate("issuer-key-001", <<1::256>>)
    acceptor_handle = RawKey.generate("acceptor-key-001", <<2::256>>)

    issuer = descriptor(issuer_handle)
    acceptor = descriptor(acceptor_handle)

    genesis =
      CharterRevisionFixture.genesis(
        claims: %{
          "parties" => [
            %{"party_descriptor_digest" => issuer.digest, "role" => "issuer"},
            %{"party_descriptor_digest" => acceptor.digest, "role" => "acceptor"}
          ]
        }
      )

    %{
      issuer_handle: issuer_handle,
      acceptor_handle: acceptor_handle,
      issuer: issuer,
      acceptor: acceptor,
      genesis: genesis
    }
  end

  def descriptor(handle) do
    DescriptorFixture.genesis(key: {DescriptorFixture.key(handle), elem(handle, 2)})
  end

  # Claims entering a sign path mint at the emission revision — exactly what
  # a host does after CAP 0.2 (CAP's algorithm-name-agility ADR: new minting
  # is exactly ("Ed25519", 2), enforced at the producer's provisional decode).
  # The hand-built compacts below stay at revision 1 + "EdDSA" headers —
  # legacy held views — so the suite keeps proving cross-revision composition:
  # a freshly minted revision-2 signature over revision-1 views.
  def mint(claims), do: Map.put(claims, "protocol_revision", 2)

  # Acceptance/termination compacts for the fixture views — signed directly
  # with the handle's key (bypassing the signer, the way a counterparty's
  # artifacts arrive from outside).
  def acceptance(revision, descriptor, handle, role) do
    claims = AcceptanceFixture.claims(revision, descriptor, role)
    {claims, standalone_compact("cap+acceptance", claims, descriptor.kid, elem(handle, 2))}
  end

  def termination(revision, descriptor, handle, role, overrides \\ %{}) do
    claims = TerminationFixture.claims(revision, descriptor, role, overrides)
    {claims, standalone_compact("cap+termination", claims, descriptor.kid, elem(handle, 2))}
  end

  def dual_acceptances(revision, setup) do
    [
      elem(acceptance(revision, setup.issuer, setup.issuer_handle, "issuer"), 1),
      elem(acceptance(revision, setup.acceptor, setup.acceptor_handle, "acceptor"), 1)
    ]
  end

  def descriptors(setup), do: [setup.issuer.compact, setup.acceptor.compact]

  def raw_set(setup, revisions, acceptances, terminations) do
    ArtifactSet.build(
      Enum.map(revisions, & &1.bytes),
      acceptances,
      terminations,
      descriptors(setup)
    )
  end

  defp standalone_compact(typ, claims, kid, private) do
    protected_segment =
      canonical!(%{"alg" => "EdDSA", "kid" => kid, "typ" => typ}) |> Base64Url.encode()

    payload_segment = canonical!(claims) |> Base64Url.encode()
    message = protected_segment <> "." <> payload_segment
    signature = :crypto.sign(:eddsa, :none, message, [private, :ed25519])
    message <> "." <> Base64Url.encode(signature)
  end

  defp canonical!(plain) do
    {:ok, bytes} = Canonicalization.encode(tagged(plain))
    bytes
  end

  defp tagged(value) when is_map(value),
    do: {:object, Enum.map(value, fn {name, item} -> {name, tagged(item)} end)}

  defp tagged(value) when is_binary(value), do: {:string, value}
  defp tagged(value) when is_integer(value), do: {:integer, value}
end
