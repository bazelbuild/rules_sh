# Copyright 2024 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Common code for sh_binary and sh_test rules."""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load(":providers.bzl", "ShBinaryInfo", "ShInfo")

visibility(["//shell"])

_SH_TOOLCHAIN_TYPE = Label("//shell:toolchain_type")

_BASH_RUNFILES_INIT_PATH = "bazel_tools/tools/bash/runfiles/runfiles.bash"
_POSIX_RUNFILES_INIT_PATH = "shell/runfiles/runfiles.sh"

# The launcher emitted while //shell/settings:experimental_use_shell_runfiles
# is off: the classic bash-only v3 snippet, kept verbatim.
_BASH_LAUNCHER_TEMPLATE = """{shebang}

# --- begin runfiles.bash initialization v3 ---
set -uo pipefail; set +e; f={init_path}
# shellcheck disable=SC1090
source "${{RUNFILES_DIR:-/dev/null}}/$f" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "${{RUNFILES_MANIFEST_FILE:-/dev/null}}" | cut -f2- -d' ')" 2>/dev/null || \
  source "$0.runfiles/$f" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "$0.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "$0.exe.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null || \
  {{ echo>&2 "ERROR: cannot find $f"; exit 1; }}; f=; set -e
# --- end runfiles.bash initialization v3 ---

runfiles_export_envvars

exec "$(rlocation "{src}")" "$@"
"""

# The launcher emitted while //shell/settings:experimental_use_shell_runfiles
# is on. It sources `runfiles.sh` from its documented location rather than the
# `runfiles.bash` compatibility symlink, so that the launcher itself goes
# through the POSIX implementation.
#
# Its body is pure POSIX shell so that it runs under whatever the sh_toolchain
# points at (bash, dash, ash, busybox sh, ...), which rules out `source`,
# `set -o pipefail` and the `grep`/`cut` pipeline used above.
#
# The initialization block is kept byte-for-byte in sync with the snippet
# documented in runfiles.sh and carries no inline comments, to keep the
# generated launcher small. `.` on a missing file is fatal in a POSIX shell, so
# rather than sourcing speculatively, `_rf_d` (runfiles directory) and `_rf_m`
# (runfiles manifest) resolve each of the five candidate locations to an
# existing path, in the same order as the bash snippet, and only the winner is
# sourced.
#
# RUNFILES_LIB_CACHE=0 opts the launcher out of the source-time manifest parse
# runfiles.sh does for repeated lookups: it resolves one path and then execs, so
# it has nothing to amortize. The caller's value is restored before the exec.
_POSIX_LAUNCHER_TEMPLATE = """{shebang}

_rf_c="${{RUNFILES_LIB_CACHE-}}"; RUNFILES_LIB_CACHE=0

# --- begin runfiles.sh initialization v1 ---
set -u; set +e; f={init_path}; _rf_p=
_rf_d() {{ [ -f "$1/$f" ] && _rf_p="$1/$f"; }}
_rf_m() {{ [ -f "$1" ] || return 1; while IFS= read -r _rf_l || [ -n "$_rf_l" ]; do \
  case "$_rf_l" in "$f "*) _rf_p="${{_rf_l#"$f "}}"; return;; esac; done < "$1"; return 1; }}
_rf_d "${{RUNFILES_DIR:-/dev/null}}" || _rf_m "${{RUNFILES_MANIFEST_FILE:-/dev/null}}" || \
  _rf_d "$0.runfiles" || _rf_m "$0.runfiles_manifest" || _rf_m "$0.exe.runfiles_manifest" || \
  {{ echo>&2 "ERROR: cannot find $f"; exit 1; }}
# shellcheck disable=SC1090
. "$_rf_p"; f=; unset -f _rf_d _rf_m; unset _rf_l _rf_p; set -e
# --- end runfiles.sh initialization v1 ---

RUNFILES_LIB_CACHE="$_rf_c"; unset _rf_c

runfiles_export_envvars

exec "$(rlocation "{src}")" "$@"
"""

def _to_rlocation_path(ctx, file):
    if file.short_path.startswith("../"):
        return file.short_path[3:]
    else:
        return ctx.workspace_name + "/" + file.short_path

# A memory optimization for an empty provider
_SHARED_PROVIDER = ShBinaryInfo()

def _sh_executable_impl(ctx):
    if len(ctx.files.srcs) != 1:
        fail("you must specify exactly one file in 'srcs'", attr = "srcs")
    src = ctx.files.srcs[0]

    direct_files = [src]
    transitive_files = []
    runfiles = ctx.runfiles(collect_default = True)

    entrypoint = ctx.actions.declare_file(ctx.label.name)
    targets_windows = ctx.target_platform_has_constraint(ctx.attr._windows_constraint[platform_common.ConstraintValueInfo])
    if ctx.attr.use_bash_launcher:
        if targets_windows:
            # Windows uses a launcher executable that invokes the correct shell.
            # A Windows-style path in a shebang is either ignored or causes an
            # error.
            shebang = ""
        else:
            shell = ctx.toolchains[_SH_TOOLCHAIN_TYPE].path
            shebang = "#!{}".format(shell)
        if ctx.attr._experimental_use_shell_runfiles[BuildSettingInfo].value:
            template = _POSIX_LAUNCHER_TEMPLATE
            init_path = _POSIX_RUNFILES_INIT_PATH
        else:
            template = _BASH_LAUNCHER_TEMPLATE
            init_path = _BASH_RUNFILES_INIT_PATH
        ctx.actions.write(
            entrypoint,
            content = template.format(
                shebang = shebang,
                init_path = init_path,
                src = _to_rlocation_path(ctx, src),
            ),
            is_executable = True,
        )
        runfiles = runfiles.merge(ctx.attr._runfiles_dep[DefaultInfo].default_runfiles)
    else:
        ctx.actions.symlink(
            output = entrypoint,
            target_file = src,
            is_executable = True,
        )

    direct_files.append(entrypoint)

    # TODO: Consider extracting this logic into a function provided by
    # sh_toolchain to allow users to inject launcher creation logic for
    # non-Windows platforms.
    if targets_windows:
        main_executable = _launcher_for_windows(ctx, entrypoint, src)
        direct_files.append(main_executable)
    else:
        main_executable = entrypoint

    files = depset(direct = direct_files, transitive = transitive_files)
    runfiles = runfiles.merge(ctx.runfiles(transitive_files = files))
    default_info = DefaultInfo(
        executable = main_executable,
        files = files,
        runfiles = runfiles,
    )

    instrumented_files_info = coverage_common.instrumented_files_info(
        ctx,
        source_attributes = ["srcs"],
        dependency_attributes = ["deps", "_runfiles_dep", "data"],
    )

    run_environment_info = RunEnvironmentInfo(
        environment = {
            key: ctx.expand_make_variables(
                "env",
                ctx.expand_location(value, ctx.attr.data, short_paths = True),
                {},
            )
            for key, value in ctx.attr.env.items()
        },
        inherited_environment = ctx.attr.env_inherit,
    )

    return [
        default_info,
        instrumented_files_info,
        run_environment_info,
        _SHARED_PROVIDER,
    ]

_WINDOWS_EXECUTABLE_EXTENSIONS = [
    "exe",
    "cmd",
    "bat",
]

def _is_windows_executable(file):
    return file.extension in _WINDOWS_EXECUTABLE_EXTENSIONS

def _create_windows_exe_launcher(ctx, sh_toolchain, primary_output):
    if not sh_toolchain.launcher or not sh_toolchain.launcher_maker:
        fail("Windows sh_toolchain requires both 'launcher' and 'launcher_maker' to be set")

    bash_launcher = ctx.actions.declare_file(ctx.label.name + ".exe")

    launch_info = ctx.actions.args().use_param_file("%s", use_always = True).set_param_file_format("multiline")
    launch_info.add("binary_type=Bash")
    launch_info.add(ctx.workspace_name, format = "workspace_name=%s")
    launch_info.add("1" if ctx.configuration.runfiles_enabled() else "0", format = "symlink_runfiles_enabled=%s")
    launch_info.add(sh_toolchain.path, format = "bash_bin_path=%s")
    bash_file_short_path = primary_output.short_path
    if bash_file_short_path.startswith("../"):
        bash_file_rlocationpath = bash_file_short_path[3:]
    else:
        bash_file_rlocationpath = ctx.workspace_name + "/" + bash_file_short_path
    launch_info.add(bash_file_rlocationpath, format = "bash_file_rlocationpath=%s")

    launcher_artifact = sh_toolchain.launcher
    ctx.actions.run(
        executable = sh_toolchain.launcher_maker,
        inputs = [launcher_artifact],
        outputs = [bash_launcher],
        arguments = [launcher_artifact.path, launch_info, bash_launcher.path],
        use_default_shell_env = True,
        toolchain = _SH_TOOLCHAIN_TYPE,
    )
    return bash_launcher

def _launcher_for_windows(ctx, primary_output, main_file):
    if _is_windows_executable(main_file):
        if main_file.extension == primary_output.extension:
            return primary_output
        else:
            fail("Source file is a Windows executable file, target name extension should match source file extension")

    # bazel_tools should always registers a toolchain for Windows, but it may have an empty path.
    sh_toolchain = ctx.toolchains[_SH_TOOLCHAIN_TYPE]
    if not sh_toolchain or not sh_toolchain.path:
        # Let fail print the toolchain type with an apparent repo name.
        fail(
            """No suitable shell toolchain found:
* if you are running Bazel on Windows, set the BAZEL_SH environment variable to the path of bash.exe
* if you are running Bazel on a non-Windows platform but are targeting Windows, register an sh_toolchain for the""",
            _SH_TOOLCHAIN_TYPE,
            "toolchain type",
        )

    return _create_windows_exe_launcher(ctx, sh_toolchain, primary_output)

def make_sh_executable_rule(doc, extra_attrs = {}, **kwargs):
    return rule(
        _sh_executable_impl,
        doc = doc,
        attrs = {
            "data": attr.label_list(
                doc = """
Files needed by this rule at runtime. May list file or rule targets. Generally allows any target.
<p>
  The <code>runfiles</code> of targets in the <code>data</code> attribute appear in the
  <code>*.runfiles</code> area of any executable which is output by or has a runtime dependency
  on this target. This may include data files or binaries used when this target's
  <code>srcs</code> are executed. See the
  <a href="https://bazel.build/reference/be/common-definitions#typical.data">data dependencies</a>
  section for more information about how to depend on and use data files.
</p>
""",
                allow_files = True,
                flags = ["SKIP_CONSTRAINTS_OVERRIDE"],
            ),
            "deps": attr.label_list(
                providers = [ShInfo],
                doc = """
The list of "library" targets to be aggregated into this target.
See general comments about <code>deps</code>
at <a href="${link common-definitions#typical.deps}">Typical attributes defined by
most build rules</a>.
<p>
  This attribute should be used to list other <code>sh_library</code> rules that provide
  interpreted program source code depended on by the code in <code>srcs</code>. The files
  provided by these rules will be present among the <code>runfiles</code> of this target.
</p>
""",
            ),
            "env": attr.string_dict(
                doc = """
Specifies additional environment variables to set when the target is executed by
<code>bazel run</code> (for <code>sh_binary</code>) or <code>bazel test</code> (for
<code>sh_test</code>).
<p>
  Values are subject to
  <a href="https://bazel.build/reference/be/make-variables#predefined_label_variables">$(location)</a>
  and
  <a href="https://bazel.build/reference/be/make-variables">"Make variable"</a> substitution.
</p>
<p>
  <em class="harmful">NOTE: The environment variables are not set when you run the target
  outside of Bazel (for example, by manually executing the binary in <code>bazel-bin/</code>).</em>
</p>
""",
            ),
            "env_inherit": attr.string_list(
                doc = """
Specifies additional environment variables to inherit from the external environment when the
target is executed by <code>bazel test</code>. Has no effect on <code>bazel run</code>.
""",
            ),
            "srcs": attr.label_list(
                allow_files = True,
                doc = """
The file containing the shell script.
<p>
  This attribute must be a singleton list, whose element is the shell script.
  This script must be executable, and may be a source file or a generated file.
  All other files required at runtime (whether scripts or data) belong in the
  <code>data</code> attribute.
</p>
""",
            ),
            # TODO: The launcher stops being bash-specific once
            # //shell/settings:experimental_use_shell_runfiles becomes the
            # default. Rename this to something like `use_launcher` then,
            # keeping `use_bash_launcher` around as a deprecated alias.
            "use_bash_launcher": attr.bool(
                doc = """
Use a bash launcher initializing the runfiles library
<p>
  With <code>--//shell/settings:experimental_use_shell_runfiles</code> the
  launcher is instead written in pure POSIX shell and initializes the POSIX
  runfiles library, so that it runs under whatever the
  <code>sh_toolchain</code> points at. It always exports
  <code>RUNFILES_DIR</code> /
  <code>RUNFILES_MANIFEST_FILE</code>, so the wrapped script can locate the
  runfiles library itself, but it does not export the library's
  <em>functions</em> (such as <code>rlocation</code>) across <code>exec</code>
  the way bash does via <code>export -f</code>, as POSIX shells have no
  equivalent. Scripts built with the flag on should therefore source the
  runfiles library themselves using the standard initialization snippet.
</p>
""",
            ),
            "_experimental_use_shell_runfiles": attr.label(
                default = Label("//shell/settings:experimental_use_shell_runfiles"),
                providers = [BuildSettingInfo],
            ),
            "_runfiles_dep": attr.label(
                default = Label("//shell/runfiles"),
            ),
            "_windows_constraint": attr.label(
                default = "@platforms//os:windows",
            ),
        } | extra_attrs,
        toolchains = [
            config_common.toolchain_type(_SH_TOOLCHAIN_TYPE, mandatory = False),
        ],
        provides = [ShBinaryInfo],
        **kwargs
    )
