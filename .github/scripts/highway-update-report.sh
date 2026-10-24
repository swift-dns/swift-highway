#!/usr/bin/env bash

set -Eeuo pipefail
shopt -s failglob
IFS=$'\n\t'

log() { printf -- "** %s\n" "$*" >&2; }
error() { printf -- "** ERROR: %s\n" "$*" >&2; }
fatal() { error "$@"; exit 1; }

export LC_ALL=C

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly repository_root
readonly vendor_root="${repository_root}/HighwayReference/CHighway"

# The upstream files whose implementation of each op the generated C ops reproduce.
readonly -a followed_implementations=(
  "${vendor_root}/include/hwy/ops/arm_neon-inl.h"
  "${vendor_root}/include/hwy/ops/x86_128-inl.h"
  "${vendor_root}/include/hwy/ops/emu128-inl.h"
  "${vendor_root}/include/hwy/ops/generic_ops-inl.h"
)

# Highway's quick reference writes the name of every op it documents in bold.
documented_names() {
  local quick_reference="${1:?documented_names requires the path of a highway quick_reference.md}"

  if [[ ! -f "${quick_reference}" ]]; then
    fatal "There is no '${quick_reference}' to read highway's ops from"
  fi

  local bold_names
  if ! bold_names="$(grep -o '\*\*[A-Z][A-Za-z0-9_]*\*\*' "${quick_reference}")"; then
    fatal "Found no op names in '${quick_reference}'"
  fi

  printf -- '%s\n' "${bold_names}" | tr -d '*' | sort -u
  return 0
}

print_names() {
  local title="${1:?print_names requires the title of the list}"
  local names="${2?print_names requires the names to list, which may be empty}"

  printf -- '### %s\n\n' "${title}"
  if [[ -z "${names}" ]]; then
    printf -- '%s\n\n' "None."
    return 0
  fi

  local name
  while IFS= read -r name; do
    printf -- '%s\n' "- \`${name}\`"
  done <<< "${names}"
  printf -- '\n'
  return 0
}

print_implementation_changes() {
  printf -- '### %s\n\n' "Changes to the implementations the C ops reproduce"

  local changes
  if ! changes="$(git -C "${repository_root}" diff --stat -- "${followed_implementations[@]}")"; then
    fatal "Failed to diff the implementations the C ops reproduce"
  fi

  if [[ -z "${changes}" ]]; then
    printf -- '%s\n' "None."
    return 0
  fi

  printf -- '%s\n' '```' "${changes}" '```'
  return 0
}

main() {
  local previous_quick_reference="${1:?Usage: highway-update-report.sh <previous quick_reference.md>}"

  local previous_names current_names
  previous_names="$(documented_names "${previous_quick_reference}")"
  current_names="$(documented_names "${vendor_root}/quick_reference.md")"

  local added removed
  added="$(comm -13 <(printf -- '%s\n' "${previous_names}") <(printf -- '%s\n' "${current_names}"))"
  removed="$(comm -23 <(printf -- '%s\n' "${previous_names}") <(printf -- '%s\n' "${current_names}"))"

  print_names "Ops highway added" "${added}"
  print_names "Ops highway removed" "${removed}"
  print_implementation_changes
  return 0
}

main "$@"
