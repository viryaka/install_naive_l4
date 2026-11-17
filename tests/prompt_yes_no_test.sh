#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
function_source=$(sed -n '/^prompt_yes_no() {/,/^}/p' "${repo_root}/install.sh")
[[ -n "${function_source}" ]] || { echo "could not extract prompt_yes_no" >&2; exit 1; }
eval "${function_source}"

error() { echo "input error"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

assert_stdout() {
  local expected=$1 actual=$2 label=$3
  [[ "${actual}" == "${expected}" ]] || fail "${label}: expected stdout '${expected}', got '${actual}'"
}

assert_only_newline() {
  local file=$1 label=$2 first_line byte_count
  IFS= read -r first_line <"${file}" || fail "${label}: stderr did not contain a newline"
  [[ -z "${first_line}" ]] || fail "${label}: stderr did not start with a newline"
  byte_count=$(wc -c <"${file}" | tr -d ' ')
  [[ "${byte_count}" == 1 ]] || fail "${label}: expected exactly one stderr newline, got ${byte_count} bytes"
}

tmp_out=$(mktemp)
tmp_err=$(mktemp)
trap 'rm -f "${tmp_out}" "${tmp_err}"' EXIT

# Empty input uses the default N; explicit N and Y return only the decision.
actual=$(printf '\n' | prompt_yes_no "question" "N" 2>/dev/null)
assert_stdout N "${actual}" "default N"
actual=$(printf 'N\n' | prompt_yes_no "question" "Y" 2>/dev/null)
assert_stdout N "${actual}" "explicit N"
actual=$(printf 'Y\n' | prompt_yes_no "question" "N" 2>/dev/null)
assert_stdout Y "${actual}" "explicit Y"

# With default N, newline_before=true must not contaminate command substitution.
actual=$(printf '\n' | prompt_yes_no "question" "N" 0 true 2>"${tmp_err}")
assert_stdout N "${actual}" "default N with newline_before=true command substitution"
assert_only_newline "${tmp_err}" "default N with newline_before=true"

printf 'Y\n' | prompt_yes_no "question" "N" 0 true >"${tmp_out}" 2>"${tmp_err}"
assert_stdout Y "$(cat "${tmp_out}")" "newline_before=true"
assert_only_newline "${tmp_err}" "newline_before=true"

# Simulate read timeout without waiting; then the default answer is returned.
read() {
  if [[ ${1-} == -rt ]]; then return 1; fi
  builtin read "$@"
}
actual=$(prompt_yes_no "question" "N" 1 2>/dev/null)
assert_stdout N "${actual}" "timeout default N"
unset -f read

# Invalid input reports to stderr, retries, then returns only the valid answer.
printf 'invalid\nN\n' | prompt_yes_no "question" "Y" >"${tmp_out}" 2>"${tmp_err}"
assert_stdout N "$(cat "${tmp_out}")" "invalid then explicit N"
grep -q 'input error' "${tmp_err}" || fail "invalid input error was not written to stderr"

echo "prompt_yes_no regression tests passed"
