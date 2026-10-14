defmodule CharterAgreementSigner.ScratchGitMaintenanceTest do
  @moduledoc """
  Every script or test that runs a git command which starts git's automatic maintenance
  (`commit`, `merge`, `fetch`, `pull`, `am`, `rebase`, `clone`) also turns that maintenance
  off (`maintenance.auto` false) for the repository it drives.

  From git 2.54 those commands start `git maintenance run --auto --detach`, a repack that
  keeps writing into `.git` after the command returns, which races any removal of that
  repository.

  Goes red on a file that drives such a command without the setting, and on a scan that no
  longer sees the known driver (which would make the check vacuous).
  """

  use ExUnit.Case, async: true

  @roots ["scripts", "test"]
  @self "test/charter_agreement_signer/scratch_git_maintenance_test.exs"
  @known_drivers ["scripts/typescript_sources.exs"]
  @maintenance_subcommand ~r/\[\s*"(commit|merge|fetch|pull|am|rebase|clone)"/

  test "every git driver turns off automatic maintenance" do
    drivers =
      for root <- @roots,
          path <- Path.wildcard(Path.join(root, "**/*.{ex,exs}")),
          path != @self,
          File.read!(path) =~ @maintenance_subcommand,
          do: path

    assert @known_drivers -- drivers == [],
           "the scan no longer sees the known git drivers #{inspect(@known_drivers -- drivers)}"

    offenders = Enum.reject(drivers, &(File.read!(&1) =~ ~s("maintenance.auto)))

    assert offenders == [],
           "these files run git commands that start background maintenance without " <>
             "turning it off: #{inspect(offenders)}"
  end
end
