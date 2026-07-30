APP_NAME := Headphone Lab Menu
EXECUTABLE := HeadphoneLabMenu
APP_DIR := build/$(APP_NAME).app
VERSION ?= 1.0.0
ARCHIVE_PATH := build/HeadphoneLabMenu-$(VERSION)-macOS.zip
SIGN_IDENTITY ?= -
NOTARY_PROFILE ?= headphone-lab-menu
ENTITLEMENTS := Resources/HeadphoneLabMenu.entitlements

ifeq ($(SIGN_IDENTITY),-)
SIGN_TIMESTAMP := --timestamp=none
else
SIGN_TIMESTAMP := --timestamp
endif

.PHONY: app archive notarize staple clean run install

app:
	swift build -c release
	rm -rf "$(APP_DIR)"
	mkdir -p "$(APP_DIR)/Contents/MacOS" "$(APP_DIR)/Contents/Resources"
	cp .build/release/$(EXECUTABLE) "$(APP_DIR)/Contents/MacOS/$(EXECUTABLE)"
	cp Resources/Info.plist "$(APP_DIR)/Contents/Info.plist"
	xcrun actool Resources/AppIcon.icon \
		--compile "$(APP_DIR)/Contents/Resources" \
		--platform macosx \
		--minimum-deployment-target 14.2 \
		--app-icon AppIcon \
		--output-partial-info-plist build/AppIcon-Info.plist >/dev/null
	xattr -cr "$(APP_DIR)"
	codesign --force --options runtime $(SIGN_TIMESTAMP) \
		--entitlements "$(ENTITLEMENTS)" \
		--sign "$(SIGN_IDENTITY)" "$(APP_DIR)"
	xattr -cr "$(APP_DIR)"
	codesign --verify --deep --strict --verbose=2 "$(APP_DIR)"
	@echo "Built $(APP_DIR)"

archive: app
	xattr -cr "$(APP_DIR)"
	rm -f "$(ARCHIVE_PATH)"
	ditto -c -k --norsrc --keepParent "$(APP_DIR)" \
		"$(ARCHIVE_PATH)"
	@echo "Archived $(ARCHIVE_PATH)"

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
