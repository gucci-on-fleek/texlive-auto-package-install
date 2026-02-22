# Target-style settings
.SUFFIXES:
.SILENT:
.ONESHELL:
.SHELLFLAGS := -eu -o pipefail -c

# C Flags

# Things we always want:
#
# -pipe: Use pipes internally (speeds up compilation).
#
# -std=gnu23: Use the latest C standard, but with GNU extensions.
#
# -I$(shell ...): Add the local include directory to the search path.
base_c_flags := \
	-pipe \
	-std=gnu23 \
	-I$(shell git rev-parse --show-toplevel || echo .)/source/c/

# Warnings:
#
# -Wall: Enable “all” warnings.
#
# -Wextra: Enable more warnings.
#
# -Wpedantic: Enable even more warnings.
#
# -Wno-unused: Ignore “Unused XXX” warnings.
#
# -Wshadow: Warn about shadowed variables.
#
# -Werror: Make all warnings errors.
warning_c_flags := \
	-Wall \
	-Wextra \
	-Wpedantic \
	-Wno-unused \
	-Wshadow \
	-Werror \

# Debugging:
#
# -DDEBUG=1: Define the DEBUG macro so that we can check it in the C source.
#
# -O0: No optimizations, so that we can debug macro expansions.
#
# -g3 -ggdb3: Maximum debugging information.
#
# -fanalyzer: Run a static analyzer before compiling.
#
# -fsanitize=address,undefined,leak: Enable address, undefined behaviour, and
#									 memory leak sanitizers.
#
# -fhardened: Enable extra security features, which should catch more bugs.
#
# -ftrivial-auto-var-init=pattern: Catch any uses of uninitialized variables.
debug_c_flags := \
	-DDEBUG=1 \
	-O0 \
	-g3	-ggdb3 \
	-fanalyzer \
	-fsanitize=address,undefined,leak \
	-fhardened -Wno-hardened \
	-ftrivial-auto-var-init=pattern

# Release:
#
# -flto=auto: Enable link-time optimization, which can speed up the program.
#
# -O3: Maximum optimizations.
#
# -fgraphite-identity -floop-nest-optimize: Enable Graphite loop optimizations.
release_c_flags := \
	-flto=auto \
	-O3 \
	-fgraphite-identity \
	-floop-nest-optimize

# Libraries
#
# -lm: Link the math library.
libraries := \
	-lm

ifndef mode
	mode := debug
endif

ifndef override_c_flags
	override_c_flags :=
endif

ifeq "${mode}" "release"
    c_flags := ${base_c_flags} ${warning_c_flags} ${release_c_flags} ${override_c_flags} ${libraries}
else ifeq "${mode}" "debug"
    c_flags := ${base_c_flags} ${warning_c_flags} ${debug_c_flags} ${override_c_flags} ${libraries}
else
    $(error "Invalid mode: ${mode}")
endif

# All
.DEFAULT_GOAL := all
.PHONY: all
all: lhydrogenlib.so third-party/libhydrogen/hydrogen.so

# Build
%.so: %.c
	gcc $^ -o $@ ${c_flags} -fPIC -shared

# Clean
.PHONY: clean
clean:
	git --interactive -xd
