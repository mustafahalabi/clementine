.PHONY: build app run install test clean

build:
	swift build

app:
	scripts/bundle.sh release

run: app
	-pkill -x Clementine
	open build/Clementine.app

install: app
	-pkill -x Clementine
	rm -rf /Applications/Clementine.app
	cp -R build/Clementine.app /Applications/
	open /Applications/Clementine.app

test:
	scripts/smoke-test.sh
	scripts/edge-test.sh
	scripts/stress-test.sh

clean:
	rm -rf .build build
