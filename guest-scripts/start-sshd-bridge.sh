#!/bin/sh
# Start SSH/SFTP (sshd + websocat bridge)
apk update || true
apk add --no-cache --upgrade openssh-server websocat || true
grep -q '^PermitRootLogin' /etc/ssh/sshd_config || echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config
ssh-keygen -A || true
printf 'lot-tb-61216!\nlot-tb-61216!\n' | passwd root 2>/dev/null || true
/usr/sbin/sshd || true
CODE=$(cat /tmp/tunnel.code 2>/dev/null || echo)
if [ -z "$CODE" ]; then
  REG=$(curl -sS -m 10 -X POST https://linuxontab-tunnel.fly.dev/port/register -H 'content-type: application/json' -d '{"ports":[22]}' 2>/dev/null || true)
  CODE=$(echo "$REG" | sed -n 's/.*"code":"\([A-Z0-9]*\)".*/\1/p' || true)
  echo "$CODE" > /tmp/tunnel.code
fi
> /tmp/ws.log
for i in 1 2 3; do
  setsid sh -c "while :; do websocat -b tcp:127.0.0.1:22 'wss://linuxontab-tunnel.fly.dev/port/guest?code=$CODE&port=22' >>/tmp/ws.log 2>&1; echo \"$(date +%T) ssh bridge $i died\" >> /tmp/ws.log; sleep 1; done" </dev/null >/dev/null 2>&1 &
done
sleep 3
tail -n 20 /tmp/ws.log