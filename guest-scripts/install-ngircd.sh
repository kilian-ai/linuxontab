#!/bin/sh
# install & start ngircd
cat >/etc/ngircd/ngircd.conf <<'EOF'
[Global]
    Name = irc.linuxontab.local
    AdminInfo1 = root
    AdminInfo2 = LinuxOnTab
    AdminEMail = root@localhost
    Info = LinuxOnTab IRC
    Listen = 0.0.0.0
    Ports = 6667
    MotdPhrase = "Welcome to your browser-only IRC server."

[Limits]
    MaxConnections = 100
    MaxJoins = 10

[Options]
    AllowRemoteOper = no
    ConnectIPv6 = no
    DNS = no
    PAM = no

[Channel]
    Name = #lobby
    Topic = LinuxOnTab lobby
EOF
ngircd || true