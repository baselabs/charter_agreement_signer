defmodule HexReleaseState do
  @moduledoc false

  alias Hex.API.Client

  # Only the standalone planner needs the Hex archive's release API.
  @compile {:no_warn_undefined, [Client, :mix_hex_api_release]}

  @pending "held for approval or not yet served: after the owner approves, dispatch publish.yml again on this same commit to recheck the served state; publication refused"
  @usage "usage: hex_release_state.exs (--plan | --served --commit SHA --clone REPOSITORY --docs-output PATH [--docs-state STATE]) [--organization ORG] NAME VERSION PACKAGE_TAR; publication refused"

  def main(argv) do
    if Mix.Project.get() do
      refuse("a Mix project is loaded; run from a directory without mix.exs")
    end

    {opts, name, version, package_tar} = parse!(argv)
    Hex.start()
    Code.ensure_loaded!(Hex.Repo)
    organization = opts[:organization]
    repo = if organization, do: "hexpm:" <> organization, else: "hexpm"
    tar = File.read!(package_tar)
    package = package_state(repo, name, version, tar)

    release = if organization, do: :upload_step, else: read_public_release(name, version)
    checksum = :crypto.hash(:sha256, tar) |> Base.encode16(case: :lower)
    docs = docs_state!(opts, release, package, version, checksum)

    if opts[:served] do
      unless package == "served" and docs == "served", do: raise(@pending)
      archive = read_docs_archive!(repo, name, version)
      commit = readback_docs!(archive, name, version, opts)
      write_output("package=#{package}\ndocs=#{docs}\ncommit=#{commit}\n")
    else
      write_output("package=#{package}\ndocs=#{docs}\n")
    end
  end

  def parse!(argv) do
    case OptionParser.parse(argv,
           strict: [
             plan: [:boolean, :keep],
             served: [:boolean, :keep],
             organization: [:string, :keep],
             commit: [:string, :keep],
             clone: [:string, :keep],
             docs_output: [:string, :keep],
             docs_state: [:string, :keep]
           ]
         ) do
      {opts, [name, version, package_tar], []} ->
        validate_options!(opts)
        {opts, name, version, package_tar}

      _ ->
        raise @usage
    end
  end

  def inspect_docs!(archive, name, version) do
    entries = unpack_docs!(archive)
    root_file!(entries, "index.html")
    record = entries |> root_file!("release.json") |> decode_record!()

    case record do
      %{"package" => ^name, "version" => ^version, "commit" => commit}
      when map_size(record) == 3 ->
        require_commit!(commit, "release.json commit")
        commit

      _ ->
        refuse(
          "served docs release.json must contain exactly package=#{name}, version=#{version} and commit"
        )
    end
  end

  def verify_ancestry!(published, dispatched, clone) do
    require_commit!(published, "published commit")
    require_commit!(dispatched, "dispatched commit")

    unless match?({_, 0}, git(clone, ["rev-parse", "--git-dir"])) do
      refuse("git could not open the repository clone for docs ancestry")
    end

    require_git_commit!(clone, published)
    require_git_commit!(clone, dispatched)

    case git(clone, ["merge-base", "--is-ancestor", published, dispatched]) do
      {_, 0} -> :ok
      {_, 1} -> refuse("served docs commit is not the dispatched commit or its ancestor")
      _ -> refuse("git could not check served docs commit ancestry")
    end
  end

  def readback_docs!(archive, name, version, opts) do
    commit = inspect_docs!(archive, name, version)
    verify_ancestry!(commit, opts[:commit], opts[:clone])

    case File.write(opts[:docs_output], archive) do
      :ok -> commit
      {:error, _} -> refuse("could not write the served docs archive")
    end
  end

  defp validate_options!(opts) do
    if length(Keyword.keys(opts)) != length(Enum.uniq(Keyword.keys(opts))) do
      raise @usage
    end

    case {opts[:plan], opts[:served]} do
      {true, nil} ->
        if Enum.any?([:commit, :clone, :docs_output, :docs_state], &Keyword.has_key?(opts, &1)) do
          raise @usage
        end

      {nil, true} ->
        require_docs_state!(opts)
        require_commit!(opts[:commit], "--commit")
        require_paths!(opts)

      _ ->
        raise @usage
    end
  end

  defp require_docs_state!(opts) do
    case {opts[:organization], opts[:docs_state]} do
      {nil, nil} -> :ok
      {org, state} when is_binary(org) and state in ["served", "staged"] -> :ok
      _ -> refuse("--docs-state must carry the private upload step's served or staged result")
    end
  end

  defp require_paths!(opts) do
    unless is_binary(opts[:clone]) and String.trim(opts[:clone]) != "" and
             File.dir?(opts[:clone]) do
      refuse("--clone must name a readable repository clone")
    end

    unless match?({_, 0}, git(opts[:clone], ["rev-parse", "--git-dir"])) do
      refuse("--clone must name a readable repository clone")
    end

    path = opts[:docs_output]

    unless is_binary(path) and String.trim(path) != "" and not File.dir?(path) and
             File.dir?(Path.dirname(path)) do
      refuse("--docs-output must name a file in an existing directory")
    end
  end

  defp require_commit!(commit, label) do
    unless is_binary(commit) and Regex.match?(~r/\A[0-9a-f]{40}\z/, commit) do
      refuse("#{label} must be 40 lowercase hexadecimal characters")
    end
  end

  defp unpack_docs!(<<0x1F, 0x8B, _::binary>> = archive) do
    case :erl_tar.extract({:binary, archive}, [:compressed, :memory]) do
      {:ok, entries} -> entries
      _ -> refuse("served docs are not a readable gzip tar archive")
    end
  end

  defp unpack_docs!(_archive),
    do: refuse("served docs are not a readable gzip tar archive")

  defp root_file!(entries, path) do
    case Enum.filter(entries, fn {entry, _} -> normalize_entry(entry) == path end) do
      [{_, bytes}] when is_binary(bytes) -> bytes
      [] -> refuse("served docs have no root #{path}")
      _ -> refuse("served docs have ambiguous root #{path} entries")
    end
  end

  defp normalize_entry(entry) do
    entry |> to_string() |> String.replace(~r/\A(?:\.\/)+/, "")
  end

  defp decode_record!(bytes) do
    case JSON.decode(bytes, :ok, object_finish: &decode_object/2) do
      {record, :ok, ""} -> record
      _ -> refuse("served docs release.json is not readable JSON")
    end
  end

  defp decode_object(pairs, acc) do
    record = Map.new(pairs)

    unless map_size(record) == length(pairs) do
      refuse("served docs release.json has duplicate members")
    end

    {record, acc}
  end

  defp require_git_commit!(clone, commit) do
    case git(clone, ["cat-file", "-t", commit]) do
      {"commit\n", 0} -> :ok
      {_, 0} -> refuse("docs ancestry object #{commit} is not a commit in the clone")
      {_, 128} -> refuse("docs ancestry commit #{commit} is missing from the clone")
      _ -> refuse("git could not read docs ancestry commit #{commit} from the clone")
    end
  end

  defp git(clone, args) do
    System.cmd("git", ["-C", clone | args], stderr_to_stdout: true)
  rescue
    _ -> refuse("git could not run in the repository clone")
  end

  defp package_state(repo, name, version, tar) do
    case read(fn -> Hex.Repo.get_package(repo, name, nil) end) do
      {:ok, {200, _headers, %{releases: releases}}} when is_list(releases) ->
        releases |> Enum.find(&(&1.version == version)) |> release_state(name, version, tar)

      {:ok, {404, _headers, _body}} ->
        refuse("#{repo} has no package #{name}; a first publication is the owner's decision")

      result ->
        refuse_read(result, "#{repo} package #{name}")
    end
  end

  defp release_state(nil, _name, _version, _tar), do: "upload"

  defp release_state(release, name, version, tar) do
    if Map.has_key?(release, :retired) do
      refuse("#{name} #{version} is retired")
    end

    unless release[:outer_checksum] == :crypto.hash(:sha256, tar) do
      refuse("#{name} #{version}: registry outer checksum differs from package archive")
    end

    "served"
  end

  defp read_public_release(name, version) do
    read(fn ->
      config =
        Client.build_config(nil, [])
        |> Map.update!(:http_headers, &Map.put(&1, "cache-control", "no-cache"))

      :mix_hex_api_release.get(config, name, version)
    end)
  end

  def docs_state!(opts, :upload_step, package, _version, _checksum) do
    case {opts[:plan], opts[:docs_state], package} do
      {true, nil, _} -> "check"
      {nil, "served", "served"} -> "served"
      _ -> raise @pending
    end
  end

  def docs_state!(_opts, release, package, version, checksum),
    do: public_docs_state!(release, package, version, checksum)

  defp public_docs_state!({:ok, {404, _headers, _body}}, "upload", _version, _checksum),
    do: "upload"

  defp public_docs_state!(
         {:ok,
          {200, _headers,
           %{
             "version" => version,
             "checksum" => checksum,
             "retirement" => nil,
             "has_docs" => has_docs
           }}},
         "served",
         version,
         checksum
       )
       when is_boolean(has_docs),
       do: if(has_docs, do: "served", else: "upload")

  defp public_docs_state!(_result, _package, _version, _checksum),
    do: refuse("Hex release API did not confirm the registry package and its docs state")

  defp read_docs_archive!(repo, name, version) do
    case read(fn -> Hex.Repo.get_docs(repo, name, version) end) do
      {:ok, {200, _headers, archive}} when is_binary(archive) -> archive
      result -> refuse_read(result, "#{repo} docs #{name} #{version}")
    end
  end

  defp read(request) do
    request.()
  rescue
    _ -> :read_error
  catch
    _, _ -> :read_error
  end

  defp refuse_read({:ok, {code, _headers, _body}}, label) do
    refuse("#{label}: registry answered HTTP #{code} or an invalid response")
  end

  defp refuse_read(_result, label), do: refuse("#{label}: registry read failed")

  defp write_output(output) do
    File.write!(System.fetch_env!("GITHUB_OUTPUT"), output, [:append])
    IO.write(output)
  end

  defp refuse(message), do: raise("#{message}; publication refused")
end
