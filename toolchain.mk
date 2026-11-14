# Shared spinel + tep toolchain, cloned and built into <repo>/vendor.
# tep is a fork (upstream main plus fixes not yet proposed upstream), built
# and tested against spinel at SPINEL_REF. Bump TEP_REF to a new fixes-N tag
# to pick up fork changes; setup moves vendor/tep to it.
# A matz/spinel commit (or tag); setup moves vendor/spinel to it.
SPINEL_REF    := 2026.10.25
TEP_REPO      ?= https://github.com/ceritium/tep
TEP_REF       ?= fixes-1
SPINELKIT_REF := v0.3.1

# VENDOR defaults to <repo>/vendor; the spinrail CLI passes its own when
# installed as a gem.
TOOLCHAIN_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
VENDOR         ?= $(TOOLCHAIN_ROOT)/vendor
SPINEL_DIR     := $(VENDOR)/spinel
TEP_DIR        := $(VENDOR)/tep
SPINELKIT_DIR  := $(VENDOR)/spinelkit
TEP            := $(TEP_DIR)/bin/tep
SPINEL_STAMP   := $(SPINEL_DIR)/.built-$(SPINEL_REF)

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

.PHONY: setup tep-ref

setup: $(SPINEL_STAMP) tep-ref $(SPHTTP_O) $(SQLITE_O) $(SPINELKIT_DIR)/spinel_kit.rb

$(SPINEL): $(SPINEL_STAMP)

$(SPINEL_STAMP):
	[ -d $(SPINEL_DIR)/.git ] || git init --quiet $(SPINEL_DIR)
	cd $(SPINEL_DIR) && git fetch --quiet --depth 1 https://github.com/matz/spinel $(SPINEL_REF) && \
	  git -c advice.detachedHead=false checkout --quiet FETCH_HEAD
	$(MAKE) -C $(SPINEL_DIR) deps
	$(MAKE) -C $(SPINEL_DIR) -j$(JOBS)
	rm -f $(SPINEL_DIR)/.built-* && touch $@

$(TEP):
	$(CLONE) $(TEP_REF) $(TEP_REPO) $(TEP_DIR)

tep-ref: | $(TEP)
	@cd $(TEP_DIR) && [ "$$(git describe --tags --exact-match 2>/dev/null)" = "$(TEP_REF)" ] || \
	  (git fetch --quiet $(TEP_REPO) tag $(TEP_REF) && git -c advice.detachedHead=false checkout --quiet $(TEP_REF))

$(TEP_DIR)/tep/sphttp.c $(TEP_DIR)/native/sqlite/tep_sqlite.c: | $(TEP)

$(SPINELKIT_DIR)/spinel_kit.rb:
	$(CLONE) $(SPINELKIT_REF) https://github.com/OriPekelman/spinelkit $(SPINELKIT_DIR)

$(SPHTTP_O): $(TEP_DIR)/tep/sphttp.c
	cc -O2 $(shell pkg-config --cflags openssl 2>/dev/null) -c $(TEP_DIR)/tep/sphttp.c -o $@

$(SQLITE_O): $(TEP_DIR)/native/sqlite/tep_sqlite.c
	cc -O2 $(shell pkg-config --cflags sqlite3 2>/dev/null) -c $(TEP_DIR)/native/sqlite/tep_sqlite.c -o $@
