#!/bin/bash
# VMWare shared files
sudo echo "vmhgfs-fuse /mnt/hgfs fuse defaults,allow_other 0 0" >> /etc/fstab
sudo ln -s /mnt/hgfs/Downloads /Downloads
sudo ln -s /mnt/hgfs/Linux /Host
# vim: set ts=8 sw=4 ai expandtab ff=unix :
