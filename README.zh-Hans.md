<div align="center">

# YunAudio

**macOS 的菜单栏音频路由器，自带一个虚拟设备 —— 而且信号路径的比特精确可以被证明。**

[![macOS 26+](https://img.shields.io/badge/macOS-26%2B-000000?logo=apple&logoColor=white)](#系统需求)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](https://swift.org)
[![Licence MIT](https://img.shields.io/badge/licence-MIT-blue)](LICENSE)
[![672 tests](https://img.shields.io/badge/tests-672-brightgreen)](#自己验一遍)
[![no dependencies](https://img.shields.io/badge/dependencies-none-lightgrey)](#系统需求)

[English](README.md) · [繁體中文](README.zh-Hant.md) · 简体中文

</div>

<img src="docs/images/window-zh-Hans.png" alt="YunAudio 主窗口：设备、跳线盘、分析与处理面板" width="100%">

## 它为什么存在

Discord 的 WebRTC 引擎会直接伸到 HAL 那一层，跟高端 USB 麦克风抢设备的控制权，
结果是每秒一次的爆音。把麦克风路由进一个由 Discord 去打开的虚拟设备，问题就消失了。

做的过程中发现 macOS 在这个领域有好几项能力没有任何软件拿出来用，于是这个项目就长大了。

## 它和别人不一样的地方

<table>
<tr><td width="50%" valign="top">

### 路径的比特精确是可以证明的

不是“我们觉得应该没有重采样”—— 是量出来的，由你自己、在你自己的硬件上量：

```
bit-exact: 261400/261400 samples identical
delay 872 frames
clock lock held at 0.999986 throughout
```

最后那个数字是你麦克风的晶振误差：慢了百万分之 14，折算成每小时 50 毫秒的漂移 ——
如果没有人去校正它。

</td><td width="50%" valign="top">

### 因为驱动是自己写的

CoreAudio 驱动可以用 `GetZeroTimeStamp()` 定义自己的时钟。这一个把采样时钟直接
推导自“该应用实际在捕获的那支麦克风”，于是两个设备同步前进，HAL 的漂移校正可以关掉，
路径上没有任何一段重采样。

第三方的 loopback 设备做不到这件事 —— 它根本不知道你在意的是哪支麦克风。

</td></tr>
</table>

**它会告诉你路径的实话。** 比特精确、已重采样，还是已处理；实测的往返延迟；时钟锁定
当前有没有保持住。你一开人声隔离，它就会说出来，并停止声称比特精确 —— 因为处理信号和
“不动它”正好相反。

**响度按广播标准测。** 峰值表回答的是“会不会削波”，而不是“我和别人一样响吗”——
Discord 归一化到约 −18 LUFS、YouTube −14、广播 −23。YunAudio 按 ITU-R BS.1770-4 测：
K 加权、400 毫秒块、75% 重叠，以及那个让停顿不计入的两段式门。然后它直接说你离所选
平台还差多少、该往哪个方向调。

**每一个来源都是一个来源。** 每个应用程序一个 process tap，而不是全部混成一路 ——
所以 Discord 和 Spotify 可以有不同音量、不同角色、在有人说话时受到不同对待。两支
麦克风就是两条通道、两个推子；这也正是为什么对唱是“两份实际测到的演唱”，而不是从
一份混音里猜出两个人。

**两份混音，不是一份。** 对方听到什么，和你听到什么，是两个不同的问题。每个来源在每条
总线上都有自己的发送量，每条总线也有自己的音色调整与耳机补偿。

**KTV 不预设中文歌没有歌词。** 先用 Music 自己的歌词和本地 `.lrc`，再并行去问 LRCLIB、
QQ 音乐、网易云音乐和 lyrics.ovh；通过校验的时间轴胜出，并取消还在跑的较慢请求。
评分会说出它的参考是什么 —— 精确的 MIDI 旋律、捕获到的原唱，或只有调性与时值 ——
因为伴奏本身不含人声旋律，硬拿它评分等于在编一个数字。

**直接监听是真的直接。** 通过通讯软件听自己会慢三十毫秒，那已经足以让人说话打结。
这里的监听是同一个聚合设备上的第二个目的地：一个缓冲区，而且测出来标在画面上。

**你可以从频谱上读出频率。** 对数坐标，所以一个八度在任何位置都是同样宽度，网格落在
100 Hz、1 kHz、10 kHz —— 而均衡器的频段就落在分析器画出来的那些频率上，看得见的就
够得着。

**它会自己调平，而且知道自己在听什么。** 自动增益只在 Apple 自己的声音分类器识别为
说话时才移动电平，所以停顿和键盘声不会把音量越推越高。同一个分类器也负责让咳嗽不去
压低音乐。

**转录知道哪句是谁说的。** 每个来源以自己的名字分别记录，全部在本机完成 —— 因为每个
来源本来就是自己的一条路由、自己的一个环。不需要说话人分离，因为没有什么要猜。

**捕获应用程序音频不需要额外驱动。** `AudioHardwareCreateProcessTap` 从 macOS 14.2
就有了，几乎没有软件在用。被捕获的应用关掉再开还在，那正是 OBS 的 issue #9144 ——
2023 年 6 月开到现在，这里用一个参数回答了它。

**实时路径不做任何内存分配。** 在 release 构建下由一个拦在整个进程每一次分配之前的
钩子断言。唯一的例外是被指名的、而不是被藏起来的：Apple 的人声隔离模型自己内部每个
周期大约分配 0.3 次。

一共二十一项，每一项背后的测量都写在 **[docs/features.md](docs/features.md)**。

## 各个界面

<table>
<tr>
<td width="33%" valign="top"><img src="docs/images/tab-sound.png" alt="处理面板"><br><b>声音</b><br>整理信号、改变声音、音色与空间 —— 按“这一级是做什么的”分组，而不是按它在信号里的位置。</td>
<td width="33%" valign="top"><img src="docs/images/tab-singing.png" alt="唱歌"><br><b>唱歌</b><br>五个来源的同步歌词、调性识别与建议移调，以及每支麦克风各自的分数。</td>
<td width="33%" valign="top"><img src="docs/images/tab-recording.png" alt="录音"><br><b>录音</b><br>WAV、FLAC 或 AAC，在混音之外每个来源各一个文件。分轨取自推子之前。</td>
</tr>
<tr>
<td valign="top"><img src="docs/images/tab-plugins.png" alt="插件"><br><b>插件</b><br>把第三方 Audio Unit 放进处理链。加载不起来的会被指名，连拒绝它的那一步一起说明。</td>
<td valign="top"><img src="docs/images/tab-scripting.png" alt="脚本"><br><b>脚本</b><br>常驻并响应事件的 JavaScript：静音、开始录音、有设备出现。</td>
<td valign="top"><img src="docs/images/tab-hardware.png" alt="硬件"><br><b>设备</b><br>设置组、每条总线的音色、耳机补偿、输出对齐，以及麦克风的灯环。</td>
</tr>
</table>

<table>
<tr>
<td width="30%" valign="top"><img src="docs/images/panel.png" alt="菜单栏面板"><br><b>菜单栏面板</b><br>大多数场合需要的东西都在这里，不用打开窗口。</td>
<td width="70%" valign="top">
<img src="docs/images/prefs-diagnostics.png" alt="诊断：完整性检查"><br>
<b>诊断。</b>完整性检查是一个按钮，不只是 CLI 的一个参数。它送一段 24 比特的伪随机
序列走完你自己的路径，从 loopback 读回来，从数据本身还原延迟，再逐个比对每个采样。
在没有时钟锁定的路径上，它会报出真实情况 —— 已重采样、还原出的延迟，以及转换的幅度
—— 而不是通过或失败。
</td>
</tr>
</table>

## 系统需求

- **macOS 26 或更高。** 实时转录需要 macOS 27；在 26 上它会显示为不可用并说明原因，
  其余功能全部可用。
- **没有任何第三方依赖。** `Package.swift` 的 `dependencies` 是空数组，而且有检查在
  维持这一点。
- 构建需要带 **macOS 27 SDK** 的 Xcode，因为实时转录用到 `AnalyzerInputConverter`。
  脚本会自己去找；手动执行 `swift build` 可能要先 `source ./App/toolchain.sh`，否则
  报错会是 `cannot find type 'AnalyzerInputConverter' in scope`，读起来像拼写错误，
  而不像一个差了一年的 SDK。

## 安装

有两条路，区别只在一个对话框。

**磁盘映像。** `./package.sh` 会构建出 `build/YunAudio-<版本>.dmg`，里面有应用程序、
虚拟设备，以及安装与卸载各一个脚本。macOS 第一次打开时会拒绝，并说无法验证开发者 ——
那是它对任何没有经过 Apple 付费公证服务的东西都会说的话，而这个项目没有那个账号。
系统设置的“隐私与安全性”里有一个**仍要打开**，按一次就够了。映像里的
`READ ME FIRST.txt` 会在你看到任何其他东西之前先说明这件事，因为一个旁边没有解释的
拒绝窗口，就是大多数人放弃的地方。

**或者自己构建。** 你自己构建出来的可执行文件不带隔离标记，所以上面那些都不适用。

```bash
# 虚拟设备。安装会重启 coreaudiod，全系统音频会中断一下，
# 并且需要管理员密码。
./Driver/build-driver.sh --install

# 应用程序。
./App/build-app.sh --run
```

卸载驱动：

```bash
sudo rm -rf /Library/Audio/Plug-Ins/HAL/YunAudioDriver.driver
sudo killall coreaudiod
```

**虚拟设备是可选的。** 捕获其他应用程序、效果链、录音、转录、监听、OBS、MIDI 和脚本，
全部不需要安装任何东西。设备买到的是另外一半：**别的应用程序可以把 YunAudio 选成自己
的麦克风**，而且那条路径是比特精确的。

## 自己验一遍

一条命令跑完全部，而且会说它**没有**跑什么。

```bash
./App/verify.sh --list                        # 阶梯，以及每一步的成本
./App/verify.sh                               # 所有不需要音频硬件的部分
./App/verify.sh --full                        # 再加上会占用硬件的 flow check
./App/verify.sh --fresh                       # 再加上独立目录的干净 clone
./App/verify.sh --only=build,tests            # 10 秒
./App/verify.sh --flow="more than one input"  # flow check 的其中一节，44 秒
```

这些步骤是故意互相看不见的：672 个单元测试、三语言字符串表互相比对、每个面板的离屏
渲染、窗口服务器实际绘制出的真实窗口照片、一个“没有别人正占用音频设备”的断言、
release 构建的比特精确测量，以及一次驱动整个界面对着真实硬件跑的 flow check。每一种
都能抓到其他抓不到的东西 —— 曾经有一整个功能发布时连标签页都没有，只有照片抓到了它。

然后去看 `build/screenshots`。这个关卡能告诉你照片拍了，它不能告诉你照片里的布局是
错的。

每一阶、以及下面每一个探测工具 —— soak 测试、回声消除的接缝、远端环 —— 都在
**[docs/verification.md](docs/verification.md)**。比特精确那个数字背后的方法写在
**[MEASUREMENT.md](MEASUREMENT.md)**：序列是什么、为什么是 24 比特、延迟怎么从数据里
还原，以及同样重要的 —— 这个测量**不能**证明什么。

## 从别的东西驱动它

| 接口 | 用来做什么 |
|---|---|
| `yunaudio-cli` | 从终端或键盘宏驱动正在运行的应用程序 |
| Unix socket，`chmod 600` | CLI 底层的传输，如果你想直接和它对话 |
| `yunaudio-mcp` | 让 agent 通过 MCP 驱动这个应用程序 |
| 常驻 JavaScript | 在应用内部响应事件：静音、开始录音、有设备出现 |
| obs-websocket v5 | 把静音状态同步到 OBS，并把 OBS 自己算不出来的同步偏移交给它 |
| CoreMIDI | 实体推子，带 soft takeover，接手时不会让信号跳变 |

底层是同一套词汇 —— `Sources/YunAudioControl` 只定义一次。细节在
**[docs/automation.md](docs/automation.md)**。

## 目录结构

```
Sources/
  YunAudioRT/       os_workgroup 与内存分配拦截器的 C 层 ——
                    那些 API 在 Swift 这边被标为不可用
  YunAudioHAL/      设备枚举、聚合设备、process tap、流格式、时钟分析
  YunAudioEngine/   IOProc、路由矩阵、时钟锚点发布、人声隔离、自测
  YunDesign/        YunUI 设计系统，翻译成 SwiftUI
  YunAudioControl/  命令词汇与控制套接字，由应用程序、命令行与 MCP 服务器共用
  YunAudioApp/      菜单栏应用程序
  yunaudio-cli/     验收工具，以及驱动运行中应用程序的命令行
  yunaudio-mcp/     MCP 服务器，让 agent 可以驱动这个应用程序
Driver/             YunAudioDriver.driver —— AudioServerPlugIn
App/                bundle 组装、图标，以及 verify.sh
```

## 已知限制

- 驱动是 ad-hoc 签名。要让分发不出现首次启动对话框，需要 Developer ID 身份与公证。
- 人声隔离会让 `AudioUnitRender` 在 IO 线程上分配内存 —— 每个周期约 0.3 次，来自
  Apple 模型内部而不是这里的代码。旁路路径保持在恰好零。测试中它没有造成断音，但它
  开启时实时契约是破的。
- 驱动出错会把 `coreaudiod` 连同所有系统音频一起带下去。上面那条卸载命令要留在手边。
- 虚拟设备的输入电平控制已经实现，但只以检视方式验证过；没有在真机上从系统设置里真的
  拉动过它，因为安装驱动会重启 `coreaudiod`。
- 回声消除的代价是时钟锁定和比特精确，并在往返各增加一个缓冲区的延迟。这不是留待以后
  修的缺陷：消除器必须同时拥有麦克风和扬声器，所以麦克风会离开路由器的聚合设备，时钟
  主控变成目的地。用笔记本扬声器时值得，用耳机时完全不值得，所以它默认关闭，而且界面
  会在你打开它之前先说清楚代价。

更多内容，包括每一件试过而且不成立的事，在 **[docs/limits.md](docs/limits.md)**。

## 文档

| | |
|---|---|
| [MEASUREMENT.md](MEASUREMENT.md) | 比特精确那个数字是怎么测的，以及它不能证明什么 |
| [docs/verification.md](docs/verification.md) | 验收关卡、下面每个探测工具，以及各自的盲区 |
| [docs/features.md](docs/features.md) | 二十一项功能的完整版，每一项都附测量 |
| [docs/automation.md](docs/automation.md) | CLI、控制套接字、MCP、脚本、OBS、MIDI |
| [docs/hardware.md](docs/hardware.md) | Razer HID 控制，以及那个协议是怎么被确立的 |
| [docs/limits.md](docs/limits.md) | 什么不能用，以及什么已经被排除 |
| [DEVICES.md](DEVICES.md) | 这里每一件硬件到底是什么，以及每个事实是怎么核实的 |
| [AGENTS.md](AGENTS.md) | 在这个项目里工作的约定 |
| [TODO.md](TODO.md) | 接下来什么值得做，以及每一项配得上多少信任 |
| [RESEARCH.md](RESEARCH.md) | 这些决定背后的竞品与 API 研究 |

## 许可

MIT —— 见 [LICENSE](LICENSE)。

虚拟设备是对着 `<CoreAudio/AudioServerPlugIn.h>` 从零写的，与 GPL-3.0 的 BlackHole
没有共用任何代码。

## 参与

**[AGENTS.md](AGENTS.md)** 是工作约定，动任何东西之前值得先读：不变量是什么、
哪些事需要人来做、四种界面检查各自的差别，以及哪些死路已经被测过了。

浓缩版 —— 断言一个数字而不是一个信念；界面要用四种方式验，因为每一种都对其他种能抓到
的东西是盲的；以及记住实时路径不做任何内存分配。

```bash
swift build && swift test
"$(xcrun --find swift-format)" lint --recursive Sources Tests
"$(xcrun --find swift-format)" format --in-place --recursive Sources Tests
```

`swift-format` 在 Xcode 的工具链里而不在 `PATH` 上，所以要通过 `xcrun` 调用。
