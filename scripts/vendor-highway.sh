#!/usr/bin/env bash

set -Eeuo pipefail
shopt -s failglob
IFS=$'\n\t'

log() { printf -- "** %s\n" "$*" >&2; }
error() { printf -- "** ERROR: %s\n" "$*" >&2; }
fatal() { error "$@"; exit 1; }

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly repository_root
readonly version_file="${repository_root}/highway-version.json"
readonly vendor_root="${repository_root}/Sources/CHighway"
readonly include_root="${vendor_root}/include"
readonly module_map="${include_root}/module.modulemap"
readonly patch_root="${repository_root}/patches"

# A module compiles every header it lists, so the module map lists only the ones the package's own
# headers reach. The rest need a hosted C++ standard library, which platforms such as WASI lack.
readonly -a module_seed_headers=(
  hwy/highway.h
  hwy/contrib/sort/vqsort.h
)

clone_dir=""

cleanup() {
  if [[ -n "${clone_dir}" && -d "${clone_dir}" ]]; then
    rm -rf -- "${clone_dir}"
  fi
  return 0
}

require_command() {
  local command_name="${1:?require_command requires the name of the command}"

  if ! command -v "${command_name}" > /dev/null 2>&1; then
    fatal "'${command_name}' is required by $(basename -- "${BASH_SOURCE[0]}") but is not installed"
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

clone_upstream() {
  local repository="${1:?clone_upstream requires the upstream repository url}"
  local tag="${2:?clone_upstream requires the tag to check out}"
  local destination="${3:?clone_upstream requires the destination directory}"

  log "Cloning ${repository} at ${tag}..."
  local -a clone_arguments=(
    -c advice.detachedHead=false
    clone --quiet --depth 1 --branch "${tag}"
  )
  if ! git "${clone_arguments[@]}" "${repository}" "${destination}"; then
    fatal "Failed to clone '${repository}' at tag '${tag}'"
  fi
  return 0
}

verify_commit() {
  local clone_dir="${1:?verify_commit requires the clone directory}"
  local expected_commit="${2:?verify_commit requires the expected commit sha}"

  local actual_commit
  if ! actual_commit="$(git -C "${clone_dir}" rev-parse HEAD)"; then
    fatal "Failed to resolve HEAD of the clone at '${clone_dir}'"
  fi

  if [[ "${actual_commit}" != "${expected_commit}" ]]; then
    fatal "The tag in '${version_file}' does not point at the commit it records." \
      "Expected: ${expected_commit}" \
      "Actual:   ${actual_commit}"
  fi

  log "Verified upstream commit ${actual_commit}."
  return 0
}

# The .cc files upstream itself compiles into libhwy and libhwy_contrib, so that vendoring
# follows upstream rather than a list here that would silently drift away from it.
library_sources_from_cmake() {
  local clone_dir="${1:?library_sources_from_cmake requires the clone directory}"

  local listed_sources
  listed_sources="$(
    awk '
      /^[[:space:]]*set\([[:space:]]*HWY_SOURCES/ { in_block = 1 }
      /^[[:space:]]*list\([[:space:]]*APPEND[[:space:]]+HWY_(CONTRIB_)?SOURCES/ { in_block = 1 }
      in_block && match($0, /hwy\/[A-Za-z0-9_\/.-]+\.cc/) {
        print substr($0, RSTART, RLENGTH)
      }
      in_block && /^[[:space:]]*\)[[:space:]]*$/ { in_block = 0 }
    ' "${clone_dir}/CMakeLists.txt"
  )"

  local globbed_sources
  globbed_sources="$(
    cd -- "${clone_dir}" && printf -- '%s\n' hwy/contrib/sort/vqsort_*.cc
  )"

  printf -- '%s\n%s\n' "${listed_sources}" "${globbed_sources}" | sort -u
  return 0
}

copy_headers() {
  local clone_dir="${1:?copy_headers requires the clone directory}"

  log "Copying headers..."
  if ! rsync --archive --quiet \
    --exclude='tests/' \
    --exclude='*_test.h' \
    --exclude='*_test_util.h' \
    --include='*/' \
    --include='*.h' \
    --exclude='*' \
    --prune-empty-dirs \
    "${clone_dir}/hwy/" "${include_root}/hwy/"; then
    fatal "Failed to copy the headers of '${clone_dir}/hwy' into '${include_root}/hwy'"
  fi
  return 0
}

copy_sources() {
  local clone_dir="${1:?copy_sources requires the clone directory}"
  local -n source_paths_ref="${2:?copy_sources requires the name of the source path array}"

  log "Copying ${#source_paths_ref[@]} library sources..."
  local source_path
  for source_path in "${source_paths_ref[@]}"; do
    if [[ ! -f "${clone_dir}/${source_path}" ]]; then
      fatal "Upstream lists '${source_path}' as a library source but the clone does not have it"
    fi

    mkdir -p -- "${include_root}/$(dirname -- "${source_path}")"
    if ! cp -- "${clone_dir}/${source_path}" "${include_root}/${source_path}"; then
      fatal "Failed to copy '${source_path}' into '${include_root}'"
    fi
  done
  return 0
}

copy_license() {
  local clone_dir="${1:?copy_license requires the clone directory}"

  local license_name
  for license_name in LICENSE LICENSE-BSD3; do
    if [[ -f "${clone_dir}/${license_name}" ]]; then
      cp -- "${clone_dir}/${license_name}" "${vendor_root}/${license_name}"
    fi
  done
  return 0
}

# Patches are written against the upstream tree rather than this one, so that the very same file
# can go upstream unchanged.
apply_patches() {
  local tag="${1:?apply_patches requires the tag the patches are written against}"

  if [[ ! -d "${patch_root}" ]]; then
    return 0
  fi

  local -a patch_paths=()
  local patch_path
  while IFS= read -r -d '' patch_path; do
    patch_paths+=( "${patch_path}" )
  done < <(find "${patch_root}" -name '*.patch' -type f -print0 | sort -z)

  if [[ "${#patch_paths[@]}" -eq 0 ]]; then
    return 0
  fi

  log "Applying ${#patch_paths[@]} patches..."
  local -a apply_arguments=(
    apply --directory="${include_root#"${repository_root}/"}"
  )
  for patch_path in "${patch_paths[@]}"; do
    if ! git -C "${repository_root}" "${apply_arguments[@]}" -- "${patch_path}"; then
      fatal "Failed to apply '${patch_path#"${repository_root}/"}' to the vendored tree." \
        "Rebase it onto highway ${tag}, or drop it if upstream has taken it."
    fi
  done
  return 0
}

headers_reachable_from_seeds() {
  local -A reached=()
  local -a queue=( "${module_seed_headers[@]}" )
  local index=0
  local header included

  while [[ "${index}" -lt "${#queue[@]}" ]]; do
    header="${queue[${index}]}"
    index=$(( index + 1 ))

    if [[ -n "${reached["${header}"]:-}" || ! -f "${include_root}/${header}" ]]; then
      continue
    fi
    reached["${header}"]=1

    while IFS= read -r included; do
      queue+=( "${included}" )
    done < <(
      sed -n 's|^[[:space:]]*#[[:space:]]*include[[:space:]]*"\([^"]*\)".*|\1|p' \
        "${include_root}/${header}"
    )
  done

  if [[ "${#reached[@]}" -eq 0 ]]; then
    fatal "None of the seed headers of the module map exist under '${include_root}'"
  fi

  printf -- '%s\n' "${!reached[@]}" | sort
  return 0
}

# A header that is included more than once, or only from inside HWY_NAMESPACE, cannot be a module
# of its own, which upstream marks by the '-inl.h' suffix.
is_textual_header() {
  local header_path="${1:?is_textual_header requires the header path}"

  case "${header_path}" in
    *-inl.h | hwy/highway.h | hwy/foreach_target.h) return 0 ;;
    *) return 1 ;;
  esac
}

generate_module_map() {
  log "Generating ${module_map#"${repository_root}/"}..."

  local -A in_module=()
  local reachable
  while IFS= read -r reachable; do
    in_module["${reachable}"]=1
  done < <(headers_reachable_from_seeds)

  local -a header_paths=()
  local header_path
  while IFS= read -r -d '' header_path; do
    header_paths+=( "${header_path#"${include_root}/"}" )
  done < <(find "${include_root}/hwy" -name '*.h' -type f -print0 | sort -z)

  if [[ "${#header_paths[@]}" -eq 0 ]]; then
    fatal "Found no headers under '${include_root}/hwy' to generate a module map from"
  fi

  {
    printf -- '%s\n' "// Generated by scripts/vendor-highway.sh. Do not edit."
    printf -- '%s\n' ""
    printf -- '%s\n' "module CHighway {"

    for header_path in "${header_paths[@]}"; do
      if ! is_textual_header "${header_path}" && [[ -n "${in_module["${header_path}"]:-}" ]]; then
        printf -- '    header "%s"\n' "${header_path}"
      fi
    done

    printf -- '%s\n' ""

    for header_path in "${header_paths[@]}"; do
      if is_textual_header "${header_path}"; then
        printf -- '    textual header "%s"\n' "${header_path}"
      fi
    done

    printf -- '%s\n' ""
    printf -- '%s\n' "    requires cplusplus"
    printf -- '%s\n' "    export *"
    printf -- '%s\n' "}"
  } > "${module_map}"

  return 0
}

main() {
  require_command git
  require_command jq
  require_command rsync

  if [[ ! -f "${version_file}" ]]; then
    fatal "There is no '${version_file}' to read the pinned upstream version from"
  fi

  local repository tag commit
  repository="$(version_field repository)"
  tag="$(version_field tag)"
  commit="$(version_field commit)"

  clone_dir="$(mktemp -d)" || fatal "Failed to create a temporary directory for the clone"
  trap cleanup EXIT

  clone_upstream "${repository}" "${tag}" "${clone_dir}"
  verify_commit "${clone_dir}" "${commit}"

  local -a source_paths=()
  while IFS= read -r source_path; do
    [[ -n "${source_path}" ]] && source_paths+=( "${source_path}" )
  done < <(library_sources_from_cmake "${clone_dir}")

  if [[ "${#source_paths[@]}" -eq 0 ]]; then
    fatal "Parsed no library sources out of '${clone_dir}/CMakeLists.txt'"
  fi

  log "Removing the previously vendored tree..."
  rm -rf -- "${include_root}/hwy"
  mkdir -p -- "${include_root}"

  copy_headers "${clone_dir}"
  copy_sources "${clone_dir}" source_paths
  copy_license "${clone_dir}"
  apply_patches "${tag}"
  generate_module_map

  log "✅ Vendored highway ${tag} (${commit:0:7})."
  return 0
}

main "$@"
