# Read Hex 2.7.0's signed registry using its read login, never a publish key.
# Run from a directory without mix.exs; --served additionally requires
# --commit DISPATCHED_SHA --clone REPOSITORY --docs-output SERVED_DOCS_TAR.
Code.require_file("hex_release_state.ex", __DIR__)
HexReleaseState.main(System.argv())
