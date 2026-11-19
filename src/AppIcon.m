#import "AppIcon.h"

// 图形按 20×20 设计：两张一样大的圆角图片，前面一张摆正偏左下，后面一张往右倾、偏右上，被前面那张压住。
// 前面那张描边之前先挖掉比它大一圈的区域，后面那张的线在交叠处断开、留出一道细缝，层次更清楚
#define CARD_W 11.0
#define CARD_H 9.0
#define CARD_R 1.9

static NSAffineTransform *place(CGFloat cx, CGFloat cy, CGFloat deg) {
    NSAffineTransform *t = [NSAffineTransform transform];
    [t translateXBy:cx yBy:cy];
    [t rotateByDegrees:deg];
    return t;
}

static NSBezierPath *card(NSAffineTransform *t, CGFloat outset) {
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(-CARD_W / 2 - outset, -CARD_H / 2 - outset,
                                                                        CARD_W + outset * 2, CARD_H + outset * 2)
                                                      xRadius:CARD_R + outset
                                                      yRadius:CARD_R + outset];
    [p transformUsingAffineTransform:t];
    return p;
}

// 在 box（正方形）里画图形。lw 是线宽（20 单位制），detail 表示画不画太阳和山
static void drawGlyph(NSRect box, CGFloat lw, NSColor *color, BOOL detail) {
    [NSGraphicsContext saveGraphicsState];
    NSAffineTransform *k = [NSAffineTransform transform];
    [k translateXBy:box.origin.x yBy:box.origin.y];
    [k scaleBy:box.size.width / 20];
    [k concat];
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    CGContextBeginTransparencyLayer(ctx, NULL);
    [color set];
    // 前面那张摆正，后面那张往右上斜着露出来：主体是正的，缩到菜单栏大小也不显得歪
    NSAffineTransform *back = place(11.6, 11.3, -14), *front = place(8.8, 8.6, 0);

    NSBezierPath *b = card(back, 0);
    b.lineWidth = lw;
    [b stroke];

    // 挖掉前面那张外扩一圈的区域：后面那张的线在这里断开
    [NSGraphicsContext.currentContext setCompositingOperation:NSCompositingOperationClear];
    [card(front, lw * 1.1) fill];
    [NSGraphicsContext.currentContext setCompositingOperation:NSCompositingOperationSourceOver];
    NSBezierPath *f = card(front, 0);
    f.lineWidth = lw;
    [f stroke];

    if (detail) {
        // 太阳在右上；两座山左大右小，只画在框里，两端接到边框上
        [NSGraphicsContext saveGraphicsState];
        [card(front, -lw / 2) addClip];
        [front concat];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(1.6, 0.9, 1.9, 1.9)] fill];
        NSBezierPath *m = [NSBezierPath bezierPath];
        [m moveToPoint:NSMakePoint(-6.2, -4.6)];
        [m lineToPoint:NSMakePoint(-2.2, -0.6)];
        [m lineToPoint:NSMakePoint(0.6, -3.2)];
        [m lineToPoint:NSMakePoint(2.0, -2.0)];
        [m lineToPoint:NSMakePoint(5.4, -5.2)];
        m.lineWidth = lw * 0.92;
        m.lineJoinStyle = NSLineJoinStyleRound;
        m.lineCapStyle = NSLineCapStyleRound;
        [m stroke];
        [NSGraphicsContext restoreGraphicsState];
    }
    CGContextEndTransparencyLayer(ctx);
    [NSGraphicsContext restoreGraphicsState];
}

// 应用图标按 1024 的画布画，纯扁平：蓝底铺满整张画布，中间白色图形，不加投影、描边、渐变。
// 不自己画圆角底板：macOS 26 看到四周留透明边的图标会当成旧式图标，给图形套上发光的玻璃质感；
// 铺满画布时系统只按自己的形状裁圆角，原样显示
static void drawIcon(CGFloat S) {
    NSAffineTransform *t = [NSAffineTransform transform];
    [t scaleBy:S / 1024.0];
    [NSGraphicsContext saveGraphicsState];
    [t concat];
    [[NSColor colorWithSRGBRed:0x3D / 255.0 green:0x6F / 255.0 blue:0xF2 / 255.0 alpha:1] setFill];
    NSRectFill(NSMakeRect(0, 0, 1024, 1024));
    // 系统会把整张画布缩进它的圆角形状里，图形占中间七成多
    drawGlyph(NSMakeRect(132, 132, 760, 760), 1.0, NSColor.whiteColor, YES);
    [NSGraphicsContext restoreGraphicsState];
}

void renderIcons(NSString *dir) {
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    int sizes[] = {16, 32, 128, 256, 512};
    for (int i = 0; i < 5; i++) {
        for (int sc = 1; sc <= 2; sc++) {
            int px = sizes[i] * sc;
            NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                                            pixelsWide:px
                                                                            pixelsHigh:px
                                                                         bitsPerSample:8
                                                                       samplesPerPixel:4
                                                                              hasAlpha:YES
                                                                              isPlanar:NO
                                                                        colorSpaceName:NSDeviceRGBColorSpace
                                                                           bytesPerRow:0
                                                                          bitsPerPixel:0];
            [NSGraphicsContext saveGraphicsState];
            [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:rep]];
            drawIcon(px);
            [NSGraphicsContext restoreGraphicsState];
            NSString *name = sc == 1 ? [NSString stringWithFormat:@"icon_%dx%d.png", sizes[i], sizes[i]]
                                     : [NSString stringWithFormat:@"icon_%dx%d@2x.png", sizes[i], sizes[i]];
            [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
                writeToFile:[dir stringByAppendingPathComponent:name]
                 atomically:YES];
        }
    }
}

// 菜单栏图标：20×20 点。图形本身占画布中间约 15×13，放大 1.08 倍、挪到正中，连线宽在内约 17×15、线宽约 1.5，
// 和远程模式的菜单栏图标大小、轻重对齐；再往下挪 0.5，两个图标在菜单栏里下边齐平
NSImage *statusIcon(void) {
    NSImage *im = [NSImage imageWithSize:NSMakeSize(20, 20)
                                 flipped:NO
                          drawingHandler:^BOOL(NSRect r) {
                              drawGlyph(NSMakeRect(-1.5, -1.9, 21.6, 21.6), 1.4, NSColor.blackColor, YES);
                              return YES;
                          }];
    im.template = YES;
    return im;
}
