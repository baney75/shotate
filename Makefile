.PHONY: build test app install selftest clean
build:
	swift build
test:
	swift test
app:
	scripts/bundle.sh
install:
	scripts/bundle.sh --install
selftest: app
	build/Snapmark.app/Contents/MacOS/Snapmark --selftest Tests/Fixtures/sample.png build/selftest.png
clean:
	rm -rf .build build
