#!/usr/bin/env bash
#
# Checks Crownpeak Artifactory for the next FirstSpirit release and, with --apply,
# updates jdk21/Dockerfile: IMAGE_VERSION, IMAGE_VERSION_SHORT, IMAGE_VERSION_INSTALL,
# IMAGE_CREATED and the sha256 digests of all pinned base images.
#
# Releases are taken one at a time, so every release gets its own image. A build number
# is YYMM + build counter (5.2.261119 = release 2026.11, build 19). The next release is
# the oldest release newer than the current one, using its highest build. A newer build
# of the current release (hotfix) comes first. fs-install always uses the newest version.
#
# Usage:
#   scripts/check-fs-update.sh [--apply] [--dockerfile PATH]
#
# Without --apply nothing is written (dry run).
#
# Credentials: FS_DOWNLOAD_SERVER, FS_DOWNLOAD_SERVER_USERNAME, FS_DOWNLOAD_SERVER_PASSWORD
# are taken from the environment. If they are not set, the file in FS_CREDENTIALS_FILE
# (default: ~/.config/fs-docker/credentials) is sourced. Values are never printed.
#
# Results are printed as key=value lines and, on GitHub Actions, written to $GITHUB_OUTPUT:
#   changed=true|false, version, version_short, version_install,
#   current_version, current_version_short, current_version_install,
#   latest_version, pending (releases still waiting after this one, space separated)
#
# Requires: bash, curl, sed, grep, sort -V, docker buildx (for the digests).

set -euo pipefail

APPLY=false
DOCKERFILE="jdk21/Dockerfile"
REPO_PATH="all-mvn-release-external-e-spirit-do/de/espirit/firstspirit"

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=true ;;
    --dockerfile) DOCKERFILE="$2"; shift ;;
    -h|--help) sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

log() { echo "$*" >&2; }
fail() { log "ERROR: $*"; exit 1; }

# --- credentials -------------------------------------------------------------
if [ -z "${FS_DOWNLOAD_SERVER_PASSWORD:-}" ]; then
  creds_file="${FS_CREDENTIALS_FILE:-$HOME/.config/fs-docker/credentials}"
  if [ -f "$creds_file" ]; then
    # shellcheck disable=SC1090
    . "$creds_file"
  fi
fi
for v in FS_DOWNLOAD_SERVER FS_DOWNLOAD_SERVER_USERNAME FS_DOWNLOAD_SERVER_PASSWORD; do
  [ -n "${!v:-}" ] || fail "$v is not set (environment or ${FS_CREDENTIALS_FILE:-~/.config/fs-docker/credentials})"
done
[ -f "$DOCKERFILE" ] || fail "Dockerfile not found: $DOCKERFILE"

# Passes the credentials to curl through stdin, so they do not appear in the process list.
artifactory_get() {
  local user_pass="${FS_DOWNLOAD_SERVER_USERNAME}:${FS_DOWNLOAD_SERVER_PASSWORD}"
  user_pass="${user_pass//\\/\\\\}"
  user_pass="${user_pass//\"/\\\"}"
  printf 'user = "%s"\n' "$user_pass" | curl -sSf -K - "${FS_DOWNLOAD_SERVER%/}/$1"
}

# All versions from a maven-metadata.xml that match the given regex, sorted ascending.
all_versions() {
  local artifact="$1" pattern="$2" metadata
  metadata=$(artifactory_get "${REPO_PATH}/${artifact}/maven-metadata.xml") \
    || fail "Could not read maven-metadata.xml for ${artifact}"
  grep -o '<version>[^<]*</version>' <<<"$metadata" \
    | sed 's/<[^>]*>//g' \
    | { grep -E "$pattern" || true; } \
    | sort -uV
}

is_newer() { # is_newer A B -> true if A > B
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]
}

release_of() { # 5.2.261119 -> 5.2.2611
  local build="${1##*.}"
  echo "${1%.*}.${build:0:4}"
}

current_arg() {
  sed -n "s/^ARG $1=\"\(.*\)\"/\1/p" "$DOCKERFILE" | head -n1
}

# --- versions ----------------------------------------------------------------
current_version=$(current_arg IMAGE_VERSION)
current_install=$(current_arg IMAGE_VERSION_INSTALL)
current_short=$(current_arg IMAGE_VERSION_SHORT)
[ -n "$current_version" ] || fail "ARG IMAGE_VERSION not found in $DOCKERFILE"

mapfile -t fs_versions < <(all_versions fs-isolated-server '^[0-9]+\.[0-9]+\.[0-9]{6}$')
version_install=$(all_versions fs-install '^[0-9]+\.[0-9]+\.[0-9]+$' | tail -n1)
[ "${#fs_versions[@]}" -gt 0 ] || fail "No release version found for fs-isolated-server"
[ -n "$version_install" ] || fail "No release version found for fs-install"
latest_version="${fs_versions[-1]}"

newer=()
for v in "${fs_versions[@]}"; do
  if is_newer "$v" "$current_version"; then newer+=("$v"); fi
done

version="$current_version"
pending=""
if [ "${#newer[@]}" -gt 0 ]; then
  # newer[] is ascending, so newer[0] belongs to the next release (a hotfix of the
  # current release or the following month). Take the highest build of that release.
  next_release=$(release_of "${newer[0]}")
  for v in "${newer[@]}"; do
    if [ "$(release_of "$v")" = "$next_release" ]; then version="$v"; fi
  done
  # Releases after this one, each with its highest build.
  declare -A highest=()
  for v in "${newer[@]}"; do
    r=$(release_of "$v")
    if [ "$r" != "$next_release" ]; then highest[$r]="$v"; fi
  done
  if [ "${#highest[@]}" -gt 0 ]; then
    pending=$(printf '%s\n' "${highest[@]}" | sort -V | tr '\n' ' ' | sed 's/ $//')
  fi
fi

build="${version##*.}"
version_short="20${build:0:2}.$((10#${build:2:2}))"

log "FirstSpirit: current ${current_version}, next ${version}, latest ${latest_version}"
log "fs-install:  current ${current_install}, latest ${version_install}"

if [ "$version" = "$current_version" ]; then
  changed=false
  log "Up to date."
else
  changed=true
  log "Next FirstSpirit release: ${version} (short ${version_short}, fs-install ${version_install})"
  if [ -n "$pending" ]; then log "Still pending after this one: ${pending}"; fi
fi

# --- base image digests ------------------------------------------------------
# Every line "FROM docker.io/<image>:<tag>@sha256:<digest>" is refreshed.
declare -a digest_updates=()
if [ "$changed" = true ]; then
  command -v docker >/dev/null || fail "docker is required to resolve base image digests"
  while read -r ref old_digest; do
    new_digest=$(docker buildx imagetools inspect "$ref" | awk '/^Digest:/ {print $2; exit}') || true
    [ -n "$new_digest" ] || fail "Could not resolve digest for $ref"
    if [ "$new_digest" = "$old_digest" ]; then
      log "Base image ${ref}: unchanged"
    else
      log "Base image ${ref}: ${old_digest} -> ${new_digest}"
    fi
    digest_updates+=("$ref $new_digest")
  done < <(sed -n 's/^FROM \([^ @]*\)@\(sha256:[0-9a-f]*\).*/\1 \2/p' "$DOCKERFILE")
fi

# --- apply -------------------------------------------------------------------
if [ "$changed" = true ] && [ "$APPLY" = true ]; then
  created="$(date +%Y-%m-%dT00:00:00%:z)"
  sed -i \
    -e "s|^ARG IMAGE_CREATED=\".*\"|ARG IMAGE_CREATED=\"${created}\"|" \
    -e "s|^ARG IMAGE_VERSION=\".*\"|ARG IMAGE_VERSION=\"${version}\"|" \
    -e "s|^ARG IMAGE_VERSION_SHORT=\".*\"|ARG IMAGE_VERSION_SHORT=\"${version_short}\"|" \
    -e "s|^ARG IMAGE_VERSION_INSTALL=\".*\"|ARG IMAGE_VERSION_INSTALL=\"${version_install}\"|" \
    "$DOCKERFILE"
  for entry in "${digest_updates[@]}"; do
    ref="${entry% *}"
    digest="${entry#* }"
    sed -i "s|^FROM ${ref//./\\.}@sha256:[0-9a-f]*|FROM ${ref}@${digest}|" "$DOCKERFILE"
  done
  log "Updated ${DOCKERFILE}."
elif [ "$changed" = true ]; then
  log "Dry run: nothing written. Use --apply to update ${DOCKERFILE}."
fi

# --- outputs -----------------------------------------------------------------
outputs="changed=${changed}
current_version=${current_version}
current_version_short=${current_short}
current_version_install=${current_install}
version=${version}
version_short=${version_short}
version_install=${version_install}
latest_version=${latest_version}
pending=${pending}"
echo "$outputs"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "$outputs" >>"$GITHUB_OUTPUT"
fi
