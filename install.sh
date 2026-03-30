#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Claude Code CLI Installer (Mirror)
#
# Usage:
#   curl -fsSL https://<mirror>/install.sh | bash
#   curl -fsSL https://<mirror>/install.sh | bash -s <version>
# =============================================================================

# 可通过环境变量覆盖：curl ... | MIRROR_URL=https://mirror.example.com bash
MIRROR_URL="${MIRROR_URL:-http://example.com}"
MIRROR_BASE_URL="${MIRROR_URL}/storage"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()   { error "$@"; exit 1; }

# ---------------------------------------------------------------------------
# Platform detection
# ---------------------------------------------------------------------------
detect_os() {
    case "$(uname -s)" in
        Linux*)  echo "linux" ;;
        Darwin*) echo "darwin" ;;
        *)       die "Unsupported OS: $(uname -s)" ;;
    esac
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "x64" ;;
        aarch64|arm64) echo "arm64" ;;
        *)             die "Unsupported architecture: $(uname -m)" ;;
    esac
}

detect_libc() {
    [ "$(detect_os)" != "linux" ] && return
    if ldd --version 2>&1 | grep -qi musl || [ -f /etc/alpine-release ]; then
        echo "-musl"
    fi
}

# ---------------------------------------------------------------------------
# Version helpers
# ---------------------------------------------------------------------------
installed_version() {
    local claude_bin="${HOME}/.claude/bin/claude"
    if [ -x "$claude_bin" ]; then
        "$claude_bin" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true
    fi
}

fetch_remote_version() {
    curl -fsSL "${MIRROR_URL}/version" || die "Failed to fetch latest version"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    local channel="${1:-stable}"
    local os arch libc platform version

    os="$(detect_os)"
    arch="$(detect_arch)"
    libc="$(detect_libc)"
    platform="${os}-${arch}${libc}"

    info "Platform: ${platform}"

    # Resolve version
    if [ "$channel" = "stable" ] || [ "$channel" = "latest" ]; then
        info "Fetching latest stable version..."
        version="$(fetch_remote_version)"
    else
        version="$channel"
    fi
    info "Target version: ${version}"

    # Fast exit if already up-to-date
    local current
    current="$(installed_version)"
    if [ -n "$current" ] && [ "$current" = "$version" ]; then
        info "Claude Code ${version} is already installed and up-to-date."
        info "Location: ${HOME}/.claude/bin/claude"
        exit 0
    fi
    if [ -n "$current" ]; then
        info "Upgrading from ${current} to ${version}..."
    fi

    # Prepare directories
    local install_dir="${HOME}/.claude"
    local bin_dir="${install_dir}/bin"
    mkdir -p "$bin_dir" "${install_dir}/downloads"

    # Download manifest
    info "Downloading manifest..."
    local manifest_url="${MIRROR_BASE_URL}/${version}/manifest.json"
    local manifest
    manifest="$(curl -fsSL "$manifest_url")" || die "Failed to download manifest"

    # Parse checksum & binary name for this platform
    local expected_checksum binary_name
    expected_checksum="$(echo "$manifest" | grep -A3 "\"${platform}\"" | grep '"checksum"' | sed 's/.*"checksum"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')"
    binary_name="$(echo "$manifest" | grep -A3 "\"${platform}\"" | grep '"binary"' | sed 's/.*"binary"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')"

    [ -z "$expected_checksum" ] && die "Platform '${platform}' not found in manifest"
    binary_name="${binary_name:-claude}"

    # Download binary
    local download_path="${install_dir}/downloads/${binary_name}-${version}-${platform}"
    local binary_url="${MIRROR_BASE_URL}/${version}/${platform}/${binary_name}"
    info "Downloading ${binary_name} ${version}..."
    curl -fSL --progress-bar -o "$download_path" "$binary_url" || die "Download failed"

    # Verify checksum
    info "Verifying checksum..."
    local actual_checksum
    if command -v sha256sum &>/dev/null; then
        actual_checksum="$(sha256sum "$download_path" | awk '{print $1}')"
    elif command -v shasum &>/dev/null; then
        actual_checksum="$(shasum -a 256 "$download_path" | awk '{print $1}')"
    else
        warn "No sha256sum/shasum found, skipping verification"
        actual_checksum="$expected_checksum"
    fi

    if [ "$actual_checksum" != "$expected_checksum" ]; then
        rm -f "$download_path"
        die "Checksum mismatch! Expected: ${expected_checksum}, Got: ${actual_checksum}"
    fi
    info "Checksum OK"

    # Install
    mv "$download_path" "${bin_dir}/${binary_name}"
    chmod +x "${bin_dir}/${binary_name}"

    # Update PATH in shell config
    local shell_config=""
    local path_entry='export PATH="${HOME}/.claude/bin:${PATH}"'

    if [ "$(basename "${SHELL:-}")" = "zsh" ] || [ -n "${ZSH_VERSION:-}" ]; then
        shell_config="${HOME}/.zshrc"
    elif [ "$(basename "${SHELL:-}")" = "bash" ] || [ -n "${BASH_VERSION:-}" ]; then
        shell_config="${HOME}/.bashrc"
    fi

    if [ -n "$shell_config" ] && [ -f "$shell_config" ] && ! grep -q '.claude/bin' "$shell_config"; then
        printf '\n# Claude Code CLI\n%s\n' "$path_entry" >> "$shell_config"
        info "Added PATH to ${shell_config}"
    fi

    export PATH="${bin_dir}:${PATH}"

    echo ""
    info "Claude Code ${version} installed successfully!"
    info "Binary: ${bin_dir}/${binary_name}"
    echo ""
    if [ -n "$shell_config" ]; then
        info "Run 'source ${shell_config}' or open a new terminal, then run 'claude' to get started."
    else
        info "Add ${bin_dir} to your PATH, then run 'claude' to get started."
    fi
}

main "$@"
