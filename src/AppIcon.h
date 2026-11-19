// PicBox 的图标：两张图片像暂存区那样扇形错开，前面那张里有太阳和山。图形用代码画，应用图标和菜单栏共用
#import <Cocoa/Cocoa.h>

// 把应用图标各档尺寸的 PNG 写进目录（iconset 的命名），给 iconutil 打成 icns
void renderIcons(NSString *dir);
// 菜单栏图标：模板图，跟随菜单栏深浅色
NSImage *statusIcon(void);
