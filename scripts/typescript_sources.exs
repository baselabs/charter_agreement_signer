# Pinned public TypeScript sources for the signer check. Modeled on CAP's
# scripts/verifier_source.exs. Extract each commit with git archive and check
# every blob before installing it. Public main reachability and forward-only
# pins are checked even in cached mode, against the last fetched public ref.

defmodule CharterAgreementSigner.TypeScriptSources do
  @moduledoc false

  @root Path.expand("..", __DIR__)
  # Fetches into the cache must not start git's detached background maintenance
  # (from git 2.54), which keeps writing into the cache after the command returns.
  @no_maintenance ["-c", "maintenance.auto=false", "-c", "gc.auto=0"]
  @sources %{
    signer: "https://github.com/baselabs/charter_agreement_signer_typescript.git",
    verifier: "https://github.com/baselabs/charter_agreement_protocol_typescript.git"
  }

  def path(kind), do: "_build/#{kind}-source"
  defp pin_path(kind), do: "priv/#{kind}-source.json"
  defp stamp_path(kind), do: path(kind) <> ".commit"

  def pin!(kind) do
    repository = Map.fetch!(@sources, kind)

    allowed =
      if kind == :signer,
        do: ["commit", "minimum_tests", "repository"],
        else: ["commit", "repository"]

    case @root |> Path.join(pin_path(kind)) |> File.read!() |> :json.decode() do
      %{"repository" => ^repository, "commit" => commit} = pin when is_binary(commit) ->
        cond do
          Enum.sort(Map.keys(pin)) != allowed ->
            raise(
              "typescript source pin: expected exactly #{Enum.join(allowed, ", ")} in #{pin_path(kind)}"
            )

          not (commit =~ ~r/\A[0-9a-f]{40}\z/) ->
            raise("typescript source pin: commit must be a full lowercase SHA-1")

          not valid_minimum?(kind, pin) ->
            raise("typescript source pin: minimum_tests must be a positive integer")

          true ->
            pin
        end

      _invalid ->
        raise(
          "typescript source pin: expected exactly #{Enum.join(allowed, ", ")} in #{pin_path(kind)}"
        )
    end
  end

  defp valid_minimum?(:signer, %{"minimum_tests" => minimum}),
    do: is_integer(minimum) and minimum > 0

  defp valid_minimum?(:verifier, _pin), do: true

  def current!(kind) do
    %{"commit" => commit} = pin!(kind)

    unless File.dir?(Path.join(@root, path(kind))) and
             File.read(Path.join(@root, stamp_path(kind))) == {:ok, commit} do
      raise(
        "typescript source: #{path(kind)} is not built from the pin; run mix typescript.sources"
      )
    end
  end

  def run(args) do
    unless Enum.all?(args, &(&1 in ["--cached", "--check"])) do
      raise("typescript source: expected --cached or --check")
    end

    for kind <- [:signer, :verifier] do
      if "--check" in args, do: current!(kind), else: materialize!(kind, "--cached" in args)
    end
  end

  defp materialize!(kind, cached?) do
    %{"repository" => repository, "commit" => commit} = pin!(kind)
    cache = Path.join(@root, path(kind) <> ".git")
    ensure_cache!(cache)

    unless cached? do
      git!(cache, [
        "fetch",
        "--quiet",
        "--no-tags",
        repository,
        "+refs/heads/main:refs/remotes/public/main"
      ])
    end

    object_present!(cache, commit)

    reachable!(cache, commit, "refs/remotes/public/main", "the pin is not on #{repository} main")
    forward_only!(kind, cache, commit)
    extract!(kind, cache, commit)
    IO.puts("typescript source: #{commit} materialized at #{path(kind)}")
  end

  defp ensure_cache!(cache) do
    unless File.dir?(cache) do
      File.mkdir_p!(Path.dirname(cache))
      {_out, 0} = System.cmd("git", ["init", "--quiet", "--bare", cache])
    end
  end

  defp object_present!(cache, commit) do
    case System.cmd("git", ["--git-dir", cache, "cat-file", "-e", commit <> "^{commit}"],
           stderr_to_stdout: true
         ) do
      {_out, 0} ->
        :ok

      _missing ->
        raise(
          "typescript source: #{commit} is not in the local cache; fetch it with mix typescript.sources"
        )
    end
  end

  defp reachable!(cache, commit, ref, message) do
    case System.cmd("git", ["--git-dir", cache, "merge-base", "--is-ancestor", commit, ref],
           stderr_to_stdout: true
         ) do
      {_out, 0} -> :ok
      _not_ancestor -> raise("typescript source: #{message} (#{commit})")
    end
  end

  # The newest pin change must move forward: the pin being materialized must
  # descend from the newest committed pin, and the newest committed pin from
  # the distinct pin before it on the first-parent history. A backward commit
  # therefore fails in its own CI run, where the working tree equals HEAD,
  # and a later forward commit repairs it. This needs a full git clone.
  defp forward_only!(kind, cache, commit) do
    [newest | older] = Enum.dedup([commit | committed_pins(kind)])

    case older do
      [previous | _rest] ->
        reachable!(
          cache,
          previous,
          newest,
          "the newest pin change moves backward: #{newest} does not descend from"
        )

      [] ->
        :ok
    end

    case File.read(Path.join(@root, stamp_path(kind))) do
      {:ok, previous} ->
        reachable!(
          cache,
          previous,
          commit,
          "the new pin does not descend from the last materialized pin; to build an older " <>
            "pin on purpose, delete #{stamp_path(kind)} first"
        )

      _no_materialized_pin ->
        :ok
    end
  end

  # Pin values along the first-parent history, newest first.
  defp committed_pins(kind) do
    case System.cmd("git", ["rev-parse", "--is-inside-work-tree"],
           cd: @root,
           stderr_to_stdout: true
         ) do
      {"true\n", 0} -> :ok
      _not_a_checkout -> raise("typescript source: the pin history check needs a git checkout")
    end

    case System.cmd("git", ["rev-parse", "--is-shallow-repository"], cd: @root) do
      {"false\n", 0} ->
        :ok

      _shallow ->
        raise("typescript source: the pin history check needs a full clone (fetch-depth 0)")
    end

    {log, 0} =
      System.cmd("git", ["log", "--first-parent", "--format=%H", "--", pin_path(kind)], cd: @root)

    log
    |> String.split()
    |> Enum.flat_map(fn sha -> pin_at(sha, kind) end)
  end

  # A commit in the log either changed the pin file or deleted it.
  defp pin_at(sha, kind) do
    case System.cmd("git", ["cat-file", "-e", "#{sha}:#{pin_path(kind)}"],
           cd: @root,
           stderr_to_stdout: true
         ) do
      {_out, 0} ->
        case System.cmd("git", ["show", "#{sha}:#{pin_path(kind)}"],
               cd: @root,
               stderr_to_stdout: true
             ) do
          {bytes, 0} ->
            [Map.fetch!(:json.decode(bytes), "commit")]

          {out, status} ->
            raise("typescript source: git show failed at #{sha} (#{status}): #{out}")
        end

      _deleted_at_sha ->
        []
    end
  end

  defp extract!(kind, cache, commit) do
    staging = Path.join(@root, "#{path(kind)}.staging-#{System.unique_integer([:positive])}")
    archive = staging <> ".tar"
    File.mkdir_p!(staging)

    try do
      git!(cache, ["archive", "--format=tar", "--output", archive, commit])
      {stamp, 0} = System.cmd("sh", ["-c", "git get-tar-commit-id < \"$1\"", "sh", archive])

      if String.trim(stamp) != commit,
        do: raise("typescript source: archive commit id differs from the pin")

      {_out, 0} = System.cmd("tar", ["-x", "-f", archive, "-C", staging])
      blobs_match!(cache, commit, staging)
      File.rm(Path.join(@root, stamp_path(kind)))
      swap_in!(kind, staging)
      File.write!(Path.join(@root, stamp_path(kind)), commit)
    after
      File.rm(archive)
      File.rm_rf(staging)
    end
  end

  defp blobs_match!(cache, commit, staging) do
    {listing, 0} = System.cmd("git", ["--git-dir", cache, "ls-tree", "-r", "-z", commit])

    expected =
      listing
      |> String.split(<<0>>, trim: true)
      |> Map.new(fn line ->
        [meta, path] = String.split(line, "\t", parts: 2)
        [_mode, _type, blob] = String.split(meta, " ")
        {path, blob}
      end)

    extracted =
      staging
      |> Path.join("**")
      |> Path.wildcard(match_dot: true)
      |> Enum.reject(&File.dir?/1)
      |> Enum.map(&Path.relative_to(&1, staging))
      |> MapSet.new()

    if extracted != MapSet.new(Map.keys(expected)),
      do: raise("typescript source: extracted file set differs from the pinned tree")

    Enum.each(expected, fn {path, blob} ->
      {actual, 0} = System.cmd("git", ["hash-object", "--no-filters", Path.join(staging, path)])

      if String.trim(actual) != blob,
        do: raise("typescript source: #{path} does not match its pinned blob")
    end)
  end

  defp swap_in!(kind, staging) do
    target = Path.join(@root, path(kind))
    retired = "#{target}.retired-#{System.unique_integer([:positive])}"
    if File.exists?(target), do: File.rename!(target, retired)
    File.rename!(staging, target)
    File.rm_rf!(retired)
  end

  defp git!(cache, args) do
    case System.cmd("git", @no_maintenance ++ ["--git-dir", cache | args], stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, status} -> raise("typescript source: git #{hd(args)} failed (#{status})\n#{out}")
    end
  end
end
