#!/usr/bin/env bash

set -Eeuo pipefail
shopt -s failglob
IFS=$'\n\t'

log() { printf -- "** %s\n" "$*" >&2; }
error() { printf -- "** ERROR: %s\n" "$*" >&2; }
fatal() { error "$@"; exit 1; }

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly repository_root
readonly package_root="${repository_root}/HighwayReference"
readonly target_name="HighwayReferenceCodegen"

architecture=""
verbose="false"
declare -a extra_build_arguments=()
workspace=""

cleanup() {
  if [[ -n "${workspace}" && -d "${workspace}" ]]; then
    rm -rf -- "${workspace}"
  fi
  return 0
}

usage() {
  printf -- 'Usage: %s [--arch <arch>] [--verbose] [-- <extra swift build arguments>]\n' \
    "$(basename -- "${BASH_SOURCE[0]}")"
  return 0
}

require_command() {
  local command_name="${1:?require_command requires the name of the command}"

  if ! command -v "${command_name}" > /dev/null 2>&1; then
    fatal "'${command_name}' is required by $(basename -- "${BASH_SOURCE[0]}") but is not installed"
  fi
  return 0
}

parse_arguments() {
  local option
  while [[ "$#" -gt 0 ]]; do
    option="$1"
    shift
    case "${option}" in
      --arch)
        architecture="${1:?--arch requires the architecture to build for, e.g. 'x86_64'}"
        shift
        ;;
      --verbose)
        verbose="true"
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      --)
        extra_build_arguments=( "$@" )
        break
        ;;
      *)
        fatal "Unknown argument '${option}'" "$(usage)"
        ;;
    esac
  done
  return 0
}

find_objdump() {
  local objdump_path

  case "$(uname -s)" in
    Darwin)
      if ! objdump_path="$(xcrun --find objdump)"; then
        fatal "'xcrun --find objdump' did not find an objdump"
      fi
      ;;
    *)
      if ! objdump_path="$(command -v llvm-objdump || command -v objdump)"; then
        fatal "Neither 'llvm-objdump' nor 'objdump' is on the PATH"
      fi
      ;;
  esac

  printf -- '%s\n' "${objdump_path}"
  return 0
}

build_target() {
  local -n build_arguments_ref="${1:?build_target requires the name of the build argument array}"

  log "Building ${target_name}..."
  if ! swift build "${build_arguments_ref[@]}" >&2; then
    fatal "Failed to build '${target_name}' of '${package_root#"${repository_root}/"}'"
  fi
  return 0
}

binary_path() {
  local -n build_arguments_ref="${1:?binary_path requires the name of the build argument array}"

  local path
  if ! path="$(swift build "${build_arguments_ref[@]}" --show-bin-path)"; then
    fatal "Failed to resolve where '${target_name}' is built to"
  fi

  printf -- '%s\n' "${path}"
  return 0
}

remove_object_files() {
  local binary_directory="${1:?remove_object_files requires the binary directory}"

  local object_directory="${binary_directory}/${target_name}.build"
  if [[ -d "${object_directory}" ]]; then
    find "${object_directory}" -name '*.o' -type f -delete
  fi
  return 0
}

find_object_files() {
  local binary_directory="${1:?find_object_files requires the binary directory}"

  local object_directory="${binary_directory}/${target_name}.build"
  if [[ ! -d "${object_directory}" ]]; then
    fatal "There is no '${object_directory}' to read the object files of '${target_name}' from"
  fi

  find "${object_directory}" -name '*.o' -type f -print0 | sort -z
  return 0
}

disassemble() {
  local objdump_path="${1:?disassemble requires the path of objdump}"
  local -n object_files_ref="${2:?disassemble requires the name of the object file array}"

  local -a objdump_arguments=(
    --disassemble
    --no-show-raw-insn
    --no-leading-addr
    --show-all-symbols
  )
  local object_file
  for object_file in "${object_files_ref[@]}"; do
    if ! "${objdump_path}" "${objdump_arguments[@]}" "${object_file}"; then
      fatal "Failed to disassemble '${object_file}'"
    fi
  done
  return 0
}

demangle_symbols() {
  local listing_file="${1:?demangle_symbols requires the disassembly listing}"
  local symbols_file="${2:?demangle_symbols requires the file to write the symbols to}"
  local demangled_file="${3:?demangle_symbols requires the file to write the demangled names to}"

  if ! sed -n 's|^<\(.*\)>:$|\1|p' "${listing_file}" > "${symbols_file}"; then
    fatal "Failed to read the symbols out of '${listing_file}'"
  fi
  if ! swift demangle --simplified < "${symbols_file}" > "${demangled_file}"; then
    fatal "Failed to demangle the symbols of '${listing_file}'"
  fi
  paste "${symbols_file}" "${demangled_file}"
  return 0
}

compare_functions() {
  local names_file="${1:?compare_functions requires the file of symbols and demangled names}"
  local listing_file="${2:?compare_functions requires the disassembly listing}"
  local show_listings="${3:?compare_functions requires whether to print the listings}"

  if ! awk -F '\t' -v names_file="${names_file}" -v show_listings="${show_listings}" '
    function trimmed_length(function_name,    length_without_padding) {
      length_without_padding = instruction_count[function_name]
      while (length_without_padding > 0 &&
             mnemonic[function_name, length_without_padding] ~ /^nop/) {
        length_without_padding--
      }
      return length_without_padding
    }

    function count_matching(function_name, total, pattern,    matched, position) {
      matched = 0
      for (position = 1; position <= total; position++) {
        if (mnemonic[function_name, position] ~ pattern) {
          matched++
        }
      }
      return matched
    }

    function same_mnemonics(first, second, total,    position) {
      for (position = 1; position <= total; position++) {
        if (mnemonic[first, position] != mnemonic[second, position]) {
          return 0
        }
      }
      return 1
    }

    function print_listing(label, function_name, total,    position) {
      printf "  %s\n", label
      for (position = 1; position <= total; position++) {
        printf "    %s\n", instruction[function_name, position]
      }
    }

    FILENAME == names_file {
      base_name = $2
      sub(/\(.*$/, "", base_name)
      if (base_name ~ /^(port|highway)[A-Z]/) {
        function_of_symbol[$1] = base_name
      }
      if (highway_target == "" && base_name ~ /^highway/ && match($1, /N_[A-Z0-9]+O[0-9]/)) {
        highway_target = substr($1, RSTART + 2, RLENGTH - 2)
        sub(/O[0-9]+$/, "", highway_target)
      }
      next
    }

    /^<.*>:$/ {
      symbol = substr($0, 2, length($0) - 3)
      if (instruction_seen) {
        current_function = ""
        instruction_seen = 0
      }
      if (current_function == "" && (symbol in function_of_symbol)) {
        current_function = function_of_symbol[symbol]
        if (current_function in instruction_count) {
          printf "** ERROR: %s is defined more than once\n", current_function > "/dev/stderr"
          failed = 1
        }
        instruction_count[current_function] = 0
        if (current_function ~ /^port/) {
          port_order[++port_total] = current_function
        }
      }
      next
    }

    /^[[:space:]]+[^[:space:]]/ {
      instruction_seen = 1
      if (current_function != "") {
        text = $0
        sub(/^[[:space:]]+/, "", text)
        gsub(/ <[^>]*>/, "", text)
        name = text
        sub(/[[:space:]].*$/, "", name)
        position = ++instruction_count[current_function]
        instruction[current_function, position] = text
        mnemonic[current_function, position] = name
      }
    }

    END {
      call_pattern = "^(bl|blr|blraa|blraaz|blrab|blrabz|call|callq|calll)$"
      branch_pattern = "^(b|b\\.[a-z]+|bc\\.[a-z]+|br|braa|braaz|brab|brabz|cbz|cbnz|tbz|tbnz|j[a-z]+)$"

      for (rank = 1; rank <= port_total; rank++) {
        port_name = port_order[rank]
        key = substr(port_name, 5)
        highway_name = "highway" key
        if (!(highway_name in instruction_count)) {
          printf "** ERROR: %s has no highway counterpart\n", port_name > "/dev/stderr"
          failed = 1
          continue
        }
        paired[highway_name] = 1

        port_length = trimmed_length(port_name)
        highway_length = trimmed_length(highway_name)
        if (port_length == highway_length && same_mnemonics(port_name, highway_name, port_length)) {
          verdict = "same"
        } else if (port_length < highway_length) {
          verdict = "shorter"
        } else if (port_length > highway_length) {
          verdict = "longer"
        } else {
          verdict = "different"
        }

        port_calls = count_matching(port_name, port_length, call_pattern)
        highway_calls = count_matching(highway_name, highway_length, call_pattern)
        port_branches = count_matching(port_name, port_length, branch_pattern)
        highway_branches = count_matching(highway_name, highway_length, branch_pattern)
        flags = ""
        if (port_calls > highway_calls) {
          flags = flags " [call]"
        }
        if (port_branches > highway_branches) {
          flags = flags " [branch]"
        }

        verdict_count[verdict]++
        if (flags != "") {
          flagged++
        }
        printf "%-40s port=%-4d highway=%-4d %s%s\n", key, port_length, highway_length, verdict, flags

        if (show_listings == "true" && verdict != "same") {
          print_listing("port", port_name, port_length)
          print_listing("highway", highway_name, highway_length)
        }
      }

      for (function_name in instruction_count) {
        if (function_name ~ /^highway/ && !(function_name in paired)) {
          printf "** ERROR: %s has no port counterpart\n", function_name > "/dev/stderr"
          failed = 1
        }
      }
      if (port_total == 0) {
        printf "** ERROR: found no port functions to compare\n" > "/dev/stderr"
        failed = 1
      }

      printf "\nSummary of %d functions on %s\n", port_total, highway_target
      printf "  same       %d\n", verdict_count["same"]
      printf "  shorter    %d\n", verdict_count["shorter"]
      printf "  longer     %d\n", verdict_count["longer"]
      printf "  different  %d\n", verdict_count["different"]
      printf "  flagged    %d\n", flagged
      exit failed
    }
  ' "${names_file}" "${listing_file}"; then
    fatal "Failed to compare the functions of '${target_name}'"
  fi
  return 0
}

main() {
  require_command swift

  parse_arguments "$@"

  local objdump_path
  objdump_path="$(find_objdump)"

  local -a build_arguments=(
    -c release
    --build-system native
    --package-path "${package_root}"
    --target "${target_name}"
    -Xswiftc -Xfrontend -Xswiftc -disable-llvm-merge-functions-pass
  )
  if [[ -n "${architecture}" ]]; then
    build_arguments+=( --arch "${architecture}" )
  fi
  build_arguments+=( "${extra_build_arguments[@]}" )

  local binary_directory
  binary_directory="$(binary_path build_arguments)"
  remove_object_files "${binary_directory}"
  build_target build_arguments

  local -a object_files=()
  local object_file
  while IFS= read -r -d '' object_file; do
    object_files+=( "${object_file}" )
  done < <(find_object_files "${binary_directory}")

  if [[ "${#object_files[@]}" -eq 0 ]]; then
    fatal "Found no object files of '${target_name}' under '${binary_directory}'"
  fi

  workspace="$(mktemp -d)" || fatal "Failed to create a temporary directory for the disassembly"
  trap cleanup EXIT
  local -r listing_file="${workspace}/listing.txt"
  local -r symbols_file="${workspace}/symbols.txt"
  local -r demangled_file="${workspace}/demangled.txt"
  local -r names_file="${workspace}/names.tsv"

  log "Disassembling ${#object_files[@]} object files..."
  disassemble "${objdump_path}" object_files > "${listing_file}"
  demangle_symbols "${listing_file}" "${symbols_file}" "${demangled_file}" > "${names_file}"

  log "Comparing the functions..."
  compare_functions "${names_file}" "${listing_file}" "${verbose}"
  return 0
}

main "$@"
