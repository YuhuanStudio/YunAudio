# 自动化

以下每一种接口都以同一套命令词汇驱动同一个正在运行的应用程序，该词汇定义于
`Sources/YunAudioControl`。窗口、命令行、MCP 服务器与常驻脚本是它的四个前端。

← [README](../../README.zh-Hans.md) · [English](../automation.md)

## URL scheme

任何能打开 URL 的东西都可以驱动它：快捷指令、Stream Deck、Keyboard Maestro、
AppleScript、从终端执行 `open`。

```bash
open "yunaudio://routing/start"     # 也有 /stop 与 /toggle
open "yunaudio://mute/on"           # 也有 /off，不带参数则为切换
open "yunaudio://record/toggle"
open "yunaudio://transcript/start"
open "yunaudio://preset/Voice%20call"
```

不带参数是切换，因为那是实体按钮想要的行为；由脚本驱动的东西应该用确定形式，那是幂等
的 —— `mute/on` 执行两次的结果是静音，而不是取消静音。无法识别的动词会被拒绝而不是
猜测，因为要避免的失败是“打错的静音变成了停止”。

## 命令行

同样的动词，但**有答案回来** —— 那是 URL 做不到的部分。`yunaudio-cli` 是对“已经在运行
的那个应用程序”说话，它自己不打开任何硬件。

```bash
yunaudio-cli status                  # 它在做什么，一行一件事实
yunaudio-cli start                   # 也有 stop、toggle
yunaudio-cli mute on                 # 也有 off，不带参数则为切换
yunaudio-cli record off
yunaudio-cli transcribe on
yunaudio-cli preset Voice call       # 不需要引号，名称会被拼接起来
yunaudio-cli config Podcast
yunaudio-cli script "yun.mute(true); yun.log(yun.status().running)"
yunaudio-cli mute --url              # 打印 URL 而不是发送它
```

`status` 打印的就是脚本通过 `yun.status()` 看到的内容，再加上当前存在的场景与设置组。
指名一个不存在的，会得到存在的那些的列表 —— 那比“找不到”有用。**无法执行的命令以 1
退出，无法解析的那一行以 2 退出**，所以 shell 脚本分得清“应用程序拒绝了”和“你打错了”。

它通过 MCP 服务器所用的同一个 Unix socket 到达应用程序，位置在
`~/Library/Application Support/YunAudio/control.sock`。这也是为什么“YunAudio 没有在运行”
是毫秒级返回的，而不是等到超时：没有人在监听就是 `connect` 失败，那是一个答案，不是一段
要等完的沉默。

`status` 故意**不是** URL 或 MIDI 音符可以发送的动词之一：问“现在是什么状况”不应该有
能力改变它。其余全部是一套词汇 —— `RemoteCommand` —— 四个前端，所以加一次动词就同时
能从 URL、打击垫、一行 JavaScript 和 shell 用到。

这里的 `record` 指的是应用程序的录音器。那个把几秒钟路由信号写成文件用于测量的动词是
`capture`。

**不是 App Intents，而且不是没试过**：快捷指令库里的条目是从 Xcode 自己的构建阶段抽取的
元数据被发现的，而一个由 shell 脚本围着 SwiftPM 可执行文件组装出来的应用程序产生不出
那些。它们会编译、会运行，然后永远不出现在任何人用得到的地方。

## MCP 服务器

`yunaudio-mcp` 是一个 Model Context Protocol 服务器：stdio 上的 JSON-RPC 2.0、零依赖、
由你指向它的任何客户端启动。

```bash
swift build -c release            # 生成 .build/release/yunaudio-mcp
claude mcp add yunaudio -- "$PWD/.build/release/yunaudio-mcp"
```

或者，对于用文件配置的客户端 —— Claude Desktop、Zed，以及任何读同一种格式的：

```json
{
  "mcpServers": {
    "yunaudio": { "command": "/absolute/path/to/yunaudio-mcp", "args": [] }
  }
}
```

九个工具：`yunaudio_status`、`yunaudio_list_names`、`yunaudio_routing`、
`yunaudio_mute`、`yunaudio_record`、`yunaudio_transcribe`、`yunaudio_apply_scene`、
`yunaudio_apply_setup` 和 `yunaudio_run_script` —— 和 URL scheme 是同一套词汇，因为
底层就是同一个 `RemoteCommand`。名称是用户自己取的，而且有些是翻译过的，所以要按名称
应用场景之前，先调用 `yunaudio_list_names`。

**YunAudio 必须在运行。** 这个服务器不持有任何状态，自己什么也不知道：它把请求转发给
应用程序，走的是 `~/Library/Application Support/YunAudio/control.sock` 这个 Unix domain
socket —— 应用程序在启动时创建它、退出时移除它，并且只让所有者可读。如果没有人在监听，
每个工具都会立刻这样回答，而不是等下去。`--socket <path>` 和
`$YUNAUDIO_CONTROL_SOCKET` 可以移动它。

用 socket 而不用 URL scheme，因为 **URL 是单向的**。`open yunaudio://mute/on` 在
Launch Services 接下事件的那一刻就返回了：它没办法说麦克风现在是不是静音的、那个场景
到底存不存在、或者有没有任何东西听到了。那对 Stream Deck 的按键没问题，因为有人在看
结果；对 agent 就没有用，因为没有人在看 —— 而把状态读回来，正是 agent 存在的一半理由。

## OBS 对接

“设置 → 直播”连接的是 `obs-websocket` v5，那个东西从 OBS 28 版就内置在里面了。有两样
东西会跨过它，而第二样正是第一样存在的原因。

**在这里把麦克风静音，会同时静音 OBS 那一路的副本** —— 如果你要求它这么做。OBS 对同一个
来源自己的静音是另一个窗口上的另一个开关，而那产生的失败正是“没有人来得及发现”的那种。

**同步偏移。** 这个应用程序送出去的每一样东西，都比画面晚到 OBS，晚的量恰好就是效果链
增加的延迟 —— 光是人声隔离就 56 毫秒。OBS 有一个 per-source 的字段可以填，却没有办法
算出该填什么。这里算得出来，精确到 frame，而在此之前它只是显示出来。48 kHz 下的
2688 个 frame 变成 −56 ms，四舍五入到整毫秒，因为 OBS 自己的对话框就是一个整毫秒的
数字框。

两件值得直说的事：

- **`obs-websocket` 默认是关闭的**，所以大多数人遇到的第一件事是连接被拒。这里回答它的
  方式是给出菜单路径，而不是给一个状态码：工具 → WebSocket 服务器设置。
- **这件事没有对着真的 OBS 验证过。** 验证是拿 obs-websocket 协议文档里的向量检查的，
  整个握手也在真实 socket 上对着一个按那份文档所述回答的 stub 服务器检查过 —— 但写这段
  代码的机器上没有安装 OBS，而**一个 stub 不能成为关于它所模仿的那个程序的证据**。


没有做，而且那是决定而不是缺口：不做原生 OBS 插件（websocket 已经足够完成需要的事，
而插件会把这个项目绑在 OBS 的构建与 ABI 上）、目前不做浏览器来源叠加层、也不做六轨录音
模型 —— `MAX_AUDIO_MIXES` 是 libobs 里的一个编译期常量，那让“六”成为别人的复用器限制，
而不是一个值得照抄的形状。

### 跨应用程序重启的捕获

OBS 的 issue #9144 —— “Application Capture loses audio when application reopens on
macOS” —— 从 2023 年 6 月开到现在，而 OBS 对它的回答是来源属性里一个标着
“Restart capture”的按钮。

macOS 26 加了 `CATapDescription.bundleIDs`，这个应用程序会设置它，所以被捕获的应用程序
关掉再开会自己重新接上。测量这件事的时候翻出一个值得知道的事实：旁边那个
`processRestoreEnabled` 标志**默认就是 true**，所以它一直都是开着的、而且一直什么都没
恢复，因为根本没有任何 bundle identifier 可以用来恢复。**只设那个标志会是一个没有任何
效果、但读起来完全像修好了的改动。**

```bash
swift run -c release yunaudio-cli tap-restore Spotify           # HAL 留下了什么
swift run -c release yunaudio-cli tap-restore Spotify --watch   # 关掉它然后看着
```
