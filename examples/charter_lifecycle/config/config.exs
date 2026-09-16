import Config

# The OTP-build assert — same shape and LOCKSTEP rule as the library root's
# config/config.exs (a path dependency's config never leaks into this
# project's config load, so the example enforces its own). Supported OTP
# majors = the CI matrix lanes (declared floor 28.1); System.version/0 does
# not encode the OTP build, and to_string/1 is mandatory because
# system_info(:otp_release) returns a CHARLIST.
supported_otp = ["28", "29"]
running_otp = to_string(:erlang.system_info(:otp_release))

unless running_otp in supported_otp do
  raise "charter_lifecycle supports Erlang/OTP #{Enum.join(supported_otp, "/")} (floor 28.1); running #{running_otp} (Elixir #{System.version()}, code root #{:code.root_dir()})."
end
