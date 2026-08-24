#!/bin/bash
sudo adduser --uid 2000 --gid 2000 --comment "Syndyne Service User" --home "/syndyne" --disabled-password syndyne || true
sudo usermod -aG adm,dialout,sudo,audio,video,input,render,spi,i2c,gpio syndyne
