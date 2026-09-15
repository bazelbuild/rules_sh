#!/bin/sh
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

# --- begin runfiles.sh initialization v1 ---
# Copy-pasted from the Bazel POSIX shell runfiles library v1.
set +e; f=shell/runfiles/runfiles.sh; _rf_p=
_rf_d() { [ -f "$1/$f" ] && _rf_p="$1/$f"; }
_rf_m() { [ -f "$1" ] || return 1; while IFS= read -r _rf_l || [ -n "$_rf_l" ]; do \
  case "$_rf_l" in "$f "*) _rf_p="${_rf_l#"$f "}"; return;; esac; done < "$1"; return 1; }
_rf_d "${RUNFILES_DIR:-/dev/null}" || _rf_m "${RUNFILES_MANIFEST_FILE:-/dev/null}" || \
  _rf_d "$0.runfiles" || _rf_m "$0.runfiles_manifest" || _rf_m "$0.exe.runfiles_manifest" || \
  { echo>&2 "ERROR: cannot find $f"; exit 1; }
# shellcheck disable=SC1090
. "$_rf_p"; f=; unset -f _rf_d _rf_m; unset _rf_l _rf_p; set -e
# --- end runfiles.sh initialization v1 ---

# Resolve the generated launcher (":bin"), not the raw source file, so that the
# launcher's own initialization snippet is exercised under the shell provided by
# the sh_toolchain.
bin_path="$(rlocation "rules_shell_tests/posix_launcher/bin")"
if [ ! -x "${bin_path}" ]; then
  echo "Expected '${bin_path}' to be an executable"
  exit 1
fi

runfiles_export_envvars

greeting=$("${bin_path}")
if [ "${greeting}" != "hello from rules_shell" ]; then
  echo "Expected 'hello from rules_shell', got '${greeting}'"
  exit 1
fi
