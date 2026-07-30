# Razer 硬體控制

← [README](../../README.zh-Hant.md) · [English](../hardware.md)

## 協定

Seiren V3 Pro 的燈環已經實作。做到這一步靠的是在 Windows 上抓一份 Synapse 驅動裝置的
封包 —— 一邊改燈光、一邊每三毫秒輪詢同一個 feature report —— 從裡面得到的每一件事，
連同原廠對 Barracuda 給出的規格、以及**後來被實測推翻的兩條結論**，都寫在
**[DEVICES.md](../../DEVICES.md)**。

那份封包確立的事情，按「能替別人省下多少時間」排序：

- **openrazer 的協定不適用。** 那個格式是 report id 0 上的 90 個位元組；這個裝置在
  任何地方都沒有宣告 90 位元組的 report，所以那個 frame 會被原封不動回彈。真正的通道是
  usage page `0xFF53` 底下、**id `0x07` 上的 64 位元組 feature report**。
- **檢查碼要算進 transaction id。** openrazer 的 XOR 從下一個位元組才開始。移植時如果
  保留那一行，做出來的 frame 會被裝置拒絕，而且沒有任何地方說為什麼。
- **這個裝置沒有「效果」。** 把 Synapse 切到 Spectrum，抓到的是 **961 個不同的 RGB
  值**，沿著一個連續的色相圓一幀一幀串流過來。動畫是跑在主機上的。所以根本沒有效果
  協定需要逆向：`0x0F 0x03` 寫十二顆 LED、`0x0F 0x04` 設亮度（0 代表關），而每一個
  效果都是我們自己要寫的。

編碼器是拿裝置上實際抓下來的兩個 frame 逐位元組對照驗證的，兩個檢查碼都算 —— 那也是
在對麥克風寫入任何東西**之前**就先確認檢查碼規則的方法。

```bash
swift run -c release yunaudio-cli light walk          # 對出燈環的排列
swift run -c release yunaudio-cli light on            # 亮度
swift run -c release yunaudio-cli light solid 255 0 0
swift run -c release yunaudio-cli light led 0 255 255 255   # 單顆 LED，用來對排列
swift run -c release yunaudio-cli light spectrum 6
swift run -c release yunaudio-cli light off
```

上面每一條都會寫進裝置，所以每一條都必須被指名要求。**沒有任何東西會自己去掃描或探測。**

同一份封包也確立了麥克風的內部拓樸，那就是三個輸入聲道的來源 —— pin 1 上的
`Device_Mic`、`Device_MicDry`、`Device_MicPostExp` —— 以及背後的音量範圍：音頭吃
0 到 +36 dB 的增益，耳機輸出是 −64 到 0 dB，兩者都用 CoreAudio 本來就公開的
UAC2 1/256 dB 單位。

燈環是由應用程式驅動的，不只是 CLI。因為這個裝置自己不算任何效果，那十二顆 LED 就是
一個「這個專案已經有東西可以放上去」的顯示器：**燈環顯示輸入電平，並在你按下靜音的
瞬間變紅。** index 0 在六點鐘方向、順時針排列，這就是為什麼電平是**按高度**填而不是
按 index 填 —— 按 index 填會像跑馬燈繞一圈，按高度填才會像儀表一樣從兩側同時往上長。
這個幾何關係沒辦法從裝置讀出來，是靠 `light walk` 一顆一顆點亮才知道的。

同一份封包還確立了 Synapse 的等化器、降噪、語音閘與人聲清晰度都是**主機端的 THX
處理，而不是裝置指令** —— 那些東西沒有任何封包可以送，這也正是這個專案自己實作它們的
原因。
