#!/bin/sh
# Download the Debian arm64 nocloud image once. Needs curl.
# Latest tree ships .raw and .tar.xz, not .raw.xz.
set -e
cd "$(dirname "$0")/.."
mkdir -p images
url="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-nocloud-arm64.tar.xz"
curl -fL "$url" -o images/debian.tar.xz
rm -rf images/debian-unpack
mkdir images/debian-unpack
tar -xJf images/debian.tar.xz -C images/debian-unpack
raw=$(find images/debian-unpack -name '*.raw' -print | head -n 1)
if [ -z "$raw" ]; then
    echo "no .raw inside $url" >&2
    exit 1
fi
mv "$raw" images/debian.raw
rm -rf images/debian-unpack images/debian.tar.xz
echo "images/debian.raw"
