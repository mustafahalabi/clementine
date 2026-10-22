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
	scripts/test-image-editor.sh
	scripts/test-waveform.sh
	scripts/test-pdf-metadata.sh
	scripts/test-productivity.sh

clean:
	rm -rf .build build

.PHONY: tools release

# Download the verified ffmpeg/ffprobe/cwebp/img2webp builds into vendor/bin (bundled by `make app`).
tools:
	scripts/fetch-tools.sh

# Signed + notarized zip/DMG in dist/ when CODESIGN_IDENTITY and NOTARY_PROFILE are set; unsigned otherwise.
release:
	scripts/release.sh

.PHONY: ui-test

# Interaction tests: real windows off-screen, driven with synthetic events (needs a logged-in GUI session).
ui-test:
	swift build
	.build/debug/Clementine --ui-test
