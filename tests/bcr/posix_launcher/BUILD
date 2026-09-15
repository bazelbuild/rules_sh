# Coverage for `use_bash_launcher` combined with the POSIX runfiles library:
# the launcher snippet must work under a non-bash sh_toolchain, and the wrapped
# scripts must be able to initialize the runfiles library themselves (POSIX
# shells cannot inherit the launcher's functions across exec).
#
# Use private rule implementations directly if all required features are available to provide test
# coverage for Bazel 8.
load("@bazel_features//:features.bzl", "bazel_features")
load("@rules_shell//shell/private:sh_binary.bzl", "sh_binary")  # buildifier: disable=bzl-visibility
load("@rules_shell//shell/private:sh_library.bzl", "sh_library")  # buildifier: disable=bzl-visibility
load("@rules_shell//shell/private:sh_test.bzl", "sh_test")  # buildifier: disable=bzl-visibility

# These targets source `shell/runfiles/runfiles.sh`, which is only present in
# the runfiles tree when the POSIX runfiles library is selected.
config_setting(
    name = "posix_runfiles",
    flag_values = {"@rules_shell//shell/settings:experimental_use_shell_runfiles": "true"},
)

_REQUIRES_POSIX_RUNFILES = select({
    ":posix_runfiles": [],
    "//conditions:default": ["@platforms//:incompatible"],
})

sh_library(
    name = "lib",
    srcs = ["lib.sh"],
    data = ["greeting.txt"],
)

bazel_features.rules._has_launcher_maker_toolchain and sh_binary(
    name = "bin",
    srcs = ["bin.sh"],
    target_compatible_with = _REQUIRES_POSIX_RUNFILES,
    use_bash_launcher = True,
    deps = [":lib"],
)  # buildifier: disable=no-effect

bazel_features.rules._has_launcher_maker_toolchain and sh_test(
    name = "test",
    srcs = ["test.sh"],
    data = [":bin"],
    target_compatible_with = _REQUIRES_POSIX_RUNFILES,
    use_bash_launcher = True,
)  # buildifier: disable=no-effect
