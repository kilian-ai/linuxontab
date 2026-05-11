#!/bin/sh
printf 'lot-tb-61216!\nlot-tb-61216!\n' | passwd root
# start sshd
ssh-keygen -A || true; grep -q '^PermitRootLogin' /etc/ssh/sshd_config || echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config; /usr/sbin/sshd || true