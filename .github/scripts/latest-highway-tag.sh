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

history_dir=""

cleanup() {
  if [[ -n "${history_dir}" && -d "${history_dir}" ]]; then
    rm -rf -- "${history_dir}"
  fi
  return 0
}

version_field() {
  local field_name="${1:?version_field requires the name of the field to read}"

  local value
  if ! value="$(jq -er --arg field "${field_name}" '.[$field]' "${version_file}")"; then
    fatal "'${version_file}' has no '${field_name}' field"
  fi

  printf -- '%s\n' "${value}"
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

clone_history() {
  local repository="${1:?clone_history requires the upstream repository url}"
  local destination="${2:?clone_history requires the destination directory}"

  log "Cloning the history of ${repository}..."
  local -a clone_arguments=(
    clone --quiet --bare --filter=tree:0
  )
  if ! git "${clone_arguments[@]}" "${repository}" "${destination}"; then
    fatal "Failed to clone the history of '${repository}'"
  fi
  return 0
}

is_ancestor() {
  local history_dir="${1:?is_ancestor requires the history clone directory}"
  local ancestor_commit="${2:?is_ancestor requires the commit that may be the ancestor}"
  local descendant_commit="${3:?is_ancestor requires the commit that may be the descendant}"

  local -a ancestor_arguments=(
    merge-base --is-ancestor "${ancestor_commit}" "${descendant_commit}"
  )
  local exit_status=0
  git -C "${history_dir}" "${ancestor_arguments[@]}" || exit_status=$?

  case "${exit_status}" in
    0) return 0 ;;
    1) return 1 ;;
    *)
      fatal "Failed to check whether '${ancestor_commit}' is an ancestor of" \
        "'${descendant_commit}' (git merge-base exited with ${exit_status})."
      ;;
  esac
}

main() {
  if [[ ! -f "${version_file}" ]]; then
    fatal "There is no '${version_file}' to read the upstream repository from"
  fi

  trap cleanup EXIT

  local repository tag release_commit pinned_ref pinned_commit
  repository="$(version_field repository)"
  tag="$(latest_release_tag "${repository}")"
  release_commit="$(commit_of_tag "${repository}" "${tag}")"
  pinned_ref="$(version_field ref)"
  pinned_commit="$(version_field commit)"

  local pinned_summary="${pinned_ref} (${pinned_commit:0:7})"
  local release_summary="${tag} (${release_commit:0:7})"
  log "Pinned: ${pinned_summary}. Latest upstream release: ${release_summary}."

  local is_outdated=false
  if [[ "${release_commit}" != "${pinned_commit}" ]]; then
    history_dir="$(mktemp -d)" || fatal "Failed to create a temporary directory for the history"

    clone_history "${repository}" "${history_dir}"
    if is_ancestor "${history_dir}" "${pinned_commit}" "${release_commit}"; then
      is_outdated=true
    elif ! is_ancestor "${history_dir}" "${release_commit}" "${pinned_commit}"; then
      fatal "The pinned commit and the latest release have diverged in '${repository}'." \
        "Pinned: ${pinned_ref} (${pinned_commit})" \
        "Release: ${tag} (${release_commit})"
    fi
  fi

  printf -- 'tag=%s\n' "${tag}"
  printf -- 'commit=%s\n' "${release_commit}"
  printf -- 'is-outdated=%s\n' "${is_outdated}"
  return 0
}

main "$@"
