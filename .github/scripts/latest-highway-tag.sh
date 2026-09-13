#!/usr/bin/env bash

set -Eeuo pipefail
shopt -s failglob
IFS=$'\n\t'

log() { printf -- "** %s\n" "$*" >&2; }
error() { printf -- "** ERROR: %s\n" "$*" >&2; }
fatal() { error "$@"; exit 1; }

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly repository_root
readonly version_file="${repository_root}/highway-version.json"

upstream_repository() {
  local repository
  if ! repository="$(jq -er '.repository' "${version_file}")"; then
    fatal "'${version_file}' has no 'repository' field"
  fi

  printf -- '%s\n' "${repository}"
  return 0
}

# Upstream tags its releases as plain '1.2.3', so anything else is not a release of it.
latest_release_tag() {
  local repository="${1:?latest_release_tag requires the upstream repository url}"

  local tags
  if ! tags="$(git ls-remote --tags --refs "${repository}")"; then
    fatal "Failed to list the tags of '${repository}'"
  fi

  local latest
  latest="$(
    printf -- '%s\n' "${tags}" \
      | sed -n 's|.*refs/tags/\([0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}\)$|\1|p' \
      | sort -V \
      | tail -n 1
  )"

  if [[ -z "${latest}" ]]; then
    fatal "Found no release tags in '${repository}'"
  fi

  printf -- '%s\n' "${latest}"
  return 0
}

commit_of_tag() {
  local repository="${1:?commit_of_tag requires the upstream repository url}"
  local tag="${2:?commit_of_tag requires the tag to resolve}"

  local references
  if ! references="$(
    git ls-remote "${repository}" "refs/tags/${tag}" "refs/tags/${tag}^{}"
  )"; then
    fatal "Failed to resolve tag '${tag}' of '${repository}'"
  fi

  # An annotated tag also has a '^{}' reference, which is the commit it points at rather than
  # the tag object itself. A lightweight tag only has the plain one.
  local reference
  reference="$(printf -- '%s\n' "${references}" | grep '\^{}$' || true)"
  if [[ -z "${reference}" ]]; then
    reference="$(printf -- '%s\n' "${references}" | head -n 1)"
  fi

  local commit="${reference%%$'\t'*}"
  if [[ ! "${commit}" =~ ^[0-9a-f]{40}$ ]]; then
    fatal "Tag '${tag}' of '${repository}' did not resolve to a commit sha: '${commit}'"
  fi

  printf -- '%s\n' "${commit}"
  return 0
}

main() {
  if [[ ! -f "${version_file}" ]]; then
    fatal "There is no '${version_file}' to read the upstream repository from"
  fi

  local repository tag commit current_tag
  repository="$(upstream_repository)"
  tag="$(latest_release_tag "${repository}")"
  commit="$(commit_of_tag "${repository}" "${tag}")"
  current_tag="$(jq -er '.tag' "${version_file}")" || fatal "'${version_file}' has no 'tag' field"

  log "Pinned: ${current_tag}. Latest upstream release: ${tag} (${commit:0:7})."

  printf -- 'tag=%s\n' "${tag}"
  printf -- 'commit=%s\n' "${commit}"
  if [[ "${tag}" == "${current_tag}" ]]; then
    printf -- 'is-outdated=false\n'
  else
    printf -- 'is-outdated=true\n'
  fi
  return 0
}

main "$@"
