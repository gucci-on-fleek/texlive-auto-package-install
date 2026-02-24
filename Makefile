# network-install
# https://github.com/gucci-on-fleek/network-install
# SPDX-License-Identifier: MPL-2.0+
# SPDX-FileCopyrightText: 2026 Max Chernoff

# Remove the builtin rules
.SUFFIXES:
MAKEFLAGS += --no-builtin-rules

# Silence the commands
.SILENT:

# Shell settings
.ONESHELL:
.SHELLFLAGS := -euo pipefail -c
SHELL := /bin/bash

# Base C Flags:
# "-pipe"         Use pipes internally (speeds up compilation).
# "-std=gnu23"    Use the latest C standard, but with GNU extensions.
# "-O2"           Optimize for speed.
# "-s"            Strip debug symbols.
# "-I./source/c/" Include the local directory for header files.
base_c_flags := \
	-pipe \
	-std=gnu23 \
	-O2 \
	-s \
	-I./source/c/ \

# Warnings:
# "-Wall"       Enable "all" warnings.
# "-Wextra"     Enable more warnings.
# "-Wpedantic"  Enable even more warnings.
# "-Wno-unused" Ignore "Unused XXX" warnings.
# "-Wshadow"    Warn about shadowed variables.
# "-Werror"     Make all warnings errors.
warning_c_flags := \
	-Wall \
	-Wextra \
	-Wpedantic \
	-Wno-unused \
	-Wshadow \
	-Werror

# Library C Flags:
# "-shared" Create a shared library.
# "-fPIC"   Generate position-independent code
library_c_flags := -shared -fPIC

# Use Zig for cross-compilation.
build_lua_hydrogen := zig cc \
	${base_c_flags} \
	${warning_c_flags} \
	${library_c_flags} \
	./source/c/lhydrogenlib.c

# The native compiler for the system.
CC ?= gcc

# The root directory of the project.
root_dir := $(shell git rev-parse --show-toplevel || pwd)

# Build the base libhydrogen library used by Python
build/libhydrogen.so: source/c/third-party/libhydrogen/hydrogen.c
	${CC} $^ -o $@ ${base_c_flags} ${warning_c_flags} ${library_c_flags}

# Build the Lua libhydrogen libraries for all platforms.
build/libhydrogen.aarch64-linux.so: source/c/lhydrogenlib.c
	${build_lua_hydrogen} -o $@ --target=aarch64-linux-gnu

build/libhydrogen.amd64-freebsd.so: source/c/lhydrogenlib.c
	${build_lua_hydrogen} -o $@ --target=x86-freebsd-none

build/libhydrogen.amd64-netbsd.so: source/c/lhydrogenlib.c
	${build_lua_hydrogen} -o $@ --target=x86_64-netbsd-none

build/libhydrogen.arm64-darwin.dylib: source/c/lhydrogenlib.c
	${build_lua_hydrogen} -o $@ --target=aarch64-macos-none -Wl,-undefined,dynamic_lookup

build/libhydrogen.armhf-linux.so: source/c/lhydrogenlib.c
	${build_lua_hydrogen} -o $@ --target=arm-linux-gnueabihf

build/libhydrogen.i386-freebsd.so: source/c/lhydrogenlib.c
	${build_lua_hydrogen} -o $@ --target=x86-freebsd-none

build/libhydrogen.i386-linux.so: source/c/lhydrogenlib.c
	${build_lua_hydrogen} -o $@ --target=x86-linux-gnu

build/libhydrogen.i386-netbsd.so: source/c/lhydrogenlib.c
	${build_lua_hydrogen} -o $@ --target=x86-netbsd-none

build/libhydrogen.universal-darwin.dylib: \
	build/libhydrogen.x86_64-darwin.dylib \
	build/libhydrogen.arm64-darwin.dylib \
	# (end of targets)
	llvm-lipo -create -output $@ $^

build/libhydrogen.windows.dll: source/c/lhydrogenlib.c
	${build_lua_hydrogen} -o $@ --target=x86_64-windows-gnu -Wno-unknown-pragmas $$(kpsewhich --var-value=SELFAUTOPARENT)/bin/windows/lua53w64.dll

build/libhydrogen.x86_64-darwin.dylib: source/c/lhydrogenlib.c
	${build_lua_hydrogen} -o $@ --target=x86_64-macos-none -Wl,-undefined,dynamic_lookup

build/libhydrogen.x86_64-darwinlegacy.dylib: source/c/lhydrogenlib.c
	${build_lua_hydrogen} -o $@ --target=x86_64-macos-none -Wl,-undefined,dynamic_lookup

build/libhydrogen.x86_64-linuxmusl.so: source/c/lhydrogenlib.c
	${build_lua_hydrogen} -o $@ --target=x86_64-linux-musl

build/libhydrogen.x86_64-linux.so: source/c/lhydrogenlib.c
	${build_lua_hydrogen} -o $@ --target=x86_64-linux-gnu

# Download libcurl
build/libcurl.dll:
	temp_dir=$$(mktemp -d)
	trap "rm -rf $$temp_dir" EXIT
	cd $$temp_dir
	wget 'https://curl.se/windows/dl-8.18.0_4/curl-8.18.0_4-win64-mingw.zip'
	unzip ./curl-*-win64-mingw.zip
	cp ./curl-*-win64-mingw/bin/libcurl-x64.dll ${root_dir}/$@

# Build the database and zip files
network-install.files.lut.gz network-install.files.zip &: scripts/generate-database.py build/libhydrogen.so
	python3 $<

# Build all the Lua libhydrogen libraries
lua_targets := \
	build/libhydrogen.aarch64-linux.so \
	build/libhydrogen.amd64-freebsd.so \
	build/libhydrogen.amd64-netbsd.so \
	build/libhydrogen.armhf-linux.so \
	build/libhydrogen.i386-freebsd.so \
	build/libhydrogen.i386-linux.so \
	build/libhydrogen.i386-netbsd.so \
	build/libhydrogen.universal-darwin.dylib \
	build/libhydrogen.windows.dll \
	build/libhydrogen.x86_64-darwinlegacy.dylib \
	build/libhydrogen.x86_64-linuxmusl.so \
	build/libhydrogen.x86_64-linux.so \
	# (end of targets)

.PHONY: lua
lua: ${lua_targets} ;

# Build almost everything
non_db_targets := \
	${lua_targets} \
	build/libhydrogen.so \
	build/libcurl.dll \
	# (end of targets)

.DEFAULT_GOAL := not-db
.PHONY: not-db
not-db: ${non_db_targets} ;

# Build everything
.PHONY: all
all: ${non_db_targets} network-install.files.lut.gz network-install.files.zip

# Clean
clean:
	rm ${all_targets}
