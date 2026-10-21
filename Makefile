# make install   build, replace /Applications/ANNOT.app and start it (keeps the permissions: same path, same signature)
# make release VERSION=0.4.0   see release.sh

APP := build/ANNOT.app
DEST := /Applications/ANNOT.app

.PHONY: build install run quit logs clean release

build:
	./build.sh

install: build quit
	rm -rf "$(DEST)"
	ditto "$(APP)" "$(DEST)"
	open "$(DEST)"

run:
	open "$(DEST)"

quit:
	-osascript -e 'quit app "ANNOT"' 2>/dev/null
	@for i in $$(seq 50); do pgrep -xq ANNOT || break; sleep 0.2; done # up to 10 s

# What the browser bridge does (capture, connection state per browser).
logs:
	/usr/bin/log stream --style compact --predicate 'subsystem == "io.klixpert.annot"'

clean:
	rm -rf build

release:
	@test -n "$(VERSION)" || { echo "usage: make release VERSION=1.2.3"; exit 1; }
	./release.sh "$(VERSION)"
