#!/bin/sh
# start sshd
ssh-keygen -A || true; grep -q '^PermitRootLogin' /etc/ssh/sshd_config || echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config; /usr/sbin/sshd || true