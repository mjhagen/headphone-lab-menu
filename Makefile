APP_NAME := Headphone Lab Menu
EXECUTABLE := HeadphoneLabMenu
APP_DIR := build/$(APP_NAME).app
VERSION ?= 1.0.0
SIGN_IDENTITY ?= -

.PHONY: app archive clean run install

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
	codesign --force --sign "$(SIGN_IDENTITY)" "$(APP_DIR)"
	codesign --verify --deep --strict --verbose=2 "$(APP_DIR)"
	@echo "Built $(APP_DIR)"

archive: app
	xattr -cr "$(APP_DIR)"
	ditto -c -k --norsrc --keepParent "$(APP_DIR)" \
		"build/HeadphoneLabMenu-$(VERSION)-macOS.zip"
	@echo "Archived build/HeadphoneLabMenu-$(VERSION)-macOS.zip"

run: app
	open "$(APP_DIR)"

install: app
	ditto "$(APP_DIR)" "/Applications/$(APP_NAME).app"
	@echo "Installed /Applications/$(APP_NAME).app"

clean:
	swift package clean
	rm -rf build
