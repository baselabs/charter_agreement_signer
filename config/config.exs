import Config

# The OTP-build assert: System.version/0 does NOT encode the OTP a given
# Elixir was compiled against, and the mix.exs :elixir requirement cannot
# express the OTP axis at all — a same-Elixir binary built on an
# unsupported OTP would otherwise compile incompatible BEAMs into shared
# _build/PLT state silently. Supported OTP majors = the CI matrix lanes
# (declared floor 28.1); anything else refuses before anything compiles.
# LOCKSTEP: this set, mix.exs's Elixir range, .tool-versions (the dev
# lane), and CI's matrix lanes move together in ONE commit.
# (system_info(:otp_release) returns a CHARLIST — the to_string/1 is
# mandatory or the assert always raises.) Repo-local enforcement only: the
# Hex package census excludes config/, so nothing here ships.
supported_otp = ["28", "29"]
running_otp = to_string(:erlang.system_info(:otp_release))

unless running_otp in supported_otp do
  raise "charter_agreement_signer supports Erlang/OTP #{Enum.join(supported_otp, "/")} (floor 28.1); running #{running_otp} (Elixir #{System.version()}, code root #{:code.root_dir()})."
end
