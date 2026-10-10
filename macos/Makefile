.PHONY: build test app install uninstall selftest brand clean
build:
	swift build
test:
	swift test
app:
	scripts/bundle.sh
install:
	scripts/bundle.sh --install
uninstall:
	../uninstall.sh
selftest: app
	build/Snapmark.app/Contents/MacOS/Snapmark --selftest Tests/Fixtures/sample.png build/selftest.png
# Regenerates the README banner, social card and example image from the app icon and renderer.
brand: app
	swift scripts/make-brand.swift build/Snapmark.iconset/icon_512x512@2x.png ../docs
	build/Snapmark.app/Contents/MacOS/Snapmark --selftest Tests/Fixtures/sample.png ../docs/example.png
clean:
	rm -rf .build build
