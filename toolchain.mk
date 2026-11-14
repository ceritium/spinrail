# Shared spinel + tep toolchain, cloned and built into <repo>/vendor.
# tep v0.12.0 is built and tested against spinel 2026.10.25.
SPINEL_REF    := 2026.10.25
TEP_REF       := v0.12.0
SPINELKIT_REF := v0.3.1

# VENDOR defaults to <repo>/vendor; the rieles CLI passes its own when
# installed as a gem.
TOOLCHAIN_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
VENDOR         ?= $(abspath $(TOOLCHAIN_ROOT)/../vendor)
SPINEL_DIR     := $(VENDOR)/spinel
TEP_DIR        := $(VENDOR)/tep
SPINELKIT_DIR  := $(VENDOR)/spinelkit
TEP            := $(TEP_DIR)/bin/tep

export SPINEL := $(SPINEL_DIR)/spinel
export SPINELKIT_DIR
# Stops tep from checking out a different spinel ref behind our back.
export TEP_SKIP_SPINEL_FRESH := 1

JOBS  ?= $(shell sysctl -n hw.ncpu 2>/dev/null || nproc)
CLONE  = git -c advice.detachedHead=false clone --quiet --depth 1 --branch

# Prebuilt next to their sources so `tep build` uses them instead of
# compiling them into ~/.cache/tep.
SPHTTP_O := $(TEP_DIR)/tep/sphttp.o
SQLITE_O := $(TEP_DIR)/native/sqlite/tep_sqlite.o

.PHONY: setup

setup: $(SPINEL) $(SPHTTP_O) $(SQLITE_O) $(SPINELKIT_DIR)/spinel_kit.rb

$(SPINEL):
	[ -d $(SPINEL_DIR) ] || $(CLONE) $(SPINEL_REF) https://github.com/matz/spinel $(SPINEL_DIR)
	$(MAKE) -C $(SPINEL_DIR) deps
	$(MAKE) -C $(SPINEL_DIR) -j$(JOBS)

$(TEP):
	$(CLONE) $(TEP_REF) https://github.com/OriPekelman/tep $(TEP_DIR)

$(SPINELKIT_DIR)/spinel_kit.rb:
	$(CLONE) $(SPINELKIT_REF) https://github.com/OriPekelman/spinelkit $(SPINELKIT_DIR)

$(SPHTTP_O): | $(TEP)
	cc -O2 $(shell pkg-config --cflags openssl 2>/dev/null) -c $(TEP_DIR)/tep/sphttp.c -o $@

$(SQLITE_O): | $(TEP)
	cc -O2 $(shell pkg-config --cflags sqlite3 2>/dev/null) -c $(TEP_DIR)/native/sqlite/tep_sqlite.c -o $@
