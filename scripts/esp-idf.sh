#!/bin/bash
# ESP IDF prerequisites
sudo apt -y install git wget flex bison gperf python3 python3-pip python3-venv cmake ninja-build ccache libffi-dev libssl-dev dfu-util libusb-1.0-0
mkdir -p ~/esp
pushd ~/esp
	git clone --recursive https://github.com/espressif/esp-idf.git
	cd esp-idf
	./install.sh all
popd
sudo chown -R wcl:wcl esp
sudo cp -n ~/.espressif/tools/openocd-esp32/v0.12.0-esp32-20230921/openocd-esp32/share/openocd/contrib/60-openocd.rules /etc/udev/rules.d
# vim: set ts=8 sw=4 ai expandtab ff=unix :
