#!/usr/bin/env bash
#
# Builds your own FirstSpirit container images, step by step.
# Runs on Linux, macOS and Windows. On Windows use Git Bash (part of Git for
# Windows) or WSL, with Docker Desktop.
#
# The script asks for the download server credentials, lists the FirstSpirit
# versions available there, asks for flavour, variant, image name, tag and
# platform, shows a summary and then runs docker build.
#
# Usage:
#   ./build-image.sh [-y|--yes] [-h|--help]
#
#   -y, --yes   Accept every default without asking. Credentials must then come
#               from the environment or the credentials file.
#
# Credentials: FS_DOWNLOAD_SERVER, FS_DOWNLOAD_SERVER_USERNAME and
# FS_DOWNLOAD_SERVER_PASSWORD are taken from the environment, then from the file
# in FS_CREDENTIALS_FILE (default: ~/.config/fs-docker/credentials, the same file
# scripts/check-fs-update.sh reads). Otherwise the script asks for them.
# The password reaches docker through the environment, never on the command line,
# and is masked as **** in the build output.
#
# Requires: bash 3.2+, curl, docker (buildx for other platforms than your own).

set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$SCRIPT")"

REPO_PATH="all-mvn-release-external-e-spirit-do/de/espirit/firstspirit"
CREDS_FILE="${FS_CREDENTIALS_FILE:-$HOME/.config/fs-docker/credentials}"
BUILDER_NAME="fs-docker-builder"
DEFAULT_SERVER="https://artifactory.e-spirit.hosting/artifactory"
SHOWN_RELEASES=10
# Oldest supported release (YYMM of the build number, 2301 = FirstSpirit 2023.1). Older
# releases need Java and fs-install combinations this repository does not provide.
OLDEST_RELEASE=2301
ASSUME_DEFAULTS=false
sel=""; idx=""; variant=""; platform_choice=""

while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes) ASSUME_DEFAULTS=true ;;
    -h|--help) sed -n '3,/^$/p' "$SCRIPT" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'
  YELLOW=$'\033[33m'; CYAN=$'\033[36m'; REVERSE=$'\033[7m'; RESET=$'\033[0m'
else
  BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; CYAN=""; REVERSE=""; RESET=""
fi

# Arrow-key menus need a real terminal. Piped input, --yes and dumb terminals get
# numbered prompts instead.
INTERACTIVE=false
if [ -t 0 ] && [ -t 1 ] && [ "${TERM:-dumb}" != dumb ] && [ "$ASSUME_DEFAULTS" = false ]; then
  INTERACTIVE=true
fi

# Git Bash on Windows (MSYS) rewrites arguments that look like Unix paths.
IS_GIT_BASH=false
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) IS_GIT_BASH=true ;; esac

TMP_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t fs-docker)
# Also shows the cursor again if the script is aborted inside a menu.
trap 'rm -rf "$TMP_DIR"; if [ "$INTERACTIVE" = true ]; then printf "\033[?25h"; fi' EXIT

# --- helpers -----------------------------------------------------------------
say()     { printf '%s\n' "$*"; }
heading() { printf '\n%s== %s ==%s\n' "$BOLD$CYAN" "$*" "$RESET"; }
warn()    { printf '%sWarning:%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
fail()    { printf '%sError:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# ask VAR "Question" [default] - reads a non-empty answer into VAR.
ask() {
  local _ask_var="$1" _ask_q="$2" _ask_def="${3:-}" _ask_ans=""
  if [ "$ASSUME_DEFAULTS" = true ]; then
    [ -n "$_ask_def" ] || fail "No default for \"$_ask_q\". Run without --yes."
    printf '%s: %s\n' "$_ask_q" "$_ask_def"
    printf -v "$_ask_var" '%s' "$_ask_def"
    return
  fi
  while :; do
    if [ -n "$_ask_def" ]; then
      read -r -p "$_ask_q [$_ask_def]: " _ask_ans || fail "Input ended."
    else
      read -r -p "$_ask_q: " _ask_ans || fail "Input ended."
    fi
    _ask_ans=$(trim "$_ask_ans")
    _ask_ans="${_ask_ans:-$_ask_def}"
    [ -n "$_ask_ans" ] && break
    say "Please enter a value."
  done
  printf -v "$_ask_var" '%s' "$_ask_ans"
}

# ask_secret VAR "Question" - reads without echo.
ask_secret() {
  local _sec_var="$1" _sec_q="$2" _sec_ans=""
  [ "$ASSUME_DEFAULTS" = false ] || fail "\"$_sec_q\" is needed. Set it in the environment or run without --yes."
  while :; do
    read -r -s -p "$_sec_q: " _sec_ans || fail "Input ended."
    echo
    [ -n "$_sec_ans" ] && break
    say "Please enter a value."
  done
  printf -v "$_sec_var" '%s' "$_sec_ans"
}

# confirm "Question" y|n - returns 0 for yes.
confirm() {
  local q="$1" def="$2" hint ans
  if [ "$def" = y ]; then hint="Y/n"; else hint="y/N"; fi
  while :; do
    if [ "$ASSUME_DEFAULTS" = true ]; then
      printf '%s [%s]: %s\n' "$q" "$hint" "$def"
      ans="$def"
    else
      read -r -p "$q [$hint]: " ans || fail "Input ended."
      ans=$(trim "$ans")
      ans="${ans:-$def}"
    fi
    case "$ans" in
      [Yy]|[Yy][Ee][Ss]) return 0 ;;
      [Nn]|[Nn][Oo]) return 1 ;;
    esac
    say "Please answer y or n."
  done
}

# ask_optional VAR "Question" - like ask, but an empty answer is allowed.
ask_optional() {
  local _opt_var="$1" _opt_q="$2" _opt_ans=""
  if [ "$ASSUME_DEFAULTS" = false ]; then
    read -r -p "$_opt_q: " _opt_ans || fail "Input ended."
    _opt_ans=$(trim "$_opt_ans")
  else
    printf '%s: \n' "$_opt_q"
  fi
  printf -v "$_opt_var" '%s' "$_opt_ans"
}

# menu VAR "Title" HEIGHT DEFAULT_INDEX ITEM... - arrow-key menu in which typing filters
# the list. Stores the 1-based index of the chosen item in VAR. Plain bash 3.2 and ANSI
# escape codes, so it works in Linux and macOS terminals, Git Bash and WSL.
menu() {
  local _mn_var="$1" _mn_title="$2" _mn_height="$3" _mn_keep=$(($4 - 1))
  shift 4
  local -a _mn_items _mn_view
  _mn_items=("$@")
  local _mn_filter="" _mn_cur=0 _mn_top=0 _mn_n=0 _mn_i _mn_j _mn_k _mn_rest _mn_lines _mn_status
  local _mn_rebuild=1 _mn_nocase=0 _mn_width
  # Lines must not wrap, or redrawing goes wrong.
  _mn_width=$(tput cols 2>/dev/null || echo 80)
  _mn_width=$((_mn_width - 4))
  [ "$_mn_height" -le $# ] || _mn_height=$#
  _mn_lines=$((_mn_height + 2))
  shopt -q nocasematch && _mn_nocase=1
  shopt -s nocasematch

  # Reserve the lines first, so drawing never scrolls the terminal.
  for ((_mn_i = 0; _mn_i < _mn_lines; _mn_i++)); do echo; done
  printf '\033[%dA\033[?25l' "$_mn_lines"

  while :; do
    if [ "$_mn_rebuild" = 1 ]; then
      _mn_view=()
      for _mn_i in "${!_mn_items[@]}"; do
        if [[ "${_mn_items[$_mn_i]}" == *"$_mn_filter"* ]]; then _mn_view+=("$_mn_i"); fi
      done
      _mn_n=${#_mn_view[@]}
      # Stay on the same item if it is still visible.
      _mn_cur=0
      for ((_mn_j = 0; _mn_j < _mn_n; _mn_j++)); do
        if [ "${_mn_view[$_mn_j]}" = "$_mn_keep" ]; then _mn_cur=$_mn_j; fi
      done
      _mn_rebuild=0
    fi
    [ "$_mn_cur" -ge "$_mn_top" ] || _mn_top=$_mn_cur
    [ "$_mn_cur" -lt $((_mn_top + _mn_height)) ] || _mn_top=$((_mn_cur - _mn_height + 1))
    [ "$_mn_top" -le $((_mn_n - _mn_height)) ] || _mn_top=$((_mn_n - _mn_height))
    [ "$_mn_top" -ge 0 ] || _mn_top=0

    printf '\r\033[2K%s%s%s %s(arrows, type to filter, Enter)%s %s\n' \
      "$BOLD" "$_mn_title" "$RESET" "$DIM" "$RESET" "$_mn_filter"
    for ((_mn_i = 0; _mn_i < _mn_height; _mn_i++)); do
      _mn_j=$((_mn_top + _mn_i))
      printf '\r\033[2K'
      if [ "$_mn_j" -ge "$_mn_n" ]; then
        echo
      elif [ "$_mn_j" = "$_mn_cur" ]; then
        printf '%s> %s %s\n' "$REVERSE" "${_mn_items[${_mn_view[$_mn_j]}]:0:$_mn_width}" "$RESET"
      else
        printf '  %s\n' "${_mn_items[${_mn_view[$_mn_j]}]:0:$_mn_width}"
      fi
    done
    _mn_status=""
    if [ "$_mn_n" -eq 0 ]; then _mn_status="no match, Backspace to change the filter"
    elif [ "$_mn_n" -gt "$_mn_height" ]; then _mn_status="$((_mn_cur + 1)) of $_mn_n"
    fi
    printf '\r\033[2K  %s%s%s\033[%dA\r' "$DIM" "$_mn_status" "$RESET" "$((_mn_lines - 1))"

    IFS= read -rsn1 _mn_k || _mn_k=""
    case "$_mn_k" in
      $'\033')
        _mn_rest=""
        IFS= read -rsn2 -t 1 _mn_rest || true
        case "$_mn_rest" in
          '[A'|'OA') [ "$_mn_cur" -le 0 ] || _mn_cur=$((_mn_cur - 1)) ;;
          '[B'|'OB') [ "$_mn_cur" -ge $((_mn_n - 1)) ] || _mn_cur=$((_mn_cur + 1)) ;;
          '[H'|'OH') _mn_cur=0 ;;
          '[F'|'OF') _mn_cur=$((_mn_n > 0 ? _mn_n - 1 : 0)) ;;
          '[5'|'[6'|'[1'|'[4')
            IFS= read -rsn1 -t 1 _mn_j || true
            case "$_mn_rest" in
              '[5') _mn_cur=$((_mn_cur - _mn_height)); [ "$_mn_cur" -ge 0 ] || _mn_cur=0 ;;
              '[6') _mn_cur=$((_mn_cur + _mn_height)); [ "$_mn_cur" -lt "$_mn_n" ] || _mn_cur=$((_mn_n > 0 ? _mn_n - 1 : 0)) ;;
              '[1') _mn_cur=0 ;;
              '[4') _mn_cur=$((_mn_n > 0 ? _mn_n - 1 : 0)) ;;
            esac ;;
        esac ;;
      '') [ "$_mn_n" -gt 0 ] && break ;;
      $'\177'|$'\b') _mn_filter="${_mn_filter%?}"; _mn_rebuild=1 ;;
      [[:print:]]) _mn_filter="$_mn_filter$_mn_k"; _mn_rebuild=1 ;;
    esac
    if [ "$_mn_n" -gt 0 ]; then _mn_keep=${_mn_view[$_mn_cur]}; fi
  done

  # Replace the menu with one line that shows the choice.
  for ((_mn_i = 0; _mn_i < _mn_lines; _mn_i++)); do printf '\r\033[2K\n'; done
  printf '\033[%dA\033[?25h' "$_mn_lines"
  [ "$_mn_nocase" = 1 ] || shopt -u nocasematch
  _mn_k="${_mn_items[${_mn_view[$_mn_cur]}]}"
  printf '%s: %s%s%s\n' "$_mn_title" "$BOLD" "${_mn_k%"${_mn_k##*[! ]}"}" "$RESET"
  printf -v "$_mn_var" '%s' "$((${_mn_view[$_mn_cur]} + 1))"
}

# choose VAR "Question" DEFAULT_INDEX OPTION... - stores the 1-based index in VAR.
# Arrow-key menu in a terminal, numbered list otherwise.
choose() {
  local _ch_var="$1" _ch_q="$2" _ch_def="$3" _ch_i=1 _ch_o _ch_ans
  shift 3
  if [ "$INTERACTIVE" = true ]; then
    menu "$_ch_var" "$_ch_q" 10 "$_ch_def" "$@"
    return
  fi
  for _ch_o in "$@"; do
    printf '  %s%2d)%s %s\n' "$BOLD" "$_ch_i" "$RESET" "$_ch_o"
    _ch_i=$((_ch_i + 1))
  done
  while :; do
    ask _ch_ans "$_ch_q" "$_ch_def"
    case "$_ch_ans" in
      *[!0-9]*) ;;
      *) if [ "$_ch_ans" -ge 1 ] && [ "$_ch_ans" -le $# ]; then
           printf -v "$_ch_var" '%s' "$_ch_ans"
           return
         fi ;;
    esac
    say "Please enter a number between 1 and $#."
  done
}

sort_versions() { sort -u -t. -k1,1n -k2,2n -k3,3n; }
reverse_lines() { awk '{ l[NR] = $0 } END { for (i = NR; i > 0; i--) print l[i] }'; }

# Prints the arguments as a shell command, quoting only where needed.
show_command() {
  local a out=""
  for a in "$@"; do
    case "$a" in
      ''|*[!A-Za-z0-9_./:=,@+-]*) out="$out $(printf '%q' "$a")" ;;
      *) out="$out $a" ;;
    esac
  done
  printf '%s' "${out# }"
}

is_older() { # is_older A B -> true if A < B
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort_versions | head -n1)" = "$1" ]
}

short_of() { # 5.2.261119 -> 2026.11
  local b="${1##*.}"
  echo "20${b:0:2}.$((10#${b:2:2}))"
}

dockerfile_arg() { # dockerfile_arg NAME [DOCKERFILE]
  sed -n "s/^ARG $1=\"\(.*\)\"/\1/p" "${2:-$DOCKERFILE}" | head -n1
}

# Reads KEY=value, KEY='value' or KEY="value" lines without executing the file.
read_creds_file() {
  local line key value
  [ -f "$CREDS_FILE" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line=$(trim "${line%$'\r'}")
    case "$line" in ''|'#'*) continue ;; esac
    line="${line#export }"
    key=$(trim "${line%%=*}")
    value="${line#*=}"
    case "$value" in
      \"*\") value="${value#\"}"; value="${value%\"}" ;;
      \'*\') value="${value#\'}"; value="${value%\'}" ;;
    esac
    case "$key" in
      FS_DOWNLOAD_SERVER|FS_DOWNLOAD_SERVER_USERNAME|FS_DOWNLOAD_SERVER_PASSWORD)
        if [ -z "${!key:-}" ]; then printf -v "$key" '%s' "$value"; fi ;;
    esac
  done <"$CREDS_FILE"
}

save_creds_file() {
  local v
  for v in "$FS_DOWNLOAD_SERVER" "$FS_DOWNLOAD_SERVER_USERNAME" "$FS_DOWNLOAD_SERVER_PASSWORD"; do
    case "$v" in *"'"*) warn "A value contains a single quote, credentials not saved."; return ;; esac
  done
  mkdir -p "$(dirname "$CREDS_FILE")"
  (
    umask 077
    printf "FS_DOWNLOAD_SERVER='%s'\nFS_DOWNLOAD_SERVER_USERNAME='%s'\nFS_DOWNLOAD_SERVER_PASSWORD='%s'\n" \
      "$FS_DOWNLOAD_SERVER" "$FS_DOWNLOAD_SERVER_USERNAME" "$FS_DOWNLOAD_SERVER_PASSWORD" >"$CREDS_FILE"
  )
  chmod 600 "$CREDS_FILE" 2>/dev/null || true
  say "${GREEN}Saved to $CREDS_FILE${RESET}"
}

# curl_auth CURL_ARGS... - the credentials go to curl through stdin, so they do not
# appear in the process list.
curl_auth() {
  local user_pass="${FS_DOWNLOAD_SERVER_USERNAME}:${FS_DOWNLOAD_SERVER_PASSWORD}"
  user_pass="${user_pass//\\/\\\\}"
  user_pass="${user_pass//\"/\\\"}"
  printf 'user = "%s"\n' "$user_pass" | curl -K - "$@"
}

# http_get PATH OUTFILE - prints the HTTP status (000 if the server is unreachable).
http_get() {
  local code
  code=$(curl_auth -sS -L --connect-timeout 15 -o "$2" -w '%{http_code}' "${FS_DOWNLOAD_SERVER}/$1" 2>"$TMP_DIR/curl.err") \
    || code="000"
  echo "${code:-000}"
}

# java_of_flavour jdk21 -> 21
java_of_flavour() { printf '%s' "$1" | tr -cd '0-9'; }

# detect_java VERSION - prints the Java version FirstSpirit VERSION is compiled for, or nothing.
# Artifactory serves single files from inside an archive ("file.jar!/entry"), so only a few
# bytes are read, not the whole jar. The first 8 bytes of a class file hold its version
# (major 65 = Java 21). The start class is used; X-Compile-Release-JDK from the manifest
# is the fallback. The first request for a version can take a while, Artifactory has to
# fetch the jar first.
detect_java() {
  local jar="${FS_DOWNLOAD_SERVER}/$REPO_PATH/fs-isolated-server/$1/fs-isolated-server-$1.jar" bytes java
  bytes=$(curl_auth -sf -L --connect-timeout 15 --max-time 180 "$jar!/de/espirit/common/bootstrap/Bootstrap.class" 2>/dev/null \
    | head -c 8 | od -An -tu1) || true
  # shellcheck disable=SC2086
  set -- $bytes
  if [ $# -eq 8 ] && [ "$1" = 202 ] && [ "$2" = 254 ] && [ "$3" = 186 ] && [ "$4" = 190 ]; then
    java=$(($7 * 256 + $8 - 44))
    if [ "$java" -ge 8 ]; then echo "$java"; return; fi
  fi
  java=$(curl_auth -sf -L --connect-timeout 15 --max-time 180 "$jar!/META-INF/MANIFEST.MF" 2>/dev/null \
    | tr -d '\r' | sed '/^$/q' | sed -n 's/^X-Compile-Release-JDK: *//p') || true
  case "$java" in ''|*[!0-9]*) ;; *) echo "$java" ;; esac
}

# next_lts JAVA - the next Java LTS release after JAVA.
next_lts() {
  local l
  for l in 8 11 17 21 25 29 33; do
    if [ "$l" -gt "$1" ]; then echo "$l"; return; fi
  done
  echo 999
}

# http_date_key "Mon, 03 Apr 2023 09:23:42 GMT" -> 20230403092342 (sortable; avoids the
# differences between GNU and BSD date).
http_date_key() {
  printf '%s\n' "$1" | awk '{ m = index("JanFebMarAprMayJunJulAugSepOctNovDec", $3)
    if (m == 0) exit
    gsub(":", "", $5); printf "%04d%02d%02d%s\n", $4, (m + 2) / 3, $2, $5 }'
}

# last_modified PATH - prints the Last-Modified date of a file on the Artifactory as a
# sortable key, or nothing. Only the headers are read.
last_modified() {
  local header
  header=$(curl_auth -sSfI -L --connect-timeout 15 --max-time 120 "${FS_DOWNLOAD_SERVER}/$1" 2>/dev/null \
    | tr -d '\r' | sed -n 's/^[Ll]ast-[Mm]odified: *//p' | tail -n1) || true
  if [ -n "$header" ]; then http_date_key "$header"; fi
}

versions_in() { # versions_in FILE REGEX
  { grep -o '<version>[^<]*</version>' "$1" || true; } \
    | sed 's/<[^>]*>//g' | { grep -E "$2" || true; } | sort_versions
}

# registry_login_state REGISTRY - prints yes, no or unknown, from the docker client config.
registry_login_state() {
  local reg="$1" config="${DOCKER_CONFIG:-$HOME/.docker}/config.json" store helper
  [ -f "$config" ] || { echo no; return; }
  # A per-registry credential helper or an auths entry means docker has credentials.
  if grep -qF "\"$reg\"" "$config"; then echo yes; return; fi
  store=$(sed -n 's/.*"credsStore" *: *"\([^"]*\)".*/\1/p' "$config" | head -n1)
  if [ -n "$store" ]; then
    helper="docker-credential-$store"
    command -v "$helper" >/dev/null 2>&1 || command -v "$helper.exe" >/dev/null 2>&1 || { echo unknown; return; }
    command -v "$helper" >/dev/null 2>&1 || helper="$helper.exe"
    if "$helper" list 2>/dev/null | grep -qF "$reg"; then echo yes; else echo no; fi
    return
  fi
  echo no
}

# --- prerequisites -----------------------------------------------------------
printf '%sFirstSpirit image builder%s\n' "$BOLD" "$RESET"
say "${DIM}Press Enter to accept the value in [brackets].${RESET}"

command -v curl >/dev/null || fail "curl is required."
command -v docker >/dev/null || fail "docker is required. Install Docker Desktop or Docker Engine first."
NATIVE_PLATFORM=$(docker version --format '{{.Server.Os}}/{{.Server.Arch}}' 2>/dev/null) \
  || fail "Docker is not running. Start Docker Desktop or the Docker daemon and try again."
case "$NATIVE_PLATFORM" in
  linux/*) ;;
  *) fail "Docker builds for $NATIVE_PLATFORM. Switch Docker Desktop to Linux containers." ;;
esac
HAS_BUILDX=false
if docker buildx version >/dev/null 2>&1; then HAS_BUILDX=true; fi

# --- credentials -------------------------------------------------------------
heading "Download server"
read_creds_file
# File modes do not exist on Windows; the user profile is private there.
if [ "$IS_GIT_BASH" = false ] && [ -f "$CREDS_FILE" ] \
  && [ -n "$(find "$CREDS_FILE" -perm -004 -o -perm -040 2>/dev/null)" ]; then
  warn "$CREDS_FILE can be read by other users."
  if confirm "Make it readable only by you (chmod 600)?" y; then chmod 600 "$CREDS_FILE"; fi
fi
need_input=true
if [ -n "${FS_DOWNLOAD_SERVER:-}" ] && [ -n "${FS_DOWNLOAD_SERVER_USERNAME:-}" ] && [ -n "${FS_DOWNLOAD_SERVER_PASSWORD:-}" ]; then
  say "Found Rezolve Artifactory credentials for user ${BOLD}${FS_DOWNLOAD_SERVER_USERNAME}${RESET} on ${FS_DOWNLOAD_SERVER}."
  if confirm "Use them?" y; then need_input=false; fi
else
  say "FirstSpirit is downloaded from the Rezolve Artifactory (formerly Crownpeak / e-Spirit)."
  say "You need its URL and your Artifactory login."
fi

typed_credentials=false
attempt=0
while :; do
  if [ "$need_input" = true ]; then
    say "${DIM}Artifactory URL including /artifactory, almost always $DEFAULT_SERVER${RESET}"
    ask FS_DOWNLOAD_SERVER "Rezolve Artifactory URL" "${FS_DOWNLOAD_SERVER:-$DEFAULT_SERVER}"
    ask FS_DOWNLOAD_SERVER_USERNAME "Rezolve Artifactory username" "${FS_DOWNLOAD_SERVER_USERNAME:-}"
    ask_secret FS_DOWNLOAD_SERVER_PASSWORD "Rezolve Artifactory password or API key (input hidden)"
    typed_credentials=true
  fi
  case "$FS_DOWNLOAD_SERVER" in
    http://*|https://*) ;;
    *) FS_DOWNLOAD_SERVER="https://$FS_DOWNLOAD_SERVER" ;;
  esac
  FS_DOWNLOAD_SERVER="${FS_DOWNLOAD_SERVER%/}"

  say "Reading the available versions ..."
  code=$(http_get "$REPO_PATH/fs-isolated-server/maven-metadata.xml" "$TMP_DIR/fs-isolated-server.xml")
  case "$code" in
    200) break ;;
    401|403) warn "The Rezolve Artifactory rejected username or password (HTTP $code)." ;;
    404) warn "No FirstSpirit artifacts found at $FS_DOWNLOAD_SERVER (HTTP 404). The URL must point to the Artifactory itself, usually $DEFAULT_SERVER" ;;
    000) warn "Could not reach $FS_DOWNLOAD_SERVER: $(head -n1 "$TMP_DIR/curl.err" 2>/dev/null)" ;;
    *) warn "Unexpected answer from the server (HTTP $code)." ;;
  esac
  attempt=$((attempt + 1))
  [ "$ASSUME_DEFAULTS" = false ] || fail "Cannot continue without working credentials."
  [ "$attempt" -lt 3 ] || fail "Giving up after 3 attempts."
  need_input=true
done
export FS_DOWNLOAD_SERVER FS_DOWNLOAD_SERVER_USERNAME FS_DOWNLOAD_SERVER_PASSWORD

if [ "$typed_credentials" = true ] && [ "$ASSUME_DEFAULTS" = false ]; then
  if [ -f "$CREDS_FILE" ]; then save_q="Overwrite $CREDS_FILE with these credentials?"
  else save_q="Save the credentials to $CREDS_FILE for next time (plain text, readable only by you)?"
  fi
  if confirm "$save_q" n; then save_creds_file; fi
fi

# --- flavours ----------------------------------------------------------------
# Every <dir>/Dockerfile is a flavour; the number in <dir> is its Java version (jdk21).
flavours=()
for f in */Dockerfile; do
  [ -f "$f" ] && flavours+=("${f%/Dockerfile}")
done
[ "${#flavours[@]}" -gt 0 ] || fail "No */Dockerfile found in $(pwd)."

# The newest version a Dockerfile is maintained for is the recommended one.
DEFAULT_VERSION=""
for f in "${flavours[@]}"; do
  v=$(dockerfile_arg IMAGE_VERSION "$f/Dockerfile")
  if [ -n "$v" ] && { [ -z "$DEFAULT_VERSION" ] || is_older "$DEFAULT_VERSION" "$v"; }; then
    DEFAULT_VERSION="$v"
  fi
done

# --- FirstSpirit version -----------------------------------------------------
heading "FirstSpirit version"
ALL_FS_ANY=$(versions_in "$TMP_DIR/fs-isolated-server.xml" '^[0-9]+\.[0-9]+\.[0-9]{6}$')
ALL_FS=$(printf '%s\n' "$ALL_FS_ANY" | awk -F. -v min="$OLDEST_RELEASE" 'substr($3, 1, 4) + 0 >= min + 0')
[ -n "$ALL_FS" ] || fail "The server lists no supported FirstSpirit versions."
OLDEST_SHORT=$(short_of "5.2.${OLDEST_RELEASE}00")
LATEST_FS=$(printf '%s\n' "$ALL_FS" | tail -n1)

# FirstSpirit versions already built on this machine, whatever the images are named.
# The version label holds the real FirstSpirit version, the tag may differ.
LOCAL_FS=" "
local_ids=$(docker images -q --filter label=org.opencontainers.image.title=FirstSpirit 2>/dev/null | sort -u)
if [ -n "$local_ids" ]; then
  # shellcheck disable=SC2086 # one argument per image id
  LOCAL_FS=" $(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' $local_ids 2>/dev/null | sort -u | tr '\n' ' ')"
fi
# fs_notes VERSION - sets notes to the notes shown next to a version in the lists.
fs_notes() {
  notes=""
  [ "$1" = "$LATEST_FS" ] && notes="latest"
  [ "$1" = "$DEFAULT_VERSION" ] && notes="${notes:+$notes, }recommended"
  case "$LOCAL_FS" in *" $1 "*) notes="${notes:+$notes, }already built" ;; esac
  return 0
}

if [ "$INTERACTIVE" = true ]; then
  # Every supported release, newest first. A release can have several builds (fixes);
  # only the newest is shown, plus the recommended one should it be an older build.
  items=(); builds=(); default_idx=1; prev_release=""; i=1
  while IFS= read -r v; do
    release="${v:0:${#v}-2}"   # 5.2.261119 -> 5.2.2611
    if [ "$release" = "$prev_release" ] && [ "$v" != "$DEFAULT_VERSION" ]; then continue; fi
    prev_release="$release"
    fs_notes "$v"
    [ "$v" = "$DEFAULT_VERSION" ] && default_idx=$i
    builds+=("$v")
    items+=("$(printf '%-11s FirstSpirit %-8s %s' "$v" "$(short_of "$v")" "${notes:+($notes)}")")
    i=$((i + 1))
  done < <(printf '%s\n' "$ALL_FS" | reverse_lines)
  menu idx "FirstSpirit version" 12 "$default_idx" "${items[@]}"
  FS_VERSION="${builds[$((idx - 1))]}"
else

# Newest build of each release, newest release first.
releases=()
while IFS= read -r v; do releases+=("$v"); done < <(
  printf '%s\n' "$ALL_FS" \
    | awk -F. '{ r = $1 "." $2 "." substr($3, 1, 4); if (!(r in last)) order[++n] = r; last[r] = $0 }
               END { for (i = n; i >= 1; i--) print last[order[i]] }' \
    | head -n "$SHOWN_RELEASES"
)

default_idx=1
i=1
for v in "${releases[@]}"; do
  fs_notes "$v"
  [ "$v" = "$DEFAULT_VERSION" ] && default_idx=$i
  printf '  %s%2d)%s %-11s FirstSpirit %-8s %s\n' "$BOLD" "$i" "$RESET" "$v" "$(short_of "$v")" "${notes:+${GREEN}($notes)${RESET}}"
  i=$((i + 1))
done
say "${DIM}Older releases (back to $OLDEST_SHORT) and other builds: type the version (e.g. 5.2.261011) or 'a' to list all.${RESET}"

while :; do
  ask sel "FirstSpirit version" "$default_idx"
  case "$sel" in
    a|A)
      printf '%s\n' "$ALL_FS" | reverse_lines \
        | awk '{ printf "  %-12s", $0; if (NR % 6 == 0) print "" } END { if (NR % 6) print "" }' ;;
    *[!0-9]*)
      if printf '%s\n' "$ALL_FS" | grep -qxF "$sel"; then FS_VERSION="$sel"; break; fi
      if printf '%s\n' "$ALL_FS_ANY" | grep -qxF "$sel"; then
        warn "FirstSpirit $(short_of "$sel") is older than $OLDEST_SHORT and not supported."
      else
        warn "Version $sel is not on the server."
      fi ;;
    *)
      if [ "$sel" -ge 1 ] && [ "$sel" -le "${#releases[@]}" ]; then FS_VERSION="${releases[$((sel - 1))]}"; break; fi
      say "Please enter a number between 1 and ${#releases[@]}, a version or 'a'." ;;
  esac
done
fi
FS_VERSION_SHORT=$(short_of "$FS_VERSION")

# --- Java version and flavour --------------------------------------------------
heading "Java"
say "Checking which Java version FirstSpirit $FS_VERSION_SHORT needs ${DIM}(the first time can take a minute)${RESET} ..."
FS_JAVA=$(detect_java "$FS_VERSION")

exact=""; newer=""; newer_java=""; newest_java=0
for f in "${flavours[@]}"; do
  j=$(java_of_flavour "$f")
  [ -n "$j" ] || continue
  [ "$j" -gt "$newest_java" ] && newest_java="$j"
  [ -z "$FS_JAVA" ] && continue
  if [ "$j" -eq "$FS_JAVA" ]; then exact="$f"; fi
  if [ "$j" -gt "$FS_JAVA" ] && { [ -z "$newer" ] || [ "$j" -lt "$newer_java" ]; }; then
    newer="$f"; newer_java="$j"
  fi
done

if [ -z "$FS_JAVA" ]; then
  fail "Could not detect the Java version of FirstSpirit $FS_VERSION, so the right Dockerfile is unknown. Check your connection and try again."
elif [ -n "$exact" ]; then
  FLAVOUR="$exact"
  say "FirstSpirit $FS_VERSION_SHORT is built for ${BOLD}Java $FS_JAVA${RESET}, using ${BOLD}$FLAVOUR/Dockerfile${RESET}."
elif [ -n "$newer" ]; then
  # The next LTS release runs it (e.g. FirstSpirit 2025.x, built for Java 17, on jdk21).
  # Anything newer most likely does not.
  if [ "$newer_java" -gt "$(next_lts "$FS_JAVA")" ]; then
    fail "FirstSpirit $FS_VERSION_SHORT is built for Java $FS_JAVA and does not run on Java $newer_java, the oldest Java with a Dockerfile here."
  fi
  FLAVOUR="$newer"
  say "FirstSpirit $FS_VERSION_SHORT is built for ${BOLD}Java $FS_JAVA${RESET} and runs on the next LTS release, using ${BOLD}$FLAVOUR/Dockerfile${RESET} (Java $newer_java)."
else
  fail "FirstSpirit $FS_VERSION_SHORT needs Java $FS_JAVA, but the newest Dockerfile here is for Java $newest_java."
fi
DOCKERFILE="$FLAVOUR/Dockerfile"
FLAVOUR_VERSION=$(dockerfile_arg IMAGE_VERSION)
if [ -n "$FLAVOUR_VERSION" ] && is_older "$FS_VERSION" "$FLAVOUR_VERSION"; then
  warn "$DOCKERFILE is maintained for $FLAVOUR_VERSION. Older versions usually build, but are not tested."
fi

# --- fs-install version ------------------------------------------------------
code=$(http_get "$REPO_PATH/fs-install/maven-metadata.xml" "$TMP_DIR/fs-install.xml")
[ "$code" = 200 ] || fail "Could not read the fs-install versions (HTTP $code)."
ALL_INSTALL=$(versions_in "$TMP_DIR/fs-install.xml" '^[0-9]+\.[0-9]+\.[0-9]+$')
[ -n "$ALL_INSTALL" ] || fail "The server lists no fs-install versions."
# fs-install (start scripts, wrapper and its configuration) is the one that was current
# when this FirstSpirit release came out: the newest one published before the release.
# Newer ones may need a newer Java (3.1.x needs Java 17). For the latest release this is
# the newest fs-install, as scripts/check-fs-update.sh picks it for the official images.
say "Finding the fs-install of that time ..."
fs_date=$(last_modified "$REPO_PATH/fs-isolated-server/$FS_VERSION/fs-isolated-server-$FS_VERSION.jar")
[ -n "$fs_date" ] || fail "Could not read the release date of FirstSpirit $FS_VERSION. Check your connection and try again."
FS_INSTALL=""
while IFS= read -r v; do
  d=$(last_modified "$REPO_PATH/fs-install/$v/fs-install-$v.tar.gz")
  [ -n "$d" ] || fail "Could not read the release date of fs-install $v. Check your connection and try again."
  if [ "$d" -le "$fs_date" ]; then FS_INSTALL="$v"; break; fi
done < <(printf '%s\n' "$ALL_INSTALL" | reverse_lines)
[ -n "$FS_INSTALL" ] || fail "No fs-install was published before FirstSpirit $FS_VERSION."
say "fs-install (start scripts and configuration): ${BOLD}$FS_INSTALL${RESET}"

# --- variant -----------------------------------------------------------------
heading "Variant"
choose variant "Variant" 1 \
  "Both: production and debug image" \
  "Production only (image firstspirit)" \
  "Debug only (image firstspirit_debug, remote debugging on port 8585)"
BUILD_BASE=false; BUILD_DEBUG=false
case "$variant" in
  1) BUILD_BASE=true; BUILD_DEBUG=true ;;
  2) BUILD_BASE=true ;;
  3) BUILD_DEBUG=true ;;
esac

# --- platform and push -------------------------------------------------------
heading "Platform"
native_arch="${NATIVE_PLATFORM#linux/}"
case "$native_arch" in
  amd64) other_platform="linux/arm64" ;;
  *) other_platform="linux/amd64" ;;
esac
choose platform_choice "Platform" 1 \
  "$NATIVE_PLATFORM (this machine)" \
  "$other_platform (emulated, slower)" \
  "linux/amd64 and linux/arm64 (multi-platform, pushed to the registry)"
case "$platform_choice" in
  1) PLATFORM="$NATIVE_PLATFORM" ;;
  2) PLATFORM="$other_platform" ;;
  3) PLATFORM="linux/amd64,linux/arm64" ;;
esac
if [ "$platform_choice" != 1 ] && [ "$HAS_BUILDX" = false ]; then
  fail "Building for $PLATFORM needs docker buildx. Install the buildx plugin or choose your own platform."
fi

if [ "$platform_choice" = 3 ]; then
  PUSH=true
  say "Multi-platform images cannot be stored locally, they are pushed right away."
else
  PUSH=false
  if confirm "Push the images to your registry after the build?" n; then PUSH=true; fi
fi

# --- image name and tag ------------------------------------------------------
heading "Image name"
if [ "$PUSH" = true ]; then
  say "${DIM}Start with your registry, e.g. registry.example.com/myproject/firstspirit.${RESET}"
  name_default=""
else
  say "${DIM}To push later, start with your registry, e.g. registry.example.com/myproject/firstspirit.${RESET}"
  name_default="firstspirit/firstspirit"
fi
while :; do
  ask IMAGE_REPO "Image name without tag" "$name_default"
  lower=$(printf '%s' "$IMAGE_REPO" | tr '[:upper:]' '[:lower:]')
  if [ "$lower" != "$IMAGE_REPO" ]; then
    say "Image names must be lowercase, using $lower."
    IMAGE_REPO="$lower"
  fi
  case "${IMAGE_REPO##*/}" in
    *:*) say "Please leave out the tag, it comes next." ; continue ;;
  esac
  if ! printf '%s' "$IMAGE_REPO" | grep -Eq '^[a-z0-9]([a-z0-9._/:-]*[a-z0-9])?$'; then
    say "Only lowercase letters, digits and . _ - / : are allowed."
    continue
  fi
  registry="${IMAGE_REPO%%/*}"
  has_registry=false
  case "$IMAGE_REPO" in
    */*) case "$registry" in *.*|*:*|localhost) has_registry=true ;; esac ;;
  esac
  # Without a registry host docker would push to the public Docker Hub.
  if [ "$PUSH" = true ] && [ "$has_registry" = false ]; then
    say "To push, the name must start with your registry host (e.g. registry.example.com/), otherwise it would go to the public Docker Hub."
    continue
  fi
  break
done
IMAGE_BASE="$IMAGE_REPO"
IMAGE_DEBUG="${IMAGE_REPO}_debug"

# The tag always names FirstSpirit version and flavour, so an image cannot pretend to be
# another version. Only a suffix can be added.
TAG_BASE="${FS_VERSION}-${FLAVOUR}"
say "${DIM}The tag is ${TAG_BASE}. You can add a suffix, e.g. a project name (-myproject).${RESET}"
while :; do
  ask_optional suffix "Tag suffix (Enter for none)"
  suffix="${suffix#-}"
  TAG="$TAG_BASE${suffix:+-$suffix}"
  if printf '%s' "$TAG" | grep -Eq '^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$'; then break; fi
  say "A suffix may contain letters, digits, _ . and - (tag max. 128 characters)."
done
say "Tag: ${BOLD}$TAG${RESET}"

# Check the login now, not after a long build.
if [ "$PUSH" = true ]; then
  case "$(registry_login_state "$registry")" in
    yes) say "Logged in to $registry." ;;
    unknown) warn "Could not check whether you are logged in to $registry. If the push fails, run: docker login $registry" ;;
    no)
      warn "You are not logged in to $registry, the push would fail after the build."
      [ "$ASSUME_DEFAULTS" = false ] || fail "Log in first: docker login $registry"
      confirm "Log in now?" y || fail "Cancelled. Log in with: docker login $registry"
      # The Git Bash window (mintty) is no real console for docker; winpty bridges that.
      if [ "$IS_GIT_BASH" = true ] && command -v winpty >/dev/null 2>&1; then
        winpty docker login "$registry" || fail "Login to $registry failed."
      else
        docker login "$registry" || fail "Login to $registry failed."
      fi
      ;;
  esac
fi

# --- cache -------------------------------------------------------------------
heading "Options"
NO_CACHE=false
if confirm "Build without cache (slower, picks up the latest OS updates)?" n; then NO_CACHE=true; fi

# --- build commands ----------------------------------------------------------
CREATED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
common=(
  -f "$DOCKERFILE"
  --build-arg FS_DOWNLOAD_SERVER
  --build-arg FS_DOWNLOAD_SERVER_USERNAME
  --build-arg FS_DOWNLOAD_SERVER_PASSWORD
  --build-arg "IMAGE_VERSION=$FS_VERSION"
  --build-arg "IMAGE_VERSION_SHORT=$FS_VERSION_SHORT"
  --build-arg "IMAGE_VERSION_INSTALL=$FS_INSTALL"
  --build-arg "IMAGE_CREATED=$CREATED"
)
[ "$NO_CACHE" = true ] && common+=(--no-cache)

if [ "$platform_choice" = 1 ]; then
  build_cmd=(docker build)
elif [ "$platform_choice" = 2 ]; then
  build_cmd=(docker buildx build --platform "$PLATFORM" --load)
else
  build_cmd=(docker buildx build --builder "$BUILDER_NAME" --platform "$PLATFORM" --push)
fi

# Production first, so the debug build reuses its layers.
commands=()
images=()
if [ "$BUILD_BASE" = true ]; then
  images+=("$IMAGE_BASE:$TAG")
  commands+=("$(show_command "${build_cmd[@]}" "${common[@]}" --target base -t "$IMAGE_BASE:$TAG" .)")
fi
if [ "$BUILD_DEBUG" = true ]; then
  images+=("$IMAGE_DEBUG:$TAG")
  commands+=("$(show_command "${build_cmd[@]}" "${common[@]}" -t "$IMAGE_DEBUG:$TAG" .)")
fi

# Local changes end up in the image. That can be intended, but should not be a surprise.
if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  changes=$(git status --porcelain -- "$FLAVOUR" config 2>/dev/null || true)
  if [ -n "$changes" ]; then
    heading "Local changes"
    warn "These files differ from the repository and will be built into the image:"
    printf '%s\n' "$changes" | sed 's/^/    /'
    confirm "Build with these changes?" n || fail "Cancelled. Undo them with: git checkout -- $FLAVOUR config"
  fi
fi

if [ "$platform_choice" != 3 ]; then
  for img in "${images[@]}"; do
    if docker image inspect "$img" >/dev/null 2>&1; then
      say "${DIM}$img exists locally and will be replaced.${RESET}"
    fi
  done
fi

heading "Summary"
printf '  %-12s %s (%s), fs-install %s\n' "FirstSpirit" "$FS_VERSION" "$FS_VERSION_SHORT" "$FS_INSTALL"
printf '  %-12s %s\n' "Dockerfile" "$DOCKERFILE"
first=true
for img in "${images[@]}"; do
  if [ "$first" = true ]; then printf '  %-12s %s\n' "Images" "$img"; first=false
  else printf '  %-12s %s\n' "" "$img"; fi
done
printf '  %-12s %s\n' "Platform" "$PLATFORM"
printf '  %-12s %s\n' "Push" "$([ "$PUSH" = true ] && echo yes || echo no)"
printf '  %-12s %s\n' "No cache" "$([ "$NO_CACHE" = true ] && echo yes || echo no)"
say ""
say "${DIM}Commands (the FS_DOWNLOAD_SERVER* values come from the environment):${RESET}"
for c in "${commands[@]}"; do say "  ${DIM}${c}${RESET}"; done
say ""
confirm "Start the build?" y || { say "Cancelled."; exit 0; }

# --- builder for other platforms ---------------------------------------------
# ensure_platforms BUILDER_ARGS... - checks that the builder can build every platform in $PLATFORM.
ensure_platforms() {
  local supported p missing=""
  supported=$(docker buildx inspect --bootstrap "$@" 2>/dev/null | sed -n 's/^ *Platforms: *//p' | tr -d '*' | tr ',' ' ')
  for p in $(printf '%s' "$PLATFORM" | tr ',' ' '); do
    case " $supported " in *" $p "*) ;; *) missing="$missing $p" ;; esac
  done
  [ -z "$missing" ] && return 0
  warn "The builder cannot build for:$missing. Emulation (QEMU) is missing."
  say "It can be installed with: docker run --privileged --rm tonistiigi/binfmt --install all"
  confirm "Install it now (runs a privileged container)?" n || fail "Cannot build for$missing."
  docker run --privileged --rm tonistiigi/binfmt --install all
}

if [ "$platform_choice" = 3 ]; then
  if ! docker buildx inspect "$BUILDER_NAME" >/dev/null 2>&1; then
    say "Creating the buildx builder $BUILDER_NAME (needed for multi-platform images) ..."
    docker buildx create --name "$BUILDER_NAME" --driver docker-container --bootstrap >/dev/null
  fi
  ensure_platforms "$BUILDER_NAME"
elif [ "$platform_choice" = 2 ]; then
  ensure_platforms
fi

# --- build -------------------------------------------------------------------
# BuildKit prints every RUN line with the build args filled in, which would show the
# password. mask_password replaces it with ****. awk reads it from the environment.
mask_password() {
  awk 'BEGIN { s = ENVIRON["FS_DOWNLOAD_SERVER_PASSWORD"]; n = length(s) }
       { line = $0; out = ""
         while (n > 0 && (i = index(line, s)) > 0) { out = out substr(line, 1, i - 1) "****"; line = substr(line, i + n) }
         print out line; fflush() }'
}

build() { # build DESCRIPTION IMAGE ARGS...
  local description="$1" image="$2"
  shift 2
  heading "Building $description: $image"
  "${build_cmd[@]}" "${common[@]}" --progress=plain "$@" -t "$image" . 2>&1 | mask_password \
    || fail "Build of $image failed."
  if [ "$PUSH" = true ] && [ "$platform_choice" != 3 ]; then
    docker push "$image" || fail "Push of $image failed. Are you logged in to the registry?"
  fi
}

[ "$BUILD_BASE" = true ] && build "production image" "$IMAGE_BASE:$TAG" --target base
[ "$BUILD_DEBUG" = true ] && build "debug image" "$IMAGE_DEBUG:$TAG"

heading "Done"
for img in "${images[@]}"; do say "  ${GREEN}${img}${RESET}"; done
if [ "$platform_choice" != 3 ]; then
  run_image="${images[${#images[@]}-1]}"
  debug_port=""
  [ "$run_image" = "$IMAGE_DEBUG:$TAG" ] && debug_port=" -p 8585:8585"
  say ""
  say "Start it with your license file:"
  # In Git Bash the host path must be a Windows path (pwd -W) and the container path must not be rewritten.
  run_prefix=""; pwd_cmd="pwd"
  if [ "$IS_GIT_BASH" = true ]; then run_prefix="MSYS_NO_PATHCONV=1 "; pwd_cmd="pwd -W"; fi
  say "  ${run_prefix}docker run -d -v \"\$(${pwd_cmd})/config/fs-license.conf:/opt/firstspirit5/conf/fs-license.conf\" -p 8000:8000 -p 1088:1088${debug_port} --name firstspirit $run_image"
  [ -f config/fs-license.conf ] || say "${DIM}(Put your fs-license.conf into config/ first.)${RESET}"
fi
