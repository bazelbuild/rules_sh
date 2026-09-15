load("//shell:sh_library.bzl", "sh_library")
load("//shell/private:root_symlinks.bzl", "ROOT_SYMLINKS_SUPPORTED", "root_symlinks")

config_setting(
    name = "posix_runfiles",
    flag_values = {"//shell/settings:experimental_use_shell_runfiles": "true"},
)

alias(
    name = "runfiles",
    actual = select({
        ":posix_runfiles": ":runfiles_sh_impl",
        "//conditions:default": ":runfiles_impl" if ROOT_SYMLINKS_SUPPORTED else "@bazel_tools//tools/bash/runfiles",
    }),
    visibility = ["//visibility:public"],
)

sh_library(
    name = "runfiles_impl",
    data = [":runfiles_at_legacy_location"],
    tags = ["manual"],
    # The test suite depends on this directly rather than through `:runfiles`,
    # so that it keeps testing the bash library with the flag flipped on.
    visibility = ["//tests/runfiles:__pkg__"],
)

root_symlinks(
    name = "runfiles_at_legacy_location",
    root_symlinks = {
        "runfiles.bash": "bazel_tools/tools/bash/runfiles/runfiles.bash",
    },
    tags = ["manual"],
)

sh_library(
    name = "runfiles_sh_impl",
    data = [
        ":runfiles_sh_at_documented_location",
        ":runfiles_sh_at_legacy_location",
    ],
    tags = ["manual"],
)

sh_library(
    name = "runfiles_sh",
    srcs = ["runfiles.sh"],
    tags = ["manual"],
    visibility = ["//tests/runfiles:__pkg__"],
)

# Place runfiles.sh at the root path used by the documented init snippet
# (`f=shell/runfiles/runfiles.sh`). Otherwise it only appears under its
# repo-prefixed location (e.g. `_main/shell/runfiles/runfiles.sh`) and the
# snippet cannot find it.
root_symlinks(
    name = "runfiles_sh_at_documented_location",
    root_symlinks = {
        "runfiles.sh": "shell/runfiles/runfiles.sh",
    },
    tags = ["manual"],
)

# Native `sh_test` (legacy 7/8 modes) and every user script carrying the
# documented bash init snippet initialize from
# `f=bazel_tools/tools/bash/runfiles/runfiles.bash`. That path is hardcoded in
# the native launcher and cannot be redirected from Starlark, so while the
# `experimental_use_shell_runfiles` flag points the `:runfiles` alias here it
# must still resolve to something sourceable. Serving runfiles.sh there is what
# makes flipping the flag a drop-in replacement; the two implementations never
# share a runfiles tree, since the alias selects between them.
root_symlinks(
    name = "runfiles_sh_at_legacy_location",
    root_symlinks = {
        "runfiles.sh": "bazel_tools/tools/bash/runfiles/runfiles.bash",
    },
    tags = ["manual"],
)

exports_files(
    [
        "runfiles.bash",
        "runfiles.sh",
    ],
    visibility = ["//tests/runfiles:__pkg__"],
)
