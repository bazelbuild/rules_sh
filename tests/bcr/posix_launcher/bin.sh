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

# Built with use_bash_launcher = True. A POSIX shell has no `export -f`, so the
# launcher's runfiles functions do not survive its exec; only RUNFILES_DIR and
# RUNFILES_MANIFEST_FILE do. This script therefore initializes the library
# itself.

# The launcher turns the library's source-time manifest parse off for itself.
# That must not reach this script, a normal consumer that gets the default.
if [ -n "${RUNFILES_LIB_CACHE:-}" ]; then
  echo >&2 "ERROR: launcher leaked RUNFILES_LIB_CACHE=${RUNFILES_LIB_CACHE}"
  exit 1
fi

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

# shellcheck disable=SC1090
. "$(rlocation "rules_shell_tests/posix_launcher/lib.sh")"

get_greeting
