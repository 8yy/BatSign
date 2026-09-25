NAME := BatSign
SCHEME := Feather
PLATFORMS := iphoneos maccatalyst

TMP := $(TMPDIR)/$(NAME)
CERT_JSON_URL := https://backloop.dev/pack.json

.PHONY: all clean deps $(PLATFORMS)

all: $(PLATFORMS)

clean:
	rm -rf $(TMP)
	rm -rf packages
	rm -rf Payload

deps:
	rm -rf deps || true
	mkdir -p deps

	-curl -fsSL "$(CERT_JSON_URL)" -o cert.json
	@if [ -f cert.json ]; then \
		jq -r '.cert' cert.json > deps/server.crt; \
		jq -r '.key1, .key2' cert.json > deps/server.pem; \
		jq -r '.info.domains.commonName' cert.json > deps/commonName.txt; \
	fi


$(PLATFORMS): deps
	rm -rf _build

	@if [ "$@" = "iphoneos" ]; then \
		DEST="generic/platform=iOS"; \
	else \
		DEST="generic/platform=macOS,variant=Mac Catalyst"; \
	fi; \
	xcodebuild \
		-project Feather.xcodeproj \
		-scheme $(SCHEME) \
		-configuration Release \
		-destination "$$DEST" \
		-derivedDataPath $(TMP)/$@ \
		-skipPackagePluginValidation \
		CODE_SIGNING_ALLOWED=NO \
		ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES=NO

	mkdir -p _build/Payload
	cp -R _build/Applications/*.app _build/Payload/BatSign.app
	chmod -R 0755 _build/Payload/BatSign.app
	codesign --force --sign - --timestamp=none _build/Payload/BatSign.app
	cp deps/* _build/Payload/BatSign.app/ || true

	mkdir -p packages

	@if [ "$@" = "iphoneos" ]; then \
		ditto -c -k --sequesterRsrc --keepParent _build/Payload "packages/BatSign.ipa"; \
	else \
		ditto -c -k --sequesterRsrc --keepParent _build/Payload/BatSign.app "packages/BatSign_Catalyst.zip"; \
	fi
