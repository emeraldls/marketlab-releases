#!/usr/bin/env bash
set -euo pipefail

REPO="emeraldls/marketlab-releases"
VERSION="latest"
DAEMON_BACKEND=""
INTERACTIVE=false

usage() {
  cat <<'EOF'
Install Market Lab from GitHub Releases.

Usage:
  install.sh [version] [--daemon native|docker]

Examples:
  install.sh
  install.sh v0.0.8 --daemon docker
  install.sh --daemon native
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --daemon)
      if [[ $# -lt 2 ]]; then
        echo "--daemon requires native or docker" >&2
        exit 1
      fi
      DAEMON_BACKEND="$2"
      shift 2
      ;;
    --daemon=*)
      DAEMON_BACKEND="${1#*=}"
      shift
      ;;
    latest|v[0-9]*)
      VERSION="$1"
      shift
      ;;
    *)
      echo "unexpected argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -n "$DAEMON_BACKEND" && "$DAEMON_BACKEND" != "native" && "$DAEMON_BACKEND" != "docker" ]]; then
  echo "--daemon must be native or docker" >&2
  exit 1
fi

if [[ -r /dev/tty && -w /dev/tty ]]; then
  INTERACTIVE=true
fi

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

require_command curl
require_command tar

detect_os() {
  case "$(uname -s)" in
    Linux) echo "unknown-linux-gnu" ;;
    Darwin) echo "apple-darwin" ;;
    *)
      echo "unsupported operating system: $(uname -s)" >&2
      exit 1
      ;;
  esac
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "x86_64" ;;
    arm64|aarch64) echo "aarch64" ;;
    *)
      echo "unsupported architecture: $(uname -m)" >&2
      exit 1
      ;;
  esac
}

select_with_arrows() {
  local prompt="$1"
  shift
  local options=("$@")
  local selected=0
  local key
  local index

  if [[ "$INTERACTIVE" != true ]]; then
    echo "0"
    return
  fi

  exec 3<>/dev/tty
  printf '\n%s\n' "$prompt" >&3
  printf '\033[?25l' >&3
  while true; do
    for index in "${!options[@]}"; do
      if [[ "$index" -eq "$selected" ]]; then
        printf '\033[2K\r\033[1;36m❯ %s\033[0m\n' "${options[$index]}" >&3
      else
        printf '\033[2K\r  %s\n' "${options[$index]}" >&3
      fi
    done

    IFS= read -rsn1 key <&3 || true
    if [[ "$key" == $'\x1b' ]]; then
      IFS= read -rsn2 key <&3 || true
      case "$key" in
        "[A")
          if [[ "$selected" -gt 0 ]]; then
            selected=$((selected - 1))
          fi
          ;;
        "[B")
          if [[ "$selected" -lt $((${#options[@]} - 1)) ]]; then
            selected=$((selected + 1))
          fi
          ;;
      esac
    elif [[ -z "$key" ]]; then
      printf '\033[?25h' >&3
      echo "$selected"
      exec 3>&-
      return
    fi
    printf '\033[%dA' "${#options[@]}" >&3
  done
}

choose_backend() {
  if [[ -n "$DAEMON_BACKEND" ]]; then
    return
  fi
  if [[ "$INTERACTIVE" != true ]]; then
    DAEMON_BACKEND="native"
    echo "no interactive terminal detected; selecting Native (use --daemon docker to override)"
    return
  fi
  local choice
  choice="$(select_with_arrows \
    "Where should Market Lab run background jobs?" \
    "Docker — isolated and manageable through Docker Desktop" \
    "Native — runs directly as your current OS user")"
  if [[ "$choice" == "0" ]]; then
    DAEMON_BACKEND="docker"
  else
    DAEMON_BACKEND="native"
  fi
}

docker_is_ready() {
  command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

wait_for_docker() {
  while ! docker_is_ready; do
    if [[ "$INTERACTIVE" != true ]]; then
      if ! command -v docker >/dev/null 2>&1; then
        echo "Docker is not installed; install Docker Desktop or Docker Engine, then retry" >&2
      else
        echo "Docker is installed but unavailable; start Docker, then retry" >&2
      fi
      exit 1
    fi

    if ! command -v docker >/dev/null 2>&1; then
      echo "Docker is not installed. Install Docker Desktop or Docker Engine before retrying." >/dev/tty
    else
      echo "Docker is installed but not running. Open Docker and wait until it is ready." >/dev/tty
    fi

    local choice
    choice="$(select_with_arrows \
      "Docker is unavailable." \
      "Retry Docker" \
      "Install Native instead" \
      "Exit")"
    case "$choice" in
      0) ;;
      1)
        DAEMON_BACKEND="native"
        return
        ;;
      *) exit 1 ;;
    esac
  done
}

choose_backend
if [[ "$DAEMON_BACKEND" == "docker" ]]; then
  wait_for_docker
fi

TARGET="$(detect_arch)-$(detect_os)"

resolve_version() {
  if [[ "$VERSION" != "latest" ]]; then
    echo "$VERSION"
    return
  fi

  curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
    | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -n 1
}

TAG="$(resolve_version)"

if [[ -z "$TAG" ]]; then
  echo "failed to resolve release version" >&2
  exit 1
fi

ARCHIVE="mlab-${TAG#v}-${TARGET}.tar.gz"
DOWNLOAD_URL="https://github.com/$REPO/releases/download/$TAG/$ARCHIVE"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"; printf "\033[?25h" >/dev/tty 2>/dev/null || true' EXIT

ARCHIVE_PATH="$TMP_DIR/$ARCHIVE"

echo "downloading $DOWNLOAD_URL"
curl -fL "$DOWNLOAD_URL" -o "$ARCHIVE_PATH"
tar -xzf "$ARCHIVE_PATH" -C "$TMP_DIR"

EXTRACTED_DIR="$TMP_DIR/mlab-${TAG#v}-${TARGET}"

if [[ ! -f "$EXTRACTED_DIR/mlab" ]]; then
  echo "release archive did not contain mlab" >&2
  exit 1
fi
if [[ "$DAEMON_BACKEND" == "native" && ! -f "$EXTRACTED_DIR/mlabd" ]]; then
  echo "release archive did not contain mlabd" >&2
  exit 1
fi

if [[ -w /usr/local/bin ]]; then
  INSTALL_DIR="/usr/local/bin"
else
  INSTALL_DIR="${HOME}/.local/bin"
  mkdir -p "$INSTALL_DIR"
fi

install -m 755 "$EXTRACTED_DIR/mlab" "$INSTALL_DIR/mlab"
if [[ "$DAEMON_BACKEND" == "native" ]]; then
  install -m 755 "$EXTRACTED_DIR/mlabd" "$INSTALL_DIR/mlabd"
fi

configure_backend() {
  if "$INSTALL_DIR/mlab" daemon backend "$DAEMON_BACKEND"; then
    return
  fi
  if [[ "$INTERACTIVE" != true || "$DAEMON_BACKEND" != "docker" ]]; then
    exit 1
  fi

  while true; do
    local choice
    choice="$(select_with_arrows \
      "Docker daemon setup failed." \
      "Retry Docker setup" \
      "Install Native instead" \
      "Exit")"
    case "$choice" in
      0)
        wait_for_docker
        if "$INSTALL_DIR/mlab" daemon backend docker; then
          return
        fi
        ;;
      1)
        if [[ ! -f "$EXTRACTED_DIR/mlabd" ]]; then
          echo "release archive did not contain mlabd" >&2
          exit 1
        fi
        DAEMON_BACKEND="native"
        install -m 755 "$EXTRACTED_DIR/mlabd" "$INSTALL_DIR/mlabd"
        "$INSTALL_DIR/mlab" daemon backend native
        return
        ;;
      *) exit 1 ;;
    esac
  done
}

configure_backend

echo "initializing market snapshots"
"$INSTALL_DIR/mlab" markets --exchange bulkf --refresh --json >/dev/null

echo "installed mlab $TAG to $INSTALL_DIR"
if [[ "$DAEMON_BACKEND" == "docker" ]]; then
  echo "mlabd is running in Docker as marketlab-mlabd"
else
  echo "mlabd is installed natively at $INSTALL_DIR/mlabd"
fi

case ":$PATH:" in
  *":$INSTALL_DIR:"*) ;;
  *)
    PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'

    case "${SHELL:-}" in
      */zsh) SHELL_PROFILE="$HOME/.zshrc" ;;
      */bash) SHELL_PROFILE="$HOME/.bashrc" ;;
      *) SHELL_PROFILE="$HOME/.profile" ;;
    esac

    if [[ "$INSTALL_DIR" == "$HOME/.local/bin" ]]; then
      if [[ ! -f "$SHELL_PROFILE" ]] || ! grep -Fqx "$PATH_LINE" "$SHELL_PROFILE"; then
        {
          echo
          echo "# Market Lab"
          echo "$PATH_LINE"
        } >> "$SHELL_PROFILE"
        echo "added $INSTALL_DIR to PATH in $SHELL_PROFILE"
      else
        echo "$INSTALL_DIR is already configured in $SHELL_PROFILE"
      fi

      echo "activate Market Lab in this shell:"
      echo "  source \"$SHELL_PROFILE\""
    else
      echo "note: $INSTALL_DIR is not currently in PATH" >&2
      echo "add it to your shell profile, then restart your shell" >&2
    fi
    ;;
esac
