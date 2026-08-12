#!/bin/sh
# Recipe: toml11 — header-only TOML parser for C++11+

NAME="toml11"
VERSION="4.2.0"
DESCRIPTION="Header-only TOML library for C++"
SOURCE_URL="https://github.com/ToruNiina/toml11/archive/refs/tags/v4.2.0.tar.gz"
SOURCE_SHA256=""

build() {
    install -d "$STAGE/usr/include"
    cp -R include/toml.hpp include/toml_fwd.hpp include/toml11 "$STAGE/usr/include/"

    # Provide CMake package metadata for Meson dependency(method='cmake').
    install -d "$STAGE/usr/lib/cmake/toml11"
    cat > "$STAGE/usr/lib/cmake/toml11/toml11Config.cmake" << 'EOF'
if(NOT TARGET toml11::toml11)
  add_library(toml11::toml11 INTERFACE IMPORTED)
  get_filename_component(_TOML11_PREFIX "${CMAKE_CURRENT_LIST_DIR}/../../.." ABSOLUTE)
  set_target_properties(toml11::toml11 PROPERTIES
    INTERFACE_INCLUDE_DIRECTORIES "${_TOML11_PREFIX}/include"
  )
endif()
set(toml11_FOUND TRUE)
EOF

    cat > "$STAGE/usr/lib/cmake/toml11/toml11ConfigVersion.cmake" << EOF
set(PACKAGE_VERSION "${VERSION}")
if(PACKAGE_FIND_VERSION VERSION_GREATER PACKAGE_VERSION)
  set(PACKAGE_VERSION_COMPATIBLE FALSE)
else()
  set(PACKAGE_VERSION_COMPATIBLE TRUE)
  if(PACKAGE_FIND_VERSION STREQUAL PACKAGE_VERSION)
    set(PACKAGE_VERSION_EXACT TRUE)
  endif()
endif()
EOF

  install -d "$STAGE/usr/lib/pkgconfig"
  cat > "$STAGE/usr/lib/pkgconfig/toml11.pc" << EOF
prefix=/usr
exec_prefix=/usr
libdir=/usr/lib
includedir=/usr/include

Name: toml11
Description: Header-only TOML library for C++
Version: ${VERSION}
Cflags: -I/usr/include
Libs:
EOF
}