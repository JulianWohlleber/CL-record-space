APP_NAME   := record_space
SCHEME     := VoiceMemoBar
BUILD_DIR  := build
RELEASE    := $(BUILD_DIR)/Build/Products/Release/$(APP_NAME).app
INSTALL    := /Applications/$(APP_NAME).app

.PHONY: build install dmg clean run uninstall

build:
	xcodebuild -project VoiceMemoBar.xcodeproj \
	  -scheme $(SCHEME) \
	  -configuration Release \
	  -derivedDataPath $(BUILD_DIR)

install: build
	@echo "==> Installing to $(INSTALL)"
	@pkill -x $(APP_NAME) 2>/dev/null || true
	@sleep 0.3
	@rm -rf "$(INSTALL)"
	@ditto "$(RELEASE)" "$(INSTALL)"
	@echo "==> Installed. Run with: open $(INSTALL)"

dmg:
	bash scripts/create-dmg.sh

run: build
	@pkill -x $(APP_NAME) 2>/dev/null || true
	@sleep 0.3
	@open "$(RELEASE)"

clean:
	rm -rf $(BUILD_DIR) DerivedData

uninstall:
	@pkill -x $(APP_NAME) 2>/dev/null || true
	@rm -rf "$(INSTALL)"
	@echo "==> Uninstalled $(APP_NAME)"
