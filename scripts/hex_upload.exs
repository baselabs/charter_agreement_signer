# Upload only verified archives with Hex 2.7.0, with no project loaded or rebuilt.
# Run from a directory without mix.exs:
#   mix run --no-mix-exs PATH/hex_upload.exs [--package] [--docs] [--organization ORG] NAME VERSION PACKAGE_TAR DOCS_TAR
defmodule HexUpload do
  @moduledoc false

  alias Hex.API.Client

  # The standalone uploader loads the pinned Hex archive. The pure tests need no Hex client.
  @compile {:no_warn_undefined,
            [
              Client,
              Hex.State,
              Hex.Tar,
              Hex.Utils,
              :mix_hex_api,
              :mix_hex_api_package,
              :mix_hex_api_release,
              :mix_hex_http,
              :mix_hex_safe_binary_to_term
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
    Hex.start()
    package = File.read!(package_tar)
    docs = if opts[:docs], do: File.read!(docs_tar)
    checksum = digest(package)
    %{metadata: metadata} = Hex.Tar.unpack!({:binary, package}, :memory)

    unless metadata["name"] == name and metadata["version"] == version do
      raise "package metadata name or version differs from the requested release; upload refused"
    end

    repo = opts[:organization]
    publish_key = require_key!("HEX_API_KEY")
    read_key = if repo, do: require_key!("HEX_ORG_KEY_PUBLISH_API_READ")
    publish_auth = [key: publish_key]
    read_auth = if repo, do: [key: read_key], else: []
    secrets = Enum.reject([publish_key, read_key], &is_nil/1)

    if repo do
      # Hex hides private packages from outside readers as 404. Establish read
      # access before a release 404 can authorize posting docs against a stage.
      config = api_config(repo, read_auth)
      request(fn -> :mix_hex_api_package.get(config, name) end) |> confirm_org_read!(name)
    end

    package_result =
      if opts[:package], do: upload_package!(repo, package, publish_auth, secrets), else: :live

    if docs do
      state = %{
        repo: repo,
        name: name,
        version: version,
        checksum: checksum,
        docs_checksum: digest(docs),
        api_url: Hex.State.fetch!(:api_url),
        secrets: secrets
      }

      result = upload_docs!(state, docs, publish_auth, read_auth, package_result)
      IO.puts("docs=#{result}")

      if repo do
        docs_state = private_docs_state!(result, state, read_auth)
        File.write!(System.fetch_env!("GITHUB_OUTPUT"), "docs=#{docs_state}\n", [:append])
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

  defp upload_package!(repo, package, auth, secrets) do
    config = api_config(repo, auth)

    {_code, _headers, body} =
      request(fn -> :mix_hex_api_release.publish(config, package, replace: false) end)
      |> successful!("package", secrets)

    case body do
      %{"status" => "staged"} ->
        IO.puts("package=staged")
        {:staged, body}

      _ ->
        IO.puts("package=accepted")
        :live
    end
  end

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
      read_stage: fn -> read_stage(state, publish_auth) end,
      read_release: fn -> read_release(repo, name, version, read_auth) end,
      post_docs: fn -> post_docs(repo, name, version, docs, publish_auth) end
    }

    state = Map.put(state, :target, target)
    run_docs!(docs_steps(target), state, requests)
  end

  def docs_steps(:staged),
    do: [:read_stage, :check_stage, :read_release, :check_release, :post_docs, :check_receipt]

  def docs_steps(:live), do: [:read_release, :check_release, :post_docs, :check_receipt]

  defp run_docs!(steps, state, requests) do
    case next_docs_step!(steps, state) do
      {:request, step, remaining} ->
        response = request(Map.fetch!(requests, step))
        run_docs!(remaining, Map.put(state, :response, response), requests)

      result ->
        result
    end
  end

  def next_docs_step!([step | remaining], _state)
      when step in [:read_stage, :read_release, :post_docs],
      do: {:request, step, remaining}

  def next_docs_step!([:check_stage | remaining], %{response: response} = state) do
    with {:ok, {200, _headers, body}} <- response,
         true <- stage_matches?(body, "release", state.checksum, state) do
      next_docs_step!(remaining, state)
    else
      _ ->
        raise "Hex did not confirm an active stage for this package archive; docs were not posted"
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

  defp private_docs_state!(:staged, _state, _read_auth), do: "staged"
  defp private_docs_state!(:skipped, _state, _read_auth), do: "served"

  defp private_docs_state!(:accepted, state, read_auth) do
    response = request(fn -> read_release(state.repo, state.name, state.version, read_auth) end)

    case served_release!(response, state.version, state.checksum) do
      {:served, true} -> "served"
      _ -> raise "Hex did not confirm served docs after accepting the archive"
    end
  end

  defp read_release(repo, name, version, auth) do
    config = api_config(repo, auth)
    :mix_hex_api_release.get(config, name, version)
  end

  defp read_stage(state, auth) do
    config = api_config(state.repo, auth)
    :mix_hex_api.get(config, stage_path(state, "release"))
  end

  defp api_config(repo, auth) do
    Client.build_config(repo, auth)
    |> Map.put(:http_adapter, http_adapter())
    |> Map.update!(:http_headers, &Map.put(&1, "cache-control", "no-cache"))
  end

  # Hex.HTTP wraps :httpc with its own redirect loop. The pinned Hex archive's
  # vendored transport passes http_options to :httpc without that loop.
  # https://github.com/hexpm/hex/blob/92cb6a1/src/mix_hex_http_httpc.erl#L30-L44
  # https://github.com/hexpm/hex/blob/92cb6a1/src/mix_hex_http_httpc.erl#L106-L137
  def http_adapter,
    do: {:mix_hex_http_httpc, %{http_options: [autoredirect: false, timeout: 15_000]}}

  defp live_docs!(result, version, checksum) do
    case served_release!(result, version, checksum) do
      {:served, false} -> :upload
      {:served, true} -> :skip
      :missing -> raise "Hex does not serve this package yet; docs were not posted"
    end
  end

  defp unpublished!(result, version, checksum) do
    case served_release!(result, version, checksum) do
      :missing -> :ok
      {:served, _} -> raise "Hex already serves this release; staged docs were not posted"
    end
  end

  defp served_release!({:ok, {404, _headers, _body}}, _version, _checksum), do: :missing

  defp served_release!(
         {:ok, {200, _headers, %{"version" => version, "retirement" => nil} = release}},
         version,
         checksum
       ) do
    unless release["checksum"] == checksum do
      raise "Hex serves this release with other package bytes; docs were not posted"
    end

    has_docs = release["has_docs"]

    unless is_boolean(has_docs) do
      raise "Hex returned no definite documentation state; docs were not posted"
    end

    {:served, has_docs}
  end

  defp served_release!(_result, _version, _checksum),
    do: raise("Could not confirm an unretired Hex release; docs were not posted")

  defp stage_matches?(
         %{
           "name" => name,
           "version" => version,
           "status" => "staged",
           "kind" => kind,
           "checksum" => checksum,
           "url" => url
         },
         kind,
         checksum,
         %{name: name, version: version} = state
       ),
       do: url == stage_url(state, kind)

  defp stage_matches?(_body, _kind, _checksum, _state), do: false

  defp stage_url(state, kind) do
    path =
      Enum.map_join(
        stage_path(state, kind),
        "/",
        &URI.encode(&1, fn byte -> URI.char_unreserved?(byte) end)
      )

    state.api_url <> "/" <> path
  end

  defp stage_path(state, "release"), do: release_path(state) ++ ["staged"]
  defp stage_path(state, "docs"), do: release_path(state) ++ ["docs", "staged"]

  defp release_path(%{repo: repo, name: name, version: version}) do
    path = ["packages", name, "releases", version]
    if repo, do: ["repos", repo | path], else: path
  end

  defp post_docs(repo, name, version, docs, auth) do
    config = api_config(repo, auth)

    path =
      :mix_hex_api.build_repository_path(config, ["packages", name, "releases", version, "docs"])

    url = config.api_url <> "/" <> :mix_hex_api.join_path_segments(path)

    headers =
      Map.merge(config.http_headers, %{
        "accept" => @hex_media,
        "authorization" => config.api_key,
        "content-length" => Integer.to_string(byte_size(docs))
      })

    # Keep the wire body for the bare 201. mix_hex_api.post/3 discards it
    # when the response lacks the Hex media type.
    config
    |> :mix_hex_http.request(:post, url, headers, {~c"application/octet-stream", docs})
    |> decode_receipt()
  end

  defp decode_receipt({:ok, {code, headers, body}} = response) do
    if hex_media?(headers) do
      with {:ok, decoded} <- :mix_hex_safe_binary_to_term.safe_binary_to_term(body) do
        {:ok, {code, headers, decoded}}
      end
    else
      response
    end
  end

  defp decode_receipt(response), do: response

  defp hex_media?(headers) do
    headers |> Map.get("content-type", "") |> String.split(";", parts: 2) |> hd() == @hex_media
  end

  defp docs_receipt!({201, %{"location" => url} = headers, ""}, %{target: :live} = state)
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
