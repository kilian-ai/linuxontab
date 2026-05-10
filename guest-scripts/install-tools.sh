#!/bin/sh
# install prerequisites (websocat,ngircd,irssi)
apk update && apk add --no-cache --upgrade websocat curl jq openssh-server unbound ngircd irssi || true