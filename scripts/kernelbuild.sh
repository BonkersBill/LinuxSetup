#!/bin/bash
# Linux Kernel Build
sudo apt -y install build-essential
sudo apt -y install build-dep linux linux-image-$(uname -r)
sudo apt -y install libncurses-dev gawk flex bison openssl libssl-dev dkms libelf-dev 
sudo apt -y install libudev-dev libpci-dev libiberty-dev autoconf llvm curl wget bc
sudo apt -y libgtk2.0-dev libglade2-dev
# vim: set ts=8 sw=4 ai expandtab ff=unix :
