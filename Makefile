XCODEPROJ := Noroshi/Noroshi.xcodeproj
SCHEME := Noroshi
CONFIGURATION := Debug
DERIVED_DATA := tmp/DerivedData
APP := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/Noroshi.app

.PHONY: run build test clean

# ビルドして Noroshi.app を起動する
run: build
	open $(APP)

build:
	xcodebuild -project $(XCODEPROJ) -scheme $(SCHEME) -configuration $(CONFIGURATION) -derivedDataPath $(DERIVED_DATA) build

test:
	xcodebuild -project $(XCODEPROJ) -scheme $(SCHEME) -derivedDataPath $(DERIVED_DATA) test

clean:
	rm -rf $(DERIVED_DATA)
