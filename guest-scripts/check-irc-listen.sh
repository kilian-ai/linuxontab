#!/bin/sh
# check IRC listening
ss -lntp | grep 6667 || true