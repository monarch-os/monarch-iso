#!/bin/bash

local_dependency_satisfied() {
  local dependency=$1 name operator version provided provided_name provided_version comparison
  name=${dependency%%[<>=]*}
  operator=${dependency#"$name"}
  version=${operator##*[<>=]}
  operator=${operator%"$version"}

  for provided in "${local_provides[@]}"; do
    provided_name=${provided%%=*}
    [[ $provided_name == "$name" ]] || continue
    [[ -n $operator ]] || return 0
    [[ $provided == *=* ]] || continue
    provided_version=${provided#*=}
    comparison=$(vercmp "$provided_version" "$version") || return 1
    case $operator in
      '=') (( comparison == 0 )) && return 0 ;;
      '>') (( comparison > 0 )) && return 0 ;;
      '<') (( comparison < 0 )) && return 0 ;;
      '>=') (( comparison >= 0 )) && return 0 ;;
      '<=') (( comparison <= 0 )) && return 0 ;;
    esac
  done
  return 1
}

load_local_package_dependencies() {
  local archive metadata key value name version dependency
  local -a dependencies=() provides=() names=()
  local_provides=()
  local_depends=()
  local_pacman_args=()

  for archive in "$@"; do
    if ! metadata=$(bsdtar -xOf "$archive" .PKGINFO); then
      echo "ERROR: cannot read .PKGINFO from $archive" >&2
      return 1
    fi
    name= version= provides=()
    while IFS= read -r value; do
      key=${value%% = *}
      value=${value#* = }
      case $key in
        pkgname) name=$value ;;
        pkgver) version=$value ;;
        provides) provides+=("$value") ;;
        depend) dependencies+=("$value") ;;
      esac
    done <<<"$metadata"
    if [[ -z $name || -z $version ]]; then
      echo "ERROR: missing pkgname or pkgver in $archive" >&2
      return 1
    fi
    local_provides+=("$name=$version" "${provides[@]}")
    names+=("$name")
  done

  for dependency in "${dependencies[@]}"; do
    if ! local_dependency_satisfied "$dependency"; then
      for name in "${names[@]}"; do
        if [[ ${dependency%%[<>=]*} == "$name" ]]; then
          echo "ERROR: local packages do not satisfy $dependency" >&2
          return 1
        fi
      done
      local_depends+=("$dependency")
    fi
  done
  # Transitive repository dependencies must also see the local providers.
  for value in "${local_provides[@]}"; do
    local_pacman_args+=(--assume-installed "$value")
  done
}
