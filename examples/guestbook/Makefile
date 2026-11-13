include ../../../toolchain.mk

RIELES  := ../../bin/rieles
PORT    ?= 3000
SOURCES := $(shell find app config db -type f -not -name '*.sqlite3') \
           $(wildcard ../../lib/rieles.rb ../../lib/rieles/*.rb ../../runtime/*.rb)

.PHONY: run routes clean

guestbook: $(SOURCES) | setup
	TEP=$(TEP) ruby $(RIELES) build . -o $@

run: guestbook
	./guestbook -p $(PORT)

routes:
	@ruby $(RIELES) routes .

clean:
	rm -rf guestbook tmp db/*.sqlite3
