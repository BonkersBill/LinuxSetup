#!/bin/bash
# Requires ChromeDepotTools
sudo apt update
sudo apt install -y git curl python3 xz-utils ca-certificates lsb-release build-essential clang bison

mkdir /syndyne/OSS/v8
pushd /syndyne/OSS/v8
    fetch v8
    gn args out.gn/arm64.release
popd

# vim: set sw=4 ts=8 expandtab ff=unix :
