<p align="center"><img src="docs/icon.png" width="128" alt="PicBox 图标"></p>

<h1 align="center">PicBox</h1>

<p align="center">截完图直接拖进终端，给 agent 看图。</p>

<p align="center">截图自动存成文件，拖进终端或复制路径，就能交给 Claude Code、Codex。<br>开源免费的 Mac 菜单栏工具。</p>

<p align="center"><a href="#安装">安装</a> · <a href="README.en.md">English</a></p>

在终端里用 Claude Code、Codex，常常要给它看图：页面报错、设计稿、数据图表。可终端里 ⌘V 只能贴文字，截图又只在剪贴板里，得先存成文件，再拖进去或复制路径。

PicBox 把存文件这一步省掉了。截图一进剪贴板，就自动存进 `~/Pictures/PicBox`，屏幕右下角弹出缩略图：

- **拖进终端**：在 Claude Code 里是一张图片附件（`[Image #1]`），在普通终端里是文件路径
- **复制路径**：单击缩略图复制路径，空格已经转义好，到终端里 ⌘V 就行
- **钉在屏幕上**：图片浮在最上层，agent 改代码时对照着看
- **识别文字**：报错截图点一下识别，整段文字复制给 agent。离线识别，中英文都认
- **自动清理**：默认保留 14 天，过期的截图自动删掉

<p align="center"><img src="docs/screenshot-shelf.jpg" width="100%" alt="终端里和 agent 对话，截图在右下角扇形展开"></p>

## 使用

- 最近 5 张像扑克牌一样摊开，最新的在最左。鼠标移到哪张，哪张就抽到最前面
- 截图、在聊天软件或浏览器里复制的图片、在访达里复制的图片文件，都会存一份
- 鼠标停在一张上，四个角出现按钮：左上收起，右上钉在屏幕上，左下复制图片，右下识别文字
- 双击用预览打开原图。Shift 单击可以多选，拖其中一张就一起拖出去
- 钉住的图拖动能移动，拖边缘或角能缩放
- 右下角的胶囊按钮能清空全部缩略图、打开截图文件夹，按住拖动能把整个暂存区挪到别处
- 保留天数在菜单栏图标里设置

<p align="center"><img src="docs/screenshot-pin.jpg" width="100%" alt="报错截图钉在屏幕上，上方是识别出的文字"></p>

## 安装

到 [Releases](https://github.com/cyanext/PicBox/releases) 下载 `PicBox-<版本>.zip`，解压后把 PicBox 拖进「应用程序」。第一次打开会提示「无法验证开发者」，到「系统设置 › 隐私与安全性」底部点「仍要打开」就行。

需要 macOS 13 或更新版本，支持 Apple 芯片和 Intel。界面跟随系统语言，显示中文或英文。打开后菜单栏出现两张图片叠在一起的图标，在里面勾上「登录时自动打开」就能开机运行。有新版本时会提示，点「更新」自动下载安装。

## 隐私

- 截图只存在本机的 `~/Pictures/PicBox`，不会传到任何地方
- 密码管理器复制的密码这类标为隐藏的内容，不会存
- 自动清理只删 PicBox 自己存的截图，文件夹里的其他文件不动
- 只有一处联网：每天检查一次 GitHub 上的新版本，只发一个请求，不带任何本机信息

## 从源码编译

需要 Xcode 命令行工具：

```bash
make install
```

## 许可

[MIT](LICENSE)
