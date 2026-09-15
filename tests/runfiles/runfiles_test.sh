#!/bin/sh
# shellcheck shell=sh
# shellcheck disable=SC3043
#
# Copyright 2018 The Bazel Authors. All rights reserved.
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

# This suite tests the POSIX shell runfiles library. It must run under an
# actual POSIX shell — bash-in-POSIX-mode is not equivalent (bashisms are
# still parsed). Fail fast if the interpreter turns out to be bash, unless the
# caller opts out via RUNFILES_TEST_ALLOW_BASH=1, so that interpreter drift (a
# toolchain change, a /bin/sh symlink flip) cannot silently cost dash coverage.
if [ -n "${BASH_VERSION:-}" ] && [ -z "${RUNFILES_TEST_ALLOW_BASH:-}" ]; then
  echo >&2 "ERROR[runfiles_test.sh]: POSIX suite invoked under bash ($BASH_VERSION);" \
           "set RUNFILES_TEST_ALLOW_BASH=1 to override"
  exit 1
fi

set -eu

NL='
'

_log_base() {
  _prefix=$1
  shift
  echo >&2 "${_prefix}[runfiles_test.sh ($(date "+%H:%M:%S %z"))] $*"
}

fail() {
  _log_base "FAILED" "$@"
  exit 1
}

log_fail() {
  _log_base "FAILED" "$@"
}

log_info() {
  _log_base "INFO" "$@"
}

is_windows() {
  [ -n "${SYSTEMROOT:-}" ] || [ -n "${COMSPEC:-}" ]
}

find_runfiles_lib() {
  if type rlocation >/dev/null 2>&1; then
    unset -f rlocation
    unset -f runfiles_export_envvars
  fi

  # RUNFILES_LIBRARY_FILE is the rlocation path of runfiles.sh, plumbed in via
  # the sh_test rule's `env` (see tests/runfiles/BUILD). The main-repo prefix
  # varies between Bzlmod (`_main/...`) and WORKSPACE (`rules_shell/...`), so
  # we can't hardcode it.
  _target="${RUNFILES_LIBRARY_FILE:-}"
  if [ -z "$_target" ]; then
    echo >&2 "ERROR: RUNFILES_LIBRARY_FILE is not set — the sh_test rule must" \
             "pass \$(rlocationpath //shell/runfiles:runfiles_sh)"
    exit 1
  fi

  if ! [ -d "${RUNFILES_DIR:-/dev/null}" ] && ! [ -f "${RUNFILES_MANIFEST_FILE:-/dev/null}" ]; then
    if [ -f "$0.runfiles_manifest" ]; then
      export RUNFILES_MANIFEST_FILE="$0.runfiles_manifest"
    elif [ -f "$0.runfiles/MANIFEST" ]; then
      export RUNFILES_MANIFEST_FILE="$0.runfiles/MANIFEST"
    elif [ -f "$0.runfiles/${_target}" ]; then
      export RUNFILES_DIR="$0.runfiles"
    fi
  fi
  if [ -f "${RUNFILES_DIR:-/dev/null}/${_target}" ]; then
    echo "${RUNFILES_DIR}/${_target}"
  elif [ -f "${RUNFILES_MANIFEST_FILE:-/dev/null}" ]; then
    while IFS= read -r _line; do
      case "$_line" in
        "${_target} "*)
          echo "${_line#"${_target} "}"
          return 0
          ;;
      esac
    done < "$RUNFILES_MANIFEST_FILE"
    echo >&2 "ERROR: cannot find $_target"
    exit 1
  else
    echo >&2 "ERROR: cannot find $_target"
    exit 1
  fi
}

test_rlocation_call_requires_no_envvars() {
  export RUNFILES_DIR=mock/runfiles
  export RUNFILES_MANIFEST_FILE=
  export RUNFILES_MANIFEST_ONLY=
  . "$runfiles_lib_path" || fail
}

test_rlocation_argument_validation() {
  export RUNFILES_DIR=
  export RUNFILES_MANIFEST_FILE=
  export RUNFILES_MANIFEST_ONLY=
  . "$runfiles_lib_path"

  if rlocation "../foo" >/dev/null 2>&1; then
    fail
  fi
  if rlocation "foo/.." >/dev/null 2>&1; then
    fail
  fi
  if rlocation "foo/../bar" >/dev/null 2>&1; then
    fail
  fi
  if rlocation "./foo" >/dev/null 2>&1; then
    fail
  fi
  if rlocation "foo/." >/dev/null 2>&1; then
    fail
  fi
  if rlocation "foo/./bar" >/dev/null 2>&1; then
    fail
  fi
  if rlocation "//foo" >/dev/null 2>&1; then
    fail
  fi
  if rlocation "foo//" >/dev/null 2>&1; then
    fail
  fi
  if rlocation "foo//bar" >/dev/null 2>&1; then
    fail
  fi
  if rlocation "\\foo" >/dev/null 2>&1; then
    fail
  fi
}

test_rlocation_abs_path() {
  export RUNFILES_DIR=
  export RUNFILES_MANIFEST_FILE=
  export RUNFILES_MANIFEST_ONLY=
  . "$runfiles_lib_path"

  if is_windows; then
    [ "$(rlocation "c:/Foo" || echo failed)" = "c:/Foo" ] || fail
    [ "$(rlocation "c:\\Foo" || echo failed)" = "c:\\Foo" ] || fail
  else
    [ "$(rlocation "/Foo" || echo failed)" = "/Foo" ] || fail
  fi
}

test_init_manifest_based_runfiles() {
  local tmpdir="$TEST_TMPDIR/test_init_manifest_based_runfiles"
  mkdir -p "$tmpdir"
  cat > "$tmpdir/foo.runfiles_manifest" << EOF
a/b $tmpdir/c/d
e/f $tmpdir/g h
y $tmpdir/y
c/dir $tmpdir/dir
unresolved $tmpdir/unresolved
 h/\si $tmpdir/ j k
 h/\s\bi $tmpdir/ j k b
 h/\n\bi $tmpdir/ \bnj k \na
 dir\swith\sspaces $tmpdir/dir with spaces
 space\snewline\nbackslash\b_dir $tmpdir/space newline\nbackslash\ba
EOF
  mkdir "${tmpdir}/c"
  mkdir "${tmpdir}/y"
  mkdir -p "${tmpdir}/dir/deeply/nested"
  touch "${tmpdir}/c/d" "${tmpdir}/g h"
  touch "${tmpdir}/dir/file"
  ln -s /does/not/exist "${tmpdir}/dir/unresolved"
  touch "${tmpdir}/dir/deeply/nested/file"
  touch "${tmpdir}/dir/deeply/nested/file with spaces"
  ln -s /does/not/exist "${tmpdir}/unresolved"
  touch "${tmpdir}/ j k"
  touch "${tmpdir}/ j k b"
  mkdir -p "${tmpdir}/dir with spaces/nested"
  touch "${tmpdir}/dir with spaces/nested/file"
  if ! is_windows; then
    touch "${tmpdir}/ \\nj k ${NL}a"
    mkdir -p "${tmpdir}/space newline${NL}backslash\\a"
    touch "${tmpdir}/space newline${NL}backslash\\a/f i\\le"
  fi

  export RUNFILES_DIR=
  export RUNFILES_MANIFEST_FILE="$tmpdir/foo.runfiles_manifest"
  . "$runfiles_lib_path"

  [ -z "$(rlocation a || echo failed)" ] || fail
  [ -z "$(rlocation c/d || echo failed)" ] || fail
  [ "$(rlocation a/b || echo failed)" = "$tmpdir/c/d" ] || fail
  [ "$(rlocation e/f || echo failed)" = "$tmpdir/g h" ] || fail
  [ "$(rlocation y || echo failed)" = "$tmpdir/y" ] || fail
  [ -z "$(rlocation c || echo failed)" ] || fail
  [ -z "$(rlocation c/di || echo failed)" ] || fail
  [ "$(rlocation c/dir || echo failed)" = "$tmpdir/dir" ] || fail
  [ "$(rlocation c/dir/file || echo failed)" = "$tmpdir/dir/file" ] || fail
  [ -z "$(rlocation c/dir/unresolved || echo failed)" ] || fail
  [ "$(rlocation c/dir/deeply/nested/file || echo failed)" = "$tmpdir/dir/deeply/nested/file" ] || fail
  [ "$(rlocation "c/dir/deeply/nested/file with spaces" || echo failed)" = "$tmpdir/dir/deeply/nested/file with spaces" ] || fail
  [ -z "$(rlocation unresolved || echo failed)" ] || fail
  [ "$(rlocation "h/ i" || echo failed)" = "$tmpdir/ j k" ] || fail
  [ "$(rlocation "h/ \\i" || echo failed)" = "$tmpdir/ j k b" ] || fail
  [ "$(rlocation "dir with spaces" || echo failed)" = "$tmpdir/dir with spaces" ] || fail
  [ "$(rlocation "dir with spaces/nested/file" || echo failed)" = "$tmpdir/dir with spaces/nested/file" ] || fail
  if ! is_windows; then
    [ "$(rlocation "h/${NL}\\i" || echo failed)" = "$tmpdir/ \\nj k ${NL}a" ] || fail
    [ "$(rlocation "space newline${NL}backslash\\_dir/f i\\le" || echo failed)" = "${tmpdir}/space newline${NL}backslash\\a/f i\\le" ] || fail
  fi

  rm -r "$tmpdir/c/d" "$tmpdir/g h" "$tmpdir/y" "$tmpdir/dir" "$tmpdir/unresolved" "$tmpdir/ j k" "$tmpdir/dir with spaces"
  if ! is_windows; then
    rm -r "$tmpdir/ \\nj k ${NL}a" "${tmpdir}/space newline${NL}backslash\\a"
    [ -z "$(rlocation "h/${NL}\\i" || echo failed)" ] || fail
    [ -z "$(rlocation "space newline${NL}backslash\\_dir/f i\\le" || echo failed)" ] || fail
  fi
  [ -z "$(rlocation a/b || echo failed)" ] || fail
  [ -z "$(rlocation e/f || echo failed)" ] || fail
  [ -z "$(rlocation y || echo failed)" ] || fail
  [ -z "$(rlocation c/dir || echo failed)" ] || fail
  [ -z "$(rlocation c/dir/file || echo failed)" ] || fail
  [ -z "$(rlocation c/dir/deeply/nested/file || echo failed)" ] || fail
  [ -z "$(rlocation "h/ i" || echo failed)" ] || fail
  [ -z "$(rlocation "dir with spaces" || echo failed)" ] || fail
  [ -z "$(rlocation "dir with spaces/nested/file" || echo failed)" ] || fail
}

test_manifest_based_envvars() {
  local tmpdir="$TEST_TMPDIR/test_manifest_based_envvars"
  mkdir -p "$tmpdir"
  echo "a b" > "$tmpdir/foo.runfiles_manifest"

  export RUNFILES_DIR=
  export RUNFILES_MANIFEST_FILE="$tmpdir/foo.runfiles_manifest"
  mkdir -p "$tmpdir/foo.runfiles"
  . "$runfiles_lib_path"

  runfiles_export_envvars
  [ "${RUNFILES_DIR:-}" = "$tmpdir/foo.runfiles" ] || fail
  [ "${RUNFILES_MANIFEST_FILE:-}" = "$tmpdir/foo.runfiles_manifest" ] || fail
}

test_init_directory_based_runfiles() {
  local tmpdir="$TEST_TMPDIR/test_init_directory_based_runfiles"
  mkdir -p "$tmpdir"

  export RUNFILES_DIR="${tmpdir}/mock/runfiles"
  export RUNFILES_MANIFEST_FILE=
  . "$runfiles_lib_path"

  mkdir -p "$RUNFILES_DIR/a"
  touch "$RUNFILES_DIR/a/b" "$RUNFILES_DIR/c d"
  [ "$(rlocation a || echo failed)" = "$RUNFILES_DIR/a" ] || fail
  [ "$(rlocation c/d || echo failed)" = "failed" ] || fail
  [ "$(rlocation a/b || echo failed)" = "$RUNFILES_DIR/a/b" ] || fail
  [ "$(rlocation "c d" || echo failed)" = "$RUNFILES_DIR/c d" ] || fail
  [ "$(rlocation "c" || echo failed)" = "failed" ] || fail
  rm -r "$RUNFILES_DIR/a" "$RUNFILES_DIR/c d"
  [ "$(rlocation a || echo failed)" = "failed" ] || fail
  [ "$(rlocation a/b || echo failed)" = "failed" ] || fail
  [ "$(rlocation "c d" || echo failed)" = "failed" ] || fail
}

test_directory_based_runfiles_with_repo_mapping_from_main() {
  local tmpdir="$TEST_TMPDIR/test_directory_based_runfiles_with_repo_mapping_from_main"
  mkdir -p "$tmpdir"

  export RUNFILES_DIR="${tmpdir}/mock/runfiles"
  mkdir -p "$RUNFILES_DIR"
  cat > "$RUNFILES_DIR/_repo_mapping" <<EOF
,config.json,config.json+1.2.3
,my_module,_main
,my_protobuf,protobuf+3.19.2
,my_workspace,_main
protobuf+3.19.2,protobuf,protobuf+3.19.2
protobuf+3.19.2,config.json,config.json+1.2.3
EOF
  export RUNFILES_MANIFEST_FILE=
  . "$runfiles_lib_path"

  mkdir -p "$RUNFILES_DIR/_main/bar"
  touch "$RUNFILES_DIR/_main/bar/runfile"
  mkdir -p "$RUNFILES_DIR/protobuf+3.19.2/bar/dir/de eply/nes ted"
  touch "$RUNFILES_DIR/protobuf+3.19.2/bar/dir/file"
  touch "$RUNFILES_DIR/protobuf+3.19.2/bar/dir/de eply/nes ted/fi+le"
  mkdir -p "$RUNFILES_DIR/protobuf+3.19.2/foo"
  touch "$RUNFILES_DIR/protobuf+3.19.2/foo/runfile"
  touch "$RUNFILES_DIR/config.json"

  [ "$(rlocation "my_module/bar/runfile" "" || echo failed)" = "$RUNFILES_DIR/_main/bar/runfile" ] || fail
  [ "$(rlocation "my_workspace/bar/runfile" "" || echo failed)" = "$RUNFILES_DIR/_main/bar/runfile" ] || fail
  [ "$(rlocation "my_protobuf/foo/runfile" "" || echo failed)" = "$RUNFILES_DIR/protobuf+3.19.2/foo/runfile" ] || fail
  [ "$(rlocation "my_protobuf/bar/dir" "" || echo failed)" = "$RUNFILES_DIR/protobuf+3.19.2/bar/dir" ] || fail
  [ "$(rlocation "my_protobuf/bar/dir/file" "" || echo failed)" = "$RUNFILES_DIR/protobuf+3.19.2/bar/dir/file" ] || fail
  [ "$(rlocation "my_protobuf/bar/dir/de eply/nes ted/fi+le" "" || echo failed)" = "$RUNFILES_DIR/protobuf+3.19.2/bar/dir/de eply/nes ted/fi+le" ] || fail

  [ "$(rlocation "protobuf/foo/runfile" "" || echo failed)" = "failed" ] || fail
  [ "$(rlocation "protobuf/bar/dir/dir/de eply/nes ted/fi+le" "" || echo failed)" = "failed" ] || fail

  [ "$(rlocation "_main/bar/runfile" "" || echo failed)" = "$RUNFILES_DIR/_main/bar/runfile" ] || fail
  [ "$(rlocation "protobuf+3.19.2/foo/runfile" "" || echo failed)" = "$RUNFILES_DIR/protobuf+3.19.2/foo/runfile" ] || fail
  [ "$(rlocation "protobuf+3.19.2/bar/dir" "" || echo failed)" = "$RUNFILES_DIR/protobuf+3.19.2/bar/dir" ] || fail
  [ "$(rlocation "protobuf+3.19.2/bar/dir/file" "" || echo failed)" = "$RUNFILES_DIR/protobuf+3.19.2/bar/dir/file" ] || fail
  [ "$(rlocation "protobuf+3.19.2/bar/dir/de eply/nes ted/fi+le" "" || echo failed)" = "$RUNFILES_DIR/protobuf+3.19.2/bar/dir/de eply/nes ted/fi+le" ] || fail

  [ "$(rlocation "config.json" "" || echo failed)" = "$RUNFILES_DIR/config.json" ] || fail
}

test_directory_based_runfiles_with_repo_mapping_from_other_repo() {
  local tmpdir="$TEST_TMPDIR/test_directory_based_runfiles_with_repo_mapping_from_other_repo"
  mkdir -p "$tmpdir"

  export RUNFILES_DIR="${tmpdir}/mock/runfiles"
  mkdir -p "$RUNFILES_DIR"
  cat > "$RUNFILES_DIR/_repo_mapping" <<EOF
,config.json,config.json+1.2.3
,my_module,_main
,my_protobuf,protobuf+3.19.2
,my_workspace,_main
protobuf+3.19.2,protobuf,protobuf+3.19.2
protobuf+3.19.2,config.json,config.json+1.2.3
EOF
  export RUNFILES_MANIFEST_FILE=
  . "$runfiles_lib_path"

  mkdir -p "$RUNFILES_DIR/_main/bar"
  touch "$RUNFILES_DIR/_main/bar/runfile"
  mkdir -p "$RUNFILES_DIR/protobuf+3.19.2/bar/dir/de eply/nes ted"
  touch "$RUNFILES_DIR/protobuf+3.19.2/bar/dir/file"
  touch "$RUNFILES_DIR/protobuf+3.19.2/bar/dir/de eply/nes ted/fi+le"
  mkdir -p "$RUNFILES_DIR/protobuf+3.19.2/foo"
  touch "$RUNFILES_DIR/protobuf+3.19.2/foo/runfile"
  touch "$RUNFILES_DIR/config.json"

  [ "$(rlocation "protobuf/foo/runfile" "protobuf+3.19.2" || echo failed)" = "$RUNFILES_DIR/protobuf+3.19.2/foo/runfile" ] || fail
  [ "$(rlocation "protobuf/bar/dir" "protobuf+3.19.2" || echo failed)" = "$RUNFILES_DIR/protobuf+3.19.2/bar/dir" ] || fail
  [ "$(rlocation "protobuf/bar/dir/file" "protobuf+3.19.2" || echo failed)" = "$RUNFILES_DIR/protobuf+3.19.2/bar/dir/file" ] || fail
  [ "$(rlocation "protobuf/bar/dir/de eply/nes ted/fi+le" "protobuf+3.19.2" || echo failed)" = "$RUNFILES_DIR/protobuf+3.19.2/bar/dir/de eply/nes ted/fi+le" ] || fail

  [ "$(rlocation "my_module/bar/runfile" "protobuf+3.19.2" || echo failed)" = "failed" ] || fail
  [ "$(rlocation "my_protobuf/bar/dir/de eply/nes ted/fi+le" "protobuf+3.19.2" || echo failed)" = "failed" ] || fail

  [ "$(rlocation "_main/bar/runfile" "protobuf+3.19.2" || echo failed)" = "$RUNFILES_DIR/_main/bar/runfile" ] || fail
  [ "$(rlocation "protobuf+3.19.2/foo/runfile" "protobuf+3.19.2" || echo failed)" = "$RUNFILES_DIR/protobuf+3.19.2/foo/runfile" ] || fail
  [ "$(rlocation "protobuf+3.19.2/bar/dir" "protobuf+3.19.2" || echo failed)" = "$RUNFILES_DIR/protobuf+3.19.2/bar/dir" ] || fail
  [ "$(rlocation "protobuf+3.19.2/bar/dir/file" "protobuf+3.19.2" || echo failed)" = "$RUNFILES_DIR/protobuf+3.19.2/bar/dir/file" ] || fail
  [ "$(rlocation "protobuf+3.19.2/bar/dir/de eply/nes ted/fi+le" "protobuf+3.19.2" || echo failed)" = "$RUNFILES_DIR/protobuf+3.19.2/bar/dir/de eply/nes ted/fi+le" ] || fail

  [ "$(rlocation "config.json" "protobuf+3.19.2" || echo failed)" = "$RUNFILES_DIR/config.json" ] || fail
}

test_directory_based_runfiles_with_repo_mapping_from_extension_repo() {
  local tmpdir="$TEST_TMPDIR/test_directory_based_runfiles_with_repo_mapping_from_extension_repo"
  mkdir -p "$tmpdir"

  export RUNFILES_DIR="${tmpdir}/mock/runfiles"
  mkdir -p "$RUNFILES_DIR"
  cat > "$RUNFILES_DIR/_repo_mapping" <<EOF
,config.json,config.json+1.2.3
,my_module,_main
,my_protobuf,protobuf+3.19.2
,my_workspace,_main
my_module++ex+*,my_module,my_module+
my_module++ext+*,my_module,my_module+
my_module++ext+*,repo1,my_module++ext+repo1
my_module++ext1+*,my_module,my_module+
EOF
  export RUNFILES_MANIFEST_FILE=
  . "$runfiles_lib_path"

  mkdir -p "$RUNFILES_DIR/_main/bar"
  touch "$RUNFILES_DIR/_main/bar/runfile"
  mkdir -p "$RUNFILES_DIR/protobuf+3.19.2/bar/dir/de eply/nes ted"
  touch "$RUNFILES_DIR/protobuf+3.19.2/bar/dir/file"
  touch "$RUNFILES_DIR/protobuf+3.19.2/bar/dir/de eply/nes ted/fi+le"
  mkdir -p "$RUNFILES_DIR/protobuf+3.19.2/foo"
  touch "$RUNFILES_DIR/protobuf+3.19.2/foo/runfile"
  touch "$RUNFILES_DIR/config.json"
  mkdir -p "$RUNFILES_DIR/my_module+/foo"
  touch "$RUNFILES_DIR/my_module+/foo/runfile"
  mkdir -p "$RUNFILES_DIR/my_module++ext+repo1/foo"
  touch "$RUNFILES_DIR/my_module++ext+repo1/foo/runfile"
  mkdir -p "$RUNFILES_DIR/repo2+/foo"
  touch "$RUNFILES_DIR/repo2+/foo/runfile"

  [ "$(rlocation "my_module/foo/runfile" "my_module++ext+repo1" || echo failed)" = "$RUNFILES_DIR/my_module+/foo/runfile" ] || fail
  [ "$(rlocation "repo1/foo/runfile" "my_module++ext+repo1" || echo failed)" = "$RUNFILES_DIR/my_module++ext+repo1/foo/runfile" ] || fail
  [ "$(rlocation "repo2+/foo/runfile" "my_module++ext+repo1" || echo failed)" = "$RUNFILES_DIR/repo2+/foo/runfile" ] || fail
}

test_manifest_based_runfiles_with_repo_mapping_from_main() {
  local tmpdir="$TEST_TMPDIR/test_manifest_based_runfiles_with_repo_mapping_from_main"
  mkdir -p "$tmpdir"

  cat > "$tmpdir/foo.repo_mapping" <<EOF
,config.json,config.json+1.2.3
,my_module,_main
,my_protobuf,protobuf+3.19.2
,my_workspace,_main
protobuf+3.19.2,protobuf,protobuf+3.19.2
protobuf+3.19.2,config.json,config.json+1.2.3
EOF
  export RUNFILES_DIR=
  export RUNFILES_MANIFEST_FILE="$tmpdir/foo.runfiles_manifest"
  cat > "$RUNFILES_MANIFEST_FILE" << EOF
_repo_mapping $tmpdir/foo.repo_mapping
config.json $tmpdir/config.json
protobuf+3.19.2/foo/runfile $tmpdir/protobuf+3.19.2/foo/runfile
_main/bar/runfile $tmpdir/_main/bar/runfile
protobuf+3.19.2/bar/dir $tmpdir/protobuf+3.19.2/bar/dir
EOF
  . "$runfiles_lib_path"

  mkdir -p "$tmpdir/_main/bar"
  touch "$tmpdir/_main/bar/runfile"
  mkdir -p "$tmpdir/protobuf+3.19.2/bar/dir/de eply/nes ted"
  touch "$tmpdir/protobuf+3.19.2/bar/dir/file"
  touch "$tmpdir/protobuf+3.19.2/bar/dir/de eply/nes ted/fi+le"
  mkdir -p "$tmpdir/protobuf+3.19.2/foo"
  touch "$tmpdir/protobuf+3.19.2/foo/runfile"
  touch "$tmpdir/config.json"

  [ "$(rlocation "my_module/bar/runfile" "" || echo failed)" = "$tmpdir/_main/bar/runfile" ] || fail
  [ "$(rlocation "my_workspace/bar/runfile" "" || echo failed)" = "$tmpdir/_main/bar/runfile" ] || fail
  [ "$(rlocation "my_protobuf/foo/runfile" "" || echo failed)" = "$tmpdir/protobuf+3.19.2/foo/runfile" ] || fail
  [ "$(rlocation "my_protobuf/bar/dir" "" || echo failed)" = "$tmpdir/protobuf+3.19.2/bar/dir" ] || fail
  [ "$(rlocation "my_protobuf/bar/dir/file" "" || echo failed)" = "$tmpdir/protobuf+3.19.2/bar/dir/file" ] || fail
  [ "$(rlocation "my_protobuf/bar/dir/de eply/nes ted/fi+le" "" || echo failed)" = "$tmpdir/protobuf+3.19.2/bar/dir/de eply/nes ted/fi+le" ] || fail

  [ -z "$(rlocation "protobuf/foo/runfile" "" || echo failed)" ] || fail
  [ -z "$(rlocation "protobuf/bar/dir/dir/de eply/nes ted/fi+le" "" || echo failed)" ] || fail

  [ "$(rlocation "_main/bar/runfile" "" || echo failed)" = "$tmpdir/_main/bar/runfile" ] || fail
  [ "$(rlocation "protobuf+3.19.2/foo/runfile" "" || echo failed)" = "$tmpdir/protobuf+3.19.2/foo/runfile" ] || fail
  [ "$(rlocation "protobuf+3.19.2/bar/dir" "" || echo failed)" = "$tmpdir/protobuf+3.19.2/bar/dir" ] || fail
  [ "$(rlocation "protobuf+3.19.2/bar/dir/file" "" || echo failed)" = "$tmpdir/protobuf+3.19.2/bar/dir/file" ] || fail
  [ "$(rlocation "protobuf+3.19.2/bar/dir/de eply/nes ted/fi+le" "" || echo failed)" = "$tmpdir/protobuf+3.19.2/bar/dir/de eply/nes ted/fi+le" ] || fail

  [ "$(rlocation "config.json" "" || echo failed)" = "$tmpdir/config.json" ] || fail
}

test_manifest_based_runfiles_with_repo_mapping_from_other_repo() {
  local tmpdir="$TEST_TMPDIR/test_manifest_based_runfiles_with_repo_mapping_from_other_repo"
  mkdir -p "$tmpdir"

  cat > "$tmpdir/foo.repo_mapping" <<EOF
,config.json,config.json+1.2.3
,my_module,_main
,my_protobuf,protobuf+3.19.2
,my_workspace,_main
protobuf+3.19.2,protobuf,protobuf+3.19.2
protobuf+3.19.2,config.json,config.json+1.2.3
EOF
  export RUNFILES_DIR=
  export RUNFILES_MANIFEST_FILE="$tmpdir/foo.runfiles_manifest"
  cat > "$RUNFILES_MANIFEST_FILE" << EOF
_repo_mapping $tmpdir/foo.repo_mapping
config.json $tmpdir/config.json
protobuf+3.19.2/foo/runfile $tmpdir/protobuf+3.19.2/foo/runfile
_main/bar/runfile $tmpdir/_main/bar/runfile
protobuf+3.19.2/bar/dir $tmpdir/protobuf+3.19.2/bar/dir
EOF
  . "$runfiles_lib_path"

  mkdir -p "$tmpdir/_main/bar"
  touch "$tmpdir/_main/bar/runfile"
  mkdir -p "$tmpdir/protobuf+3.19.2/bar/dir/de eply/nes ted"
  touch "$tmpdir/protobuf+3.19.2/bar/dir/file"
  touch "$tmpdir/protobuf+3.19.2/bar/dir/de eply/nes ted/fi+le"
  mkdir -p "$tmpdir/protobuf+3.19.2/foo"
  touch "$tmpdir/protobuf+3.19.2/foo/runfile"
  touch "$tmpdir/config.json"

  [ "$(rlocation "protobuf/foo/runfile" "protobuf+3.19.2" || echo failed)" = "$tmpdir/protobuf+3.19.2/foo/runfile" ] || fail
  [ "$(rlocation "protobuf/bar/dir" "protobuf+3.19.2" || echo failed)" = "$tmpdir/protobuf+3.19.2/bar/dir" ] || fail
  [ "$(rlocation "protobuf/bar/dir/file" "protobuf+3.19.2" || echo failed)" = "$tmpdir/protobuf+3.19.2/bar/dir/file" ] || fail
  [ "$(rlocation "protobuf/bar/dir/de eply/nes ted/fi+le" "protobuf+3.19.2" || echo failed)" = "$tmpdir/protobuf+3.19.2/bar/dir/de eply/nes ted/fi+le" ] || fail

  [ -z "$(rlocation "my_module/bar/runfile" "protobuf+3.19.2" || echo failed)" ] || fail
  [ -z "$(rlocation "my_protobuf/bar/dir/de eply/nes ted/fi+le" "protobuf+3.19.2" || echo failed)" ] || fail

  [ "$(rlocation "_main/bar/runfile" "protobuf+3.19.2" || echo failed)" = "$tmpdir/_main/bar/runfile" ] || fail
  [ "$(rlocation "protobuf+3.19.2/foo/runfile" "protobuf+3.19.2" || echo failed)" = "$tmpdir/protobuf+3.19.2/foo/runfile" ] || fail
  [ "$(rlocation "protobuf+3.19.2/bar/dir" "protobuf+3.19.2" || echo failed)" = "$tmpdir/protobuf+3.19.2/bar/dir" ] || fail
  [ "$(rlocation "protobuf+3.19.2/bar/dir/file" "protobuf+3.19.2" || echo failed)" = "$tmpdir/protobuf+3.19.2/bar/dir/file" ] || fail
  [ "$(rlocation "protobuf+3.19.2/bar/dir/de eply/nes ted/fi+le" "protobuf+3.19.2" || echo failed)" = "$tmpdir/protobuf+3.19.2/bar/dir/de eply/nes ted/fi+le" ] || fail

  [ "$(rlocation "config.json" "protobuf+3.19.2" || echo failed)" = "$tmpdir/config.json" ] || fail
}

test_manifest_based_runfiles_with_repo_mapping_from_extension_repo() {
  local tmpdir="$TEST_TMPDIR/test_manifest_based_runfiles_with_repo_mapping_from_extension_repo"
  mkdir -p "$tmpdir"

  cat > "$tmpdir/foo.repo_mapping" <<EOF
,config.json,config.json+1.2.3
,my_module,_main
,my_protobuf,protobuf+3.19.2
,my_workspace,_main
my_module++ex+*,my_module,my_module+
my_module++ext+*,my_module,my_module+
my_module++ext+*,repo1,my_module++ext+repo1
my_module++ext1+*,my_module,my_module+
EOF
  export RUNFILES_DIR=
  export RUNFILES_MANIFEST_FILE="$tmpdir/foo.runfiles_manifest"
  cat > "$RUNFILES_MANIFEST_FILE" << EOF
_repo_mapping $tmpdir/foo.repo_mapping
config.json $tmpdir/config.json
protobuf+3.19.2/foo/runfile $tmpdir/protobuf+3.19.2/foo/runfile
_main/bar/runfile $tmpdir/_main/bar/runfile
protobuf+3.19.2/bar/dir $tmpdir/protobuf+3.19.2/bar/dir
my_module+/foo/runfile $tmpdir/my_module+/runfile
my_module++ext+repo1/foo/runfile $tmpdir/my_module++ext+repo1/runfile
repo2+/foo/runfile $tmpdir/repo2+/runfile
EOF
  . "$runfiles_lib_path"

  mkdir -p "$tmpdir/_main/bar"
  touch "$tmpdir/_main/bar/runfile"
  mkdir -p "$tmpdir/protobuf+3.19.2/bar/dir/de eply/nes ted"
  touch "$tmpdir/protobuf+3.19.2/bar/dir/file"
  touch "$tmpdir/protobuf+3.19.2/bar/dir/de eply/nes ted/fi+le"
  mkdir -p "$tmpdir/protobuf+3.19.2/foo"
  touch "$tmpdir/protobuf+3.19.2/foo/runfile"
  touch "$tmpdir/config.json"
  mkdir -p "$tmpdir/my_module+"
  touch "$tmpdir/my_module+/runfile"
  mkdir -p "$tmpdir/my_module++ext+repo1"
  touch "$tmpdir/my_module++ext+repo1/runfile"
  mkdir -p "$tmpdir/repo2+"
  touch "$tmpdir/repo2+/runfile"

  [ "$(rlocation "my_module/foo/runfile" "my_module++ext+repo1" || echo failed)" = "$tmpdir/my_module+/runfile" ] || fail
  [ "$(rlocation "repo1/foo/runfile" "my_module++ext+repo1" || echo failed)" = "$tmpdir/my_module++ext+repo1/runfile" ] || fail
  [ "$(rlocation "repo2+/foo/runfile" "my_module++ext+repo1" || echo failed)" = "$tmpdir/repo2+/runfile" ] || fail
}

test_directory_based_runfiles_with_repo_mapping_from_module_root_repo() {
  # Regression: __runfiles_compute_repo_prefix used to return "rules_shell+*"
  # for source repo "rules_shell+" (any bzlmod module's canonical name ends in
  # a separator with no trailing safe chars). The sed pattern it replaces
  # returns the input unchanged in that case. If we compute the wrong prefix
  # here, a compact-form mapping row unrelated to this repo can spuriously
  # match and rlocation returns the wrong file.
  local tmpdir="$TEST_TMPDIR/test_directory_based_runfiles_with_repo_mapping_from_module_root_repo"
  mkdir -p "$tmpdir"

  export RUNFILES_DIR="${tmpdir}/mock/runfiles"
  mkdir -p "$RUNFILES_DIR"
  # No literal "rules_shell+,dep,..." row; only a compact form that would
  # spuriously match if pfx computation returns "rules_shell+*".
  cat > "$RUNFILES_DIR/_repo_mapping" <<EOF
rules_shell+*,dep,wrong+
EOF
  export RUNFILES_MANIFEST_FILE=
  . "$runfiles_lib_path"

  mkdir -p "$RUNFILES_DIR/dep/pkg"
  touch "$RUNFILES_DIR/dep/pkg/f"
  mkdir -p "$RUNFILES_DIR/wrong+/pkg"
  touch "$RUNFILES_DIR/wrong+/pkg/f"

  # With the correct sed-equivalent prefix, "rules_shell+" is left unchanged
  # (no trailing safe chars to replace), so the compact row does not match.
  # rlocation falls back to the original path "dep/pkg/f".
  [ "$(rlocation "dep/pkg/f" "rules_shell+" || echo failed)" = "$RUNFILES_DIR/dep/pkg/f" ] || fail
}

test_directory_based_envvars() {
  export RUNFILES_DIR=mock/runfiles
  export RUNFILES_MANIFEST_FILE=
  . "$runfiles_lib_path"

  runfiles_export_envvars
  [ "${RUNFILES_DIR:-}" = "mock/runfiles" ] || fail
  [ -z "${RUNFILES_MANIFEST_FILE:-}" ] || fail
}

test_rlocation_auto_detects_source_repo_under_bash() {
  # Under bash, rlocation with no source-repo arg must walk BASH_SOURCE[2] via
  # runfiles_current_repository to identify the caller's repo — matching
  # runfiles.bash. Without this the repo mapping is silently resolved through
  # the main repo for every downstream sh_binary/sh_test.
  # Skipped under a POSIX shell (no BASH_SOURCE, no auto-detect possible).
  if ! command -v bash > /dev/null 2>&1; then
    return 0
  fi

  local tmpdir="$TEST_TMPDIR/test_rlocation_auto_detects_source_repo_under_bash"
  mkdir -p "$tmpdir"

  export RUNFILES_DIR="${tmpdir}/mock/runfiles"
  mkdir -p "$RUNFILES_DIR/some_repo+/pkg"

  # Repo mapping: from source repo "some_repo+", "dep" -> "realdep+".
  # Also add a main-repo row that maps "dep" somewhere ELSE, so we can tell
  # whether auto-detection ran (the caller lives in some_repo+, not _main).
  cat > "$RUNFILES_DIR/_repo_mapping" <<EOF
,dep,mainrepo_dep+
some_repo+,dep,realdep+
EOF

  mkdir -p "$RUNFILES_DIR/realdep+" "$RUNFILES_DIR/mainrepo_dep+"
  touch "$RUNFILES_DIR/realdep+/foo" "$RUNFILES_DIR/mainrepo_dep+/foo"

  # Helper lives at RUNFILES_DIR/some_repo+/pkg/caller.sh so
  # runfiles_current_repository can identify its repo as "some_repo+" via the
  # under-RUNFILES_DIR branch.
  cat > "$RUNFILES_DIR/some_repo+/pkg/caller.sh" <<HELPER
#!/bin/bash
# shellcheck disable=SC1090
. "$runfiles_lib_path"
rlocation "dep/foo"
HELPER
  chmod +x "$RUNFILES_DIR/some_repo+/pkg/caller.sh"

  export RUNFILES_MANIFEST_FILE=

  local actual
  actual=$(bash "$RUNFILES_DIR/some_repo+/pkg/caller.sh")
  [ "$actual" = "$RUNFILES_DIR/realdep+/foo" ] \
    || fail "expected $RUNFILES_DIR/realdep+/foo, got: $actual"
}

test_runfiles_current_repository_under_set_u() {
  export RUNFILES_DIR=
  export RUNFILES_MANIFEST_FILE=
  . "$runfiles_lib_path"

  # Enabling nounset must not crash runfiles_current_repository, regardless of
  # calling convention. rc is expected to be non-zero since no runfiles are
  # configured, but the function must not error on unbound $1.
  set -u
  runfiles_current_repository "$0" >/dev/null 2>&1 || :
  runfiles_current_repository >/dev/null 2>&1 || :
  set +u
}

# Platform detection must work without shelling out to uname. Drive
# __runfiles_detect_platform directly with a faked environment so that the
# Windows branches are covered on non-Windows hosts too.
test_platform_detection_without_uname() {
  export RUNFILES_DIR=
  export RUNFILES_MANIFEST_FILE=
  . "$runfiles_lib_path"

  tmpdir="$TEST_TMPDIR/test_platform_detection_without_uname"
  mkdir -p "$tmpdir"

  # A /proc/version that does not exist, so only the environment is consulted.
  absent="$tmpdir/absent"

  check_detection() {
    _what="$1"
    _want="$2"
    if [ "${_RLOCATION_ISABS_WINDOWS:-}" != "$_want" ] ||
      [ "${_RLOCATION_CASE_INSENSITIVE:-}" != "$_want" ]; then
      fail "$_what: expected windows='$_want', got" \
        "_RLOCATION_ISABS_WINDOWS='${_RLOCATION_ISABS_WINDOWS:-}'" \
        "_RLOCATION_CASE_INSENSITIVE='${_RLOCATION_CASE_INSENSITIVE:-}'"
    fi
  }

  # 1. MSYSTEM, set by every MSYS2 / MinGW / Git-for-Windows shell.
  (
    MSYSTEM=MINGW64 __runfiles_detect_platform "$absent"
    check_detection "MSYSTEM=MINGW64" 1
  ) || return 1

  # 2. OSTYPE, set by bash on Cygwin and MSYS.
  for ostype in cygwin msys win32; do
    (
      unset MSYSTEM
      OSTYPE="$ostype" __runfiles_detect_platform "$absent"
      check_detection "OSTYPE=$ostype" 1
    ) || return 1
  done

  # 3. /proc/version naming a Windows runtime.
  for procver in "CYGWIN_NT-10.0-19045 version 3.4.7" \
    "MSYS_NT-10.0-19045 version 3.4.7" \
    "MINGW64_NT-10.0-19045 version 3.4.7"; do
    echo "$procver" > "$tmpdir/proc_version"
    (
      unset MSYSTEM OSTYPE
      __runfiles_detect_platform "$tmpdir/proc_version"
      check_detection "/proc/version=$procver" 1
    ) || return 1
  done

  # 4. A Unix /proc/version wins over inherited Windows env vars: WSL can
  #    import WINDIR from the host through WSLENV and must not be mistaken for
  #    a Windows shell.
  echo "Linux version 5.15.0-1051-microsoft-standard-WSL2" > "$tmpdir/proc_version"
  (
    unset MSYSTEM OSTYPE
    WINDIR='C:\Windows' SYSTEMROOT='C:\Windows' \
      __runfiles_detect_platform "$tmpdir/proc_version"
    check_detection "WSL with WINDIR set" ""
  ) || return 1

  # 5. No /proc at all, but Windows env vars present.
  (
    unset MSYSTEM OSTYPE
    WINDIR='C:\Windows' __runfiles_detect_platform "$absent"
    check_detection "WINDIR without /proc" 1
  ) || return 1

  # 6. Nothing indicates Windows.
  (
    unset MSYSTEM OSTYPE WINDIR SystemRoot SYSTEMROOT
    __runfiles_detect_platform "$absent"
    check_detection "no Windows signals" ""
  ) || return 1

  # The library must leave no temporaries behind in the caller's environment.
  for leaked in _rf_dp_win _rf_dp_line _rf_dp_procver_file; do
    eval "_value=\${$leaked:-}"
    if [ -n "$_value" ]; then
      fail "detection leaked \$$leaked='$_value' into the environment"
    fi
  done
}

# A manifest lookup falls back to the longest path prefix of the requested
# path, to resolve files only reachable through a directory runfile. That
# prefix has to end on a path separator: `c/dir` must not be treated as a
# prefix of `c/dirx/file` or of `c/dirfile`. The shared bash suite has no such
# collision, so cover it here.
test_manifest_prefix_respects_path_boundaries() {
  tmpdir="$TEST_TMPDIR/test_manifest_prefix_respects_path_boundaries"
  rm -rf "$tmpdir"
  mkdir -p "$tmpdir/dir" "$tmpdir/dirx"
  touch "$tmpdir/dir/file" "$tmpdir/dirx/file" "$tmpdir/dirfile"
  echo "c/dir $tmpdir/dir" > "$tmpdir/manifest"

  export RUNFILES_DIR=
  export RUNFILES_MANIFEST_FILE="$tmpdir/manifest"
  . "$runfiles_lib_path"

  [ "$(rlocation c/dir/file)" = "$tmpdir/dir/file" ] \
    || fail "expected c/dir/file to resolve through the c/dir prefix"
  [ -z "$(rlocation c/dirx/file)" ] \
    || fail "c/dir must not be treated as a path prefix of c/dirx/file"
  [ -z "$(rlocation c/dirfile)" ] \
    || fail "c/dir must not be treated as a path prefix of c/dirfile"
  # The prefix walk must also stop at the shortest segment, not match a bare
  # substring of the first one.
  [ -z "$(rlocation c)" ] || fail "c must not resolve"
}

# Manifest matching is case-insensitive on Windows. The shared bash suite only
# covers that when actually running on Windows, so force the flag on here to
# get the branch exercised everywhere.
test_manifest_lookup_case_insensitive() {
  tmpdir="$TEST_TMPDIR/test_manifest_lookup_case_insensitive"
  rm -rf "$tmpdir"
  mkdir -p "$tmpdir/dir"
  touch "$tmpdir/f" "$tmpdir/dir/file"
  cat > "$tmpdir/manifest" <<EOF
A/B/File.TXT $tmpdir/f
C/Dir $tmpdir/dir
EOF

  export RUNFILES_DIR=
  export RUNFILES_MANIFEST_FILE="$tmpdir/manifest"
  . "$runfiles_lib_path"
  export _RLOCATION_CASE_INSENSITIVE=1

  [ "$(rlocation a/b/file.txt)" = "$tmpdir/f" ] \
    || fail "expected a case-insensitive exact match"
  [ "$(rlocation A/B/File.TXT)" = "$tmpdir/f" ] \
    || fail "expected the exact-case lookup to keep working"
  [ "$(rlocation c/dir/file)" = "$tmpdir/dir/file" ] \
    || fail "expected a case-insensitive prefix match"
  [ -z "$(rlocation c/dirx/file)" ] \
    || fail "case-insensitive matching must still respect path boundaries"
}

# Sourcing the library parses the manifest into an in-memory index, which every
# manifest test above goes through. The tests below cover the index itself:
# that it is built, that it answers the same as the scan it replaces, and that
# the entries it cannot hold still resolve. Keys are mangled into shell
# variable names, so paths differing only in a separator must not collide, and
# lookups run in a command substitution, so the index has to survive into a
# subshell.
test_manifest_index_is_built_and_keyed_injectively() {
  tmpdir="$TEST_TMPDIR/test_manifest_index_is_built_and_keyed_injectively"
  rm -rf "$tmpdir"
  mkdir -p "$tmpdir"
  # Every pair of these differs only in characters the mangling rewrites.
  for n in slash dot dash under plus; do touch "$tmpdir/$n"; done
  cat > "$tmpdir/manifest" <<EOF
r/a/b $tmpdir/slash
r/a.b $tmpdir/dot
r/a-b $tmpdir/dash
r/a_b $tmpdir/under
r/a+b $tmpdir/plus
EOF

  export RUNFILES_DIR=
  export RUNFILES_MANIFEST_FILE="$tmpdir/manifest"
  . "$runfiles_lib_path"

  [ "${_rf_ix_file:-}" = "$tmpdir/manifest" ] \
    || fail "sourcing the library did not index the manifest"

  for n in slash dot dash under plus; do
    case $n in
      slash) key="r/a/b" ;;
      dot)   key="r/a.b" ;;
      dash)  key="r/a-b" ;;
      under) key="r/a_b" ;;
      plus)  key="r/a+b" ;;
    esac
    [ "$(rlocation "$key")" = "$tmpdir/$n" ] \
      || fail "expected $key to resolve to $tmpdir/$n, got: $(rlocation "$key")"
  done
}

# The index holds the first entry for a key, the way the bash library's
# `grep -m1` does, and reports an entry with no value the way a scan does:
# absent for a direct lookup, but still the end of the prefix walk.
test_manifest_index_matches_scan_semantics() {
  tmpdir="$TEST_TMPDIR/test_manifest_index_matches_scan_semantics"
  rm -rf "$tmpdir"
  mkdir -p "$tmpdir/dir" "$tmpdir/other"
  touch "$tmpdir/first" "$tmpdir/second" "$tmpdir/dir/file" "$tmpdir/other/file"
  cat > "$tmpdir/manifest" <<EOF
r/dup $tmpdir/first
r/dup $tmpdir/second
r/empty
r/empty/nested $tmpdir/dir
r/out $tmpdir/other
EOF

  export RUNFILES_DIR=
  export RUNFILES_MANIFEST_FILE="$tmpdir/manifest"
  . "$runfiles_lib_path"
  [ "${_rf_ix_file:-}" = "$tmpdir/manifest" ] || fail "manifest was not indexed"

  [ "$(rlocation r/dup)" = "$tmpdir/first" ] \
    || fail "expected the first entry for a duplicated key to win"
  [ -z "$(rlocation r/empty)" ] \
    || fail "expected an entry with an empty value to count as absent"
  # r/empty is listed, so the walk up from r/empty/x stops there rather than
  # continuing to a shorter prefix, and the lookup resolves to nothing.
  [ -z "$(rlocation r/empty/x)" ] \
    || fail "expected the prefix walk to stop at the listed empty entry"
  [ "$(rlocation r/empty/nested/file)" = "$tmpdir/dir/file" ] \
    || fail "expected a longer prefix to still win over the empty one"
}

# Entries the index cannot hold -- escaped ones, and keys with a character the
# mangling has no encoding for -- have to keep resolving through the scan.
test_manifest_index_falls_back_to_scanning() {
  tmpdir="$TEST_TMPDIR/test_manifest_index_falls_back_to_scanning"
  rm -rf "$tmpdir"
  mkdir -p "$tmpdir"
  touch "$tmpdir/spaced" "$tmpdir/comma" "$tmpdir/tilde"
  cat > "$tmpdir/manifest" <<EOF
 r/with\sspace $tmpdir/spaced
r/with,comma $tmpdir/comma
r/with~tilde $tmpdir/tilde
EOF

  export RUNFILES_DIR=
  export RUNFILES_MANIFEST_FILE="$tmpdir/manifest"
  . "$runfiles_lib_path"
  [ "${_rf_ix_file:-}" = "$tmpdir/manifest" ] || fail "manifest was not indexed"

  [ "$(rlocation "r/with space")" = "$tmpdir/spaced" ] \
    || fail "expected an escaped entry to resolve through the scan"
  [ "$(rlocation "r/with,comma")" = "$tmpdir/comma" ] \
    || fail "expected a comma in a key to resolve through the scan"
  [ "$(rlocation "r/with~tilde")" = "$tmpdir/tilde" ] \
    || fail "expected a tilde in a key to resolve through the scan"
}

# An index is only valid for the manifest and the case-sensitivity mode it was
# built from. Changing either after sourcing must fall back to scanning rather
# than answer from a stale index.
test_manifest_index_is_bypassed_when_stale() {
  tmpdir="$TEST_TMPDIR/test_manifest_index_is_bypassed_when_stale"
  rm -rf "$tmpdir"
  mkdir -p "$tmpdir"
  touch "$tmpdir/one" "$tmpdir/two"
  echo "r/f $tmpdir/one" > "$tmpdir/manifest"
  echo "r/f $tmpdir/two" > "$tmpdir/manifest2"

  export RUNFILES_DIR=
  export RUNFILES_MANIFEST_FILE="$tmpdir/manifest"
  . "$runfiles_lib_path"

  export RUNFILES_MANIFEST_FILE="$tmpdir/manifest2"
  [ "$(rlocation r/f)" = "$tmpdir/two" ] \
    || fail "a manifest set after sourcing must not be answered from the index"

  export _RLOCATION_CASE_INSENSITIVE=1
  export RUNFILES_MANIFEST_FILE="$tmpdir/manifest"
  [ "$(rlocation r/f)" = "$tmpdir/one" ] \
    || fail "a case-sensitivity change must not be answered from the index"
}

# The case-insensitive index is unreachable on a Unix host without building it
# explicitly, since the mode is decided at source time. It only exists where
# the shell can fold case cheaply; otherwise there must be no index at all,
# rather than one with unfolded keys.
test_manifest_index_case_insensitive() {
  tmpdir="$TEST_TMPDIR/test_manifest_index_case_insensitive"
  rm -rf "$tmpdir"
  mkdir -p "$tmpdir/dir"
  touch "$tmpdir/f" "$tmpdir/dir/file"
  cat > "$tmpdir/manifest" <<EOF
A/B/File.TXT $tmpdir/f
C/Dir $tmpdir/dir
EOF

  export RUNFILES_DIR=
  export RUNFILES_MANIFEST_FILE="$tmpdir/manifest"
  . "$runfiles_lib_path"
  export _RLOCATION_CASE_INSENSITIVE=1
  __runfiles_index_build "$RUNFILES_MANIFEST_FILE"

  if [ -n "${_RUNFILES_INDEX_FOLD:-}" ]; then
    [ "${_rf_ix_file:-}" = "$tmpdir/manifest" ] \
      || fail "expected a case-insensitive index where folding is available"
  else
    [ -z "${_rf_ix_file:-}" ] \
      || fail "expected no index at all where folding is unavailable"
  fi

  [ "$(rlocation a/b/file.txt)" = "$tmpdir/f" ] \
    || fail "expected a case-insensitive exact match"
  [ "$(rlocation A/B/File.TXT)" = "$tmpdir/f" ] \
    || fail "expected the exact-case lookup to keep working"
  [ "$(rlocation c/dir/file)" = "$tmpdir/dir/file" ] \
    || fail "expected a case-insensitive prefix match"
  [ -z "$(rlocation c/dirx/file)" ] \
    || fail "case-insensitive matching must still respect path boundaries"
}

# RUNFILES_LIB_CACHE=0, which the generated launcher sets for itself, has to
# leave every lookup working -- by scanning.
test_manifest_index_disabled_by_env() {
  tmpdir="$TEST_TMPDIR/test_manifest_index_disabled_by_env"
  rm -rf "$tmpdir"
  mkdir -p "$tmpdir/dir"
  touch "$tmpdir/f" "$tmpdir/dir/file"
  cat > "$tmpdir/manifest" <<EOF
r/f $tmpdir/f
r/d $tmpdir/dir
EOF

  export RUNFILES_DIR=
  export RUNFILES_MANIFEST_FILE="$tmpdir/manifest"
  export RUNFILES_LIB_CACHE=0
  . "$runfiles_lib_path"
  unset RUNFILES_LIB_CACHE

  [ -z "${_rf_ix_file:-}" ] \
    || fail "RUNFILES_LIB_CACHE=0 must not index the manifest"
  [ "$(rlocation r/f)" = "$tmpdir/f" ] \
    || fail "expected an exact match without an index"
  [ "$(rlocation r/d/file)" = "$tmpdir/dir/file" ] \
    || fail "expected a prefix match without an index"
  [ -z "$(rlocation r/nope)" ] || fail "expected a miss without an index"
}

main() {
  manifest_file="${RUNFILES_MANIFEST_FILE:-}"
  dir="${RUNFILES_DIR:-}"
  runfiles_lib_path=$(find_runfiles_lib)

  tests="
    test_rlocation_call_requires_no_envvars
    test_rlocation_argument_validation
    test_rlocation_abs_path
    test_init_manifest_based_runfiles
    test_manifest_based_envvars
    test_init_directory_based_runfiles
    test_directory_based_runfiles_with_repo_mapping_from_main
    test_directory_based_runfiles_with_repo_mapping_from_other_repo
    test_directory_based_runfiles_with_repo_mapping_from_extension_repo
    test_manifest_based_runfiles_with_repo_mapping_from_main
    test_manifest_based_runfiles_with_repo_mapping_from_other_repo
    test_manifest_based_runfiles_with_repo_mapping_from_extension_repo
    test_directory_based_runfiles_with_repo_mapping_from_module_root_repo
    test_directory_based_envvars
    test_rlocation_auto_detects_source_repo_under_bash
    test_runfiles_current_repository_under_set_u
    test_platform_detection_without_uname
    test_manifest_prefix_respects_path_boundaries
    test_manifest_lookup_case_insensitive
    test_manifest_index_is_built_and_keyed_injectively
    test_manifest_index_matches_scan_semantics
    test_manifest_index_falls_back_to_scanning
    test_manifest_index_is_bypassed_when_stale
    test_manifest_index_case_insensitive
    test_manifest_index_disabled_by_env
  "
  failure=0
  for t in $tests; do
    export RUNFILES_MANIFEST_FILE="$manifest_file"
    export RUNFILES_DIR="$dir"
    log_info "Running $t"
    if ! ($t); then
      log_fail "$t"
      failure=1
    fi
  done
  return $failure
}

main
