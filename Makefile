XCODEPROJ := Noroshi/Noroshi.xcodeproj
SCHEME := Noroshi
CONFIGURATION := Debug
DERIVED_DATA := tmp/DerivedData
# install の target 固有変数 CONFIGURATION を反映するため遅延展開にする
APP = $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/Noroshi.app
INSTALL_APP := $(HOME)/Applications/Noroshi.app
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

.PHONY: run build test clean install

# ビルドして Noroshi.app を起動する
run: build
	open $(APP)

build:
	xcodebuild -project $(XCODEPROJ) -scheme $(SCHEME) -configuration $(CONFIGURATION) -derivedDataPath $(DERIVED_DATA) build

# Release ビルドを ~/Applications に配置して普段使いできるようにする (ADR 0007)
install: CONFIGURATION := Release
install: build
	mkdir -p $(HOME)/Applications
	rm -rf $(INSTALL_APP)
	ditto $(APP) $(INSTALL_APP)
	$(LSREGISTER) -f $(INSTALL_APP)

test:
	xcodebuild -project $(XCODEPROJ) -scheme $(SCHEME) -derivedDataPath $(DERIVED_DATA) test

clean:
	rm -rf $(DERIVED_DATA)
