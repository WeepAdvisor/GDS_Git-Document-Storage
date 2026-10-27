APP        := GitDocumentStorage
PRODUCT    := GDS
PROJECT    := $(APP).xcodeproj
SCHEME     := $(APP)
PKG_DIR    := Packages/GitDocsKit
DERIVED    := build/DerivedData

.PHONY: generate build run test test-package test-xcode clean logs reset

generate:
	xcodegen generate

## Сборка без подписи — проверка компиляции (CI/агент без Team ID).
build: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-derivedDataPath $(DERIVED) \
		CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
		build -quiet

## Сборка с подписью (нужен Config/Local.xcconfig), установка в ~/Applications и запуск.
run: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-derivedDataPath $(DERIVED) build -quiet
	mkdir -p ~/Applications
	rm -rf ~/Applications/$(PRODUCT).app
	cp -R $(DERIVED)/Build/Products/Debug/$(PRODUCT).app ~/Applications/
	open ~/Applications/$(PRODUCT).app

test: test-package

test-package:
	cd $(PKG_DIR) && swift test

clean:
	rm -rf build $(PROJECT) $(PKG_DIR)/.build

logs:
	scripts/fp-logs.sh

reset:
	scripts/fp-reset.sh
