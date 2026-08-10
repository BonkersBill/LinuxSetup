#!/bin/bash
# Chrome - do not use default chromium package because it is locked to DuckDuckGo
pushd ~/Downloads
# popd
	sudo rm google-chrome-stable_current_amd64.deb
	wget https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
	sudo dpkg -i google-chrome-stable_current_amd64.deb
popd

# vim: set ts=8 sw=4 ai expandtab ff=unix :
