# 毛咪剪

毛咪剪是一款面向录屏剪辑的 macOS 视频编辑器，使用 Swift、SwiftUI 和 AVFoundation。

可通过「毛咪剪 → 语言」在简体中文和 English 之间切换。

MaoMiJian is a macOS video editor for screen recordings. Choose **毛咪剪 → 语言 → English** to switch the interface.

- 在多轨时间线上剪切音视频和图片，可查看音频波形、拖框多选、批量切割、调倍速和音高。
- 添加文字、箭头、形状、计时器、高亮和局部放大。文字和形状有 3D 样式，高亮可淡入淡出，局部放大可调整边框。
- 将转场拖到素材首尾或接缝，拖动门形标记的边缘调整时长。预览可选择 1080p、720p、540p 或 360p。
- 在同一个视频或图片上堆叠滤镜，单独调整强度和顺序。「去除背景」会从素材边缘自动采样颜色，可调敏感度去除绿幕、蓝幕等单色背景。
- 导入 SRT、统一设置字幕样式并保存常用模板。可单独导出 M4A 音频、SRT 字幕，也可一次导出两个文件。
- macOS 26 上可在本机生成自动字幕并查看预计剩余时间。支持批量校对、本机字幕翻译和双语字幕。编辑时自动保存恢复草稿。
- 「字幕 → 配音」可用 Audio8-TTS 0.1B ONNX INT8 在 Apple 芯片 Mac 上朗读原文或译文，并按字幕时间放入音频轨。
- MP4 默认用 HEVC（H.265）均衡档导出，Apple 芯片 Mac 可选「录屏压缩」。同时支持 H.264、文件大小估算和高码率近无损选项。

## 下载

预编译版适用于 Apple 芯片 Mac 和 macOS 14 及以上。下载 ZIP，解压后将「毛咪剪.app」移入「应用程序」。发布包采用临时签名，未做 Apple 公证，macOS 可能提示无法验证开发者。也可以在本机按下文从源码构建。

[GitHub Releases](https://github.com/EnceladusCat/maomijian/releases)

旧版 .framecut 工程可以用毛咪剪打开。仓库的「示例」目录提供了一个可直接打开的工程及其演示素材。工程仍需访问其引用的音视频文件。

[使用说明](使用说明.md) · [示例工程](示例)

## 从源码构建

安装 Xcode 或 Xcode Command Line Tools，使用 macOS 14 或更新的 SDK。在仓库根目录运行：

```sh
./build.sh "$PWD/毛咪剪.app"
open "毛咪剪.app"
```

构建脚本使用当前 Mac 的架构。Apple 芯片版构建时会联网打包 Python、ONNX Runtime 和 Audio8 推理组件，用户可直接使用。运行像素与时间线检查的命令见[使用说明](使用说明.md#从源码构建)。

## 许可证

本项目代码与自有资源以 [MIT 许可证](LICENSE) 发布。随包附有第三方运行组件的许可与声明。首次使用配音时单独下载的权重遵循 [Audio8 Community License v1.0](https://huggingface.co/Edge0/audio8-TTS-0.1B-ONNX-INT8/blob/4b04c49d6fd8155257e4aa8972df203af97173ba/LICENSE)。
