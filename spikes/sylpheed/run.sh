#!/bin/sh
# Run build.sh steps in the lot-gtk-build container (see Dockerfile):
#   sh spikes/sylpheed/run.sh [step...]
R="$(cd "$(dirname "$0")/../.." && pwd)"
exec docker run --rm -v lo-work:/work \
  -v "$R/toolchain:/lot/toolchain:ro" -v "$R/sysroot:/lot/sysroot:ro" \
  -v "$R/spikes/libreoffice:/lot/spike:ro" -v "$R/spikes/sylpheed:/lot/syl:ro" \
  -v "$R/packages:/lot/packages:ro" \
  lot-gtk-build sh /lot/syl/build.sh "$@"
