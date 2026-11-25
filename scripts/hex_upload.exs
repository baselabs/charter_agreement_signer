# Upload only verified archives with Hex 2.7.0, with no project loaded or rebuilt.
# Run from a directory without mix.exs:
#   mix run --no-mix-exs PATH/hex_upload.exs [--package] [--docs] [--organization ORG] NAME VERSION PACKAGE_TAR DOCS_TAR
defmodule HexUpload do
  @moduledoc false

  alias Hex.API.{Client, Package, Release, ReleaseDocs}

  # The standalone uploader loads the pinned Hex archive. The pure tests need no Hex client.
  @compile {:no_warn_undefined,
            [
              Client,
              Package,
              Release,
              ReleaseDocs,
              Hex.State,
              Hex.Tar,
              Hex.Utils,
              :mix_hex_api_release
            ]}

  @hex_media "application/vnd.hex+erlang"

  def main(argv) do
    if Mix.Project.get() do
      raise "a Mix project is loaded; run from a directory without mix.exs"
    end

    case OptionParser.parse(argv,
           strict: [package: :boolean, docs: :boolean, organization: :string]
         ) do
      {opts, [name, version, package_tar, docs_tar], []} ->
        unless opts[:package] || opts[:docs], do: raise("choose --package, --docs, or both")
        upload(opts, name, version, package_tar, docs_tar)

      _ ->
        raise "usage: hex_upload.exs [--package] [--docs] [--organization ORG] NAME VERSION PACKAGE_TAR DOCS_TAR"
    end
  end

  defp upload(opts, name, version, package_tar, docs_tar) do
    package = File.read!(package_tar)
    docs = if opts[:docs], do: File.read!(docs_tar)
    repo = opts[:organization]

    if repo && docs do
      with_docs_output!(System.get_env("GITHUB_OUTPUT"), fn output ->
        run_upload(opts, repo, name, version, package, docs, output)
      end)
    else
      run_upload(opts, repo, name, version, package, docs, nil)
    end
  end

  def with_docs_output!(path, upload) do
    with true <- is_binary(path) and path != "",
         {:ok, %{type: :regular}} <- File.stat(path),
         {:ok, output} <- File.open(path, [:append, :binary]) do
      try do
        upload.(output)
      after
        File.close(output)
      end
    else
      _ -> raise "private docs upload requires a writable GITHUB_OUTPUT file; upload refused"
    end
  end

  defp run_upload(opts, repo, name, version, package, docs, output) do
    Hex.start()
    %{metadata: metadata} = Hex.Tar.unpack!({:binary, package}, :memory)

    unless metadata["name"] == name and metadata["version"] == version do
      raise "package metadata name or version differs from the requested release; upload refused"
    end

    publish_key = require_key!("HEX_API_KEY")
    read_key = if repo, do: require_key!("HEX_ORG_KEY_PUBLISH_API_READ")
    publish_auth = [key: publish_key]
    read_auth = if repo, do: [key: read_key], else: []

    state = %{
      repo: repo,
      name: name,
      version: version,
      checksum: digest(package),
      docs_checksum: if(docs, do: digest(docs)),
      api_url: Hex.State.fetch!(:api_url),
      secrets: Enum.reject([publish_key, read_key], &is_nil/1)
    }

    # An existing package establishes access before a private release 404
    # can authorize a write, and rules out first publication on every registry.
    request(fn -> Package.get(repo, name, read_auth) end) |> confirm_org_read!(name)

    package_result =
      if opts[:package] do
        upload_package!(state, package, read_auth, publish_auth)
      else
        :live
      end

    if docs do
      result = upload_docs!(state, docs, publish_auth, read_auth, package_result)
      IO.puts("docs=#{result}")

      if output do
        docs_state = private_docs_state!(result, state, read_auth)

        unless IO.binwrite(output, "docs=#{docs_state}\n") == :ok do
          raise "could not record private docs upload state in GITHUB_OUTPUT"
        end
      end
    end
  end

  defp require_key!(name) do
    key = System.get_env(name, "")
    if String.trim(key) == "", do: raise("#{name} is empty; upload refused")
    key
  end

  def confirm_org_read!({:ok, {200, _headers, %{"name" => name}}}, name), do: :ok

  def confirm_org_read!(_response, _name),
    do: raise("Hex did not confirm organization package read access; upload refused")

  defp upload_package!(state, package, read_auth, publish_auth) do
    stage = read_stage(state, "release", publish_auth) |> pending_stage!("release", state)
    release = read_release(state.repo, state.name, state.version, read_auth)

    case package_preflight!(stage, release, state) do
      :pending ->
        :pending

      :skip ->
        :live

      :upload ->
        response =
          request(fn ->
            Release.publish(state.repo, package, publish_auth, fn _ -> :ok end, replace: false)
          end)

        case package_receipt(response, state) do
          {:ok, result} ->
            result

          :ambiguous ->
            release = read_release(state.repo, state.name, state.version, read_auth)
            reconcile_package!(response, release, state)
        end
    end
  end

  def package_preflight!(:pending, release, %{version: version, checksum: checksum}) do
    served_release!(release, version, checksum)
    :pending
  end

  def package_preflight!(:missing, release, %{version: version, checksum: checksum}) do
    case served_release!(release, version, checksum) do
      :missing -> :upload
      {:served, _} -> :skip
    end
  end

  # The insert Location is relative even for an organization. The release
  # body URL and the staged receipt identify the organization explicitly.
  # https://github.com/hexpm/hexpm/blob/5e638200/lib/hexpm_web/controllers/api/release_controller.ex#L222-L244
  def package_receipt({:ok, {201, %{"location" => location} = headers, body}}, state) do
    cond do
      not hex_media?(headers) ->
        :ambiguous

      location == stage_url(state, "release") and
          stage_matches?(body, "release", state.checksum, state) ->
        {:ok, {:staged, body}}

      location == "/api/" <> encode_path(release_path(%{state | repo: nil})) and
          live_package_receipt?(body, state) ->
        {:ok, :live}

      true ->
        :ambiguous
    end
  end

  def package_receipt(_response, _state), do: :ambiguous

  defp live_package_receipt?(
         %{
           "version" => version,
           "checksum" => checksum,
           "retirement" => nil,
           "has_docs" => false,
           "url" => url
         },
         %{version: version, checksum: checksum} = state
       ),
       do: url == state.api_url <> "/" <> encode_path(release_path(state))

  defp live_package_receipt?(_body, _state), do: false

  def reconcile_package!(failure, release, state) do
    case package_preflight!(:missing, release, state) do
      :skip ->
        IO.puts("package=served")
        :live

      :upload ->
        successful!(failure, "package", state.secrets)
        raise "Hex returned an invalid package upload receipt; no matching release is served"
    end
  end

  defp upload_docs!(_state, _docs, _publish_auth, _read_auth, :pending), do: :staged

  defp upload_docs!(state, docs, publish_auth, read_auth, package_result) do
    %{repo: repo, name: name, version: version} = state

    target =
      case package_result do
        {:staged, receipt} ->
          unless stage_matches?(receipt, "release", state.checksum, state) do
            raise "Hex did not return a stage URL for this package archive; docs were not posted"
          end

          :staged

        :live ->
          :live
      end

    # Hex restricts the staged receipt to the staging credential or an eligible
    # approver (hexpm 5e638200, staged_releases.ex:368–371). The private release
    # GET uses the separate API-read key. Keep that GET last before the POST.
    requests = %{
      read_stage: fn -> read_stage(state, "release", publish_auth) end,
      read_docs_stage: fn -> read_stage(state, "docs", publish_auth) end,
      read_release: fn -> read_release(repo, name, version, read_auth) end,
      post_docs: fn -> post_docs(state, docs, publish_auth) end
    }

    state = Map.merge(state, %{target: target, package_receipt: package_result})
    run_docs!(docs_steps(target), state, requests)
  end

  def docs_steps(:staged),
    do: [:read_stage, :check_stage, :read_release, :check_release, :post_docs, :check_receipt]

  def docs_steps(:live),
    do: [
      :read_stage,
      :check_stage,
      :read_docs_stage,
      :check_docs_stage,
      :read_release,
      :check_release,
      :post_docs,
      :check_receipt
    ]

  defp run_docs!(steps, state, requests) do
    case next_docs_step!(steps, state) do
      {:request, step, remaining} ->
        response = Map.fetch!(requests, step).()
        run_docs!(remaining, Map.put(state, :response, response), requests)

      result ->
        result
    end
  end

  def next_docs_step!([step | remaining], _state)
      when step in [:read_stage, :read_docs_stage, :read_release, :post_docs],
      do: {:request, step, remaining}

  def next_docs_step!([:check_stage | remaining], %{target: :staged} = state) do
    {:staged, receipt} = state.package_receipt

    case pending_stage!(state.response, "release", state) do
      :pending ->
        {:ok, {200, _, current}} = state.response

        # The new package receipt is the baseline with no attached docs.
        # Hex hashes the docs checksum into approval_checksum.
        if current["approval_checksum"] == receipt["approval_checksum"] do
          next_docs_step!(remaining, state)
        else
          :staged
        end

      :missing ->
        raise "Hex did not confirm an active stage for this package archive; docs were not posted"
    end
  end

  def next_docs_step!([:check_stage | remaining], %{target: :live} = state) do
    case pending_stage!(state.response, "release", state) do
      :missing -> next_docs_step!(remaining, state)
      :pending -> :staged
    end
  end

  def next_docs_step!([:check_docs_stage | remaining], state) do
    case pending_stage!(state.response, "docs", state) do
      :missing -> next_docs_step!(remaining, state)
      :pending -> :staged
    end
  end

  def next_docs_step!([:check_release | remaining], %{target: :staged} = state) do
    unpublished!(state.response, state.version, state.checksum)
    next_docs_step!(remaining, state)
  end

  def next_docs_step!([:check_release | remaining], %{target: :live} = state) do
    case live_docs!(state.response, state.version, state.checksum) do
      :skip -> :skipped
      :upload -> next_docs_step!(remaining, state)
    end
  end

  def next_docs_step!([:check_receipt], state) do
    state.response
    |> successful!("docs", state.secrets)
    |> docs_receipt!(state)
  end

  def pending_stage!({:ok, {404, _, _}}, _kind, _state), do: :missing

  def pending_stage!({:ok, {200, _, %{"status" => status} = body}}, kind, state)
      when status in ["staged", "approved", "rejected", "expired"] do
    checksum =
      if kind == "release" and status == "staged", do: state.checksum, else: body["checksum"]

    unless stage_matches?(Map.put(body, "status", "staged"), kind, checksum, state) do
      raise "Hex did not confirm an active stage for this package archive; upload refused"
    end

    if status == "staged", do: :pending, else: :missing
  end

  def pending_stage!(response, _kind, _state), do: refuse_read!("Hex stage", response)

  defp private_docs_state!(:staged, _state, _read_auth), do: "staged"
  defp private_docs_state!(:skipped, _state, _read_auth), do: "served"

  defp private_docs_state!(:accepted, state, read_auth) do
    response = read_release(state.repo, state.name, state.version, read_auth)

    case served_release!(response, state.version, state.checksum) do
      {:served, true} -> "served"
      _ -> raise "Hex did not confirm served docs after accepting the archive"
    end
  end

  defp read_release(repo, name, version, auth) do
    request(fn ->
      config =
        Client.build_config(repo, auth)
        |> Map.update!(:http_headers, &Map.put(&1, "cache-control", "no-cache"))

      :mix_hex_api_release.get(config, name, version)
    end)
  end

  defp read_stage(state, kind, auth) do
    request(fn -> Release.get_staged(stage_url(state, kind), auth) end)
  end

  defp refuse_read!(label, {:ok, {status, _, _}}),
    do: raise("#{label} could not be verified (HTTP #{status}); upload refused")

  defp refuse_read!(label, _response),
    do: raise("#{label} read failed; upload refused")

  defp live_docs!(result, version, checksum) do
    case served_release!(result, version, checksum, "docs were not posted") do
      {:served, false} -> :upload
      {:served, true} -> :skip
      :missing -> raise "Hex does not serve this package yet; docs were not posted"
    end
  end

  defp unpublished!(result, version, checksum) do
    case served_release!(result, version, checksum, "docs were not posted") do
      :missing -> :ok
      {:served, _} -> raise "Hex already serves this release; staged docs were not posted"
    end
  end

  defp served_release!(result, version, checksum, refusal \\ "upload refused")

  defp served_release!({:ok, {404, _headers, _body}}, _version, _checksum, _refusal),
    do: :missing

  defp served_release!(
         {:ok, {200, _headers, %{"version" => version, "retirement" => nil} = release}},
         version,
         checksum,
         refusal
       ) do
    unless release["checksum"] == checksum do
      raise "Hex serves this release with other package bytes; #{refusal}"
    end

    has_docs = release["has_docs"]

    unless is_boolean(has_docs) do
      raise "Hex returned no definite documentation state; #{refusal}"
    end

    {:served, has_docs}
  end

  defp served_release!({:ok, {status, _, _}}, _version, _checksum, refusal),
    do: raise("Could not confirm an unretired Hex release (HTTP #{status}); #{refusal}")

  defp served_release!(_result, _version, _checksum, refusal),
    do: raise("Could not read the Hex release; #{refusal}")

  defp stage_matches?(
         %{
           "name" => name,
           "version" => version,
           "status" => "staged",
           "kind" => kind,
           "checksum" => checksum,
           "url" => url,
           "approval_checksum" => approval_checksum
         },
         kind,
         checksum,
         %{name: name, version: version} = state
       ),
       do:
         url == stage_url(state, kind) and digest_string?(checksum) and
           digest_string?(approval_checksum)

  defp stage_matches?(_body, _kind, _checksum, _state), do: false

  defp digest_string?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp stage_url(state, kind) do
    state.api_url <> "/" <> encode_path(scoped_stage_path(state, kind))
  end

  defp scoped_stage_path(%{repo: nil} = state, kind), do: stage_path(state, kind)
  defp scoped_stage_path(state, kind), do: ["repos", state.repo | stage_path(state, kind)]

  defp encode_path(path),
    do: Enum.map_join(path, "/", &URI.encode(&1, fn byte -> URI.char_unreserved?(byte) end))

  defp stage_path(state, "release"), do: release_path(%{state | repo: nil}) ++ ["staged"]
  defp stage_path(state, "docs"), do: release_path(%{state | repo: nil}) ++ ["docs", "staged"]

  defp release_path(%{repo: repo, name: name, version: version}) do
    path = ["packages", name, "releases", version]
    if repo, do: ["repos", repo | path], else: path
  end

  defp post_docs(state, docs, auth) do
    request(fn -> ReleaseDocs.publish(state.repo, state.name, state.version, docs, auth) end)
  end

  defp hex_media?(headers) do
    headers |> Map.get("content-type", "") |> String.split(";", parts: 2) |> hd() == @hex_media
  end

  # The pinned Hex client reports an untyped response body as nil.
  # https://github.com/hexpm/hex/blob/92cb6a1/src/mix_hex_api.erl#L113-L128
  defp docs_receipt!({201, %{"location" => url} = headers, nil}, %{target: :live} = state)
       when not is_map_key(headers, "content-type") do
    expected = docs_tarball_url(state)
    if url != expected, do: raise("Hex returned an unexpected docs tarball location")
    :accepted
  end

  defp docs_receipt!({201, %{"location" => url} = headers, %{"url" => url} = body}, state) do
    {kind, checksum} =
      if state.target == :staged,
        do: {"release", state.checksum},
        else: {"docs", state.docs_checksum}

    unless hex_media?(headers) and stage_matches?(body, kind, checksum, state) do
      raise "Hex returned an unexpected docs upload receipt"
    end

    :staged
  end

  defp docs_receipt!(_result, _state),
    do: raise("Hex returned an unexpected docs upload receipt")

  defp docs_tarball_url(%{repo: repo, name: name, version: version}) do
    prefix = if repo, do: "https://repo.hex.pm/repos/#{repo}", else: "https://repo.hex.pm"
    "#{prefix}/docs/#{name}-#{version}.tar.gz"
  end

  defp digest(archive), do: :crypto.hash(:sha256, archive) |> Base.encode16(case: :lower)

  defp request(upload) do
    upload.()
  rescue
    _ -> :upload_error
  catch
    _, _ -> :upload_error
  end

  defp successful!({:ok, {code, _headers, _body} = receipt}, _label, _secrets)
       when code in 200..299,
       do: receipt

  defp successful!({:ok, {code, _headers, body}}, label, secrets) do
    message = if is_map(body), do: body["message"]

    if is_binary(message) and String.valid?(message) do
      safe_message =
        secrets
        |> Enum.sort_by(&byte_size/1, :desc)
        |> Enum.reduce(message, &String.replace(&2, &1, "[REDACTED]"))
        |> Hex.Utils.escape_terminal()

      raise "#{label} upload refused (HTTP #{code}): #{safe_message}"
    end

    raise "#{label} upload refused (HTTP #{code})"
  end

  defp successful!(_result, label, _secrets),
    do: raise("#{label} upload failed; no response body logged")
end

HexUpload.main(System.argv())
