#!/bin/bash
set -e

# ANSI Color Codes (Internal constants, safe for format string)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
BOLD='\033[1m'

INSTALL_DIR="/usr/local"
GO_DIR="${INSTALL_DIR}/go"
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# Template for headers
FMT_STEP="${BOLD}[%s]${NC} %s\n"
FMT_INFO="      %s: ${GREEN}%s${NC} %s\n"
FMT_ERR="${RED}${BOLD}ERROR:${NC} %s\n"

printf "${BOLD}--- Go Smart Auto-Installer ---${NC}\n"

# 1. Detect Architecture
ARCH=$(uname -m)
case $ARCH in
    x86_64)  GOARCH="amd64" ;;
    aarch64) GOARCH="arm64" ;;
    *) printf "$FMT_ERR" "Unsupported architecture $ARCH"; exit 1 ;;
esac

# 2. Fetch Latest Version Metadata
printf "$FMT_STEP" "1/5" "Checking latest version metadata..."
VERSION=$(curl -s 'https://go.dev/VERSION?m=text' | head -n 1 | sed 's/go//')
FILENAME="go${VERSION}.linux-${GOARCH}.tar.gz"
printf "      Latest Release: ${GREEN}%s${NC} (%s)\n" "$VERSION" "$GOARCH"

# 3. Decision Point
NEEDS_INSTALL=true
if [[ -x $(command -v go) ]]; then
    CURRENT_VER=$(go version | awk '{print $3}' | sed 's/go//')
    if [[ $CURRENT_VER == "$VERSION" ]]; then
        printf "      ${YELLOW}STATUS:${NC} Go %s is already current. Skipping install.\n" "$VERSION"
        NEEDS_INSTALL=false
    fi
fi

if [[ $NEEDS_INSTALL == true ]]; then
    # 4. Fetch Checksum, Download, and Atomic Install
    printf "$FMT_STEP" "2/5" "Fetching SHA256 manifest..."
    DL_JSON=$(curl -s 'https://go.dev/dl/?mode=json')
    EXPECTED_SHA=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    for release in data:
        for file in release.get('files', []):
            if file['filename'] == '$FILENAME':
                print(file['sha256'])
                sys.exit(0)
except Exception:
    pass
sys.exit(1)
" "$DL_JSON" 2>/dev/null || echo "")

    if [[ -z $EXPECTED_SHA ]]; then
        printf "$FMT_ERR" "Could not find SHA256 for $FILENAME"
        exit 1
    fi

    printf "$FMT_STEP" "3/5" "Downloading & Verifying binary..."
    wget -q --show-progress "https://go.dev/dl/$FILENAME" -O "$TEMP_DIR/$FILENAME"
    ACTUAL_SHA=$(sha256sum "$TEMP_DIR/$FILENAME" | awk '{print $1}')

    if [[ $ACTUAL_SHA != "$EXPECTED_SHA" ]]; then
        printf "$FMT_ERR" "Checksum mismatch!"
        exit 1
    fi

    printf "$FMT_STEP" "4/5" "Performing Atomic Installation..."
    sudo rm -rf "${GO_DIR}.tmp"
    sudo mkdir -p "${GO_DIR}.tmp"
    sudo tar -C "${GO_DIR}.tmp" --strip-components=1 -xzf "$TEMP_DIR/$FILENAME"
    sudo chmod -R +rX "${GO_DIR}.tmp"

    # Functional test using GOROOT override
    if ! GOROOT="${GO_DIR}.tmp" "${GO_DIR}.tmp/bin/go" version > /dev/null 2>&1; then
        printf "$FMT_ERR" "Extracted binary failed functional test."
        exit 1
    fi

    sudo rm -rf "$GO_DIR"
    sudo mv "${GO_DIR}.tmp" "$GO_DIR"
    hash -r
    printf "      Installation: ${GREEN}SUCCESSFUL${NC}\n"
else
    printf "$FMT_STEP" "2-4/5" "Installation steps ${YELLOW}SKIPPED${NC}."
fi

# 5. Environment Health Check
printf "$FMT_STEP" "5/5" "Verifying ~/.bashrc integrity..."
MARKER="# Go Language Configuration - Managed by install_go.sh"

if ! grep -q "$MARKER" ~/.bashrc; then
    printf "      ${YELLOW}REPAIRING:${NC} Managed Go config missing. Patching...\n"
    cp ~/.bashrc ~/.bashrc.bak."$(date +%Y%m%d%H%M)"
    # Using a formatted printf to append is safer than a raw heredoc sometimes
    printf "\n%s\nexport GOROOT=%s\nexport GOPATH=\$HOME/go\nexport PATH=\$PATH:\$GOROOT/bin:\$GOPATH/bin\n# End of Go Configuration\n" \
           "$MARKER" "$GO_DIR" >> ~/.bashrc
    printf "      Environment: ${GREEN}REPAIRED${NC}\n"
else
    printf "      Environment: ${GREEN}VERIFIED OK${NC}\n"
fi

printf "\n${GREEN}${BOLD}--- STATUS: ALL SYSTEMS GREEN ---${NC}\n"

