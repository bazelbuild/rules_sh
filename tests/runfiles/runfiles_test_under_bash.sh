#!/bin/sh
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

# Runs the POSIX suite under bash.
#
# runfiles_test.sh carries a `#!/bin/sh` shebang, so on Linux it runs under
# dash and exercises the library's portable code paths. Their bash
# counterparts -- above all the manifest index, whose key mangling is a
# separate implementation under bash -- are what most users get, since the
# default sh_toolchain is bash on every platform.
set -eu
exec bash "$(dirname "$0")/runfiles_test.sh"
