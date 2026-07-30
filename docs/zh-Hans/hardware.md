# Razer 硬件

← [README](../../README.zh-Hans.md) · [English](../hardware.md)

## Razer 硬件控制

Seiren V3 Pro 的灯环已经实现。做到这一步靠的是在 Windows 上抓一份 Synapse 驱动设备的
数据 —— 一边改灯光、一边每三毫秒轮询同一个 feature report —— 从里面得到的每一件事，
连同原厂对 Barracuda 给出的规格、以及**后来被实测推翻的两条结论**，都写在
**[DEVICES.md](../../DEVICES.md)**。

那份抓包确立的事情，按“能替别人省下多少时间”排序：

- **openrazer 的协议不适用。** 那个格式是 report id 0 上的 90 个字节；这个设备在任何
  地方都没有声明 90 字节的 report，所以那个 frame 会被原封不动弹回。真正的通道是
  usage page `0xFF53` 下、**id `0x07` 上的 64 字节 feature report**。
- **校验和要算进 transaction id。** openrazer 的 XOR 从下一个字节才开始。移植时如果
  保留那一行，做出来的 frame 会被设备拒绝，而且没有任何地方说明原因。
- **这个设备没有“效果”。** 把 Synapse 切到 Spectrum，抓到的是 **961 个不同的 RGB
  值**，沿着一个连续的色相圆一帧一帧流过来。动画是跑在主机上的。所以根本没有效果协议
  需要逆向：`0x0F 0x03` 写十二颗 LED、`0x0F 0x04` 设亮度（0 表示关），而每一个效果
  都是我们自己要写的。

编码器是拿设备上实际抓下来的两个 frame 逐字节对照验证的，两个校验和都算 —— 那也是在
向麦克风写入任何东西**之前**就先确认校验和规则的办法。

```bash
swift run -c release yunaudio-cli light walk          # 对出灯环的排列
swift run -c release yunaudio-cli light on            # 亮度
swift run -c release yunaudio-cli light solid 255 0 0
swift run -c release yunaudio-cli light led 0 255 255 255   # 单颗 LED，用来对排列
swift run -c release yunaudio-cli light spectrum 6
swift run -c release yunaudio-cli light off
```

上面每一条都会写入设备，所以每一条都必须被指名要求。**没有任何东西会自己去扫描或探测。**

同一份抓包也确立了麦克风的内部拓扑，那就是三个输入声道的来源 —— pin 1 上的
`Device_Mic`、`Device_MicDry`、`Device_MicPostExp` —— 以及背后的音量范围：音头接受
0 到 +36 dB 的增益，耳机输出是 −64 到 0 dB，两者都用 CoreAudio 本来就公开的
UAC2 1/256 dB 单位。

灯环是由应用程序驱动的，不只是 CLI。因为这个设备自己不计算任何效果，那十二颗 LED 就是
一个“这个项目已经有内容可以放上去”的显示器：**灯环显示输入电平，并在你按下静音的
瞬间变红。** index 0 在六点钟方向、顺时针排列，这就是为什么电平是**按高度**填充而不是
按 index 填充 —— 按 index 填会像跑马灯绕一圈，按高度填才会像仪表一样从两侧同时往上涨。
这个几何关系没法从设备读出来，是靠 `light walk` 一颗一颗点亮才知道的。

同一份抓包还确立了 Synapse 的均衡、降噪、语音门与人声清晰度都是**主机端的 THX 处理，
而不是设备命令** —— 那些东西没有任何数据可以发送，这也正是这个项目自己实现它们的原因。
