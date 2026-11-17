# MaxTubePlus Desktop — build helpers (the PKGBUILD uses the same targets).
CC ?= cc
CFLAGS ?= -O2
PREFIX ?= /usr
DESTDIR ?=
PYTHON ?= python3
CORE_SRC := ../MaxTubePlus/Core/MTPCore.c
CORE_LIB := maxtubeplus_desktop/libmtpcore.so

.PHONY: all core test smoke clean install

all: core

# The exact C core the iOS tweak uses, built as a shared library for ctypes.
core: $(CORE_LIB)
$(CORE_LIB): $(CORE_SRC) ../MaxTubePlus/Core/MTPCore.h
	$(CC) $(CFLAGS) $(LDFLAGS) -std=c99 -D_DEFAULT_SOURCE -fPIC -shared -Wall -Wextra -o $@ $(CORE_SRC)

test: core
	$(PYTHON) -m unittest discover -s tests -v

# Launches the real window offscreen, checks every page builds, then exits.
smoke: core
	xvfb-run -a $(PYTHON) -m maxtubeplus_desktop --self-test

install: core
	install -Dm755 $(CORE_LIB) $(DESTDIR)$(PREFIX)/lib/maxtubeplus/libmtpcore.so
	install -Dm644 data/io.github.maxtubeplus.Desktop.desktop $(DESTDIR)$(PREFIX)/share/applications/io.github.maxtubeplus.Desktop.desktop
	install -Dm644 data/io.github.maxtubeplus.Desktop.svg $(DESTDIR)$(PREFIX)/share/icons/hicolor/scalable/apps/io.github.maxtubeplus.Desktop.svg
	install -Dm644 data/io.github.maxtubeplus.Desktop.metainfo.xml $(DESTDIR)$(PREFIX)/share/metainfo/io.github.maxtubeplus.Desktop.metainfo.xml

clean:
	rm -f $(CORE_LIB)
	rm -rf build dist *.egg-info
