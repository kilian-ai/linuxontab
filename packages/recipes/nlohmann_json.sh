#!/bin/sh
# Recipe: nlohmann_json — header-only JSON for Modern C++

NAME="nlohmann_json"
VERSION="3.11.3"
DESCRIPTION="Header-only JSON for Modern C++"
SOURCE_URL="https://github.com/nlohmann/json/releases/download/v3.11.3/json.tar.xz"
SOURCE_SHA256=""

build() {
    install -d "$STAGE/usr/include" "$STAGE/usr/lib/pkgconfig"
    cp -R include/nlohmann "$STAGE/usr/include/"

    cat > "$STAGE/usr/lib/pkgconfig/nlohmann_json.pc" << 'EOF'
prefix=/usr
exec_prefix=${prefix}
libdir=${exec_prefix}/lib
includedir=${prefix}/include

Name: nlohmann_json
Description: JSON for Modern C++
Version: 3.11.3
Cflags: -I${includedir}
Libs:
EOF
}