# 限制

← [README](../../README.zh-Hans.md) · [English](../limits.md)

## 已排除的方案

**`AUAudioMix`。** macOS 26 内置了一个分级的人声／环境分离器 —— 它是
`AUSoundIsolation` 那种“开或关”的可调版本，带一个 Studio 风格（Apple 对
NVIDIA Broadcast 的回答），而且是连续的混合比例而不是一个开关。纸面上看，它是这个
平台上最有差异化的东西。

**它不能用在实时路径上，而且理由是测出来的，不是推论的**：它直接拒绝单声道与立体声
输入、要求五个输出声道而不是四个，而且就算两边格式都喂对了它仍然无法初始化 ——
因为它需要 `kAUAudioMixProperty_SpatialAudioMixMetadata`，那是相机写进 Cinematic
素材里的捕获期元数据，麦克风没有任何办法提供。

它是一个**素材后期处理用**的 Audio Unit。把单声道麦克风编码成 ambisonics 只是算术；
那份元数据不是。测试把这三个约束全部断言下来，所以将来某一版 macOS 只要放宽其中任何
一项，这个项目会知道，而不是再也不去看。

**MLX。** 为音高追踪试过，然后移除。mlx-swift 自己的 README 就写着：命令行上的
SwiftPM 没办法构建它的 Metal shader；而 MLX 在库缺失时**不会退回 CPU** ——
它加载不到默认的 metallib，然后把整个进程一起带走，而且是在一个三元素的乘法上。

除此之外，就算 Metal 正常也一样成立：在少数几个 frame 上做 2048 点变换，是一个
“启动与同步的成本高于算术本身”的尺度。vDSP 就是 Apple 为这件事写的。MLX 值得上场
的时机是有一个训练好的模型要跑，那是另一个功能、另一种构建。

**用 `kAudioSubDeviceInputChannelsKey` 把蓝牙麦克风排除在 aggregate 外。** 实测这个
key 是描述而不是选择：三个输入请求一个仍得到三个，一个输入请求零仍得到一个。测试保留
着，将来 HAL 改变就会被发现。macOS 也没有 iOS
`AVAudioSessionCategoryOptionBluetoothHighQualityRecording` 的对应 API；它明确标成
macOS 不可用。高质量蓝牙输出必须改用另一台设备提供麦克风，再以真实耳机验证。

**把 AVFoundation 当成干净监听输出。** macOS 27 SDK 的空间渲染能力在 AVFAudio，并
不是 Core Audio 设备属性。改走 `AVAudioEngine`／`AVAudioEnvironmentNode` 会替换输出
路径、增加需要另测的延迟，而且按定义终结比特精确。它最多适合明确标成 processed 的
output-only bus，不是监听路径的替代品。

**用 MediaRemote 扩大 now-playing 控制范围。** 在实测主机上 private framework 与符号
都加载成功，但查询一律返回空字典；同一个播放器同时能以 Apple Events 读到数据。会静默
失败的 private API 不是可支持的 fallback。公开 API 补上缺口以前，集成边界仍是播放器的
scripting dictionary。

**在目前 shell 组装的 SwiftPM bundle 里加入 App Intents。** 代码会编译、会执行，但目前
打包方式不会生成让 Shortcuts 与系统体验发现它的 metadata。未来迁移 app packaging 后，
应直接复用现有 remote-command vocabulary；现在复制一份命令只会得到无法被发现的第二界面。

**用 strided vDSP 取代交错音频的 routing loop。** 两条 route、512 frames 的实测是手写
loop 954 ns，vDSP 1,501 ns，算术完全相同。交错音频使访问必然带 stride，短循环的调用与
fallback 成本高于标量工作。

**实时神经变声。** 48 kHz／128 frames 的期限是 2.67 ms；目前 RVC／fish-speech 类完整
pipeline 在调度与设备延迟以前就需要远超过 100 ms。除非整条 pipeline 实测能通过 realtime
admission budget，否则只能做离线或明确标成高延迟的处理。

## 现行限制

- 驱动是 ad-hoc 签名。分发需要 Developer ID 身份与公证。
- 人声隔离会让 `AudioUnitRender` 在 IO 线程上分配内存 —— 每个周期约 0.3 次，来自
  Apple 模型内部而不是这里的代码。旁路路径保持在恰好零。测试中它没有造成过断音，
  但它开启时实时契约是破的。
- 驱动出错会把 `coreaudiod` 连同所有挂在上面的系统音频一起带下去。上面那条卸载命令
  要留在手边。
- 虚拟设备的输入电平控制已经实现，但只验证到“可以编译”和“以检视确认公开方式正确”；
  没有在真机上从系统设置里真的拉动过它，因为安装驱动会重启 `coreaudiod`。
- 回声消除的代价是时钟锁定和比特精确，并在往返各增加一个缓冲区的延迟。这不是留待
  以后修的缺陷：消除器必须同时拥有麦克风和扬声器，所以麦克风会离开路由器的聚合设备，
  时钟主控变成目的地。用笔记本扬声器时值得，用耳机时完全不值得，所以它默认关闭，
  而且界面会在你打开它之前先说清楚代价。
