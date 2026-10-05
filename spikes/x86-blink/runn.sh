#!/bin/sh
# runn.sh BLINK "1 2 3" [script]  (in the guest, from /opt/x86 with noderoot/) — run Node once per listed run id, one at a
# time, each in the background with a ~240 s timeout (the guest shell does
# not reap a crashed Blink, so a foreground loop would stall). No $((...)):
# the wasm hush build has no arithmetic.
B=$1; RUNS=$2; JS=${3:-nodetest.js}
export BLINK_OVERLAYS=/opt/x86/noderoot:
TICKS="1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60 61 62 63 64 65 66 67 68 69 70 71 72 73 74 75 76 77 78 79 80"
for i in $RUNS; do
  out=/tmp/run.$B.$i
  ./$B noderoot/usr/bin/node --jitless $JS > $out 2>&1 < /dev/null &
  p=$!
  status=timeout
  for t in $TICKS; do
    sleep 3
    if ! kill -0 $p 2>/dev/null; then status=exited; break; fi
    # a crashed Blink stays a zombie (the guest shell doesn't reap it) and
    # kill -0 still succeeds on zombies
    if grep -q "^State:.*Z" /proc/$p/status 2>/dev/null; then status=died; break; fi
  done
  [ $status = timeout ] && kill -9 $p
  echo "== $B run $i ($status after ~${t}x3s): PASS lines:"
  grep -c PASS $out
  tail -1 $out
done
echo RUNS-DONE
