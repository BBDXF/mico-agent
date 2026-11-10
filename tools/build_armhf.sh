#!/bin/sh
# Cross-build the armhf release inside debian:stretch (gcc 6.3, glibc 2.24,
# libstdc++ 6.0.22 -- matches the LX06 firmware). Usage from the repo root:
#   docker run --rm -v "$PWD:/src" -w /src debian:stretch sh tools/build_armhf.sh
# (also works with podman). Extra args are passed to make (e.g. VERSION=1.2.3).
set -eu
echo 'deb http://archive.debian.org/debian stretch main' > /etc/apt/sources.list
echo 'deb http://archive.debian.org/debian-security stretch/updates main' >> /etc/apt/sources.list
echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check-valid
dpkg --add-architecture armhf
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    git make ca-certificates crossbuild-essential-armhf libcurl4-openssl-dev:armhf
git config --global --add safe.directory "$PWD" || true
make BUILD=build-armhf CROSS=arm-linux-gnueabihf- ARCH=armhf "$@" dist
arm-linux-gnueabihf-readelf -d build-armhf/mico-agent.stripped
sh tools/check_abi.sh build-armhf/mico-agent.stripped arm-linux-gnueabihf-readelf
