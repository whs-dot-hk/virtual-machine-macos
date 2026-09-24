#!/bin/sh
# Download the Debian arm64 nocloud image once. Needs curl and xz.
set -e
cd "$(dirname "$0")/.."
mkdir -p images
url="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-nocloud-arm64.raw"
curl -fL "$url.xz" -o images/debian.raw.xz
xz -dkf images/debian.raw.xz
echo "images/debian.raw"
