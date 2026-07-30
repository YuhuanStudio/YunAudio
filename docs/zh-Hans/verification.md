# 验证

验收关卡与其下每一个探测工具。README 列出各步骤；本页记载每一步确立了什么，以及它
无法确立什么。

← [README](../../README.zh-Hans.md) · [MEASUREMENT.md](../../MEASUREMENT.md) ·
[English](../verification.md)

## 验收关卡

一条命令跑完全部，而且会说它**没有**跑什么：

```bash
./App/verify.sh --list                        # 阶梯，以及每一步的成本
./App/verify.sh                               # 所有不需要音频硬件的部分
./App/verify.sh --full                        # 再加上 flow check，它会占用硬件约两分钟
./App/verify.sh --fresh                       # 再加上独立目录、从零构建的干净 clone
./App/verify.sh --only=build,tests            # 10 秒
./App/verify.sh --flow="more than one input"  # flow check 的其中一节，44 秒
```

它会编译、跑测试、检查每一条用户可见的字符串都经过翻译层、组装 bundle、离屏渲染每个
面板、拍下每个标签页的真实窗口照片，并且在 `--full` 时，用 release 构建证明路径比特
精确、以及实时线程不做任何分配。

**跳过任何东西的执行都会明说。** 一个悄悄略过了“唯一碰到真实硬件的那个检查”却仍然显示
绿色的摘要，比红色更糟。

**缩小范围执行也会列出它跳过的每一项**，所以一次十秒的执行不会被误当成跑完了。整个
关卡是六到十分钟，而多数改动只碰一件事；为了一行修改跑完全部不是严谨，那是让人不再去
跑它的理由，而没有人跑的关卡比没有关卡更糟。

然后**去看 `build/screenshots`**。这个关卡能告诉你照片拍了，它不能告诉你照片里的布局
是错的。

## 单项探测工具

```bash
swift run -c release yunaudio-cli                     # 探测每一个设备
swift run -c release yunaudio-cli selftest            # 证明比特精确
swift run -c release yunaudio-cli route "Mic" "YunAudio" 5
swift run -c release yunaudio-cli dsp                 # 测量人声隔离
swift run -c release yunaudio-cli apps                # 列出可捕获的进程
swift run -c release yunaudio-cli tap Discord         # 路由某个应用的音频
swift run -c release yunaudio-cli tap-restore Spotify # 捕获能否撑过重新启动
swift run -c release yunaudio-cli tone 12 &           # 一个可被捕获的噪声源
swift run -c release yunaudio-cli far-end <pid> 6     # 证明 AEC 的参考信号
swift run -c release yunaudio-cli aec-route           # 走消除器的路由
swift run -c release yunaudio-cli volume 0.5          # 移动设备自身的电平
swift run -c release yunaudio-cli soak 30             # 让一条路由撑半小时
swift run -c release yunaudio-cli capture 10          # 把路由的信号写成文件
swift run -c release yunaudio-cli audio-start         # 半秒内判断 CoreAudio 能否启动
```

### `soak` —— 唯一跑得够久的那个

其他每一项都只测几秒钟。每分钟几 KB 的泄漏、一个会游走的周期率、或者一小时后才放弃的
时钟锁定，在那个尺度上全都是看不见的，而它们每一个都会毁掉这个项目存在的目的。

对着真实驱动测六分钟：

```
cycle rate                    375.0/s, worst deviation 0.1
memory growth                 +4.0 kB/min
allocations on the IO thread  0
processor                     0.40% of one core
path at the end               bit-exact
clock                         locked, 0.999983 – 0.999985 throughout
```

375.0 恰好就是 48000/128。每分钟 4 kB 是分配器的噪声而不是增长 —— 结束时的占用比它
自己的中点还低 —— 而整个进程稳定在 4.7 MB。这一项判定失败的条件是：内存每小时爬升超过
一 MB、周期率游走超过 5%、处理器成本增加一个数量级，或者实时契约破掉一次。

### `aec-route` 与 `aec-measure` —— 接缝与深度是两件事

`aec-route` 是集成检查。消除器在路径上时，麦克风属于 `AUVoiceProcessingIO` 而不是
路由器的聚合设备，被消除后的信号要跨过一个无锁 ring 才能到达 route，所以值得测的是
**那个接缝**：ring 的水位应该保持平稳。水位往上爬表示路由器是两者中较慢的一方、延迟
正在增加；掉到零表示它在饿、音频有断点。

测八秒钟：48 kHz 下 388,096 个 frame、零丢失、−128 frame 的漂移、IO 线程上零分配。

那检查的是管路，不是深度。`aec-measure` 才是测“实际消掉多少”的那个 —— 让同一条声学
路径跑两次，一次开消除器、一次旁路。

### `far-end` —— 检查检视看不出来的事

它证明的是：真实的 frame 有跨过 tap 的 IO 线程和消除器之间那个 ring。对着 `tone`
（振幅 0.2）跑，它应该报出 **−14.0 dBFS 的峰值和 −17.0 的 RMS** —— 正弦波的 RMS 比
峰值低 3.01 dB，所以这两个数字放在一起就说明降混的电平是对的，而且 ring 没有动过
采样值。

### 两个容易踩的坑

**`afplay` 不是一个可用的测试素材。** 它从来不会出现在 HAL 的进程列表里，因为它把音频
交给一个系统进程，而不是自己开一个 client。根本没有东西可以 tap。

**音频相关测试要跑 release 构建。** debug 构建每个 IO 周期会报出几百次分配，那些来自
Swift 自己的检查机制。

## 界面验证

四项互相独立的检查，每一项都对其他项所能检测的内容是盲的。

```bash
./App/build-app.sh
YUNAUDIO_FLOWCHECK=1  ./build/YunAudio.app/Contents/MacOS/YunAudioApp   # 行为
YUNAUDIO_RENDER=out   ./build/YunAudio.app/Contents/MacOS/YunAudioApp   # 颜色
YUNAUDIO_SCREENSHOT=out ./build/YunAudio.app/Contents/MacOS/YunAudioApp # 真实窗口
./App/check-strings.sh                                                 # 本地化
./App/build-app.sh --verify                                            # 可发布性
```

**flow check** 驱动模型走过一个人能走的每一条路径，并断言返回的结果。

**离屏渲染**把 view tree 在两种外观下各光栅化一次 —— 那是唯一能抓到“在一种主题下可读、
在另一种下消失”的颜色的办法。

**截图**拍的是最小尺寸下的实际窗口，包含标题栏和那三颗红绿灯 —— 也就是窗口自身贡献的
一切，而那是离屏渲染在结构上不可能显示的。

**`--verify`** 把构建好的 app 复制到别处、把构建目录移到拿不到的位置，然后运行它。
SwiftPM 的 `Bundle.module` 会退回去找构建目录，所以一个从来没把资源 bundle 复制进去的
app，在构建它的那台机器上完美运行，在其他每一台上一启动就死 ——
`could not load resource bundle`。除了把构建目录拿走，没有任何办法区分这两者。

**字符串检查**会在任何一条没有经过 `loc()` 的用户可见字面量上失败 —— 包好的字面量和
没包的长得完全一样，所以除了扫描器没有东西找得到它们；曾经有四条通过了其他所有检查，
包括整个偏好设置侧边栏以英文坐在中文内容旁边。

它也会拒绝**任何一行既不是注释、也不是合法键值对的内容**。这一条是后来加的，而理由
测量过：一次合并在两份字符串表里留下了冲突标记，而系统的解析器读到那一行就停 ——
565 行键值在文件里，只解出 531 个键，整个 OBS 面板在中文界面下显示英文，而所有检查
都是绿的，因为它们用正则捞键值，正好跳过了那几行。
