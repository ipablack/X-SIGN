NAME := X-SIGN
SCHEME := Feather
PLATFORMS := iphoneos
XSIGN_APP_NAME ?= Xsign
XSIGN_BUNDLE_ID ?= Xsign
XSIGN_APP_VERSION ?= 1.0
XSIGN_BUILD_NUMBER ?= 1
XSIGN_RELEASE_ORIGIN ?=
XSIGN_STUDIO_BUILD_REQUEST ?=
export XSIGN_APP_NAME XSIGN_BUNDLE_ID XSIGN_APP_VERSION XSIGN_BUILD_NUMBER
export XSIGN_RELEASE_ORIGIN XSIGN_STUDIO_BUILD_REQUEST

TMP := $(or $(TMPDIR),/tmp)/$(NAME)
RESULT_BUNDLE_ARGUMENT := $(if $(XSIGN_RESULT_BUNDLE),-resultBundlePath "$(XSIGN_RESULT_BUNDLE)",)

.PHONY: all clean deps $(PLATFORMS)

all: $(PLATFORMS)

clean:
	rm -rf $(TMP)
	rm -rf packages
	rm -rf _build

deps:
	python3 Tools/Prepare_Zsign.py

$(PLATFORMS): deps
	rm -rf _build

	xcodebuild \
		-workspace Feather.xcworkspace \
		-scheme $(SCHEME) \
		-configuration Release \
		-destination "generic/platform=iOS" \
		-derivedDataPath $(TMP)/$@ \
		$(RESULT_BUNDLE_ARGUMENT) \
		-skipPackagePluginValidation \
		CODE_SIGNING_ALLOWED=NO \
		CURRENT_PROJECT_VERSION="$(XSIGN_BUILD_NUMBER)" \
		FEATHER_PRODUCT_BUNDLE_IDENTIFIER="$(XSIGN_BUNDLE_ID)" \
		FEATHER_PROJECT_VERSION="$(XSIGN_APP_VERSION)" \
		XSIGN_APP_DISPLAY_NAME="$$XSIGN_APP_NAME" \
		XSIGN_RELEASE_ORIGIN="$(XSIGN_RELEASE_ORIGIN)" \
		XSIGN_STUDIO_BUILD_REQUEST="$(XSIGN_STUDIO_BUILD_REQUEST)" \
		ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES=NO

	mkdir -p _build/Payload
	cp -R _build/Applications/*.app _build/Payload/$(NAME).app || cp -R $(TMP)/$@/Build/Products/Release-iphoneos/*.app _build/Payload/$(NAME).app

	python3 Tools/XSign_Release.py finalize-info _build/Payload/$(NAME).app/Info.plist

	chmod -R 0755 _build/Payload/$(NAME).app
	codesign --force --sign - --timestamp=none _build/Payload/$(NAME).app

	mkdir -p packages
	ditto -c -k --sequesterRsrc --keepParent _build/Payload "packages/$(NAME).ipa"
