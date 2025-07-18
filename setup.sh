#!/bin/bash
sudo apt-get -y update
sudo apt-get -y upgrade

# VMWare shared files
#sudo echo "vmhgfs-fuse /mnt/hgfs fuse defaults,allow_other 0 0" >> /etc/fstab
#sudo ln -s /mnt/hgfs/Downloads /Downloads
#sudo ln -s /mnt/hgfs/Linux /Host

# Developer Sanity
sudo apt-get -y install vim vim-addon-manager dos2unix
sudo update-alternatives --set editor /usr/bin/vim.basic

sudo apt-get -y install tmux screen

sudo apt-get -y install nfs-common
sudo apt-get -y install smbclient cifs-utils
sudo apt-get -y install net-tools

# SysAdmin Sanity
sudo apt-get -y install gparted mtools dosfstools

# An X terminal server for remote access
sudo apt-get -y install lxterminal

# Raspbian - Add tools for autostart
sudo apt-get -y install lxsession-default-apps

# SSH
sudo apt-get -y install openssh
sudo systemctl enable ssh
sudo systemclt start ssh

# Linux Kernel Build
sudo apt-get -y install build-essential
sudo apt-get -y build-dep linux linux-image-$(uname -r)
sudo apt-get -y install libncurses-dev gawk flex bison openssl libssl-dev dkms libelf-dev libudev-dev libpci-dev libiberty-dev autoconf llvm curl wget

# RPi Crossbuild
# sudo apt-get -y install git bc bison flex libssl-dev make libc6-dev libncurses5-dev
# sudo apt-get -y install crossbuild-essential-armhf
# sudo apt-get -y install crossbuild-essential-arm64

# Clang
bash -c "$(wget -O - https://apt.llvm.org/llvm.sh)"
sudo apt-get -y install clang-format

# Chrome
pushd ~/Downloads
	wget https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
	sudo apt-get -y install ./google-chrome-stable_current_amd64.deb
popd

# QT5 (for Cangaroo CANbus tools)
#sudo apt-get -y install qt5-qmake qtbase5-dev libnl-3-dev libnl-route-3-dev

# Python 3 (As required by Zephyr)
# sudo apt-get -y install python3-dev python3-pip python3-setuptools python3-tk python3-wheel python3-venv xz-utils file 

# Zephyr Tools
#sudo apt-get -y install --no-install-recommends git cmake ninja-build gperf \
#  ccache dfu-util device-tree-compiler wget \
#  make gcc gcc-multilib g++-multilib libsdl2-dev libmagic1

# NodeJS
pushd ~/Downloads
	curl -fsSL https://deb.nodesource.com/setup_24.x | bash - && sudo apt-get -y install nodejs
popd
npm install -g pm2
npm install -g npm@latest

#  Angular
#npm install -g @angular/cli

# NodeRED
#pushd ~
#	npm install -g --unsafe-perm node-red
#	pm2 start node-red -- -v --userDir .node-red --settings .node-red/settings.js
#	pm2 save
#	pm2 startup systemd
#popd

# Docker
#sudo apt-get -y install docker-compose
#sudo apt-get -y install apt-transport-https ca-certificates curl gnupg2 software-properties-common
#curl -fsSL https://download.docker.com/linux/debian/gpg | sudo apt-key add -
#sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/debian $(lsb_release -cs) stable"
#sudo curl -L https://github.com/docker/compose/releases/download/1.25.3/docker-compose-`uname -s`-`uname -m` -o /usr/local/bin/docker-compose
#sudo chmod +x /usr/local/bin/docker-compose
#sudo apt-cache policy docker-ce
#sudo apt-get -y install docker-ce
#sudo usermod -aG docker wcl

# ESP IDF prerequisites
#sudo apt-get -y install git wget flex bison gperf python3 python3-pip python3-venv cmake ninja-build ccache libffi-dev libssl-dev dfu-util libusb-1.0-0
#mkdir -p ~/esp
#pushd ~/esp
#	git clone --recursive https://github.com/espressif/esp-idf.git
#	cd esp-idf
#	./install.sh all
#popd
#sudo chown -R wcl:wcl esp
#sudo cp -n ~/.espressif/tools/openocd-esp32/v0.12.0-esp32-20230921/openocd-esp32/share/openocd/contrib/60-openocd.rules /etc/udev/rules.d

# vim: set ts=8 sw=4 ai expandtab :
