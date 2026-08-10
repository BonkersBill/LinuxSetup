#!/bin/bash
# CAN bus tools
sudo apt insall -y can-utils
sudo modprobe can
sudo modprobe can-raw
sudo modprobe slcan
sudo npm install -g socketcan
sudo npm install -g buffer

# vim: set ts=8 sw=4 ai expandtab ff=unix :
