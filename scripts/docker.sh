#!/bin/bash
# Docker
sudo apt -y install docker-compose
sudo apt -y install apt-transport-https ca-certificates curl gnupg2 software-properties-common
curl -fsSL https://download.docker.com/linux/debian/gpg | sudo apt-key add -
sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/debian $(lsb_release -cs) stable"
sudo curl -L https://github.com/docker/compose/releases/download/1.25.3/docker-compose-`uname -s`-`uname -m` -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
sudo apt-cache policy docker-ce
sudo apt -y install docker-ce
sudo usermod -aG docker wcl
# vim: set ts=8 sw=4 ai expandtab ff=unix :
