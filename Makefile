# Reforge — common tasks. Run `make help` for the list.
APP_NAME    := Reforge.app
INSTALL_DIR ?= /Applications

.PHONY: help build install reinstall run dev icon clean

help:
	@echo "make install   Build and (re)install $(APP_NAME) into $(INSTALL_DIR)"
	@echo "make run       Install, then open the app"
	@echo "make dev       Build and open a local dev copy (settings + key in ./.dev, no Keychain)"
	@echo "make build     Build only (creates ./$(APP_NAME))"
	@echo "make icon      Redraw the app icon from scripts/make-icon.swift"
	@echo "make clean     Remove build outputs"

build:
	./build.sh

# Quits the running app, then replaces the installed copy with a fresh build.
# The old copy is moved into a temp folder rather than deleted in place.
install: build
	@test -n "$(INSTALL_DIR)" && test -d "$(INSTALL_DIR)" || { echo "INSTALL_DIR '$(INSTALL_DIR)' does not exist"; exit 1; }
	@pkill -x Reforge 2>/dev/null || true
	@pkill -x AddonUpdater 2>/dev/null || true
	@tmp="$$(mktemp -d -t reforge)" && test -n "$$tmp" && \
		ditto "$(APP_NAME)" "$$tmp/staged.app" && \
		{ test ! -e "$(INSTALL_DIR)/$(APP_NAME)" || mv "$(INSTALL_DIR)/$(APP_NAME)" "$$tmp/previous.app"; } && \
		mv "$$tmp/staged.app" "$(INSTALL_DIR)/$(APP_NAME)" && \
		rm -r -f "$$tmp"
	@echo "Installed $(INSTALL_DIR)/$(APP_NAME)"

reinstall: install

run: install
	open "$(INSTALL_DIR)/$(APP_NAME)"

# Opens ./Reforge.app with its settings and API key kept in ./.dev instead of
# Application Support and the Keychain, so rebuilds never prompt for the Keychain.
dev: build
	@pkill -f "$(CURDIR)/$(APP_NAME)/" 2>/dev/null || true
	open -n --env REFORGE_DEV_DIR="$(CURDIR)/.dev" "$(APP_NAME)"

icon:
	swift scripts/make-icon.swift

clean:
	swift package clean
	rm -r -f ".build/release" "./$(APP_NAME)"
