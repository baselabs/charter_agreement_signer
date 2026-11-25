defmodule CharterAgreementSigner.TypeScriptSourcesTest do
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @sources %{
    "signer" => "https://github.com/baselabs/charter_agreement_signer_typescript.git",
    "verifier" => "https://github.com/baselabs/charter_agreement_protocol_typescript.git"
  }
  @toolchain "scripts/toolchain.sh"
  @contents "#!/usr/bin/env bash\n"

  setup do
    scratch = "cas-ts-#{System.pid()}-#{System.unique_integer([:positive])}"
    directory = Path.join(System.tmp_dir!(), scratch)
    root = Path.join(directory, "cas")
    upstream = Path.join(directory, "upstream")
    File.mkdir!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    for dir <- [root, upstream] do
      File.mkdir_p!(Path.join(dir, "scripts"))
      git!(dir, ["init", "--quiet", "--template=", "--initial-branch=main"])
    end

    for name <- ["materialize_typescript_sources.exs", "typescript_sources.exs"] do
      File.cp!(Path.join([@root, "scripts", name]), Path.join([root, "scripts", name]))
    end

    toolchain = Path.join(upstream, @toolchain)
    File.write!(toolchain, @contents)
    File.chmod!(toolchain, 0o755)
    git!(upstream, ["add", "--chmod=+x", @toolchain])
    commit!(upstream)
    commit = git!(upstream, ["rev-parse", "HEAD"])

    File.mkdir!(Path.join(root, "_build"))
    File.mkdir!(Path.join(root, "priv"))

    for {kind, _repository} <- @sources do
      cache = source(root, kind) <> ".git"
      git!(root, ["init", "--quiet", "--bare", "--template=", cache])
      fetch!(cache, upstream)
      write_pin!(root, kind, commit)
    end

    git!(root, ["add", "priv"])
    commit!(root)
    %{root: root, upstream: upstream, commit: commit}
  end

  test "cached sources replace stamped archives with detached checkouts", context do
    %{root: root, commit: commit} = context

    for {kind, _repository} <- @sources do
      target = source(root, kind)
      File.mkdir!(target)
      File.write!(target <> ".commit", commit)
    end

    assert {output, 1} = run(root, "--check")
    assert output =~ "is not built from the pin"
    assert {_output, 0} = run(root, "--cached")

    for {kind, _repository} <- @sources do
      target = source(root, kind)
      assert File.dir?(Path.join(target, ".git"))
      refute File.exists?(Path.join(target, ".git/objects/info/alternates"))
      assert git!(target, ["rev-parse", "HEAD"]) == commit
      assert git!(target, ["rev-parse", "--abbrev-ref", "HEAD"]) == "HEAD"
      assert git!(target, ["ls-files", "--stage", "--", @toolchain]) =~ ~r/^100755 /
      assert File.read!(Path.join(target, @toolchain)) == @contents
      assert File.read!(target <> ".commit") == commit
      File.write!(Path.join(target, ".generated"), "npm output")
    end

    assert {_output, 0} = run(root, "--check")
    assert {_output, 0} = run(root, "--cached")

    for {kind, _repository} <- @sources do
      refute File.exists?(Path.join(source(root, kind), ".generated"))
    end

    assert_clean_build!(root)
  end

  test "checkout bytes that differ from their blobs leave the previous source intact", context do
    %{root: root, upstream: upstream, commit: commit} = context
    assert {_output, 0} = run(root, "--cached")

    target = source(root, "signer")
    File.write!(Path.join(upstream, ".gitattributes"), "#{@toolchain} text eol=crlf\n")
    commit_all!(upstream)
    fetch!(target <> ".git", upstream)
    write_pin!(root, "signer", git!(upstream, ["rev-parse", "HEAD"]))

    assert {output, 1} = run(root, "--cached")
    assert output =~ "#{@toolchain} does not match its pinned blob"
    assert git!(target, ["rev-parse", "HEAD"]) == commit
    assert File.read!(Path.join(target, @toolchain)) == @contents
    assert File.read!(target <> ".commit") == commit
    assert_clean_build!(root)
  end

  defp assert_clean_build!(root) do
    expected =
      Enum.flat_map(Map.keys(@sources), fn kind ->
        target = "#{kind}-source"
        refute File.exists?(Path.join(source(root, kind) <> ".git", "worktrees"))
        [target, target <> ".commit", target <> ".git"]
      end)

    assert Enum.sort(File.ls!(Path.join(root, "_build"))) == Enum.sort(expected)
  end

  defp source(root, kind), do: Path.join(root, "_build/#{kind}-source")

  defp write_pin!(root, kind, commit) do
    pin = %{"repository" => Map.fetch!(@sources, kind), "commit" => commit}
    pin = if kind == "signer", do: Map.put(pin, "minimum_tests", 1), else: pin
    File.write!(Path.join(root, "priv/#{kind}-source.json"), :json.encode(pin))
  end

  defp fetch!(cache, upstream) do
    git!(cache, ["fetch", "--quiet", upstream, "refs/heads/main:refs/remotes/public/main"])
  end

  defp commit_all!(dir) do
    git!(dir, ["add", "."])
    commit!(dir)
  end

  defp commit!(dir) do
    git!(dir, ["commit", "--quiet", "--message", "Fixture commit"])
  end

  defp git!(dir, args) do
    config = [
      "maintenance.auto=false",
      "gc.auto=0",
      "core.autocrlf=false",
      "core.hooksPath=/dev/null",
      "user.name=Fixture",
      "user.email=fixture@example.invalid",
      "commit.gpgsign=false"
    ]

    arguments = Enum.flat_map(config, &["-c", &1]) ++ args
    {output, status} = System.cmd("git", arguments, cd: dir, stderr_to_stdout: true)
    assert status == 0, output
    String.trim(output)
  end

  defp run(root, flag) do
    System.cmd("elixir", ["scripts/materialize_typescript_sources.exs", flag],
      cd: root,
      stderr_to_stdout: true
    )
  end
end
