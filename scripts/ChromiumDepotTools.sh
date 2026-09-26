#!/bin/bash
pushd /syndyne/OSS
    git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git
    pushd depot_tools
        ./gclient config https://googlesource.com
        ./gclient sync
    popd
popd

# vim: set sw=4 ts=8 expandtab ai ff=unix :
