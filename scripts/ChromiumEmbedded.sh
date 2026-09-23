#!/bin/bash
# requires gsutil 5.37 or later - in cef_project/tools/buildtools set version to 5.37
apt-get install -y git python3 python3-pip curl bzip2 unzip patchelf cmake build-essential libglib2.0 libgtk-3-dev libxi-dev
mkdir -p /syndyne/oss
pushd /syndyne/oss
    git clone https://github.com/chromiumembedded/cef-project.git
    mkdir cef-project/build
    pushd cef-project/build
        # Probably need to patch version as above
        cmake -G "Unix Makefiles" -DCMAKE_BUILD_TYPE=Release -DPROJECT_ARCH="arm64" ..
        make -j4
        EXE="/syndyne/OSS/cef-project/build/third_party/cef/cef_binary_144.0.6+g5f7e671+chromium-144.0.7559.59_linuxarm64/tests/ceftests/Release/chrome-sandbox" && sudo -- chown root:root $EXE && sudo -- chmod 4755 $EXE
    popd
popd

# vim: sw=4 ts-8 ai expandtabs ff=unix :
