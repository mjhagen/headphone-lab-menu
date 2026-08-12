APP_NAME := Headphone EQ
EXECUTABLE := HeadphoneEQ
APP_DIR := build/$(APP_NAME).app
STAGING_ROOT := /tmp/nl.mingo.HeadphoneEQ-build
STAGING_APP_DIR := $(STAGING_ROOT)/$(APP_NAME).app
VERSION ?= 2.1.0
ARCHIVE_PATH := build/HeadphoneEQ-$(VERSION)-macOS.zip
SIGN_IDENTITY ?= -
NOTARY_PROFILE ?= headphone-lab-menu
ENTITLEMENTS := Resources/HeadphoneLabMenu.entitlements
SPARKLE_FRAMEWORK_SOURCE := .build/release/Sparkle.framework
SPARKLE_FRAMEWORK := $(STAGING_APP_DIR)/Contents/Frameworks/Sparkle.framework
SPARKLE_ACCOUNT ?= nl.mingo.HeadphoneLabMenu
SPARKLE_KEY_FILE ?=
SPARKLE_BIN := .build/artifacts/sparkle/Sparkle/bin
SPARKLE_FEED_DIR := build/sparkle-feed

ifeq ($(strip $(SPARKLE_KEY_FILE)),)
SPARKLE_SIGNING_ARGS := --account "$(SPARKLE_ACCOUNT)"
else
SPARKLE_SIGNING_ARGS := --ed-key-file "$(SPARKLE_KEY_FILE)"
endif

ifeq ($(SIGN_IDENTITY),-)
SIGN_TIMESTAMP := --timestamp=none
else
SIGN_TIMESTAMP := --timestamp
endif

.PHONY: app archive appcast release sparkle-key notarize staple clean run install

app:
	swift build -c release
	mkdir -p build
	rm -rf "$(STAGING_ROOT)"
	mkdir -p "$(STAGING_APP_DIR)/Contents/MacOS" \
		"$(STAGING_APP_DIR)/Contents/Resources" \
		"$(STAGING_APP_DIR)/Contents/Frameworks"
	cp .build/release/$(EXECUTABLE) \
		"$(STAGING_APP_DIR)/Contents/MacOS/$(EXECUTABLE)"
	ditto --norsrc "$(SPARKLE_FRAMEWORK_SOURCE)" "$(SPARKLE_FRAMEWORK)"
	cp Resources/Info.plist "$(STAGING_APP_DIR)/Contents/Info.plist"
	cp .build/checkouts/Sparkle/LICENSE \
		"$(STAGING_APP_DIR)/Contents/Resources/Sparkle-LICENSE.txt"
	chmod 644 "$(STAGING_APP_DIR)/Contents/Resources/Sparkle-LICENSE.txt"
	xcrun actool Resources/AppIcon.icon \
		--compile "$(STAGING_APP_DIR)/Contents/Resources" \
		--platform macosx \
		--minimum-deployment-target 14.2 \
		--app-icon AppIcon \
		--output-partial-info-plist build/AppIcon-Info.plist >/dev/null
	xattr -cr "$(STAGING_APP_DIR)"
	codesign --force --options runtime $(SIGN_TIMESTAMP) \
		--sign "$(SIGN_IDENTITY)" \
		"$(SPARKLE_FRAMEWORK)/Versions/B/XPCServices/Installer.xpc"
	codesign --force --options runtime $(SIGN_TIMESTAMP) \
		--preserve-metadata=entitlements \
		--sign "$(SIGN_IDENTITY)" \
		"$(SPARKLE_FRAMEWORK)/Versions/B/XPCServices/Downloader.xpc"
	codesign --force --options runtime $(SIGN_TIMESTAMP) \
		--sign "$(SIGN_IDENTITY)" \
		"$(SPARKLE_FRAMEWORK)/Versions/B/Autoupdate"
	codesign --force --options runtime $(SIGN_TIMESTAMP) \
		--sign "$(SIGN_IDENTITY)" \
		"$(SPARKLE_FRAMEWORK)/Versions/B/Updater.app"
	codesign --force --options runtime $(SIGN_TIMESTAMP) \
		--sign "$(SIGN_IDENTITY)" "$(SPARKLE_FRAMEWORK)"
	codesign --force --options runtime $(SIGN_TIMESTAMP) \
		--entitlements "$(ENTITLEMENTS)" \
		--sign "$(SIGN_IDENTITY)" "$(STAGING_APP_DIR)"
	xattr -cr "$(STAGING_APP_DIR)"
	codesign --verify --deep --strict --verbose=2 "$(STAGING_APP_DIR)"
	rm -rf "$(APP_DIR)"
	ditto --norsrc "$(STAGING_APP_DIR)" "$(APP_DIR)"
	rm -rf "$(STAGING_ROOT)"
	@echo "Built $(APP_DIR)"

archive: app
	xattr -cr "$(APP_DIR)"
	rm -f "$(ARCHIVE_PATH)"
	ditto -c -k --norsrc --keepParent "$(APP_DIR)" \
		"$(ARCHIVE_PATH)"
	@echo "Archived $(ARCHIVE_PATH)"

appcast:
	@test -f "$(ARCHIVE_PATH)" || \
		(echo "Build and notarize $(ARCHIVE_PATH) before generating the appcast" >&2; exit 1)
	rm -rf "$(SPARKLE_FEED_DIR)"
	mkdir -p "$(SPARKLE_FEED_DIR)"
	cp appcast.xml "$(SPARKLE_FEED_DIR)/appcast.xml"
	cp "$(ARCHIVE_PATH)" "$(SPARKLE_FEED_DIR)/"
	"$(SPARKLE_BIN)/generate_appcast" \
		$(SPARKLE_SIGNING_ARGS) \
		--download-url-prefix \
		"https://github.com/mjhagen/headphone-lab-menu/releases/download/v$(VERSION)/" \
		--link "https://github.com/mjhagen/headphone-lab-menu" \
		-o "$(abspath appcast.xml)" "$(SPARKLE_FEED_DIR)"
	@echo "Generated appcast.xml"

release: notarize
	$(MAKE) appcast VERSION="$(VERSION)" \
		SPARKLE_ACCOUNT="$(SPARKLE_ACCOUNT)" \
		SPARKLE_KEY_FILE="$(SPARKLE_KEY_FILE)"

sparkle-key:
	"$(SPARKLE_BIN)/generate_keys" --account "$(SPARKLE_ACCOUNT)"

notarize: archive
	@test "$(SIGN_IDENTITY)" != "-" || \
		(echo "SIGN_IDENTITY must be a Developer ID Application certificate" >&2; exit 1)
	xcrun notarytool submit "$(ARCHIVE_PATH)" \
		--keychain-profile "$(NOTARY_PROFILE)" \
		--wait
	$(MAKE) staple VERSION="$(VERSION)"

staple:
	xattr -cr "$(APP_DIR)"
	codesign --verify --deep --strict --verbose=2 "$(APP_DIR)"
	xcrun stapler staple "$(APP_DIR)"
	xcrun stapler validate "$(APP_DIR)"
	rm -f "$(ARCHIVE_PATH)"
	ditto -c -k --keepParent "$(APP_DIR)" "$(ARCHIVE_PATH)"
	cd build && shasum -a 256 "$(notdir $(ARCHIVE_PATH))" > \
		"$(notdir $(ARCHIVE_PATH)).sha256"
	spctl --assess --type execute --verbose=4 "$(APP_DIR)"
	@echo "Notarized $(ARCHIVE_PATH)"

run: app
	open "$(APP_DIR)"

install: app
	ditto "$(APP_DIR)" "/Applications/$(APP_NAME).app"
	@echo "Installed /Applications/$(APP_NAME).app"

clean:
	swift package clean
	rm -rf build
