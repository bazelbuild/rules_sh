# shellcheck shell=sh
# shellcheck disable=SC3043
# Copyright 2026 The Bazel Authors. All rights reserved.
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

# Runfiles lookup library for Bazel-built shell binaries and tests.
# Pure POSIX shell implementation — no external binary dependencies.
#
# This is a POSIX shell port of runfiles.bash. It exposes the same public API
# -- rlocation, runfiles_export_envvars, runfiles_current_repository and
# runfiles_rlocation_checked -- and is validated against the same test suite.
# Everything runfiles.bash shells out to is reimplemented with shell builtins
# and parameter expansion: there are no grep, sed, awk, cut, tr, dirname,
# basename, wc, tail or uname calls, so the library has no dependency on the
# tools installed on the host.
#
# REPLACING runfiles.bash
#
# Swapping this library in for runfiles.bash does not change behavior. When the
# interpreter is bash -- which is what the sh_toolchain resolves to by default
# on every platform -- this library still reports the caller's repository from
# BASH_SOURCE, accepts the same 0-arg / numeric-index calling convention for
# runfiles_current_repository(), and exports its functions with `export -f` so
# they survive exec in a launcher.
#
# RUNNING UNDER A NON-BASH SHELL
#
# Pointing the sh_toolchain at dash, ash, busybox sh or similar is an
# additional capability rather than a mode of the above, and two things are
# necessarily different because the shell cannot express them:
# - There is no BASH_SOURCE, so runfiles_current_repository() needs the
#   caller's script path as its first argument, and rlocation() without a
#   second argument assumes the main repository rather than auto-detecting the
#   caller's. Portable callers should pass the source repo name explicitly.
# - There is no `export -f`, so functions cannot be inherited across exec and
#   every script must source this library itself.
#
# LOOKUP COST
#
# A lookup served from the runfiles directory costs a single stat. A lookup
# served from the manifest has to search it, and a POSIX shell has no bulk-read
# primitive -- `read` is its only way to get at a file -- so a scan of an
# N-line manifest costs O(N) at roughly 10us per line.
#
# Which of the two a script gets is not a property of the platform: like the
# bash library, this one uses the manifest whenever RUNFILES_MANIFEST_FILE
# names an existing file. On Linux a sandboxed `bazel test` sees only
# RUNFILES_DIR, while `bazel run` and a directly executed binary both export a
# manifest; on Windows there is no symlink tree, so everything searches.
#
# Sourcing this library parses the manifest once into an index that answers a
# lookup in constant time, and resolves the calling script's repository once.
# Lookups after that cost essentially nothing, which means:
#
# - Source this library once, at the top of the script. Sourcing it again --
#   in a function, a loop or a subshell -- parses the manifest again. Only the
#   sourcing shell can hold the index: `$(rlocation ...)` is a subshell, so it
#   inherits one but cannot build one.
# - A script that resolves only one or two paths can skip the parse by setting
#   RUNFILES_LIB_CACHE=0 before sourcing; its lookups scan instead. The
#   generated launcher, which resolves one path and execs, does this.
#
# Scanning remains the fallback, for the entries the index cannot hold and for
# a manifest chosen after the library was sourced:
# - A lookup that hits costs one scan, stopping at the matching line.
# - A lookup that misses costs one further scan, which resolves every path
#   prefix at once (see __runfiles_find_prefix).
# Per-line work in a scan is multiplied by the size of the manifest, so those
# loops reject a line with a single `case` and copy nothing until it matches.
#
# ENVIRONMENT:
# - If RUNFILES_LIB_DEBUG=1 is set, the script will print diagnostic messages
#   to stderr. Diagnostics emitted while the library is being sourced are lost
#   if the caller sources it with stderr redirected, as the bash snippet
#   (runfiles.bash initialization v3) does.
# - If RUNFILES_LIB_CACHE=0 is set when this library is sourced, it skips the
#   source-time manifest parse and scans for every lookup.
#
# USAGE:
# 1.  Depend on this runfiles library from your build rule:
#
#       sh_binary(
#           name = "my_binary",
#           ...
#           deps = ["@rules_shell//shell/runfiles"],
#       )
#
# 2.  Source the runfiles library.
#
#     The runfiles library itself defines rlocation which you would need to
#     look up the library's runtime location, thus we have a chicken-and-egg
#     problem. Insert the following code snippet to the top of your main
#     script:
#
#       # --- begin runfiles.sh initialization v1 ---
#       # Copy-pasted from the Bazel POSIX shell runfiles library v1.
#       set +e; f=shell/runfiles/runfiles.sh; _rf_p=
#       _rf_d() { [ -f "$1/$f" ] && _rf_p="$1/$f"; }
#       _rf_m() { [ -f "$1" ] || return 1; while IFS= read -r _rf_l || [ -n "$_rf_l" ]; do \
#         case "$_rf_l" in "$f "*) _rf_p="${_rf_l#"$f "}"; return;; esac; done < "$1"; return 1; }
#       _rf_d "${RUNFILES_DIR:-/dev/null}" || _rf_m "${RUNFILES_MANIFEST_FILE:-/dev/null}" || \
#         _rf_d "$0.runfiles" || _rf_m "$0.runfiles_manifest" || _rf_m "$0.exe.runfiles_manifest" || \
#         { echo>&2 "ERROR: cannot find $f"; exit 1; }
#       # shellcheck disable=SC1090
#       . "$_rf_p"; f=; unset -f _rf_d _rf_m; unset _rf_l _rf_p; set -e
#       # --- end runfiles.sh initialization v1 ---
#
#     The snippet resolves each candidate to an existing path before sourcing
#     it: `.` on a missing file is fatal in a POSIX shell, so sourcing
#     speculatively the way the bash snippet does would abort the script.
#     `_rf_d` checks a runfiles directory, `_rf_m` scans a runfiles manifest,
#     and the candidates are tried in the same order as in the bash snippet.
#
# 3.  Use rlocation to look up runfile paths.
#
#       cat "$(rlocation my_workspace/path/to/my/data.txt)"
#

# --- Initialization ---

if ! [ -d "${RUNFILES_DIR:-/dev/null}" ] && ! [ -f "${RUNFILES_MANIFEST_FILE:-/dev/null}" ]; then
  if [ -f "$0.runfiles_manifest" ]; then
    export RUNFILES_MANIFEST_FILE="$0.runfiles_manifest"
  elif [ -f "$0.runfiles/MANIFEST" ]; then
    export RUNFILES_MANIFEST_FILE="$0.runfiles/MANIFEST"
  elif [ -f "$0.runfiles/shell/runfiles/runfiles.sh" ]; then
    export RUNFILES_DIR="$0.runfiles"
  fi
fi

# Detects whether we are running in a Windows shell environment (MSYS2, MinGW
# or Cygwin) and sets _RLOCATION_ISABS_WINDOWS / _RLOCATION_CASE_INSENSITIVE
# accordingly. runfiles.bash shells out to `uname -s | tr ...` for this; here it
# is done with the environment and shell builtins only.
#
# Signals, in order of reliability:
#   1. MSYSTEM is set by every MSYS2, MinGW and Git-for-Windows shell.
#   2. OSTYPE is set by bash to "cygwin" / "msys" (absent under dash).
#   3. /proc/version names the runtime on Cygwin and MSYS2 ("CYGWIN_NT-...",
#      "MSYS_NT-...", "MINGW64_NT-..."). If the file exists and does not name
#      one of those, we are on a Unix-like system and must not consult the
#      Windows environment variables below -- WSL, for instance, can inherit
#      WINDIR from the host through WSLENV.
#   4. Only when there is no /proc at all (so, not Linux and not Cygwin/MSYS)
#      do WINDIR / SystemRoot indicate a Windows environment.
#
# $1 optionally overrides the /proc/version path so that the Windows branches
# can be covered by tests on non-Windows hosts.
__runfiles_detect_platform() {
  _rf_dp_procver_file="${1:-/proc/version}"
  _rf_dp_win=
  _rf_dp_line=

  if [ -n "${MSYSTEM:-}" ]; then
    _rf_dp_win=1
  else
    # OSTYPE is a bash variable and simply expands to the empty string under a
    # POSIX shell, which is why it is read through ${OSTYPE:-}. Consulting it
    # costs nothing and catches a Cygwin bash that has no MSYSTEM and no /proc.
    # shellcheck disable=SC3028
    case "${OSTYPE:-}" in
      cygwin*|msys*|win32*) _rf_dp_win=1 ;;
    esac
  fi

  if [ -z "$_rf_dp_win" ]; then
    if [ -r "$_rf_dp_procver_file" ]; then
      IFS= read -r _rf_dp_line < "$_rf_dp_procver_file" || :
      case "$_rf_dp_line" in
        *CYGWIN*|*Cygwin*|*cygwin*|*MSYS*|*Msys*|*msys*|*MINGW*|*Mingw*|*mingw*)
          _rf_dp_win=1
          ;;
      esac
    elif [ -n "${WINDIR:-}${SystemRoot:-}${SYSTEMROOT:-}" ]; then
      _rf_dp_win=1
    fi
  fi

  if [ -n "$_rf_dp_win" ]; then
    export _RLOCATION_ISABS_WINDOWS=1
    export _RLOCATION_CASE_INSENSITIVE=1
  else
    export _RLOCATION_ISABS_WINDOWS=
    export _RLOCATION_CASE_INSENSITIVE=
  fi

  _rf_dp_procver_file=
  _rf_dp_win=
  _rf_dp_line=
}

__runfiles_detect_platform

# Literal newline for use in case patterns and string comparisons.
_RUNFILES_NL='
'
export _RUNFILES_NL

# --- Internal helper functions ---

# Returns 0 if $1 is an absolute path, 1 otherwise.
__runfiles_is_abs() {
  case "$1" in
    /[!/]*) return 0 ;;
  esac
  if [ -n "$_RLOCATION_ISABS_WINDOWS" ]; then
    case "$1" in
      [a-zA-Z]:[/\\]*) return 0 ;;
    esac
  fi
  return 1
}

# Convert ASCII uppercase to lowercase (pure shell, no tr).
# Only called on Windows for case-insensitive path comparison. This is O(N^2)
# for a string of length N in most POSIX shells (each concat re-copies the
# output), so callers on hot paths should prefer __runfiles_line_starts_with_ci
# which compares char-by-char with early exit.
__runfiles_tolower() {
  _rf_tl_in="$1"
  _rf_tl_out=""
  while [ -n "$_rf_tl_in" ]; do
    _rf_tl_c="${_rf_tl_in%"${_rf_tl_in#?}"}"
    _rf_tl_in="${_rf_tl_in#?}"
    case "$_rf_tl_c" in
      A) _rf_tl_c=a;; B) _rf_tl_c=b;; C) _rf_tl_c=c;; D) _rf_tl_c=d;;
      E) _rf_tl_c=e;; F) _rf_tl_c=f;; G) _rf_tl_c=g;; H) _rf_tl_c=h;;
      I) _rf_tl_c=i;; J) _rf_tl_c=j;; K) _rf_tl_c=k;; L) _rf_tl_c=l;;
      M) _rf_tl_c=m;; N) _rf_tl_c=n;; O) _rf_tl_c=o;; P) _rf_tl_c=p;;
      Q) _rf_tl_c=q;; R) _rf_tl_c=r;; S) _rf_tl_c=s;; T) _rf_tl_c=t;;
      U) _rf_tl_c=u;; V) _rf_tl_c=v;; W) _rf_tl_c=w;; X) _rf_tl_c=x;;
      Y) _rf_tl_c=y;; Z) _rf_tl_c=z;;
    esac
    _rf_tl_out="${_rf_tl_out}${_rf_tl_c}"
  done
  printf '%s' "$_rf_tl_out"
}

# Return 0 iff the first ${#lpfx} chars of $line, lowercased, equal $lpfx.
# $lpfx must already be lowercase. Used on Windows for case-insensitive
# manifest scanning: it stops at the first mismatch, rather than lowercasing a
# whole line per iteration the way __runfiles_tolower would.
__runfiles_line_starts_with_ci() {
  _rf_lsw_line="$1"
  _rf_lsw_lpfx="$2"
  while [ -n "$_rf_lsw_lpfx" ]; do
    [ -z "$_rf_lsw_line" ] && return 1
    _rf_lsw_pc="${_rf_lsw_lpfx%"${_rf_lsw_lpfx#?}"}"
    _rf_lsw_lpfx="${_rf_lsw_lpfx#?}"
    _rf_lsw_lc="${_rf_lsw_line%"${_rf_lsw_line#?}"}"
    _rf_lsw_line="${_rf_lsw_line#?}"
    case "$_rf_lsw_lc" in
      A) _rf_lsw_lc=a;; B) _rf_lsw_lc=b;; C) _rf_lsw_lc=c;; D) _rf_lsw_lc=d;;
      E) _rf_lsw_lc=e;; F) _rf_lsw_lc=f;; G) _rf_lsw_lc=g;; H) _rf_lsw_lc=h;;
      I) _rf_lsw_lc=i;; J) _rf_lsw_lc=j;; K) _rf_lsw_lc=k;; L) _rf_lsw_lc=l;;
      M) _rf_lsw_lc=m;; N) _rf_lsw_lc=n;; O) _rf_lsw_lc=o;; P) _rf_lsw_lc=p;;
      Q) _rf_lsw_lc=q;; R) _rf_lsw_lc=r;; S) _rf_lsw_lc=s;; T) _rf_lsw_lc=t;;
      U) _rf_lsw_lc=u;; V) _rf_lsw_lc=v;; W) _rf_lsw_lc=w;; X) _rf_lsw_lc=x;;
      Y) _rf_lsw_lc=y;; Z) _rf_lsw_lc=z;;
    esac
    [ "$_rf_lsw_lc" != "$_rf_lsw_pc" ] && return 1
  done
  return 0
}

# Replace one or more consecutive backslashes with a single forward slash.
# Equivalent to: sed 's|\\\\*|/|g'
__runfiles_normalize_backslashes() {
  _rf_nb_in="$1"
  _rf_nb_out=""
  _rf_nb_bs=false
  while [ -n "$_rf_nb_in" ]; do
    _rf_nb_c="${_rf_nb_in%"${_rf_nb_in#?}"}"
    _rf_nb_in="${_rf_nb_in#?}"
    case "$_rf_nb_c" in
      "\\")
        if [ "$_rf_nb_bs" = false ]; then
          _rf_nb_out="${_rf_nb_out}/"
          _rf_nb_bs=true
        fi
        ;;
      *)
        _rf_nb_bs=false
        _rf_nb_out="${_rf_nb_out}${_rf_nb_c}"
        ;;
    esac
  done
  printf '%s' "$_rf_nb_out"
}

# Replace all occurrences of $2 in $1 with $3.
# Equivalent to: ${1//$2/$3} (bash-only).
__runfiles_gsub() {
  _rf_gs_in="$1"
  _rf_gs_old="$2"
  _rf_gs_new="$3"
  # An empty needle would loop forever: `*""*` matches unconditionally and the
  # parameter expansion strips nothing.
  if [ -z "$_rf_gs_old" ]; then
    printf '%s' "$_rf_gs_in"
    return 0
  fi
  _rf_gs_out=""
  while :; do
    case "$_rf_gs_in" in
      *"$_rf_gs_old"*)
        _rf_gs_out="${_rf_gs_out}${_rf_gs_in%%"$_rf_gs_old"*}${_rf_gs_new}"
        _rf_gs_in="${_rf_gs_in#*"$_rf_gs_old"}"
        ;;
      *)
        _rf_gs_out="${_rf_gs_out}${_rf_gs_in}"
        break
        ;;
    esac
  done
  printf '%s' "$_rf_gs_out"
}

# Encode a runfiles path for manifest lookup: \ -> \b, space -> \s.
# Newlines must be handled separately by the caller (\n).
# Equivalent to: sed 's/\\/\\b/g; s/ /\\s/g'
__runfiles_encode_manifest_path() {
  _rf_em_in="$1"
  _rf_em_out=""
  while [ -n "$_rf_em_in" ]; do
    _rf_em_c="${_rf_em_in%"${_rf_em_in#?}"}"
    _rf_em_in="${_rf_em_in#?}"
    case "$_rf_em_c" in
      "\\") _rf_em_out="${_rf_em_out}\\b" ;;
      " ")  _rf_em_out="${_rf_em_out}\\s" ;;
      *)    _rf_em_out="${_rf_em_out}${_rf_em_c}" ;;
    esac
  done
  printf '%s' "$_rf_em_out"
}

# Compute the wildcard prefix for repo mapping lookups, into _rf_cp_out.
# Replaces the rightmost run of safe chars ([-a-zA-Z0-9_.]) that follows a
# separator (non-safe char) with `*`, preserving any trailing non-safe chars.
# Leaves the input unchanged when there is no non-safe-followed-by-safe pair
# (e.g. `rules_shell+`, `protobuf+`, and other bzlmod module root names).
# Equivalent to: sed 's/\(.*[^-a-zA-Z0-9_.]\)[-a-zA-Z0-9_.]\{1,\}/\1*/'
#
# The result is stored rather than printed so that rlocation does not fork a
# subshell for it on every lookup.
__runfiles_compute_repo_prefix() {
  _rf_cp_repo="$1"
  # Phase 1: peel any trailing non-safe chars into $suffix. Sed keeps these
  # after the star (e.g. `my_module++ext+` -> `my_module++*+`).
  _rf_cp_suffix=""
  _rf_cp_head="$_rf_cp_repo"
  while [ -n "$_rf_cp_head" ]; do
    _rf_cp_last="${_rf_cp_head#"${_rf_cp_head%?}"}"
    case "$_rf_cp_last" in
      [-a-zA-Z0-9_.]) break ;;
      *)
        _rf_cp_suffix="${_rf_cp_last}${_rf_cp_suffix}"
        _rf_cp_head="${_rf_cp_head%?}"
        ;;
    esac
  done
  # Phase 2: peel the trailing safe run off $head. We only need to know
  # whether we stripped at least one safe char (sed requires ≥1).
  _rf_cp_stripped_safe=0
  while [ -n "$_rf_cp_head" ]; do
    _rf_cp_last="${_rf_cp_head#"${_rf_cp_head%?}"}"
    case "$_rf_cp_last" in
      [-a-zA-Z0-9_.])
        _rf_cp_stripped_safe=1
        _rf_cp_head="${_rf_cp_head%?}"
        ;;
      *) break ;;
    esac
  done
  # Sed requires BOTH ≥1 safe chars AND a non-safe char before them.
  if [ "$_rf_cp_stripped_safe" -eq 0 ] || [ -z "$_rf_cp_head" ]; then
    _rf_cp_out="$_rf_cp_repo"
    return 0
  fi
  _rf_cp_out="${_rf_cp_head}*${_rf_cp_suffix}"
}

# --- Manifest index ---
#
# A manifest lookup is a scan, so sourcing this library parses the manifest
# once into an in-memory index, and every lookup after that is O(1) in the
# manifest's size. See "LOOKUP COST" in the header.
#
# The parse happens at source time because the sourcing shell is the only one
# whose variables a lookup can see: rlocation prints its answer, so it is
# called as `$(rlocation ...)`, and a command substitution runs in a subshell
# that inherits those variables but cannot hand anything back.
#
# The only keyed store a POSIX shell has is its own variable namespace, so the
# index is a set of variables named `_rf_ci<generation>_<mangled key>`, read
# and written through `eval`. Values reach `eval` as a variable *reference*
# rather than as text, so nothing a manifest contains is ever evaluated as
# shell source.
#
# Two kinds of entry are left out of the index, and a lookup that needs one
# falls back to scanning:
#   - escaped entries, which start with a space and whose keys contain `\`
#   - keys holding a character the mangling cannot represent
# Neither can be a path prefix of a lookup the index does serve: an escaped key
# contains a space or a newline, and the mangling accepts a key only if every
# prefix of it is acceptable too. That is what lets __runfiles_find_prefix walk
# a path's prefixes through the index without missing a longer match.

# Configuration, exported alongside _RLOCATION_CASE_INSENSITIVE so that a
# script which inherits the library's functions through `export -f` rather than
# sourcing it still sees the same settings. The index itself is never exported:
# it would have to be copied into the environment of every process the script
# starts, and a process that inherits the functions can parse its own.
_RUNFILES_INDEX_OK=1   # whether the source-time caching is possible and wanted
_RUNFILES_INDEX_FOLD=  # whether the mangling can fold case cheaply

# Mutable state, never exported. Every read below tolerates it being unset, so
# that a process which inherits only the functions starts without believing in
# an index that its parent holds.
_rf_ix_file=       # manifest the current index was built from, empty if none
_rf_ix_ci=         # _RLOCATION_CASE_INSENSITIVE that index was built under
_rf_ix_pfx=        # variable-name prefix of the current index
_rf_ix_gen=0       # bumped per build, so replacing an index is O(1) rather
                   # than a walk that unsets every variable of the old one
_rf_rc_memo_key=   # inputs the memoized caller repository was resolved from
_rf_rc_memo_val=   # that caller's repository (see rlocation)

# RUNFILES_LIB_CACHE=0 turns the source-time work off, for a script that
# resolves one or two paths and cannot amortize a parse. The generated
# launcher sets it for itself and restores the caller's value before its exec.
case "${RUNFILES_LIB_CACHE:-}" in
  0) _RUNFILES_INDEX_OK= ;;
esac

# RUNFILES_LIB_PORTABLE_INDEX forces the pure-POSIX mangling even under bash,
# so that the test suite covers both implementations on one host.
#
# Case folding decides whether an index is possible at all on a
# case-insensitive platform: every key has to be lowercased on the way in, and
# without bash's ${var,,} that is a character-at-a-time loop over the whole
# manifest, which costs more than the index wins back. macOS still ships bash
# 3.2, which has no ${var,,}; Windows, the only case-insensitive platform,
# resolves its sh_toolchain to MSYS2 bash 5.
_rf_ix_bash=
if [ -n "${BASH_VERSION:-}" ] && [ -z "${RUNFILES_LIB_PORTABLE_INDEX:-}" ]; then
  _rf_ix_bash=1
  case "$BASH_VERSION" in
    [0-3].*) ;;
    *) _RUNFILES_INDEX_FOLD=1 ;;
  esac
fi
export _RUNFILES_INDEX_OK
export _RUNFILES_INDEX_FOLD

# Mangle the manifest key $1 into the tail of an index variable name, in
# _rf_ck. Returns 1 for a key that cannot be represented, whose lookups then
# fall back to scanning.
#
# The mapping stays injective by escaping `_` first: every literal `_` becomes
# `_u` before `/`, `.`, `-` and `+` introduce `_s`, `_d`, `_m` and `_p`.
# Without that, `a/b`, `a.b` and `a_b` would collide on a single entry.
#
# _RLOCATION_CASE_INSENSITIVE is read per call rather than baked in at source
# time, because the rest of the library reads it per call too and tests set it
# after sourcing to exercise the Windows path on a Unix host.
if [ -n "$_RUNFILES_INDEX_FOLD" ]; then
  # bash substitutes one character class per builtin operation; the portable
  # variant below costs three to five times as much on a 10k-line manifest.
  #
  # ${var,,} is bash 4 syntax, so the definition goes through `eval` to keep
  # bash 3 from having to parse it.
  eval '__runfiles_cache_key() {
    case "$1" in *[!A-Za-z0-9_/.+-]*) return 1 ;; esac
    if [ -n "$_RLOCATION_CASE_INSENSITIVE" ]; then
      _rf_ck="${1,,}"
    else
      _rf_ck="$1"
    fi
    _rf_ck="${_rf_ck//_/_u}"
    _rf_ck="${_rf_ck//\//_s}"
    _rf_ck="${_rf_ck//./_d}"
    _rf_ck="${_rf_ck//-/_m}"
    _rf_ck="${_rf_ck//+/_p}"
  }'
elif [ -n "$_rf_ix_bash" ]; then
  # bash 3: the substitutions are available but ${var,,} is not, so
  # __runfiles_index_ready keeps this variant away from case-insensitive
  # lookups.
  # shellcheck disable=SC3060  # guarded by the BASH_VERSION test above
  __runfiles_cache_key() {
    case "$1" in *[!A-Za-z0-9_/.+-]*) return 1 ;; esac
    _rf_ck="$1"
    _rf_ck="${_rf_ck//_/_u}"
    _rf_ck="${_rf_ck//\//_s}"
    _rf_ck="${_rf_ck//./_d}"
    _rf_ck="${_rf_ck//-/_m}"
    _rf_ck="${_rf_ck//+/_p}"
  }
else
  # The loop advances to the next character needing escaping rather than
  # walking the key one character at a time: a runfiles path has a handful of
  # separators among dozens of ordinary characters, and __runfiles_gsub would
  # have to make a full pass per character class.
  __runfiles_cache_key() {
    case "$1" in *[!A-Za-z0-9_/.+-]*) return 1 ;; esac
    _rf_ck_in="$1"
    _rf_ck=
    while :; do
      case "$_rf_ck_in" in
        *[_/.+-]*)
          _rf_ck_head="${_rf_ck_in%%[_/.+-]*}"
          _rf_ck_in="${_rf_ck_in#"$_rf_ck_head"}"
          _rf_ck_c="${_rf_ck_in%"${_rf_ck_in#?}"}"
          _rf_ck_in="${_rf_ck_in#?}"
          case $_rf_ck_c in
            _) _rf_ck_c=_u ;;
            /) _rf_ck_c=_s ;;
            .) _rf_ck_c=_d ;;
            -) _rf_ck_c=_m ;;
            +) _rf_ck_c=_p ;;
          esac
          _rf_ck="${_rf_ck}${_rf_ck_head}${_rf_ck_c}"
          ;;
        *)
          _rf_ck="${_rf_ck}${_rf_ck_in}"
          break
          ;;
      esac
    done
  }
fi

# Parse the manifest $1 into a fresh index, replacing any index already built.
# Leaves the library without an index -- every lookup then scans, which is
# always correct -- when $1 is not a file, when caching is off, or when keys
# would have to be folded on a shell that cannot fold them cheaply.
__runfiles_index_build() {
  _rf_ix_file=
  [ -n "${_RUNFILES_INDEX_OK:-}" ] || return 0
  [ -f "${1:-/dev/null}" ] || return 0
  if [ -n "$_RLOCATION_CASE_INSENSITIVE" ] && [ -z "${_RUNFILES_INDEX_FOLD:-}" ]; then
    return 0
  fi
  _rf_ix_gen=$((${_rf_ix_gen:-0} + 1))
  _rf_ix_pfx="_rf_ci${_rf_ix_gen}_"
  if [ "${RUNFILES_LIB_DEBUG:-}" = 1 ]; then
    echo >&2 "INFO[runfiles.sh]: indexing runfiles manifest ($1)"
  fi
  while IFS= read -r _rf_ib_line || [ -n "$_rf_ib_line" ]; do
    _rf_ib_key="${_rf_ib_line%% *}"
    # Rejects blank lines and escaped entries, which begin with a space.
    [ -n "$_rf_ib_key" ] || continue
    case "$_rf_ib_line" in *" "*) ;; *) continue ;; esac
    _rf_ib_val="${_rf_ib_line#* }"
    __runfiles_cache_key "$_rf_ib_key" || continue
    # An entry with an empty value is stored as a lone newline so that a lookup
    # can tell "listed, with no value" -- where the prefix walk stops -- from
    # "not listed", which reads back as empty too. A manifest value is a path
    # on a single line, so a lone newline is never one.
    [ -n "$_rf_ib_val" ] || _rf_ib_val="$_RUNFILES_NL"
    # ${name=value} assigns only when name is unset, so the first entry for a
    # key wins, matching the `grep -m1` the bash library does.
    eval ": \"\${${_rf_ix_pfx}${_rf_ck}=\$_rf_ib_val}\""
  done < "$1"
  _rf_ix_file="$1"
  _rf_ix_ci="$_RLOCATION_CASE_INSENSITIVE"
}

# Return 0 if lookups against the manifest $1 can be served from the index.
#
# An index is never built from here: a lookup usually runs in a command
# substitution's subshell, so it would be rebuilt per lookup and cost more than
# scanning. A script that points RUNFILES_MANIFEST_FILE at another manifest
# after sourcing therefore goes back to scanning, and can call
# __runfiles_index_build itself to index the new one.
__runfiles_index_ready() {
  [ -n "${_rf_ix_file:-}" ] && [ "$1" = "$_rf_ix_file" ] || return 1
  # Keys are folded on the way into the index, so an index is only usable in
  # the case-sensitivity mode it was built under.
  [ "$_RLOCATION_CASE_INSENSITIVE" = "${_rf_ix_ci:-}" ]
}

# Find the first line in $2 whose key is exactly $1 and store the value
# (everything after the key and the separating space) in _rf_fl_val.
# $1 must already be in manifest (escaped) form.
# On Windows (_RLOCATION_CASE_INSENSITIVE=1), matching is case-insensitive
# but the value is returned with its original casing.
#
# The result is stored rather than printed so that callers do not fork a
# subshell per lookup.
__runfiles_find_line() {
  _rf_fl_val=

  # An escaped search key starts with a space, so __runfiles_cache_key rejects
  # it and the lookup drops through to the scan, which is where escaped entries
  # live.
  if __runfiles_index_ready "$2" && __runfiles_cache_key "$1"; then
    eval "_rf_fl_val=\"\${${_rf_ix_pfx}${_rf_ck}-}\""
    [ -n "$_rf_fl_val" ] || return 1
    # A listed entry whose value is empty, which the scan reports the same way.
    [ "$_rf_fl_val" = "$_RUNFILES_NL" ] && _rf_fl_val=
    return 0
  fi

  _rf_fl_pfx_sp="$1 "

  if [ -n "$_RLOCATION_CASE_INSENSITIVE" ]; then
    _rf_fl_lpfx="$(__runfiles_tolower "$_rf_fl_pfx_sp")"
    _rf_fl_plen=${#_rf_fl_pfx_sp}
    while IFS= read -r _rf_fl_line || [ -n "$_rf_fl_line" ]; do
      if __runfiles_line_starts_with_ci "$_rf_fl_line" "$_rf_fl_lpfx"; then
        _rf_fl_val="$_rf_fl_line"
        _rf_fl_i=0
        while [ "$_rf_fl_i" -lt "$_rf_fl_plen" ]; do
          _rf_fl_val="${_rf_fl_val#?}"
          _rf_fl_i=$((_rf_fl_i + 1))
        done
        return 0
      fi
    done < "$2"
  else
    while IFS= read -r _rf_fl_line || [ -n "$_rf_fl_line" ]; do
      case "$_rf_fl_line" in
        "${_rf_fl_pfx_sp}"*)
          _rf_fl_val="${_rf_fl_line#"${_rf_fl_pfx_sp}"}"
          return 0
          ;;
      esac
    done < "$2"
  fi
  return 1
}

# Find the entry in $2 for the longest proper `/`-separated path prefix of the
# rlocation path $1. This resolves a file that is only reachable through a
# directory runfile, since a manifest lists the directory and not its contents.
#
# Resolving every prefix in one pass is a performance requirement rather than a
# style choice. runfiles.bash greps the manifest once per candidate prefix,
# which stays cheap because grep reads the file in large blocks, while here
# every scan is a `read` loop costing ~10µs per line. See "LOOKUP COST" in the
# header.
#
# Comparison happens in the manifest's own (escaped) domain, so that no line
# has to be decoded during the scan; only the winning entry is decoded, by the
# caller. On Windows matching is case-insensitive but values are returned with
# their original casing.
#
# Args: $1=rlocation path $2=manifest $3=escaped form of $1
#       $4=non-empty iff $1 has to be looked up in escaped form
# Sets:
#   _rf_fp_val     the matched value, still escaped
#   _rf_fp_esc     non-empty iff the matched entry was an escaped one
#   _rf_fp_suffix  the part of $1 below the matched key, to append to the value
# Returns 1 if no prefix matched.
__runfiles_find_prefix() {
  _rf_fp_path="$1"
  _rf_fp_epath="$3"
  _rf_fp_want_esc="$4"
  _rf_fp_val=
  _rf_fp_esc=
  _rf_fp_suffix=
  _rf_fp_key=
  _rf_fp_klen=0

  # The index holds exactly the unescaped entries, which is the set the scan
  # below considers when $4 is empty. Requiring $1 itself to be indexable is
  # what makes the walk complete: every prefix of an indexable key is itself
  # indexable, so no prefix can be hiding in the manifest unindexed.
  if [ -z "$_rf_fp_want_esc" ] && __runfiles_index_ready "$2" &&
    __runfiles_cache_key "$_rf_fp_path"; then
    # Walking the prefixes longest-first yields the longest matching key by
    # construction, which is what the single scan below computes the hard way.
    _rf_fp_t="${_rf_fp_path%/*}"
    while :; do
      __runfiles_cache_key "$_rf_fp_t" || return 1
      eval "_rf_fp_val=\"\${${_rf_ix_pfx}${_rf_ck}-}\""
      if [ -n "$_rf_fp_val" ]; then
        # A listed prefix with an empty value ends the walk, exactly as the
        # longest-match scan below would end on it.
        [ "$_rf_fp_val" = "$_RUNFILES_NL" ] && _rf_fp_val=
        _rf_fp_suffix="${_rf_fp_path#"$_rf_fp_t"}"
        return 0
      fi
      case "$_rf_fp_t" in
        */*) _rf_fp_t="${_rf_fp_t%/*}" ;;
        *) return 1 ;;
      esac
    done
  fi

  if [ -n "$_RLOCATION_CASE_INSENSITIVE" ]; then
    _rf_fp_lepath="$(__runfiles_tolower "$_rf_fp_epath")"
  fi

  # The body below runs once per manifest line, so everything that is not
  # needed to reject a line is deferred — in particular the value, which is
  # never copied out of a line that does not match. The reject is a single
  # quoted `case`: a manifest key can only be a prefix of $1 if $1 starts with
  # it, which is as selective as the pattern the bash library hands to grep.
  while IFS= read -r _rf_fp_line || [ -n "$_rf_fp_line" ]; do
    _rf_fp_k="${_rf_fp_line%% *}"
    if [ -z "$_rf_fp_k" ]; then
      # Leading space: an escaped entry, or a blank line.
      [ -n "$_rf_fp_want_esc" ] || continue
      _rf_fp_k="${_rf_fp_line# }"
      _rf_fp_k="${_rf_fp_k%% *}"
      [ -n "$_rf_fp_k" ] || continue
      _rf_fp_this_esc=1
    else
      _rf_fp_this_esc=
    fi
    if [ -n "$_RLOCATION_CASE_INSENSITIVE" ]; then
      _rf_fp_cmp="$(__runfiles_tolower "$_rf_fp_k")"
      _rf_fp_against="$_rf_fp_lepath"
    else
      _rf_fp_cmp="$_rf_fp_k"
      _rf_fp_against="$_rf_fp_epath"
    fi
    case "$_rf_fp_against" in
      "$_rf_fp_cmp"*) ;;
      *) continue ;;
    esac

    # Past this point the line is a genuine candidate, so the rest of the work
    # is off the hot path.
    #
    # The key has to end on a path separator: `c/dir` is a prefix of
    # `c/dir/file` but not of `c/dirx/file`.
    case "$_rf_fp_against" in
      "$_rf_fp_cmp"/*) ;;
      *) continue ;;
    esac
    # Only a longer key than the best one so far can win.
    [ "${#_rf_fp_k}" -gt "$_rf_fp_klen" ] || continue
    case "$_rf_fp_line" in *" "*) ;; *) continue ;; esac
    if [ -n "$_rf_fp_this_esc" ]; then
      _rf_fp_v="${_rf_fp_line# }"
      _rf_fp_v="${_rf_fp_v#* }"
    else
      _rf_fp_v="${_rf_fp_line#* }"
    fi
    # An entry with an empty value is treated as absent, matching the bash
    # library: it does not stop the walk up the path prefixes.
    [ -n "$_rf_fp_v" ] || continue
    _rf_fp_key="$_rf_fp_k"
    _rf_fp_klen=${#_rf_fp_k}
    _rf_fp_val="$_rf_fp_v"
    _rf_fp_esc="$_rf_fp_this_esc"
  done < "$2"

  [ -n "$_rf_fp_key" ] || return 1

  # Recover the unescaped suffix. The matched key is a whole number of path
  # segments of $1 and `/` is never escaped, so counting segments translates
  # between the escaped and unescaped forms without needing a decoder.
  _rf_fp_n=1
  _rf_fp_t="$_rf_fp_key"
  while :; do
    case "$_rf_fp_t" in
      */*) _rf_fp_t="${_rf_fp_t#*/}"; _rf_fp_n=$((_rf_fp_n + 1)) ;;
      *) break ;;
    esac
  done
  _rf_fp_t="$_rf_fp_path"
  _rf_fp_raw=
  while [ "$_rf_fp_n" -gt 0 ]; do
    _rf_fp_seg="${_rf_fp_t%%/*}"
    _rf_fp_t="${_rf_fp_t#"$_rf_fp_seg"}"
    _rf_fp_t="${_rf_fp_t#/}"
    _rf_fp_raw="${_rf_fp_raw}${_rf_fp_seg}/"
    _rf_fp_n=$((_rf_fp_n - 1))
  done
  _rf_fp_suffix="${_rf_fp_path#"${_rf_fp_raw%/}"}"
  return 0
}

# Find the first non-escaped manifest line whose value (target path) matches
# $1. Prints the key (rlocation path) on stdout.
# On Windows, matching is case-insensitive.
__runfiles_find_by_target() {
  _rf_ft_target="$1"
  _rf_ft_file="$2"

  if [ -n "$_RLOCATION_CASE_INSENSITIVE" ]; then
    _rf_ft_ltgt="$(__runfiles_tolower "$_rf_ft_target")"
    _rf_ft_tlen=${#_rf_ft_target}
    while IFS= read -r _rf_ft_line || [ -n "$_rf_ft_line" ]; do
      case "$_rf_ft_line" in " "*) continue ;; esac
      _rf_ft_key="${_rf_ft_line%% *}"
      _rf_ft_val="${_rf_ft_line#* }"
      # Cheap length check first — avoids per-char lowercasing when lengths
      # can't match.
      [ "${#_rf_ft_val}" = "$_rf_ft_tlen" ] || continue
      if __runfiles_line_starts_with_ci "$_rf_ft_val" "$_rf_ft_ltgt"; then
        printf '%s' "$_rf_ft_key"
        return 0
      fi
    done < "$_rf_ft_file"
  else
    while IFS= read -r _rf_ft_line || [ -n "$_rf_ft_line" ]; do
      # One quoted `case` rejects the ~all lines that do not match, without
      # copying anything out of them. A non-escaped entry contains exactly one
      # space, so ending in " $target" is the same test as its value being
      # $target; the split below re-checks it regardless.
      case "$_rf_ft_line" in
        " "*) continue ;;
        *" $_rf_ft_target") ;;
        *) continue ;;
      esac
      _rf_ft_key="${_rf_ft_line%% *}"
      _rf_ft_val="${_rf_ft_line#* }"
      if [ "$_rf_ft_val" = "$_rf_ft_target" ]; then
        printf '%s' "$_rf_ft_key"
        return 0
      fi
    done < "$_rf_ft_file"
  fi
  return 1
}

# Look up a repo mapping entry.
# Args: $1=source_repo $2=source_repo_prefix $3=target_apparent_name
#       $4=mapping_file
# Stores the canonical target repo name in _rf_rm_out and returns 1 if there is
# no entry. Stored rather than printed so that rlocation does not fork a
# subshell for it on every lookup.
# On Windows, matching is case-insensitive.
__runfiles_find_repo_mapping() {
  _rf_rm_src="$1"
  _rf_rm_pfx="$2"
  _rf_rm_tgt="$3"
  _rf_rm_file="$4"
  _rf_rm_out=

  if [ -n "$_RLOCATION_CASE_INSENSITIVE" ]; then
    _rf_rm_pfx_src="$(__runfiles_tolower "${_rf_rm_src},${_rf_rm_tgt},")"
    _rf_rm_pfx_pfx="$(__runfiles_tolower "${_rf_rm_pfx},${_rf_rm_tgt},")"
    while IFS= read -r _rf_rm_line || [ -n "$_rf_rm_line" ]; do
      # Compare only the prefix (src,tgt,) case-insensitively — a cheap early
      # exit for the ~all lines that don't match, without the O(N^2) lowercase
      # of a whole line.
      if __runfiles_line_starts_with_ci "$_rf_rm_line" "$_rf_rm_pfx_src" \
        || __runfiles_line_starts_with_ci "$_rf_rm_line" "$_rf_rm_pfx_pfx"; then
        _rf_rm_rest="${_rf_rm_line#*,}"
        _rf_rm_out="${_rf_rm_rest#*,}"
        return 0
      fi
    done < "$_rf_rm_file"
  else
    while IFS= read -r _rf_rm_line || [ -n "$_rf_rm_line" ]; do
      case "$_rf_rm_line" in
        "${_rf_rm_src},${_rf_rm_tgt},"*|"${_rf_rm_pfx},${_rf_rm_tgt},"*)
          _rf_rm_rest="${_rf_rm_line#*,}"
          _rf_rm_out="${_rf_rm_rest#*,}"
          return 0
          ;;
      esac
    done < "$_rf_rm_file"
  fi
  return 1
}

# Parse the repository name from an exec path.
# Scans path segments for /bazel-out/<config>/bin/external/<repo>/ or
# /bazel-bin/external/<repo>/ and returns the last matching <repo>.
# Equivalent to: grep -E -o '...' | tail -1 | awk -F/ '{print $(NF-1)}'
__runfiles_parse_exec_path_repo() {
  _rf_pe_path="$1"
  _rf_pe_result=""
  _rf_pe_rest="$_rf_pe_path"

  # Track last 4 path segments via a sliding window.
  _rf_pe_p4="" _rf_pe_p3="" _rf_pe_p2="" _rf_pe_p1=""
  while :; do
    case "$_rf_pe_rest" in
      */*)
        _rf_pe_seg="${_rf_pe_rest%%/*}"
        _rf_pe_rest="${_rf_pe_rest#*/}"
        ;;
      *)
        _rf_pe_seg="$_rf_pe_rest"
        _rf_pe_rest=""
        ;;
    esac

    # Pattern: bazel-bin/external/<repo>
    if [ "$_rf_pe_p2" = "bazel-bin" ] && [ "$_rf_pe_p1" = "external" ] \
       && [ -n "$_rf_pe_seg" ]; then
      _rf_pe_result="$_rf_pe_seg"
    fi
    # Pattern: bazel-out/<config>/bin/external/<repo>
    if [ "$_rf_pe_p4" = "bazel-out" ] && [ "$_rf_pe_p2" = "bin" ] \
       && [ "$_rf_pe_p1" = "external" ] && [ -n "$_rf_pe_seg" ]; then
      _rf_pe_result="$_rf_pe_seg"
    fi

    _rf_pe_p4="$_rf_pe_p3"
    _rf_pe_p3="$_rf_pe_p2"
    _rf_pe_p2="$_rf_pe_p1"
    _rf_pe_p1="$_rf_pe_seg"

    [ -z "$_rf_pe_rest" ] && break
  done

  if [ -n "$_rf_pe_result" ]; then
    printf '%s' "$_rf_pe_result"
    return 0
  fi
  return 1
}

# --- Public API ---

# Prints to stdout the runtime location of a data-dependency.
# The optional second argument specifies the canonical name of the repository
# whose repository mapping should be used to resolve the repository part of
# the provided path. If not specified:
#   * Under bash, the caller's repository is auto-detected via BASH_SOURCE
#     (matching runfiles.bash behavior). Because this file is aliased in as
#     the shell runfiles impl for every downstream sh_binary/sh_test when the
#     experimental flag is on, third-party bash callers depend on this.
#   * Under a pure POSIX shell there is no BASH_SOURCE, so the main repository
#     is assumed. Portable callers should pass the source repo explicitly.
rlocation() {
  if [ "${RUNFILES_LIB_DEBUG:-}" = 1 ]; then
    echo >&2 "INFO[runfiles.sh]: rlocation($1): start"
  fi
  if __runfiles_is_abs "$1"; then
    if [ "${RUNFILES_LIB_DEBUG:-}" = 1 ]; then
      echo >&2 "INFO[runfiles.sh]: rlocation($1): absolute path, return"
    fi
    printf '%s\n' "$1"
    return 0
  fi
  case "$1" in
    ../*|*/..|./*|*/./*|*/.|*//*) # shellcheck disable=SC2254
      if [ "${RUNFILES_LIB_DEBUG:-}" = 1 ]; then
        echo >&2 "ERROR[runfiles.sh]: rlocation($1): path is not normalized"
      fi
      return 1
      ;;
    \\*)
      if [ "${RUNFILES_LIB_DEBUG:-}" = 1 ]; then
        echo >&2 "ERROR[runfiles.sh]: rlocation($1): absolute path without" \
                 "drive name"
      fi
      return 1
      ;;
  esac

  if [ -f "${RUNFILES_REPO_MAPPING:-}" ]; then
    local target_repo_apparent_name="${1%%/*}"
    local remainder=
    case "$1" in
      */*) remainder="${1#*/}" ;;
    esac
    if [ -n "$remainder" ]; then
      local source_repo=""
      if [ -n "${2+x}" ]; then
        source_repo="$2"
      elif [ -n "${BASH_VERSION:-}" ]; then
        # Idx 2 walks past runfiles_current_repository and rlocation to the
        # actual caller, mirroring runfiles.bash; BASH_SOURCE[1] here is that
        # same frame, one call closer.
        #
        # The answer depends only on the caller's script and on where the
        # runfiles live, so it is memoized: resolving it costs a command
        # substitution plus, with a manifest, a scan matching on entry values,
        # which the index cannot serve. The memo is primed at source time for
        # the sourcing script and skipped under RUNFILES_LIB_DEBUG.
        local _rf_rc_key _rf_rc_src
        eval '_rf_rc_src="${BASH_SOURCE[1]:-}"'
        _rf_rc_key="$_rf_rc_src|${RUNFILES_MANIFEST_FILE:-}|${RUNFILES_DIR:-}|${PWD:-}"
        if [ "${RUNFILES_LIB_DEBUG:-}" != 1 ] &&
          [ "$_rf_rc_key" = "${_rf_rc_memo_key:-}" ]; then
          source_repo="$_rf_rc_memo_val"
        else
          # `|| true` preserves whatever repo name the parse-exec-path fallback
          # already printed to stdout, mirroring bash's `local -r x=$(...)`
          # where `local` masks the subshell's exit code.
          source_repo="$(runfiles_current_repository 2 || true)"
          _rf_rc_memo_key="$_rf_rc_key"
          _rf_rc_memo_val="$source_repo"
        fi
      fi
      if [ "${RUNFILES_LIB_DEBUG:-}" = 1 ]; then
        echo >&2 "INFO[runfiles.sh]: rlocation($1): looking up canonical name for ($target_repo_apparent_name) from ($source_repo) in ($RUNFILES_REPO_MAPPING)"
      fi
      local source_repo_prefix
      __runfiles_compute_repo_prefix "$source_repo"
      source_repo_prefix="$_rf_cp_out"
      if [ "${RUNFILES_LIB_DEBUG:-}" = 1 ]; then
        echo >&2 "INFO[runfiles.sh]: rlocation($1): matching source_repo ($source_repo) or prefix ($source_repo_prefix) with target ($target_repo_apparent_name)"
      fi
      local target_repo
      __runfiles_find_repo_mapping "$source_repo" "$source_repo_prefix" "$target_repo_apparent_name" "$RUNFILES_REPO_MAPPING" || true
      target_repo="$_rf_rm_out"
      if [ "${RUNFILES_LIB_DEBUG:-}" = 1 ]; then
        echo >&2 "INFO[runfiles.sh]: rlocation($1): canonical name of target repo is ($target_repo)"
      fi
      if [ -n "$target_repo" ]; then
        local rlocation_path="$target_repo/$remainder"
      else
        local rlocation_path="$1"
      fi
    else
      local rlocation_path="$1"
    fi
  else
    if [ "${RUNFILES_LIB_DEBUG:-}" = 1 ]; then
      echo >&2 "INFO[runfiles.sh]: rlocation($1): not using repository mapping (${RUNFILES_REPO_MAPPING:-}) since it does not exist"
    fi
    local rlocation_path="$1"
  fi

  runfiles_rlocation_checked "$rlocation_path"
}

# Exports the environment variables that subprocesses need in order to use
# runfiles.
# If a subprocess is a Bazel-built binary rule that also uses the runfiles
# libraries under @bazel_tools//tools/<lang>/runfiles, then that binary needs
# these envvars in order to initialize its own runfiles library.
runfiles_export_envvars() {
  if ! [ -f "${RUNFILES_MANIFEST_FILE:-/dev/null}" ] \
     && ! [ -d "${RUNFILES_DIR:-/dev/null}" ]; then
    return 1
  fi

  if ! [ -f "${RUNFILES_MANIFEST_FILE:-/dev/null}" ]; then
    if [ -f "$RUNFILES_DIR/MANIFEST" ]; then
      export RUNFILES_MANIFEST_FILE="$RUNFILES_DIR/MANIFEST"
    elif [ -f "${RUNFILES_DIR}_manifest" ]; then
      export RUNFILES_MANIFEST_FILE="${RUNFILES_DIR}_manifest"
    else
      export RUNFILES_MANIFEST_FILE=
    fi
  elif ! [ -d "${RUNFILES_DIR:-/dev/null}" ]; then
    case "$RUNFILES_MANIFEST_FILE" in
      */MANIFEST)
        if [ -d "${RUNFILES_MANIFEST_FILE%/MANIFEST}" ]; then
          export RUNFILES_DIR="${RUNFILES_MANIFEST_FILE%/MANIFEST}"
          export JAVA_RUNFILES="$RUNFILES_DIR"
        else
          export RUNFILES_DIR=
        fi
        ;;
      *_manifest)
        if [ -d "${RUNFILES_MANIFEST_FILE%_manifest}" ]; then
          export RUNFILES_DIR="${RUNFILES_MANIFEST_FILE%_manifest}"
          export JAVA_RUNFILES="$RUNFILES_DIR"
        else
          export RUNFILES_DIR=
        fi
        ;;
      *)
        export RUNFILES_DIR=
        ;;
    esac
  fi
}

# Returns the canonical name of the Bazel repository containing the calling
# script.
#
# Calling convention:
#   * Under bash, this matches runfiles.bash: the optional first argument is
#     a numeric index N (default 1) selecting the N-th caller via BASH_SOURCE.
#     This lets bash consumers that source this file — either directly or via
#     the launcher — call runfiles_current_repository with no arguments.
#   * Under a POSIX shell there is no BASH_SOURCE, so the caller must supply
#     its own script path as the first argument:
#
#       runfiles_current_repository "$0"
#
# Note: This function only works correctly with Bzlmod enabled. Without
# Bzlmod, its return value is ignored if passed to rlocation.
runfiles_current_repository() {
  local raw_caller_path=
  local _rf_arg="${1:-}"
  # Non-numeric arg: caller passed a script path (POSIX calling convention).
  # Accepted under both bash and POSIX so portable scripts work.
  case "$_rf_arg" in
    *[!0-9]*) raw_caller_path="$_rf_arg" ;;
  esac
  if [ -z "$raw_caller_path" ]; then
    if [ -n "${BASH_VERSION:-}" ]; then
      # Empty arg defaults to idx=1 (bash convention, N-th caller).
      # BASH_SOURCE array indexing is bash-only syntax; hide it from POSIX
      # shells via eval so parsing succeeds. `:-` guards against out-of-bounds
      # indices under `set -u`.
      eval 'raw_caller_path="${BASH_SOURCE[${_rf_arg:-1}]:-}"'
      if [ -z "$raw_caller_path" ]; then
        if [ "${RUNFILES_LIB_DEBUG:-}" = 1 ]; then
          echo >&2 "ERROR[runfiles.sh]: runfiles_current_repository: no caller" \
                   "path resolvable from BASH_SOURCE (idx=${_rf_arg:-1} out of range)"
        fi
        return 1
      fi
    else
      if [ "${RUNFILES_LIB_DEBUG:-}" = 1 ]; then
        if [ -z "$_rf_arg" ]; then
          echo >&2 "ERROR[runfiles.sh]: runfiles_current_repository: caller" \
                   "path argument is required under a POSIX shell (pass \"\$0\")"
        else
          echo >&2 "ERROR[runfiles.sh]: runfiles_current_repository: numeric" \
                   "caller index ($_rf_arg) requires bash; pass the caller" \
                   "path (\"\$0\") instead"
        fi
      fi
      return 1
    fi
  fi
  if __runfiles_is_abs "$raw_caller_path"; then
    local caller_path="$raw_caller_path"
  else
    # dirname/basename without external binaries
    local _rf_dir _rf_base
    case "$raw_caller_path" in
      */*) _rf_dir="${raw_caller_path%/*}"; [ -z "$_rf_dir" ] && _rf_dir="/" ;;
      *)   _rf_dir="." ;;
    esac
    _rf_base="${raw_caller_path##*/}"
    local caller_path
    caller_path="$(cd "$_rf_dir" || return 1; pwd)/$_rf_base"
  fi
  if [ "${RUNFILES_LIB_DEBUG:-}" = 1 ]; then
    echo >&2 "INFO[runfiles.sh]: runfiles_current_repository(${1:-}): caller's path is ($caller_path)"
  fi

  local rlocation_path=

  # If the runfiles manifest exists, search for an entry with target the
  # caller's path.
  if [ -f "${RUNFILES_MANIFEST_FILE:-/dev/null}" ]; then
    local normalized_caller_path
    normalized_caller_path="$(__runfiles_normalize_backslashes "$caller_path")"
    local escaped_caller_path="$normalized_caller_path"
    rlocation_path="$(__runfiles_find_by_target "$escaped_caller_path" "$RUNFILES_MANIFEST_FILE")" || true
    if [ -z "$rlocation_path" ]; then
      if [ "${RUNFILES_LIB_DEBUG:-}" = 1 ]; then
        echo >&2 "ERROR[runfiles.sh]: runfiles_current_repository(${1:-}): ($normalized_caller_path) is not the target of an entry in the runfiles manifest ($RUNFILES_MANIFEST_FILE)"
      fi
      local repository
      repository="$(__runfiles_parse_exec_path_repo "$normalized_caller_path")" || true
      if [ -n "$repository" ]; then
        if [ "${RUNFILES_LIB_DEBUG:-}" = 1 ]; then
          echo >&2 "INFO[runfiles.sh]: runfiles_current_repository(${1:-}): ($normalized_caller_path) lies in repository ($repository) (parsed exec path)"
        fi
        printf '%s\n' "$repository"
      else
        if [ "${RUNFILES_LIB_DEBUG:-}" = 1 ]; then
          echo >&2 "INFO[runfiles.sh]: runfiles_current_repository(${1:-}): ($normalized_caller_path) lies in the main repository (parsed exec path)"
        fi
        printf '%s\n' ""
      fi
      return 1
    else
      if [ "${RUNFILES_LIB_DEBUG:-}" = 1 ]; then
        echo >&2 "INFO[runfiles.sh]: runfiles_current_repository(${1:-}): ($normalized_caller_path) is the target of ($rlocation_path) in the runfiles manifest"
      fi
    fi
  fi

  # If the runfiles directory exists, check if the caller's path is of the
  # form $RUNFILES_DIR/rlocation_path and if so, set $rlocation_path.
  if [ -z "$rlocation_path" ] && [ -d "${RUNFILES_DIR:-/dev/null}" ]; then
    local normalized_caller_path normalized_dir
    normalized_caller_path="$(__runfiles_normalize_backslashes "$caller_path")"
    local _rf_rd="${RUNFILES_DIR%/}"
    _rf_rd="${_rf_rd%\\}"
    normalized_dir="$(__runfiles_normalize_backslashes "$_rf_rd")"
    if [ -n "$_RLOCATION_CASE_INSENSITIVE" ]; then
      normalized_caller_path="$(__runfiles_tolower "$normalized_caller_path")"
      normalized_dir="$(__runfiles_tolower "$normalized_dir")"
    fi
    case "$normalized_caller_path" in
      "$normalized_dir"/*)
        rlocation_path="${normalized_caller_path#"$normalized_dir"}"
        rlocation_path="${rlocation_path#/}"
        ;;
    esac
    if [ -z "$rlocation_path" ]; then
      if [ "${RUNFILES_LIB_DEBUG:-}" = 1 ]; then
        echo >&2 "INFO[runfiles.sh]: runfiles_current_repository(${1:-}): ($normalized_caller_path) does not lie under the runfiles directory ($normalized_dir)"
      fi
      local repository
      repository="$(__runfiles_parse_exec_path_repo "$normalized_caller_path")" || true
      if [ -n "$repository" ]; then
        if [ "${RUNFILES_LIB_DEBUG:-}" = 1 ]; then
          echo >&2 "INFO[runfiles.sh]: runfiles_current_repository(${1:-}): ($normalized_caller_path) lies in repository ($repository) (parsed exec path)"
        fi
        printf '%s\n' "$repository"
      else
        if [ "${RUNFILES_LIB_DEBUG:-}" = 1 ]; then
          echo >&2 "INFO[runfiles.sh]: runfiles_current_repository(${1:-}): ($normalized_caller_path) lies in the main repository (parsed exec path)"
        fi
        printf '%s\n' ""
      fi
      return 0
    else
      if [ "${RUNFILES_LIB_DEBUG:-}" = 1 ]; then
        echo >&2 "INFO[runfiles.sh]: runfiles_current_repository(${1:-}): ($caller_path) has path ($rlocation_path) relative to the runfiles directory ($RUNFILES_DIR)"
      fi
    fi
  fi

  if [ -z "$rlocation_path" ]; then
    if [ "${RUNFILES_LIB_DEBUG:-}" = 1 ]; then
      echo >&2 "ERROR[runfiles.sh]: runfiles_current_repository(${1:-}): cannot determine repository for ($caller_path) since neither the runfiles directory (${RUNFILES_DIR:-}) nor the runfiles manifest (${RUNFILES_MANIFEST_FILE:-}) exist"
    fi
    return 1
  fi

  if [ "${RUNFILES_LIB_DEBUG:-}" = 1 ]; then
    echo >&2 "INFO[runfiles.sh]: runfiles_current_repository(${1:-}): ($caller_path) corresponds to rlocation path ($rlocation_path)"
  fi
  # Normalize the rlocation path to be of the form repo/pkg/file.
  rlocation_path="${rlocation_path#_main/external/}"
  rlocation_path="${rlocation_path#_main/../}"
  local repository="${rlocation_path%%/*}"
  if [ "$repository" = "_main" ]; then
    if [ "${RUNFILES_LIB_DEBUG:-}" = 1 ]; then
      echo >&2 "INFO[runfiles.sh]: runfiles_current_repository(${1:-}): ($rlocation_path) lies in the main repository"
    fi
    printf '%s\n' ""
  else
    if [ "${RUNFILES_LIB_DEBUG:-}" = 1 ]; then
      echo >&2 "INFO[runfiles.sh]: runfiles_current_repository(${1:-}): ($rlocation_path) lies in repository ($repository)"
    fi
    printf '%s\n' "$repository"
  fi
}

runfiles_rlocation_checked() {
  # FIXME: If the runfiles lookup fails, the exit code of this function is 0
  #  if and only if the runfiles manifest exists. In particular, the exit code
  #  behavior is not consistent across platforms.
  # The manifest takes precedence over the runfiles directory: whether the
  # directory is populated is a property of the execution of the action or
  # test, which is not known at analysis time, so the directory may exist but
  # contain stale contents from a previous execution. If the manifest exists,
  # it is always authoritative. Matches runfiles.bash:377-380.
  if [ -f "${RUNFILES_MANIFEST_FILE:-/dev/null}" ]; then
    if [ "${RUNFILES_LIB_DEBUG:-}" = 1 ]; then
      echo >&2 "INFO[runfiles.sh]: rlocation($1): looking in RUNFILES_MANIFEST_FILE ($RUNFILES_MANIFEST_FILE)"
    fi
    # If the rlocation path contains a space or newline, it is stored in the
    # manifest prefixed with a space and with spaces, newlines and backslashes
    # escaped as \s, \n and \b.
    local search_key escaped suffix
    case "$1" in
      *" "*|*"$_RUNFILES_NL"*)
        search_key="$(__runfiles_encode_manifest_path "$1")"
        search_key="$(__runfiles_gsub "$search_key" "$_RUNFILES_NL" '\n')"
        escaped=1
        if [ "${RUNFILES_LIB_DEBUG:-}" = 1 ]; then
          echo >&2 "INFO[runfiles.sh]: rlocation($1): using escaped search key ($search_key)"
        fi
        ;;
      *)
        search_key="$1"
        escaped=
        ;;
    esac

    # Look for $1 itself first: the overwhelmingly common case, served by the
    # index or by a scan that rejects a line with a single `case`.
    #
    # An entry with an empty value counts as absent, matching the bash
    # library, hence the test on _rf_fl_val rather than on the exit status.
    local result=
    if __runfiles_find_line "${escaped:+ }$search_key" "$RUNFILES_MANIFEST_FILE" &&
      [ -n "$_rf_fl_val" ]; then
      result="$_rf_fl_val"
      suffix=
    elif [ "${1%/*}" != "$1" ] &&
      __runfiles_find_prefix "$1" "$RUNFILES_MANIFEST_FILE" "$search_key" "$escaped"; then
      # $1 is not listed, but it may lie under a directory that is. One extra
      # scan resolves every path prefix at once; a path without a separator
      # skips the walk entirely, as the _repo_mapping lookup does.
      result="$_rf_fp_val"
      escaped="$_rf_fp_esc"
      suffix="$_rf_fp_suffix"
    else
      if [ "${RUNFILES_LIB_DEBUG:-}" = 1 ]; then
        echo >&2 "INFO[runfiles.sh]: rlocation($1): not found in manifest"
      fi
      printf '%s\n' ""
      return 0
    fi
    if [ -n "$escaped" ]; then
      result="$(__runfiles_gsub "$result" '\n' "$_RUNFILES_NL")"
      result="$(__runfiles_gsub "$result" '\b' '\')"
    fi
    result="${result}${suffix}"
    if [ -e "$result" ]; then
      if [ "${RUNFILES_LIB_DEBUG:-}" = 1 ]; then
        echo >&2 "INFO[runfiles.sh]: rlocation($1): found in manifest as ($result)"
      fi
      printf '%s\n' "$result"
    else
      # The manifest lookup succeeded but the file is not there. When the hit
      # came from a path prefix we deliberately do not retry with a shorter
      # one, for two reasons:
      # 1. Manifests generated by Bazel never contain a path that is a prefix
      #    of another path.
      # 2. Runfiles libraries for other languages do not check for file
      #    existence and would have returned the non-existent path. It seems
      #    better to return no path rather than a potentially different,
      #    non-empty path.
      if [ "${RUNFILES_LIB_DEBUG:-}" = 1 ]; then
        echo >&2 "INFO[runfiles.sh]: rlocation($1): found in manifest as ($result), but file does not exist"
      fi
      printf '%s\n' ""
    fi
  elif [ -e "${RUNFILES_DIR:-/dev/null}/$1" ]; then
    if [ "${RUNFILES_LIB_DEBUG:-}" = 1 ]; then
      echo >&2 "INFO[runfiles.sh]: rlocation($1): found under RUNFILES_DIR ($RUNFILES_DIR), return"
    fi
    printf '%s\n' "${RUNFILES_DIR}/$1"
  else
    if [ "${RUNFILES_LIB_DEBUG:-}" = 1 ]; then
      echo >&2 "ERROR[runfiles.sh]: cannot look up runfile \"$1\" " \
               "(RUNFILES_DIR=\"${RUNFILES_DIR:-}\"," \
               "RUNFILES_MANIFEST_FILE=\"${RUNFILES_MANIFEST_FILE:-}\")"
    fi
    return 1
  fi
}

# When running under bash, export functions so they survive exec (used by the
# bash launcher). POSIX sh has no equivalent of `export -f``, so this block is
# skipped in pure POSIX shells.
# shellcheck disable=SC3045
if [ -n "${BASH_VERSION:-}" ]; then
  export -f __runfiles_detect_platform
  export -f __runfiles_is_abs
  export -f __runfiles_tolower
  export -f __runfiles_line_starts_with_ci
  export -f __runfiles_normalize_backslashes
  export -f __runfiles_gsub
  export -f __runfiles_encode_manifest_path
  export -f __runfiles_compute_repo_prefix
  export -f __runfiles_cache_key
  export -f __runfiles_index_build
  export -f __runfiles_index_ready
  export -f __runfiles_find_line
  export -f __runfiles_find_prefix
  export -f __runfiles_find_by_target
  export -f __runfiles_find_repo_mapping
  export -f __runfiles_parse_exec_path_repo
  export -f rlocation
  export -f runfiles_export_envvars
  export -f runfiles_current_repository
  export -f runfiles_rlocation_checked
fi

# --- Source-time caching ---
#
# Everything below runs in the shell that sourced this file, the only shell
# whose variables every later `$(rlocation ...)` subshell inherits, so it is
# done once for the whole script. RUNFILES_LIB_CACHE=0 turns it off.

# Parse the manifest into an index, so that lookups do not scan it. This also
# makes the _repo_mapping lookup below a constant-time one.
__runfiles_index_build "${RUNFILES_MANIFEST_FILE:-}"

# The repo mapping manifest may not exist with old versions of Bazel.
RUNFILES_REPO_MAPPING=$(runfiles_rlocation_checked _repo_mapping || echo "")
export RUNFILES_REPO_MAPPING

# Resolve the sourcing script's repository once and prime rlocation's memo with
# it. Without a repo mapping rlocation never asks for it, and under a POSIX
# shell it cannot be detected at all, so both cases skip this.
#
# The two BASH_SOURCE indices below name the same frame, the sourcing script,
# counted from two different places: index 1 at the top level of a sourced
# file, one more from inside the runfiles_current_repository call. It is the
# frame rlocation reads as BASH_SOURCE[1], which is what makes the key match.
if [ -n "${_RUNFILES_INDEX_OK:-}" ] && [ -n "${BASH_VERSION:-}" ] &&
  [ "${RUNFILES_LIB_DEBUG:-}" != 1 ] && [ -f "${RUNFILES_REPO_MAPPING:-}" ]; then
  eval '_rf_rc_memo_key="${BASH_SOURCE[1]:-}"'
  if [ -n "$_rf_rc_memo_key" ]; then
    _rf_rc_memo_val="$(runfiles_current_repository 2 || true)"
    _rf_rc_memo_key="$_rf_rc_memo_key|${RUNFILES_MANIFEST_FILE:-}|${RUNFILES_DIR:-}|${PWD:-}"
  fi
fi
