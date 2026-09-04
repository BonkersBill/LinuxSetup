#!/bin/bash
# CAN bus tools
set +x
sudo apt install -y can-utils
sudo modprobe can
sudo modprobe can-raw
sudo modprobe slcan
npm install -g --allow-scripts=socketcan socketcan
npm install -g buffer

# vim: set ts=8 sw=4 ai expandtab ff=unix :
