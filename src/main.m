// PicBox：剪贴板里一出现图片（截图、浏览器里复制图片等），就存成文件放进 ~/Pictures/PicBox，
// 在屏幕右下角像扑克牌一样扇形展开。拖出来发到任何应用，单击放回剪贴板，Shift 多选一起拖，
// 可以钉在屏幕上、识别图里的文字。缩略图点 × 或拖走后消失，文件留在目录里，到期自动删
#import <Cocoa/Cocoa.h>
#import <ImageIO/ImageIO.h>
#import <QuartzCore/QuartzCore.h>
#import <ServiceManagement/ServiceManagement.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <Vision/Vision.h>
#import <dlfcn.h>
#import "AppIcon.h"
#import "Updater.h"

#define CARD_W 180   // 缩略图宽
#define CARD_HMIN 60 // 缩略图高的范围，太长太扁的图按这个裁
#define CARD_HMAX 200
#define MAX_CARDS 5 // 最多叠几张，再多把最旧的收掉
#define FAN_R 380   // 扇形的半径：各张围着下方这么远的一个圆心展开
#define FAN_STEP 7  // 相邻两张差的角度（度）
#define LIFT 16     // 鼠标停着的那张往外抽出这么多
#define PAD 12   // 面板四周给阴影留的空
#define BTN 26   // 打开目录按钮的直径
#define MARGIN 12
#define POLL 0.3 // 看剪贴板的间隔（秒）
#define DEFAULT_KEEP_DAYS 14
#define PIN_AREA 0.15   // 刚钉上时最多占屏幕可用面积的这个比例
#define PIN_SIDE 0.5    // 宽、高各自最多占屏幕可用区域的这个比例
#define CARD_BTN_TAG 77 // 牌角上 × 和图钉的标记，鼠标停在上面时悬停的那张不变

static NSString *saveDirPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Pictures/PicBox"];
}

// 1.0 叫「截图暂存」时的目录和设置域，第一次启动时搬过来
#define OLD_DIR @"Pictures/截图暂存"
#define OLD_DOMAIN @"local.shotshelf"

// 识别图里的文字（系统自带的文字识别，离线），中英文都认。在后台做，结果回主线程；没认出来给空串
static void recognizeText(NSImage *img, void (^done)(NSString *text)) {
    CGImageRef cg = [img CGImageForProposedRect:NULL context:nil hints:nil];
    if (!cg) {
        done(@"");
        return;
    }
    CGImageRetain(cg);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        VNRecognizeTextRequest *req = [VNRecognizeTextRequest new];
        req.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
        req.recognitionLanguages = @[ @"zh-Hans", @"zh-Hant", @"en-US" ];
        req.usesLanguageCorrection = YES;
        [[[VNImageRequestHandler alloc] initWithCGImage:cg options:@{}] performRequests:@[ req ] error:nil];
        CGImageRelease(cg);
        NSMutableArray *lines = [NSMutableArray array];
        for (VNRecognizedTextObservation *o in req.results) {
            NSString *t = [o topCandidates:1].firstObject.string;
            if (t.length) {
                [lines addObject:t];
            }
        }
        NSString *text = [lines componentsJoinedByString:@"\n"];
        dispatch_async(dispatch_get_main_queue(), ^{
            done(text);
        });
    });
}

// 在 view 中间弹一个小提示，一秒多后淡出
static void toast(NSView *view, NSString *msg) {
    NSTextField *t = [NSTextField labelWithString:msg];
    t.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    t.textColor = NSColor.whiteColor;
    t.alignment = NSTextAlignmentCenter;
    [t sizeToFit];
    NSSize s = t.frame.size;
    // 连着弹时先撤掉上一个，免得叠在一起
    for (NSView *old in [view.subviews copy]) {
        if ([old.identifier isEqualToString:@"toast"]) {
            [old removeFromSuperview];
        }
    }
    NSView *bg = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, s.width + 20, s.height + 10)];
    bg.identifier = @"toast";
    bg.wantsLayer = YES;
    bg.layer.backgroundColor = [NSColor colorWithWhite:0.1 alpha:0.8].CGColor;
    bg.layer.cornerRadius = (s.height + 10) / 2;
    t.frame = NSMakeRect(10, 5, s.width, s.height);
    [bg addSubview:t];
    [bg setFrameOrigin:NSMakePoint(round(NSMidX(view.bounds) - NSWidth(bg.frame) / 2),
                                   round(NSMidY(view.bounds) - NSHeight(bg.frame) / 2))];
    [view addSubview:bg positioned:NSWindowAbove relativeTo:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        [NSAnimationContext
            runAnimationGroup:^(NSAnimationContext *ctx) {
                ctx.duration = 0.3;
                bg.animator.alphaValue = 0;
            }
            completionHandler:^{
                [bg removeFromSuperview];
            }];
    });
}

// 牌上用的小图：按牌的大小（Retina 两倍）解码，不把整张原图放进内存。全屏截图原图解码后几十 MB，5 张就几百 MB
static NSImage *makeThumb(NSData *data) {
    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!src) {
        return nil;
    }
    NSDictionary *props = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(src, 0, NULL));
    double w = [props[(id)kCGImagePropertyPixelWidth] doubleValue], h = [props[(id)kCGImagePropertyPixelHeight] doubleValue];
    // 牌是 CARD_W 宽、高按比例夹在 CARD_HMIN–CARD_HMAX，图按铺满裁切：缩放比要让宽、高都铺满
    double ch = w > 0 ? MAX(CARD_HMIN, MIN(CARD_HMAX, CARD_W * h / w)) : CARD_HMIN;
    double f = w > 0 && h > 0 ? MIN(1, MAX(CARD_W * 2 / w, ch * 2 / h)) : 1;
    NSDictionary *opt = @{
        (id)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
        (id)kCGImageSourceCreateThumbnailWithTransform : @YES,
        (id)kCGImageSourceThumbnailMaxPixelSize : @(MAX(1, ceil(MAX(w, h) * f)))
    };
    CGImageRef cg = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)opt);
    CFRelease(src);
    if (!cg) {
        return nil;
    }
    NSImage *img = [[NSImage alloc] initWithCGImage:cg size:NSMakeSize(CGImageGetWidth(cg) / 2.0, CGImageGetHeight(cg) / 2.0)];
    CGImageRelease(cg);
    return img;
}

#pragma mark 缩略图

// 小圆图标按钮（×、图钉、识别文字），鼠标停上去才显示。白色符号叠在深色圆底上：
// 图浅时看圆底，图深时看白色符号
static NSButton *roundButton(NSString *symbol, NSString *desc, id target, SEL action) {
    NSButton *b = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:desc]
                                     target:target
                                     action:action];
    b.bordered = NO;
    NSImageSymbolConfiguration *size = [NSImageSymbolConfiguration configurationWithPointSize:16 weight:NSFontWeightSemibold];
    NSImageSymbolConfiguration *colors =
        [NSImageSymbolConfiguration configurationWithPaletteColors:@[ NSColor.whiteColor, [NSColor colorWithWhite:0.1 alpha:0.75] ]];
    b.symbolConfiguration = [size configurationByApplyingConfiguration:colors];
    b.wantsLayer = YES;
    // 不带圆底的符号（识别文字的取景框）自己补一个同色的深色圆底，符号缩小放在里面，和 ×、图钉看起来一组
    if (![symbol hasSuffix:@".circle.fill"]) {
        b.layer.backgroundColor = [NSColor colorWithWhite:0.1 alpha:0.75].CGColor;
        b.symbolConfiguration = [[NSImageSymbolConfiguration configurationWithPointSize:10 weight:NSFontWeightBold]
            configurationByApplyingConfiguration:[NSImageSymbolConfiguration configurationWithPaletteColors:@[ NSColor.whiteColor ]]];
    }
    b.layer.cornerRadius = 10;
    b.toolTip = desc;
    b.hidden = YES;
    return b;
}

@interface Card : NSView <NSDraggingSource>
@property(strong) NSURL *url;
@property(strong) NSImage *image; // 牌上的小图，原图要用时从 url 读
@property CGFloat angle;     // 扇形里的角度（度），正数是逆时针
@property NSPoint baseOrigin; // 没抽出时的位置，抽出、放回都相对它挪
@property NSPoint baseCenter; // 没抽出时的中心，摆 × 和图钉用
// 这张牌的 × 和图钉：摆正放在面板上，不跟牌一起转（转了角度的图标会发糊）。每张牌各有一组，动画只跟着自己的牌
@property(strong) NSButton *closeBtn, *pinBtn, *ocrBtn, *imageCopyBtn;
@property(readonly) NSArray<NSButton *> *buttons; // 上面四个，排版、显隐时一起处理
@property(nonatomic) BOOL selected; // Shift 点选中，选中的几张一起拖
@property(copy) void (^onClick)(Card *, BOOL shift);
// 拖这张牌时一起拖的几张（选中了就是所有选中的，否则只有它自己），和拖完放下后的处理
@property(copy) NSArray<Card *> * (^dragGroup)(Card *);
@property(copy) void (^onDropped)(NSArray<Card *> *);
@property(strong) NSArray<Card *> *dragging;
@property(strong) NSView *photo;
@property(copy) void (^onRemove)(Card *);
@property(copy) void (^onPin)(Card *);
@property(strong) NSEvent *downEvent;
@end

@implementation Card

- (NSArray<NSButton *> *)buttons {
    return @[ self.closeBtn, self.pinBtn, self.ocrBtn, self.imageCopyBtn ];
}

- (instancetype)initWithURL:(NSURL *)url image:(NSImage *)image {
    NSSize s = image.size;
    CGFloat h = s.width > 0 ? round(CARD_W * s.height / s.width) : CARD_HMIN;
    h = MAX(CARD_HMIN, MIN(CARD_HMAX, h));
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, CARD_W, h)])) {
        return nil;
    }
    self.url = url;
    self.image = image;
    // 外层只带一层浅阴影，图片放在里层裁圆角（裁圆角的层画不出阴影）
    self.wantsLayer = YES;
    self.layer.shadowColor = NSColor.blackColor.CGColor;
    self.layer.shadowOpacity = 0.16;
    self.layer.shadowRadius = 3;
    self.layer.shadowOffset = CGSizeMake(0, -1);
    // 给出阴影形状，不然每帧都要按图片内容算阴影，转着角度做动画时最费
    CGPathRef sp = CGPathCreateWithRoundedRect(self.bounds, 8, 8, NULL);
    self.layer.shadowPath = sp;
    CGPathRelease(sp);
    NSView *ph = [[NSView alloc] initWithFrame:self.bounds];
    ph.wantsLayer = YES;
    ph.layer.contents = image;
    ph.layer.contentsGravity = kCAGravityResizeAspectFill;
    ph.layer.cornerRadius = 8;
    ph.layer.masksToBounds = YES;
    ph.layer.borderWidth = 0.5;
    ph.layer.borderColor = [NSColor colorWithWhite:0.5 alpha:0.4].CGColor;
    ph.layer.backgroundColor = NSColor.windowBackgroundColor.CGColor;
    [self addSubview:ph];
    self.photo = ph;
    self.toolTip = @"拖出来发送或保存。单击复制文件路径，Shift 单击多选，双击打开";
    return self;
}

// 以 center 为中心、转 angle 度摆放。先转正再挪，免得转过的 frame 算错位置
- (void)placeAt:(NSPoint)center angle:(CGFloat)angle {
    self.frameCenterRotation = 0;
    NSSize s = self.bounds.size;
    NSPoint o = NSMakePoint(round(center.x - s.width / 2), round(center.y - s.height / 2));
    [self setFrameOrigin:o];
    self.baseCenter = NSMakePoint(o.x + s.width / 2, o.y + s.height / 2);
    self.frameCenterRotation = angle;
}

// 面板不抢焦点，第一下点击就要能拖
- (BOOL)acceptsFirstMouse:(NSEvent *)e {
    return YES;
}

// 选中时图片外框换成强调色粗边
- (void)setSelected:(BOOL)on {
    _selected = on;
    self.photo.layer.borderWidth = on ? 3 : 0.5;
    self.photo.layer.borderColor =
        on ? NSColor.controlAccentColor.CGColor : [NSColor colorWithWhite:0.5 alpha:0.4].CGColor;
}

- (void)mouseDown:(NSEvent *)e {
    self.downEvent = e;
}

// 没拖动就松手：双击打开，单击交给 onClick（放回剪贴板，按着 Shift 是多选）
- (void)mouseUp:(NSEvent *)e {
    if (!self.downEvent) {
        return;
    }
    self.downEvent = nil;
    if (e.clickCount == 2) {
        [[NSWorkspace sharedWorkspace] openURL:self.url];
    } else if (e.clickCount == 1 && self.onClick) {
        self.onClick(self, (e.modifierFlags & NSEventModifierFlagShift) != 0);
    }
}

- (void)mouseDragged:(NSEvent *)e {
    if (!self.downEvent) {
        return;
    }
    NSPoint a = self.downEvent.locationInWindow, b = e.locationInWindow;
    if (hypot(b.x - a.x, b.y - a.y) < 4) {
        return;
    }
    // 选中的几张一起拖：拖动时的预览按各张现在的位置摆
    self.dragging = self.dragGroup ? self.dragGroup(self) : @[ self ];
    NSMutableArray *items = [NSMutableArray array];
    for (Card *c in self.dragging) {
        NSDraggingItem *it = [[NSDraggingItem alloc] initWithPasteboardWriter:c.url];
        [it setDraggingFrame:[self convertRect:c.bounds fromView:c] contents:c.image];
        [items addObject:it];
    }
    [self beginDraggingSessionWithItems:items event:self.downEvent source:self];
    self.downEvent = nil;
}

// 只给复制：允许「通用」的话，拖到访达里同一块磁盘上，访达会把文件从截图目录挪走
- (NSDragOperation)draggingSession:(NSDraggingSession *)s sourceOperationMaskForDraggingContext:(NSDraggingContext)c {
    return NSDragOperationCopy;
}

// 拖到别处放下了才收起（一起拖的几张都收起）；拖回原处或中途取消，缩略图留着
- (void)draggingSession:(NSDraggingSession *)s endedAtPoint:(NSPoint)p operation:(NSDragOperation)op {
    NSArray *group = self.dragging ?: @[ self ];
    self.dragging = nil;
    if (op != NSDragOperationNone && self.onDropped) {
        self.onDropped(group);
    }
}

@end

#pragma mark 钉在屏幕上

// 钉住的图：拖图片移动窗口，拖边缘或角放大缩小（比例不变），鼠标停上去右上角出现 ×
@interface PinView : NSView
@property(strong) NSButton *closeBtn, *ocrBtn;
@end
@implementation PinView
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (!self.trackingAreas.count) {
        [self addTrackingArea:[[NSTrackingArea alloc]
                                  initWithRect:NSZeroRect
                                       options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                         owner:self
                                      userInfo:nil]];
    }
}
- (void)mouseEntered:(NSEvent *)e {
    self.closeBtn.hidden = self.ocrBtn.hidden = NO;
}
- (void)mouseExited:(NSEvent *)e {
    self.closeBtn.hidden = self.ocrBtn.hidden = YES;
}
- (BOOL)acceptsFirstMouse:(NSEvent *)e {
    return YES;
}
- (BOOL)mouseDownCanMoveWindow {
    return YES;
}
@end

// 不抢焦点：钉着的图点一下、拖一下，正在打字的窗口还是当前窗口
@interface PinWindow : NSPanel
@property(copy) void (^onClose)(PinWindow *);
@property(copy) void (^onOCR)(PinWindow *); // 点了识别文字
@property(strong) NSImage *image;
@end
@implementation PinWindow

// r 是钉好之后的位置和大小，比例和图片一致
- (instancetype)initWithImage:(NSImage *)img frame:(NSRect)r {
    NSSize s = r.size;
    self = [super initWithContentRect:r
                            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable |
                                      NSWindowStyleMaskFullSizeContentView | NSWindowStyleMaskNonactivatingPanel
                              backing:NSBackingStoreBuffered
                                defer:NO];
    if (!self) {
        return nil;
    }
    self.titlebarAppearsTransparent = YES;
    self.titleVisibility = NSWindowTitleHidden;
    for (NSNumber *b in @[ @(NSWindowCloseButton), @(NSWindowMiniaturizeButton), @(NSWindowZoomButton) ]) {
        [self standardWindowButton:b.integerValue].hidden = YES;
    }
    self.level = NSFloatingWindowLevel;
    self.hidesOnDeactivate = NO;
    self.movableByWindowBackground = YES;
    self.releasedWhenClosed = NO;
    self.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    self.contentAspectRatio = s;
    // 拖着缩放不设上限；下限让短边至少 60，太小了点不到 ×
    CGFloat mf = 60 / MIN(s.width, s.height);
    self.contentMinSize = NSMakeSize(round(s.width * MAX(mf, 0.1)), round(s.height * MAX(mf, 0.1)));

    PinView *v = [[PinView alloc] initWithFrame:NSMakeRect(0, 0, s.width, s.height)];
    v.wantsLayer = YES;
    v.layer.contents = img;
    v.layer.contentsGravity = kCAGravityResizeAspect;
    v.layer.backgroundColor = NSColor.windowBackgroundColor.CGColor;
    v.closeBtn = roundButton(@"xmark.circle.fill", @"取消钉住", self, @selector(unpin:));
    v.closeBtn.frame = NSMakeRect(s.width - 26, s.height - 26, 20, 20);
    v.closeBtn.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    [v addSubview:v.closeBtn];
    // 右下角识别文字，和牌上的位置一致
    v.ocrBtn = roundButton(@"text.viewfinder", @"识别文字", self, @selector(ocr:));
    v.ocrBtn.frame = NSMakeRect(s.width - 26, 6, 20, 20);
    v.ocrBtn.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [v addSubview:v.ocrBtn];
    self.contentView = v;
    self.image = img;
    return self;
}

- (void)ocr:(id)sender {
    if (self.onOCR) {
        self.onOCR(self);
    }
}

- (void)unpin:(id)sender {
    [self orderOut:nil];
    if (self.onClose) {
        self.onClose(self);
    }
}

@end

#pragma mark 识别出的文字

// 显示识别出的文字：可以选中一部分 ⌘C 复制，也可以点「全部复制」。
// 本程序没有菜单栏里的「编辑」菜单，⌘C、⌘A、⌘W 在这里自己处理；Esc 关闭
@interface TextPanel : NSPanel
@property(strong) NSTextView *tv;
@property BOOL hasText; // 识别完且认出了文字
@property NSRect anchor;  // 图片在屏幕上的位置，调高度时贴着它
@property(copy) void (^onCopy)(NSString *text);
@property(copy) void (^onClose)(TextPanel *);
@end
@implementation TextPanel

#define TP_W 380
#define TP_BAR 44  // 底部放「全部复制」的那一条
#define TP_MIN 120 // 内容区最矮
// anchor 是图片在屏幕上的位置，文字窗口放在它上方，放不下就放下方，再拉回屏幕里。高度先按「正在识别…」，认出来再按文字调
- (instancetype)initNear:(NSRect)anchor {
    const CGFloat W = TP_W, H = TP_MIN, BAR = TP_BAR;
    self = [super initWithContentRect:NSMakeRect(0, 0, W, H)
                            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable |
                                      NSWindowStyleMaskUtilityWindow | NSWindowStyleMaskNonactivatingPanel
                              backing:NSBackingStoreBuffered
                                defer:NO];
    if (!self) {
        return nil;
    }
    self.title = @"识别的文字";
    self.level = NSFloatingWindowLevel;
    self.hidesOnDeactivate = NO;
    self.releasedWhenClosed = NO;
    self.becomesKeyOnlyIfNeeded = NO;
    self.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    self.contentMinSize = NSMakeSize(240, TP_MIN);
    self.anchor = anchor;
    NSView *cv = self.contentView;

    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, BAR, W, H - BAR)];
    sv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    sv.hasVerticalScroller = YES;
    sv.drawsBackground = NO;
    NSTextView *tv = [[NSTextView alloc] initWithFrame:sv.contentView.bounds];
    tv.editable = NO;
    tv.selectable = YES;
    tv.richText = NO;
    tv.drawsBackground = NO;
    tv.font = [NSFont systemFontOfSize:13];
    tv.textColor = NSColor.secondaryLabelColor;
    tv.textContainerInset = NSMakeSize(10, 10);
    tv.verticallyResizable = YES;
    tv.autoresizingMask = NSViewWidthSizable;
    tv.textContainer.widthTracksTextView = YES;
    tv.string = @"正在识别…";
    sv.documentView = tv;
    [cv addSubview:sv];
    self.tv = tv;

    NSBox *line = [[NSBox alloc] initWithFrame:NSMakeRect(0, BAR - 1, W, 1)];
    line.boxType = NSBoxSeparator;
    line.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [cv addSubview:line];
    NSButton *copy = [NSButton buttonWithTitle:@"全部复制" target:self action:@selector(copyAll:)];
    copy.bezelStyle = NSBezelStylePush;
    [copy sizeToFit];
    [copy setFrameOrigin:NSMakePoint(W - 12 - copy.frame.size.width, round((BAR - copy.frame.size.height) / 2))];
    copy.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [cv addSubview:copy];

    [self setFrame:[self frameForHeight:H] display:NO];
    return self;
}

// 内容区高 h 时窗口该在哪：放在图片上方、往上长；上方放不下就放下方、往下长；最后拉回屏幕里
- (NSRect)frameForHeight:(CGFloat)h {
    NSRect a = self.anchor;
    NSScreen *scr = NSScreen.screens.firstObject;
    for (NSScreen *x in NSScreen.screens) {
        if (NSIntersectsRect(x.frame, a)) {
            scr = x;
            break;
        }
    }
    NSRect vis = scr.visibleFrame;
    NSSize sz = [self frameRectForContentRect:NSMakeRect(0, 0, self.contentView.frame.size.width ?: TP_W, h)].size;
    CGFloat x = NSMidX(a) - sz.width / 2, y = NSMaxY(a) + 10;
    if (y + sz.height > NSMaxY(vis)) {
        y = NSMinY(a) - 10 - sz.height;
    }
    x = MAX(NSMinX(vis), MIN(NSMaxX(vis) - sz.width, x));
    y = MAX(NSMinY(vis), MIN(NSMaxY(vis) - sz.height, y));
    return NSMakeRect(round(x), round(y), sz.width, sz.height);
}

// 按文字的实际高度调窗口：最矮 TP_MIN，最高屏幕可用高度的六成，再多就滚动
- (void)fitHeight {
    NSLayoutManager *lm = self.tv.layoutManager;
    [lm ensureLayoutForTextContainer:self.tv.textContainer];
    CGFloat th = ceil([lm usedRectForTextContainer:self.tv.textContainer].size.height) + self.tv.textContainerInset.height * 2;
    NSScreen *scr = self.screen ?: NSScreen.screens.firstObject;
    CGFloat h = MAX(TP_MIN, MIN(scr.visibleFrame.size.height * 0.6, th + TP_BAR));
    [self setFrame:[self frameForHeight:h] display:YES animate:YES];
}

- (BOOL)canBecomeKeyWindow {
    return YES;
}

- (void)showText:(NSString *)text {
    self.hasText = text.length > 0;
    self.tv.textColor = text.length ? NSColor.labelColor : NSColor.secondaryLabelColor;
    self.tv.string = text.length ? text : @"没有识别到文字";
    [self fitHeight];
}

- (void)copyAll:(id)sender {
    if (self.onCopy && self.hasText) {
        self.onCopy(self.tv.string);
        toast(self.contentView, @"已复制");
    }
}

- (BOOL)performKeyEquivalent:(NSEvent *)e {
    if ((e.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask) == NSEventModifierFlagCommand) {
        NSString *k = e.charactersIgnoringModifiers.lowercaseString;
        if ([k isEqualToString:@"c"]) {
            // 选了一部分就复制选中的，没选就整段复制
            if (self.tv.selectedRange.length) {
                [self.tv copy:nil];
                toast(self.contentView, @"已复制选中的文字");
            } else {
                [self copyAll:nil];
            }
            return YES;
        }
        if ([k isEqualToString:@"a"]) {
            [self.tv selectAll:nil];
            return YES;
        }
        if ([k isEqualToString:@"w"]) {
            [self close];
            return YES;
        }
    }
    return [super performKeyEquivalent:e];
}

- (void)cancelOperation:(id)sender {
    [self close];
}

- (void)close {
    [super close];
    if (self.onClose) {
        self.onClose(self);
    }
}

@end

#pragma mark 面板

// 打开目录的小圆按钮，兼作暂存区的把手：点一下打开目录，按住拖动整个暂存区，松手后回调 onMoved 记住位置
@interface DirButton : NSView
@property(copy) void (^onClick)(void);
@property(copy) void (^onMoved)(void);
@end
@implementation DirButton {
    NSPoint _down, _origin;
    BOOL _dragged;
}
- (instancetype)initWithFrame:(NSRect)r {
    if (!(self = [super initWithFrame:r])) {
        return nil;
    }
    NSVisualEffectView *v = [[NSVisualEffectView alloc] initWithFrame:self.bounds];
    v.material = NSVisualEffectMaterialHUDWindow;
    v.state = NSVisualEffectStateActive;
    v.wantsLayer = YES;
    v.layer.cornerRadius = r.size.width / 2;
    v.layer.masksToBounds = YES;
    [self addSubview:v];
    NSImageView *iv = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:@"folder"
                                                                accessibilityDescription:@"打开截图目录"]];
    iv.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:12 weight:NSFontWeightMedium];
    iv.frame = self.bounds;
    [self addSubview:iv];
    self.toolTip = @"点一下打开截图目录，按住拖动移动暂存区";
    return self;
}
- (NSView *)hitTest:(NSPoint)p {
    return NSPointInRect([self convertPoint:p fromView:self.superview], self.bounds) ? self : nil;
}
- (BOOL)acceptsFirstMouse:(NSEvent *)e {
    return YES;
}
- (BOOL)mouseDownCanMoveWindow {
    return NO;
}
// 暂存区不抢焦点，系统不给非焦点窗口换光标（cursorRect 不生效），自己在进出时换
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (!self.trackingAreas.count) {
        [self addTrackingArea:[[NSTrackingArea alloc]
                                  initWithRect:NSZeroRect
                                       options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                         owner:self
                                      userInfo:nil]];
    }
}
- (void)mouseEntered:(NSEvent *)e {
    [NSCursor.openHandCursor set];
}
- (void)mouseExited:(NSEvent *)e {
    if (!_dragged) {
        [NSCursor.arrowCursor set];
    }
}
- (void)mouseDown:(NSEvent *)e {
    _down = NSEvent.mouseLocation;
    _origin = self.window.frame.origin;
    _dragged = NO;
}
- (void)mouseDragged:(NSEvent *)e {
    NSPoint p = NSEvent.mouseLocation;
    if (!_dragged && hypot(p.x - _down.x, p.y - _down.y) < 3) {
        return;
    }
    _dragged = YES;
    [NSCursor.closedHandCursor set];
    [self.window setFrameOrigin:NSMakePoint(round(_origin.x + p.x - _down.x), round(_origin.y + p.y - _down.y))];
}
- (void)mouseUp:(NSEvent *)e {
    if (_dragged) {
        _dragged = NO;
        [NSCursor.openHandCursor set];
        if (self.onMoved) {
            self.onMoved();
        }
    } else if (self.onClick) {
        self.onClick();
    }
}
@end

// 不抢焦点的浮动面板：截图时正在打字的窗口不受影响
@interface Shelf : NSPanel
@end
@implementation Shelf
- (BOOL)canBecomeKeyWindow {
    return NO;
}
@end

// 面板内容：看鼠标落在哪张缩略图上。几张叠在一起，各自的跟踪区域分不出谁在上面，所以统一在这里按点击测试找
@interface ShelfView : NSView
@property(copy) void (^onHover)(Card *card);
@end
@implementation ShelfView
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (!self.trackingAreas.count) {
        [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                           options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited |
                                                                   NSTrackingActiveAlways | NSTrackingInVisibleRect
                                                             owner:self
                                                          userInfo:nil]];
    }
}
- (void)mouseMoved:(NSEvent *)e {
    NSView *v = [self hitTest:[self.superview convertPoint:e.locationInWindow fromView:nil]];
    if ([v isKindOfClass:NSButton.class] && ((NSButton *)v).tag == CARD_BTN_TAG) {
        return;
    }
    while (v && ![v isKindOfClass:Card.class]) {
        v = v.superview;
    }
    if (self.onHover) {
        self.onHover((Card *)v);
    }
}
- (void)mouseExited:(NSEvent *)e {
    if (self.onHover) {
        self.onHover(nil);
    }
}
@end

@interface AppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property(strong) NSStatusItem *statusItem;
@property(strong) Shelf *panel;
@property(strong) NSMutableArray<Card *> *cards; // 0 是最新的，排在最下面
@property(strong) NSMutableArray<PinWindow *> *pins;
@property(strong) NSMutableArray<TextPanel *> *textPanels;
@property(strong) NSMenuItem *loginItem;
@property(strong) NSMenu *keepMenu;
@property(strong) DirButton *dirBtn;
@property(weak) Card *hovered; // 鼠标停着的那张，转正放到最上面
@end

@implementation AppDelegate {
    NSInteger _lastChange;
    NSData *_lastRaw; // 上一次存的剪贴板原始数据，几秒内又来一样的就不再存
    CFAbsoluteTime _lastRawAt;
}

// 本程序一直在后台（暂存区不抢焦点），后台程序设的光标会被前台程序盖掉，拖文件夹按钮时手形出不来。
// 系统有个私有开关允许后台程序改光标，很多菜单栏工具都在用。按名字在运行时找，找不到就算了
static void allowCursorInBackground(void) {
    int (*conn)(void) = (int (*)(void))dlsym(RTLD_DEFAULT, "_CGSDefaultConnection");
    void (*setProp)(int, int, CFStringRef, CFTypeRef) =
        (void (*)(int, int, CFStringRef, CFTypeRef))dlsym(RTLD_DEFAULT, "CGSSetConnectionProperty");
    if (conn && setProp) {
        int c = conn();
        setProp(c, c, CFSTR("SetsCursorInBackground"), kCFBooleanTrue);
    }
}

// 1.0 叫「截图暂存」：设置在 local.shotshelf 域、截图在 ~/Pictures/截图暂存。第一次启动时搬过来，只搬一次
static void migrateFromOldName(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    if ([ud boolForKey:@"migrated"]) {
        return;
    }
    NSDictionary *old = [ud persistentDomainForName:OLD_DOMAIN];
    for (NSString *k in @[ @"keepDays", @"shelfRight", @"shelfBottom", @"shelfScreen" ]) {
        if (old[k] && ![ud objectForKey:k]) {
            [ud setObject:old[k] forKey:k];
        }
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *from = [NSHomeDirectory() stringByAppendingPathComponent:OLD_DIR], *to = saveDirPath();
    BOOL isDir = NO;
    if ([fm fileExistsAtPath:from isDirectory:&isDir] && isDir) {
        if (![fm fileExistsAtPath:to]) {
            [fm moveItemAtPath:from toPath:to error:nil];
        } else {
            for (NSString *f in [fm contentsOfDirectoryAtPath:from error:nil]) {
                NSString *dst = [to stringByAppendingPathComponent:f];
                if (![fm fileExistsAtPath:dst]) {
                    [fm moveItemAtPath:[from stringByAppendingPathComponent:f] toPath:dst error:nil];
                }
            }
            if (![fm contentsOfDirectoryAtPath:from error:nil].count) {
                [fm removeItemAtPath:from error:nil];
            }
        }
    }
    [ud setBool:YES forKey:@"migrated"];
}

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    // 开发用的 --demo 只画图：不搬旧目录、不清理截图、不看剪贴板，免得按开发版自己的设置动到真实的截图目录
    NSArray *args = NSProcessInfo.processInfo.arguments;
    NSUInteger di = [args indexOfObject:@"--demo"];
    BOOL demo = di != NSNotFound && args.count >= di + 3;
    if (!demo) {
        migrateFromOldName();
    }
    allowCursorInBackground();
    self.cards = [NSMutableArray array];
    self.pins = [NSMutableArray array];
    self.textPanels = [NSMutableArray array];
    [[NSFileManager defaultManager] createDirectoryAtPath:saveDirPath()
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSSquareStatusItemLength];
    self.statusItem.button.image = statusIcon();
    self.statusItem.button.toolTip = @"PicBox";
    NSMenu *m = [NSMenu new];
    m.delegate = self;
    [m addItemWithTitle:@"打开截图目录" action:@selector(openDir:) keyEquivalent:@""].target = self;
    [m addItemWithTitle:@"收起全部缩略图" action:@selector(clearAll:) keyEquivalent:@""].target = self;
    NSMenuItem *keep = [m addItemWithTitle:@"自动清理" action:nil keyEquivalent:@""];
    self.keepMenu = [NSMenu new];
    for (NSNumber *d in @[ @1, @3, @7, @14, @30, @0 ]) {
        NSString *t = d.intValue ? [NSString stringWithFormat:@"保留 %@ 天", d] : @"不清理";
        NSMenuItem *it = [self.keepMenu addItemWithTitle:t action:@selector(pickKeep:) keyEquivalent:@""];
        it.target = self;
        it.tag = d.intValue;
    }
    keep.submenu = self.keepMenu;
    [m addItem:[NSMenuItem separatorItem]];
    self.loginItem = [m addItemWithTitle:@"登录时自动打开" action:@selector(toggleLogin:) keyEquivalent:@""];
    self.loginItem.target = self;
    NSString *ver = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"";
    [m addItemWithTitle:[NSString stringWithFormat:@"检查更新…（当前 %@）", ver] action:@selector(checkUpdate:) keyEquivalent:@""].target = self;
    [m addItem:[NSMenuItem separatorItem]];
    [m addItemWithTitle:@"退出" action:@selector(terminate:) keyEquivalent:@"q"];
    self.statusItem.menu = m;

    Shelf *p = [[Shelf alloc] initWithContentRect:NSMakeRect(0, 0, CARD_W, CARD_HMIN)
                                        styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                          backing:NSBackingStoreBuffered
                                            defer:YES];
    p.level = NSFloatingWindowLevel;
    p.opaque = NO;
    p.backgroundColor = NSColor.clearColor;
    p.hasShadow = NO; // 阴影由每张缩略图自己画，窗口阴影太重
    p.hidesOnDeactivate = NO;
    p.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary |
                           NSWindowCollectionBehaviorStationary;
    p.acceptsMouseMovedEvents = YES;
    ShelfView *sv = [[ShelfView alloc] initWithFrame:p.contentLayoutRect];
    sv.wantsLayer = YES;
    __weak AppDelegate *me = self;
    sv.onHover = ^(Card *c) {
        [me hover:c];
    };
    p.contentView = sv;
    self.panel = p;
    self.dirBtn = [self makeDirButton];
    [p.contentView addSubview:self.dirBtn];

    if (demo) {
        // --demo <输出 PNG> <悬停第几张，-1 不悬停> <图片...>
        [self demo:[args subarrayWithRange:NSMakeRange(di + 3, args.count - di - 3)]
                out:args[di + 1]
              hover:[args[di + 2] intValue]];
        return;
    }

    // 启动时清一次，之后每小时一次
    [self cleanup];
    NSTimer *ct = [NSTimer timerWithTimeInterval:3600 target:self selector:@selector(cleanup) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:ct forMode:NSRunLoopCommonModes];

    [[Updater shared] startWithRepo:@"cyanext/PicBox"];

    // 打开前剪贴板里已有的图片不算
    _lastChange = NSPasteboard.generalPasteboard.changeCount;
    NSTimer *t = [NSTimer timerWithTimeInterval:POLL target:self selector:@selector(poll:) userInfo:nil repeats:YES];
    t.tolerance = 0.1;
    [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
}

// 打开目录的小圆按钮，放在暂存区右下角，兼作拖动暂存区的把手
- (DirButton *)makeDirButton {
    DirButton *b = [[DirButton alloc] initWithFrame:NSMakeRect(0, 0, BTN, BTN)];
    __weak AppDelegate *me = self;
    b.onClick = ^{
        [me openDir:nil];
    };
    b.onMoved = ^{
        [me saveAnchor];
    };
    return b;
}

// 暂存区在哪块屏：记住拖过去的那块，拔掉了就用主屏。不跟着焦点换屏
- (NSScreen *)shelfScreen {
    NSNumber *want = [[NSUserDefaults standardUserDefaults] objectForKey:@"shelfScreen"];
    for (NSScreen *s in NSScreen.screens) {
        if (want && [s.deviceDescription[@"NSScreenNumber"] isEqual:want]) {
            return s;
        }
    }
    return NSScreen.screens.firstObject ?: NSScreen.mainScreen;
}

// 暂存区的位置记成右下角到屏幕可用区域右边、下边的距离：牌多牌少面板大小会变，右下角不动
- (NSRect)shelfFrameWithSize:(NSSize)sz {
    NSRect vis = self.shelfScreen.visibleFrame;
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    CGFloat dx = [ud objectForKey:@"shelfRight"] ? [ud doubleForKey:@"shelfRight"] : MARGIN;
    CGFloat dy = [ud objectForKey:@"shelfBottom"] ? [ud doubleForKey:@"shelfBottom"] : MARGIN;
    // 不让它跑出屏幕：换了分辨率、换了屏幕也拉得回来
    // 取整：落在半个像素上，按钮和图会发虚
    CGFloat x = round(MAX(NSMinX(vis), MIN(NSMaxX(vis) - dx - sz.width, NSMaxX(vis) - sz.width)));
    CGFloat y = round(MAX(NSMinY(vis), MIN(NSMinY(vis) + dy, NSMaxY(vis) - sz.height)));
    return NSMakeRect(x, y, sz.width, sz.height);
}

- (void)saveAnchor {
    NSScreen *scr = self.panel.screen ?: self.shelfScreen;
    NSRect vis = scr.visibleFrame, f = self.panel.frame;
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setObject:scr.deviceDescription[@"NSScreenNumber"] forKey:@"shelfScreen"];
    [ud setDouble:MAX(0, NSMaxX(vis) - NSMaxX(f)) forKey:@"shelfRight"];
    [ud setDouble:MAX(0, NSMinY(f) - NSMinY(vis)) forKey:@"shelfBottom"];
    [self.panel setFrame:[self shelfFrameWithSize:f.size] display:YES];
}

- (int)keepDays {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    return [ud objectForKey:@"keepDays"] ? (int)[ud integerForKey:@"keepDays"] : DEFAULT_KEEP_DAYS;
}

- (void)pickKeep:(NSMenuItem *)it {
    [[NSUserDefaults standardUserDefaults] setInteger:it.tag forKey:@"keepDays"];
    [self cleanup];
}

// 删掉目录里超过保留天数的截图。只动本程序存的「截图 」开头的文件，目录里别的东西不碰
- (void)cleanup {
    int days = [self keepDays];
    if (days <= 0) {
        return;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:-days * 86400.0];
    NSURL *dir = [NSURL fileURLWithPath:saveDirPath()];
    NSArray *files = [fm contentsOfDirectoryAtURL:dir
                       includingPropertiesForKeys:@[ NSURLCreationDateKey, NSURLIsRegularFileKey ]
                                          options:NSDirectoryEnumerationSkipsHiddenFiles
                                            error:nil];
    for (NSURL *u in files) {
        NSDate *d = nil;
        NSNumber *reg = nil;
        [u getResourceValue:&d forKey:NSURLCreationDateKey error:nil];
        [u getResourceValue:&reg forKey:NSURLIsRegularFileKey error:nil];
        if (reg.boolValue && [u.lastPathComponent hasPrefix:@"截图 "] && d && [d compare:limit] == NSOrderedAscending) {
            [fm removeItemAtURL:u error:nil];
        }
    }
    // 文件已经删掉的缩略图一并收起
    BOOL changed = NO;
    for (Card *c in [self.cards copy]) {
        if (![fm fileExistsAtPath:c.url.path]) {
            [self dropCard:c];
            changed = YES;
        }
    }
    if (changed) {
        [self layout];
    }
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    int days = [self keepDays];
    for (NSMenuItem *it in self.keepMenu.itemArray) {
        it.state = it.tag == days ? NSControlStateValueOn : NSControlStateValueOff;
    }
    self.loginItem.state = SMAppService.mainAppService.status == SMAppServiceStatusEnabled ? NSControlStateValueOn
                                                                                             : NSControlStateValueOff;
}

- (void)checkUpdate:(id)s {
    [[Updater shared] checkNow];
}

- (void)openDir:(id)s {
    [[NSFileManager defaultManager] createDirectoryAtPath:saveDirPath()
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:saveDirPath()]];
}

- (void)clearAll:(id)s {
    for (Card *c in [self.cards copy]) {
        [self dropCard:c];
    }
    [self layout];
}

- (void)toggleLogin:(id)s {
    SMAppService *svc = SMAppService.mainAppService;
    NSError *err = nil;
    BOOL ok = svc.status == SMAppServiceStatusEnabled ? [svc unregisterAndReturnError:&err]
                                                       : [svc registerAndReturnError:&err];
    if (!ok) {
        NSAlert *a = [NSAlert new];
        a.messageText = @"设置失败";
        a.informativeText = err.localizedDescription ?: @"请把程序放到「应用程序」文件夹后再试。";
        [NSApp activateIgnoringOtherApps:YES];
        [a runModal];
    }
}

#pragma mark 剪贴板

static BOOL isImageFile(NSURL *u) {
    UTType *t = [UTType typeWithFilenameExtension:u.pathExtension];
    return t && [t conformsToType:UTTypeImage];
}

// 剪贴板有变化且是图片就存一份：
// 1. 带文件链接的：指向图片就存（企业微信、微信复制图片时会带上它自己目录里的图片文件），指向别的文件跳过。
//    访达里复制的读原文件；其他应用直接用剪贴板里的图片数据，不去读别的应用目录里的文件，免得系统弹权限提示。
//    截图目录里的文件不再存，免得从这里复制一张又多一张
// 2. 不带文件链接、但带文字的跳过：Excel、Word 复制表格或文字时会附带一张预览图
// 3. 密码管理器等标了「隐藏」「临时」的内容跳过
// 4. 几秒内剪贴板又写进一模一样的图（有的应用会连写两次），不重复存
// 读剪贴板在主线程；转格式、写文件、做小图放到后台，大图也不卡界面
- (void)poll:(NSTimer *)t {
    NSPasteboard *pb = NSPasteboard.generalPasteboard;
    if (pb.changeCount == _lastChange) {
        return;
    }
    _lastChange = pb.changeCount;
    NSArray *types = pb.types;
    if ([types containsObject:@"org.nspasteboard.ConcealedType"] || [types containsObject:@"org.nspasteboard.TransientType"]) {
        return;
    }
    NSArray<NSURL *> *files = [pb readObjectsForClasses:@[ NSURL.class ]
                                                options:@{NSPasteboardURLReadingFileURLsOnlyKey : @YES}];
    if (files.count) {
        NSString *mine = [saveDirPath() stringByAppendingString:@"/"];
        NSMutableArray *images = [NSMutableArray array];
        for (NSURL *u in files) {
            if (isImageFile(u) && ![u.path hasPrefix:mine]) {
                [images addObject:u];
            }
        }
        if (!images.count) {
            return;
        }
        if ([NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier isEqualToString:@"com.apple.finder"]) {
            for (NSURL *u in images) {
                [self store:nil file:u];
            }
            return;
        }
    } else if ([types containsObject:NSPasteboardTypeString]) {
        return;
    }
    NSString *type = nil;
    for (NSString *ty in @[ NSPasteboardTypePNG, NSPasteboardTypeTIFF, @"public.jpeg" ]) {
        if ([types containsObject:ty]) {
            type = ty;
            break;
        }
    }
    NSData *raw = type ? [pb dataForType:type] : nil;
    if (!raw.length) {
        return;
    }
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - _lastRawAt < 5 && [raw isEqualToData:_lastRaw]) {
        return;
    }
    _lastRaw = raw;
    _lastRawAt = now;
    [self store:@[ raw, type ] file:nil];
}

// 后台存一张：raw 是 @[剪贴板数据, 类型]，或者 file 是访达里复制的图片文件。存好、做好小图后回主线程加一张牌
- (void)store:(NSArray *)raw file:(NSURL *)file {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSData *data;
        NSString *ext;
        if (file) {
            data = [NSData dataWithContentsOfURL:file];
            ext = file.pathExtension.lowercaseString;
        } else if ([raw[1] isEqualToString:NSPasteboardTypeTIFF]) {
            NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:raw[0]];
            data = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
            ext = @"png";
        } else {
            data = raw[0];
            ext = [raw[1] isEqualToString:NSPasteboardTypePNG] ? @"png" : @"jpg";
        }
        NSImage *thumb = data ? makeThumb(data) : nil;
        NSURL *url = thumb ? [self save:data ext:ext] : nil;
        if (!url) {
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self addCard:url image:thumb];
        });
    });
}

// 在后台线程调用：文件名带秒，同一秒有重名就加序号
- (NSURL *)save:(NSData *)data ext:(NSString *)ext {
    static NSDateFormatter *f;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        f = [NSDateFormatter new];
        f.dateFormat = @"yyyy-MM-dd HH.mm.ss";
    });
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:saveDirPath() withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *base;
    @synchronized(f) {
        base = [NSString stringWithFormat:@"截图 %@", [f stringFromDate:[NSDate date]]];
    }
    @synchronized(self) {
        NSString *path = [saveDirPath() stringByAppendingPathComponent:[base stringByAppendingPathExtension:ext]];
        for (int i = 2; [fm fileExistsAtPath:path]; i++) {
            NSString *name = [NSString stringWithFormat:@"%@ %d", base, i];
            path = [saveDirPath() stringByAppendingPathComponent:[name stringByAppendingPathExtension:ext]];
        }
        return [data writeToFile:path atomically:YES] ? [NSURL fileURLWithPath:path] : nil;
    }
}

#pragma mark 排版

- (void)addCard:(NSURL *)url image:(NSImage *)img {
    Card *c = [[Card alloc] initWithURL:url image:img];
    __weak AppDelegate *me = self;
    c.onRemove = ^(Card *x) {
        [me dropCard:x];
        [me layout];
    };
    c.onPin = ^(Card *x) {
        [me pin:x];
    };
    c.closeBtn = roundButton(@"xmark.circle.fill", @"收起", self, @selector(cardButton:));
    c.pinBtn = roundButton(@"pin.circle.fill", @"钉在屏幕上", self, @selector(cardButton:));
    c.ocrBtn = roundButton(@"text.viewfinder", @"识别文字", self, @selector(cardButton:));
    c.imageCopyBtn = roundButton(@"doc.on.doc", @"复制图片", self, @selector(cardButton:));
    c.onClick = ^(Card *x, BOOL shift) {
        [me clickCard:x shift:shift];
    };
    c.dragGroup = ^NSArray<Card *> *(Card *x) {
        return x.selected ? [me selectedCards] : @[ x ];
    };
    c.onDropped = ^(NSArray<Card *> *group) {
        for (Card *x in group) {
            [me dropCard:x];
        }
        [me layout];
    };
    for (NSButton *b in c.buttons) {
        b.tag = CARD_BTN_TAG;
        b.frame = NSMakeRect(0, 0, 20, 20);
        b.alphaValue = 0;
        [self.panel.contentView addSubview:b];
    }
    [self.cards insertObject:c atIndex:0];
    while (self.cards.count > MAX_CARDS) {
        [self dropCard:self.cards.lastObject];
    }
    [self.panel.contentView addSubview:c];
    [self layout];
}

// 拿掉一张牌，连同它角上的按钮
- (void)dropCard:(Card *)c {
    if (self.hovered == c) {
        self.hovered = nil;
    }
    [c removeFromSuperview];
    for (NSButton *b in c.buttons) {
        [b removeFromSuperview];
    }
    [self.cards removeObject:c];
}

// 牌角上的 ×、图钉、识别文字
- (void)cardButton:(NSButton *)b {
    for (Card *c in [self.cards copy]) {
        if (b == c.closeBtn && c.onRemove) {
            c.onRemove(c);
        } else if (b == c.pinBtn) {
            [self pin:c];
        } else if (b == c.ocrBtn) {
            [self ocrCard:c];
        } else if (b == c.imageCopyBtn) {
            [self copyImageOf:c];
        }
    }
}

// 选中的牌，按牌堆里的顺序
- (NSArray<Card *> *)selectedCards {
    return [self.cards filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"selected == YES"]];
}

// 单击：按着 Shift 是选中、取消选中；不按就清掉多选，复制这张截图的文件路径。
// 终端里 ⌘V 只能贴文字、贴不了图，贴路径 agent 就能读到图。
// 空格等特殊字符前加反斜杠，和把文件拖进终端时一样，贴进去就是一个完整的路径
- (void)clickCard:(Card *)c shift:(BOOL)shift {
    if (shift) {
        c.selected = !c.selected;
        return;
    }
    for (Card *x in self.cards) {
        x.selected = NO;
    }
    NSMutableString *path = [NSMutableString string];
    NSCharacterSet *special = [NSCharacterSet characterSetWithCharactersInString:@" \t'\"\\()[]{}&;|<>*?$`!#~"];
    NSString *raw = c.url.path;
    for (NSUInteger i = 0; i < raw.length; i++) {
        unichar ch = [raw characterAtIndex:i];
        if ([special characterIsMember:ch]) {
            [path appendString:@"\\"];
        }
        [path appendFormat:@"%C", ch];
    }
    [self writeToPasteboard:path];
    toast(c, @"已复制路径");
}

// 牌角上的复制按钮：把图片本身放进剪贴板，聊天软件、文档里 ⌘V，Claude Code 里 Ctrl+V
- (void)copyImageOf:(Card *)c {
    for (Card *x in self.cards) {
        x.selected = NO;
    }
    NSData *data = [NSData dataWithContentsOfURL:c.url];
    NSImage *img = data ? [[NSImage alloc] initWithData:data] : nil;
    if (!img) {
        return;
    }
    // 同时给 PNG 和 TIFF：有的应用只认其中一种
    NSPasteboardItem *it = [NSPasteboardItem new];
    BOOL png = [c.url.pathExtension.lowercaseString isEqualToString:@"png"];
    NSData *pngData = png ? data
                          : [[NSBitmapImageRep imageRepWithData:img.TIFFRepresentation] representationUsingType:NSBitmapImageFileTypePNG
                                                                                                    properties:@{}];
    [it setData:pngData forType:NSPasteboardTypePNG];
    [it setData:img.TIFFRepresentation forType:NSPasteboardTypeTIFF];
    [self writeToPasteboard:it];
    toast(c, @"已复制图片");
}

// 往剪贴板里写东西，并记下这次变化，免得自己又把它当成新图存一遍
- (void)writeToPasteboard:(id<NSPasteboardWriting>)obj {
    NSPasteboard *pb = NSPasteboard.generalPasteboard;
    [pb clearContents];
    [pb writeObjects:@[ obj ]];
    _lastChange = pb.changeCount;
}

- (void)ocrCard:(Card *)c {
    NSImage *full = [[NSImage alloc] initWithContentsOfURL:c.url];
    if (full) {
        [self showTextOf:full near:[self.panel convertRectToScreen:[c convertRect:c.bounds toView:nil]]];
    }
}

// 识别图里的文字：先弹出文字窗口显示「正在识别…」，认出来再填进去
- (void)showTextOf:(NSImage *)img near:(NSRect)anchor {
    TextPanel *tp = [[TextPanel alloc] initNear:anchor];
    __weak AppDelegate *me = self;
    tp.onCopy = ^(NSString *text) {
        [me writeToPasteboard:text];
    };
    tp.onClose = ^(TextPanel *x) {
        [me.textPanels removeObject:x];
    };
    [self.textPanels addObject:tp];
    [tp makeKeyAndOrderFront:nil];
    __weak TextPanel *wtp = tp;
    recognizeText(img, ^(NSString *text) {
        [wtp showText:text];
    });
}

// 扇形的几何：n 张、各自的高 hs，围着下方同一个圆心展开。算出各张的角度、以圆心为原点的中心位置，
// 和转过之后合起来占的范围
static NSRect fanGeometry(NSUInteger n, const CGFloat *hs, CGFloat *angles, NSPoint *centers) {
    CGFloat minX = INFINITY, minY = INFINITY, maxX = -INFINITY, maxY = -INFINITY;
    for (NSUInteger i = 0; i < n; i++) {
        angles[i] = FAN_STEP * ((n - 1) / 2.0 - i);
        double t = angles[i] * M_PI / 180, r = FAN_R + hs[i] / 2;
        centers[i] = NSMakePoint(-r * sin(t), r * cos(t));
        for (int k = 0; k < 4; k++) {
            double x = (k & 1 ? 0.5 : -0.5) * CARD_W, y = (k & 2 ? 0.5 : -0.5) * hs[i];
            double px = centers[i].x + x * cos(t) - y * sin(t), py = centers[i].y + x * sin(t) + y * cos(t);
            minX = MIN(minX, px);
            maxX = MAX(maxX, px);
            minY = MIN(minY, py);
            maxY = MAX(maxY, py);
        }
    }
    return NSMakeRect(minX, minY, maxX - minX, maxY - minY);
}

// 扑克牌那样的扇形：最新的在最左、盖在最前面，旧的往右依次压在后面，底边贴着面板底。
// 打开目录按钮在右下角、牌堆右边。面板记的是右下角，牌多了往左、往上长，按钮不动。没有缩略图就把面板藏起来
- (void)layout {
    NSUInteger n = self.cards.count;
    if (!n) {
        self.hovered = nil;
        [self.panel orderOut:nil];
        return;
    }
    CGFloat hs[MAX_CARDS], angles[MAX_CARDS];
    NSPoint centers[MAX_CARDS];
    for (NSUInteger i = 0; i < n; i++) {
        hs[i] = self.cards[i].bounds.size.height;
    }
    NSRect fan = fanGeometry(n, hs, angles, centers);
    // 取整：落在半个像素上，按钮和图会发虚
    CGFloat W = ceil(NSWidth(fan)) + PAD * 2 + 8 + BTN;
    CGFloat H = ceil(NSHeight(fan)) + PAD * 2 + LIFT;
    for (NSUInteger i = 0; i < n; i++) {
        Card *c = self.cards[i];
        c.angle = angles[i];
        [c placeAt:NSMakePoint(centers[i].x - NSMinX(fan) + PAD, centers[i].y - NSMinY(fan) + PAD) angle:c.angle];
        c.baseOrigin = c.frame.origin;
        if (c == self.hovered) {
            [c setFrameOrigin:[self liftedOrigin:c]];
        }
    }
    [self restack];
    [self placeHoverButtons];
    [self.dirBtn setFrameOrigin:NSMakePoint(W - PAD - BTN, PAD)];
    [self.panel setFrame:[self shelfFrameWithSize:NSMakeSize(W, H)] display:YES];
    [self.panel orderFrontRegardless];
}

// 钉住时的大小：
// 1. 先按 1:1：像素按屏幕缩放换成点，图里的字和原来屏幕上一样大。只缩小不放大，小图也按原样
// 2. 面积最多占屏幕可用面积的 PIN_AREA。按面积限制，长条图、竖长图都保持形状、字还看得清
//    （按长边限制的话，1600×200 的长条会被压成 480×60）
// 3. 宽、高各自最多占屏幕的 PIN_SIDE，高也不超过暂存区上方剩下的空间
// 位置：暂存区正上方、和右边对齐，多钉几张依次往左错开
- (NSRect)pinFrameFor:(NSImage *)img offset:(int)k {
    NSScreen *scr = self.panel.screen ?: self.shelfScreen;
    NSRect vis = scr.visibleFrame, shelf = self.panel.frame;
    NSImageRep *rep = img.representations.firstObject;
    CGFloat scale = scr.backingScaleFactor ?: 2;
    NSSize s = rep.pixelsWide > 0 ? NSMakeSize(rep.pixelsWide / scale, rep.pixelsHigh / scale) : img.size;
    if (s.width <= 0 || s.height <= 0) {
        s = NSMakeSize(400, 300);
    }
    CGFloat bottom = NSMaxY(shelf) + 4;
    CGFloat maxW = vis.size.width * PIN_SIDE;
    CGFloat maxH = MIN(vis.size.height * PIN_SIDE, NSMaxY(vis) - bottom - MARGIN);
    CGFloat maxArea = vis.size.width * vis.size.height * PIN_AREA;
    CGFloat f = MIN(MIN(1, sqrt(maxArea / (s.width * s.height))), MIN(maxW / s.width, MAX(maxH, 120) / s.height));
    s = NSMakeSize(MAX(1, round(s.width * f)), MAX(1, round(s.height * f)));
    CGFloat right = NSMaxX(shelf) - PAD - 24 * k;
    return NSMakeRect(MAX(NSMinX(vis), right - s.width), MIN(bottom, NSMaxY(vis) - s.height), s.width, s.height);
}

// 钉到屏幕上：从这张牌的位置放大、滑到暂存区上方。牌留在原处，还能拖出来用
- (void)pin:(Card *)c {
    NSImage *full = [[NSImage alloc] initWithContentsOfURL:c.url]; // 牌上只有小图，钉住要原图
    if (!full) {
        return;
    }
    NSRect target = [self pinFrameFor:full offset:(int)self.pins.count % 6];
    PinWindow *w = [[PinWindow alloc] initWithImage:full frame:target];
    __weak AppDelegate *me = self;
    w.onClose = ^(PinWindow *x) {
        [me.pins removeObject:x];
    };
    w.onOCR = ^(PinWindow *x) {
        [me showTextOf:x.image near:x.frame];
    };
    [self.pins addObject:w];
    // 起点：牌在屏幕上的中心，宽和牌一样，高按图片比例
    NSRect cr = [self.panel convertRectToScreen:[c convertRect:c.bounds toView:nil]];
    CGFloat sh = round(CARD_W * target.size.height / target.size.width);
    NSRect start = NSMakeRect(NSMidX(cr) - CARD_W / 2, NSMidY(cr) - sh / 2, CARD_W, sh);
    [w setFrame:start display:NO];
    w.alphaValue = 0.6;
    [w orderFrontRegardless];
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = 0.28;
        ctx.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        [w.animator setFrame:target display:YES];
        w.animator.alphaValue = 1;
    }];
}

// 抽出来的位置：顺着这张牌朝上的方向挪 LIFT
- (NSPoint)liftedOrigin:(Card *)c {
    double t = c.angle * M_PI / 180;
    return NSMakePoint(c.baseOrigin.x - LIFT * sin(t), c.baseOrigin.y + LIFT * cos(t));
}

// 叠放次序：旧的在下、新的在上，鼠标停着的那张放到最上面；按钮都在牌上面，悬停那张的按钮在最上面
- (void)restack {
    NSView *cv = self.panel.contentView;
    NSMutableArray<Card *> *order = [NSMutableArray array];
    for (NSInteger i = (NSInteger)self.cards.count - 1; i >= 0; i--) {
        if (self.cards[i] != self.hovered) {
            [order addObject:self.cards[i]];
        }
    }
    if (self.hovered) {
        [order addObject:self.hovered];
    }
    for (Card *c in order) {
        [cv addSubview:c positioned:NSWindowAbove relativeTo:nil];
    }
    for (Card *c in order) {
        for (NSButton *b in c.buttons) {
            [cv addSubview:b positioned:NSWindowAbove relativeTo:nil];
        }
    }
}

// 按钮在牌的角上，按牌的角度算出位置，图标本身摆正。lifted 表示牌抽出来之后的位置
- (NSPoint)originOf:(NSButton *)b on:(Card *)c lifted:(BOOL)lifted {
    double t = c.angle * M_PI / 180, l = lifted ? LIFT : 0;
    NSSize sz = c.bounds.size;
    NSPoint ctr = NSMakePoint(c.baseCenter.x - l * sin(t), c.baseCenter.y + l * cos(t));
    // × 左上、图钉右上、复制图片左下、识别文字右下
    BOOL left = b == c.closeBtn || b == c.imageCopyBtn, bottom = b == c.ocrBtn || b == c.imageCopyBtn;
    double dx = (left ? -1 : 1) * (sz.width / 2 - 14), dy = (bottom ? -1 : 1) * (sz.height / 2 - 14);
    NSPoint p = NSMakePoint(ctr.x + dx * cos(t) - dy * sin(t), ctr.y + dx * sin(t) + dy * cos(t));
    return NSMakePoint(round(p.x - 10), round(p.y - 10));
}

// 不带动画地摆好各张牌的按钮（重新排版后用）：悬停那张的显示在抽出后的位置，其他的藏起来
- (void)placeHoverButtons {
    for (Card *c in self.cards) {
        BOOL on = c == self.hovered;
        for (NSButton *b in c.buttons) {
            b.hidden = !on;
            b.alphaValue = on ? 1 : 0;
            [b setFrameOrigin:[self originOf:b on:c lifted:on]];
        }
    }
}

// 鼠标移到哪张，那张抽出来一点、切到最上面；移出面板放回去。
// 每张牌的按钮只跟着自己的牌动：新的那张的按钮从牌没抽出时的位置、透明开始，一起滑出、显出来；
// 旧的那张的按钮跟着它缩回、淡出，做完藏起来
- (void)hover:(Card *)c {
    if (c == self.hovered) {
        return;
    }
    Card *old = self.hovered;
    self.hovered = c;
    [self restack];
    for (NSButton *b in c ? c.buttons : @[]) {
        [b setFrameOrigin:[self originOf:b on:c lifted:NO]];
        b.alphaValue = 0;
        b.hidden = NO;
    }
    [NSAnimationContext
        runAnimationGroup:^(NSAnimationContext *ctx) {
            ctx.duration = 0.18;
            ctx.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
            if (old) {
                [old.animator setFrameOrigin:old.baseOrigin];
                for (NSButton *b in old.buttons) {
                    [b.animator setFrameOrigin:[self originOf:b on:old lifted:NO]];
                    b.animator.alphaValue = 0;
                }
            }
            if (c) {
                [c.animator setFrameOrigin:[self liftedOrigin:c]];
                for (NSButton *b in c.buttons) {
                    [b.animator setFrameOrigin:[self originOf:b on:c lifted:YES]];
                    b.animator.alphaValue = 1;
                }
            }
        }
        completionHandler:^{
            if (old && old != self.hovered) {
                for (NSButton *b in old.buttons) {
                    b.hidden = YES;
                }
            }
        }];
}

// 开发用：把几张图片摆成缩略图，按 hover 指定的那张悬停，把面板画成透明底的 PNG 后退出，用来检查样式、做效果图
- (void)demo:(NSArray<NSString *> *)images out:(NSString *)out hover:(int)hover {
    ((ShelfView *)self.panel.contentView).onHover = nil; // 不跟真实鼠标，画出来的就是指定的那张
    for (NSString *p in images) {
        NSData *d = [NSData dataWithContentsOfFile:p];
        NSImage *img = d ? makeThumb(d) : nil;
        if (img) {
            [self addCard:[NSURL fileURLWithPath:p] image:img];
        }
    }
    if (hover >= 0 && hover < (int)self.cards.count) {
        self.hovered = self.cards[hover];
        [self layout];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 600 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        NSView *cv = self.panel.contentView;
        NSSize sz = cv.bounds.size;
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                                        pixelsWide:(NSInteger)sz.width * 2
                                                                        pixelsHigh:(NSInteger)sz.height * 2
                                                                     bitsPerSample:8
                                                                   samplesPerPixel:4
                                                                          hasAlpha:YES
                                                                          isPlanar:NO
                                                                    colorSpaceName:NSDeviceRGBColorSpace
                                                                       bytesPerRow:0
                                                                      bitsPerPixel:0];
        NSGraphicsContext *g = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
        CGContextRef ctx = g.CGContext;
        CGContextScaleCTM(ctx, 2, 2);
        [cv.layer renderInContext:ctx];
        [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:out atomically:YES];
        [NSApp terminate:nil];
    });
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        // 开发用：--render-icon <目录> 把应用图标各档 PNG 写进目录后退出，make icon 用它
        NSArray *args = NSProcessInfo.processInfo.arguments;
        NSUInteger ri = [args indexOfObject:@"--render-icon"];
        if (ri != NSNotFound && args.count > ri + 1) {
            renderIcons(args[ri + 1]);
            return 0;
        }
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *d = [AppDelegate new];
        app.delegate = d;
        app.activationPolicy = NSApplicationActivationPolicyAccessory;
        [app run];
    }
    return 0;
}
