# PicBox 的构建脚本。常用：make build、make app、make install

APP_NAME   := PicBox
EXECUTABLE := picbox
BUNDLE_ID  := local.picbox
VERSION    := $(shell cat VERSION)
MIN_MACOS  := 13.0

BUILD     := build
BIN       := $(BUILD)/$(EXECUTABLE)
ICNS      := $(BUILD)/AppIcon.icns
# 桌面在同步盘里，系统会给 .app 和 .iconset 加 FinderInfo，签不了名，所以在临时目录里组装
STAGE     := /tmp/picbox-build
ICONSET   := $(STAGE)/AppIcon.iconset
APP       := $(STAGE)/$(APP_NAME).app
INSTALLED := /Applications/$(APP_NAME).app

SRCS    := $(wildcard src/*.m)
HDRS    := $(wildcard src/*.h)
CFLAGS  := -fobjc-arc -O2 -arch arm64 -arch x86_64 -mmacosx-version-min=$(MIN_MACOS) \
           -Wall -Wextra -Werror -Wno-unused-parameter
LDFLAGS := -framework Cocoa -framework QuartzCore -framework ServiceManagement \
           -framework UniformTypeIdentifiers -framework ImageIO -framework Vision

.PHONY: build icon app install clean

build: $(BIN)

$(BIN): $(SRCS) $(HDRS)
	@mkdir -p $(BUILD)
	clang $(CFLAGS) -o $@ $(SRCS) $(LDFLAGS)

# 程序自己把图标画出来，再打成 icns
icon: $(ICNS)

$(ICNS): $(BIN)
	rm -rf $(ICONSET)
	$(BIN) --render-icon $(ICONSET)
	iconutil -c icns $(ICONSET) -o $@

app: $(BIN) $(ICNS)
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp $(BIN) "$(APP)/Contents/MacOS/$(EXECUTABLE)"
	cp $(ICNS) "$(APP)/Contents/Resources/AppIcon.icns"
	sed -e 's/@APP_NAME@/$(APP_NAME)/g' -e 's/@EXECUTABLE@/$(EXECUTABLE)/g' \
	    -e 's/@BUNDLE_ID@/$(BUNDLE_ID)/g' -e 's/@VERSION@/$(VERSION)/g' \
	    -e 's/@MIN_MACOS@/$(MIN_MACOS)/g' Resources/Info.plist.in > "$(APP)/Contents/Info.plist"
	/usr/bin/xattr -cr "$(APP)"
	codesign -s - --force --deep "$(APP)"

# 装到「应用程序」并重新打开，旧版本先退出
install: app
	-pkill -TERM -f "$(INSTALLED)/Contents/MacOS/$(EXECUTABLE)$$"
	@sleep 0.5
	rm -rf "$(INSTALLED)"
	cp -R "$(APP)" "$(INSTALLED)"
	@# 换了图标后访达、启动台会继续显示缓存里的旧图：更新时间、重新登记，让系统重读图标
	touch "$(INSTALLED)"
	/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$(INSTALLED)"
	open "$(INSTALLED)"

clean:
	rm -rf $(BUILD) $(STAGE)
