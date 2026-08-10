#!/bin/bash
sudo apt install -y mate-desktop-environment
sudo update-alternatives --set x-session-manager /usr/bin/mate-session
sudo apt install -y lightdm-gtk-greeter
sudo systemctl enable lightdm
sudo systemctl set-default graphical.target
# vim: set ts=8 sw=4 ai expandtab ff=unix :
