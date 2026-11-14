# Reforge — common tasks. Run `make help` for the list.
APP_NAME    := Reforge.app
DEV_APP     := build/Reforge Dev.app
INSTALL_DIR ?= /Applications

# Older SDK when the Command Line Tools can't build SwiftUI with the newest one (see the script).
PICKED_SDK := $(shell scripts/pick-sdk.sh)
ifneq ($(PICKED_SDK),)
export SDKROOT := $(PICKED_SDK)
endif

.PHONY: help build test e2e install reinstall run dev icon clean

help:
	@echo "make install   Build and (re)install $(APP_NAME) into $(INSTALL_DIR)"
	@echo "make run       Install, then open the app"
	@echo "make dev       Build and open \"$(DEV_APP)\" (settings + key in ./.dev, no Keychain)"
	@echo "make build     Build only (creates \"$(DEV_APP)\", separate from the installed app)"
	@echo "make test      Run the headless test suite (swift test)"
	@echo "make e2e       Build the app and run the end-to-end smoke tests (needs Accessibility permission)"
	@echo "make icon      Redraw the app icon from scripts/make-icon.swift"
	@echo "make clean     Remove build outputs"

build:
	./build.sh

# With only the Command Line Tools (no Xcode), Swift Testing sits outside the default search
# paths and its Foundation cross-import overlay ships without a module, so point swift at it.
# Newer SwiftPM also stopped finding its macro plugin (@Test, @Suite) there, so load it directly.
CLT_FRAMEWORKS := /Library/Developer/CommandLineTools/Library/Developer/Frameworks
CLT_TESTING_MACROS := /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
ifeq ($(shell xcode-select -p 2>/dev/null),/Library/Developer/CommandLineTools)
TEST_FLAGS := -Xswiftc -F -Xswiftc $(CLT_FRAMEWORKS) -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
	-Xlinker -rpath -Xlinker $(CLT_FRAMEWORKS)
ifneq ($(wildcard $(CLT_TESTING_MACROS)),)
TEST_FLAGS += -Xswiftc -load-plugin-library -Xswiftc $(CLT_TESTING_MACROS)
endif
endif

test:
	swift test $(TEST_FLAGS) --skip ReforgeE2ETests $(ARGS)

# Launches "build/Reforge Dev.app" in stub mode (REFORGE_E2E_FIXTURE, no network/Keychain/real folders) and
# drives it through the Accessibility API. Grant Accessibility to your terminal or IDE first.
e2e: build
	REFORGE_E2E=1 swift test $(TEST_FLAGS) --filter ReforgeE2ETests $(ARGS)

# Builds the real app (local.reforge) in a temp folder, quits the installed copy, and swaps the
# new build in. Only this target produces the release identity, so the repo never holds a second
# "Reforge" for macOS to confuse with the installed one. The old copy is moved into the temp
# folder rather than deleted in place.
install:
	@test -n "$(INSTALL_DIR)" && test -d "$(INSTALL_DIR)" || { echo "INSTALL_DIR '$(INSTALL_DIR)' does not exist"; exit 1; }
	@tmp="$$(mktemp -d -t reforge)" && test -n "$$tmp" && \
		./build.sh release "$$tmp" && \
		{ pkill -f "$(INSTALL_DIR)/$(APP_NAME)/" 2>/dev/null || true; } && \
		mv "$$tmp/$(APP_NAME)" "$$tmp/staged.app" && \
		{ test ! -e "$(INSTALL_DIR)/$(APP_NAME)" || mv "$(INSTALL_DIR)/$(APP_NAME)" "$$tmp/previous.app"; } && \
		mv "$$tmp/staged.app" "$(INSTALL_DIR)/$(APP_NAME)" && \
		rm -r -f "$$tmp"
	@echo "Installed $(INSTALL_DIR)/$(APP_NAME)"

reinstall: install

run: install
	open "$(INSTALL_DIR)/$(APP_NAME)"

# Opens "build/Reforge Dev.app" with its settings and API key kept in ./.dev instead of
# Application Support and the Keychain, so rebuilds never prompt for the Keychain.
dev: build
	@pkill -f "$(CURDIR)/$(DEV_APP)/" 2>/dev/null || true
	open -n --env REFORGE_DEV_DIR="$(CURDIR)/.dev" "$(DEV_APP)"

icon:
	swift scripts/make-icon.swift

clean:
	swift package clean
	rm -r -f ".build/release" "./$(APP_NAME)" "./build"
