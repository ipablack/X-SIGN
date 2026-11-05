NAME := X-SIGN
SCHEME := Feather
PLATFORMS := iphoneos

TMP := $(TMPDIR)/$(NAME)

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
		-skipPackagePluginValidation \
		CODE_SIGNING_ALLOWED=NO \
		ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES=NO

	mkdir -p _build/Payload
	cp -R _build/Applications/*.app _build/Payload/$(NAME).app || cp -R $(TMP)/$@/Build/Products/Release-iphoneos/*.app _build/Payload/$(NAME).app
	
	# إزالة شاشة الريشة الافتراضية نهائياً ليبدأ التطبيق بشاشة X مباشرة
	/usr/libexec/PlistBuddy -c "Delete :UILaunchScreen:UIImageName" _build/Payload/$(NAME).app/Info.plist || true
	/usr/libexec/PlistBuddy -c "Delete :UILaunchStoryboardName" _build/Payload/$(NAME).app/Info.plist || true
	/usr/libexec/PlistBuddy -c "Add :UILaunchScreen dict" _build/Payload/$(NAME).app/Info.plist || true
	
	chmod -R 0755 _build/Payload/$(NAME).app
	codesign --force --sign - --timestamp=none _build/Payload/$(NAME).app || true

	mkdir -p packages
	ditto -c -k --sequesterRsrc --keepParent _build/Payload "packages/$(NAME).ipa"
