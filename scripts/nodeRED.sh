#!/bin/bash
# NodeRED
pushd ~
	npm install -g --unsafe-perm node-red
	pm2 start node-red -- -v --userDir .node-red --settings .node-red/settings.js
	pm2 save
	pm2 startup systemd
popd
# vim: set ts=8 sw=4 ai expandtab ff=unix :
