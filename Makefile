export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

# Release: exports and face tracking run noticeably faster optimized.
run: build
	-osascript -e 'tell application id "dev.alexis.Hyperclip" to quit' 2>/dev/null
	while lsappinfo find bundleid=dev.alexis.Hyperclip | grep -q ASN; do sleep 0.2; done
	open -n build/Build/Products/Release/Hyperclip.app

build:
	xcodegen generate -q
	xcodebuild -project Hyperclip.xcodeproj -scheme Hyperclip -configuration Release -derivedDataPath build -quiet build

.PHONY: run build
