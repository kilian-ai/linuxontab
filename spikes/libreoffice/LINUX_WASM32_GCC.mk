# -*- Mode: makefile-gmake; tab-width: 4; indent-tabs-mode: t -*-
#
# This file is part of the LibreOffice project.
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# Linux on WebAssembly (wasm32, the LinuxOnTab kernel): every program is one
# statically linked wasm module (DISABLE_DYNLOADING), C++ exceptions and
# setjmp/longjmp use native wasm exception handling. The compiler drivers
# (CC/CXX) add the target, sysroot and runtime objects; see
# spikes/libreoffice/bin/wasm-cc in the LinuxOnTab repository.
# Deliberately not based on linux.mk: -z defs, --hash-style and rpaths are
# ELF linker options wasm-ld does not have.

include $(GBUILDDIR)/platform/unxgcc.mk

# One static module: no position-independent code, no stack protector
# (like the Emscripten build), no ELF-only linker options.
gb_CFLAGS := $(filter-out -fPIC,$(gb_CFLAGS))
gb_CXXFLAGS := $(filter-out -fPIC,$(gb_CXXFLAGS))
gb_LinkTarget_CFLAGS := $(filter-out -fPIC -fstack-protector-strong,$(gb_LinkTarget_CFLAGS)) -fno-stack-protector
gb_LinkTarget_CXXFLAGS := $(filter-out -fPIC -fstack-protector-strong,$(gb_LinkTarget_CXXFLAGS)) -fno-stack-protector
gb_LinkTarget_LDFLAGS := $(filter-out -fstack-protector-strong -Wl$(COMMA)-z$(COMMA)combreloc -Wl$(COMMA)-Bsymbolic-functions,$(gb_LinkTarget_LDFLAGS))

gb_LinkTarget_EXCEPTIONFLAGS := -fwasm-exceptions
gb_PrecompiledHeader_EXCEPTIONFLAGS := $(gb_LinkTarget_EXCEPTIONFLAGS)

gb_LINKEROPTFLAGS :=
gb_LINKERSTRIPDEBUGFLAGS :=
gb_COMPILEROPTFLAGS := -O2

define gb_Library_get_rpath
endef

define gb_Executable_get_rpath
endef

# vim: set noet sw=4 ts=4
