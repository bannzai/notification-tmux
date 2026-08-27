XCODEPROJ := Noroshi/Noroshi.xcodeproj
SCHEME := Noroshi
CONFIGURATION := Debug
DERIVED_DATA := tmp/DerivedData
# install の target 固有変数 CONFIGURATION を反映するため遅延展開にする
APP = $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/Noroshi.app
INSTALL_APP := /Applications/Noroshi.app
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
# LicenseList の build tool plugin (PrepareLicenseList) は Xcode GUI の「Trust & Enable」に相当する
# 承認を要求し、CLI ビルドでは承認手段が無いまま "Validate plug-in" で失敗する。
# 依存先は cybozu/LicenseList でバージョンは Package.resolved で固定しているため、検証をスキップする。
SKIP_PLUGIN_VALIDATION := -skipPackagePluginValidation

SUZU_DIR := suzu
SUZU_BIN := $(SUZU_DIR)/bin/suzu
SUZU_INSTALL_DIR := $(HOME)/.local/bin

.PHONY: run build test clean install cli build-cli test-cli verify-cli

# ビルドして Noroshi.app を起動する
run: build
	open $(APP)

build:
	xcodebuild -project $(XCODEPROJ) -scheme $(SCHEME) -configuration $(CONFIGURATION) -derivedDataPath $(DERIVED_DATA) $(SKIP_PLUGIN_VALIDATION) build

# Release ビルドを /Applications に配置して普段使いできるようにする (ADR 0007)
install: CONFIGURATION := Release
install: build
	rm -rf $(INSTALL_APP)
	ditto $(APP) $(INSTALL_APP)
	$(LSREGISTER) -f $(INSTALL_APP)

test:
	xcodebuild -project $(XCODEPROJ) -scheme $(SCHEME) -derivedDataPath $(DERIVED_DATA) $(SKIP_PLUGIN_VALIDATION) test

clean:
	rm -rf $(DERIVED_DATA) $(SUZU_DIR)/bin

# suzu (nested tmux の額縁 + 通知サイドバー) をビルドして ~/.local/bin へ配置する
cli: build-cli
	mkdir -p $(SUZU_INSTALL_DIR)
	install -m 0755 $(SUZU_BIN) $(SUZU_INSTALL_DIR)/suzu

build-cli:
	cd $(SUZU_DIR) && go build -o bin/suzu .

test-cli:
	cd $(SUZU_DIR) && go vet ./... && go test ./...

# 隔離 socket だけを使う E2E。普段の tmux には触れない
verify-cli: build-cli
	bash $(SUZU_DIR)/verify.sh
