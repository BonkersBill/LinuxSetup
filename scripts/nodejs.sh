#!/bin/bash
# NodeJS
pushd ~/Downloads
	curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.6/install.sh | bash
popd
source ~/.bashrc
nvm install --lts
npm install -g pm2
npm install -g npm@latest
# vim: set ts=8 sw=4 ai expandtab ff=unix :
