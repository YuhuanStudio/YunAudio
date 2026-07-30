# 驗收

驗收關卡與底下每一個探測工具的完整版。README 有那個階梯；這一份講每一階實際上在做
什麼，以及**它不能告訴你什麼**。

← [README](../../README.zh-Hant.md) · [MEASUREMENT.md](../../MEASUREMENT.md) ·
[English](../verification.md)

## 關卡

一條指令跑完全部，而且會說它**沒有**跑什麼：

```bash
./App/verify.sh --list                        # 階梯，以及每一步的成本
./App/verify.sh                               # 所有不需要音訊硬體的部分
./App/verify.sh --full                        # 再加上 flow check，它會佔用硬體約兩分鐘
./App/verify.sh --fresh                       # 再加上獨立目錄、從零建起的乾淨 clone
./App/verify.sh --only=build,tests            # 10 秒
./App/verify.sh --flow="more than one input"  # flow check 的其中一節，44 秒
```

它會編譯、跑測試、檢查每一條使用者看得到的字串都經過翻譯層、組裝 bundle、離屏繪製
每個面板、拍下每個分頁的真實視窗照片，並且在 `--full` 時，用 release 建置證明路徑
位元精確、以及即時執行緒不做任何配置。

**跳過任何東西的執行都會明說。** 一個安靜略過了「唯一碰到真實硬體的那個檢查」卻仍然
顯示綠色的摘要，比紅色更糟。

**縮小範圍執行也會列出它跳過的每一項**，所以一次十秒的執行不會被誤當成跑完了。整個
關卡是六到十分鐘，而多數改動只碰一件事；為了一行修改跑完全部不是嚴謹，那是讓人不再
去跑它的理由，而沒有人跑的關卡比沒有關卡更糟。

然後**去看 `build/screenshots`**。這個關卡能告訴你照片拍了，它不能告訴你照片裡的版面
是錯的。

## 單獨拿出來用的工具

```bash
swift run -c release yunaudio-cli                     # 探測每一個裝置
swift run -c release yunaudio-cli selftest            # 證明位元精確
swift run -c release yunaudio-cli route "Mic" "YunAudio" 5
swift run -c release yunaudio-cli dsp                 # 量人聲隔離
swift run -c release yunaudio-cli apps                # 列出可擷取的行程
swift run -c release yunaudio-cli tap Discord         # 路由某個應用的音訊
swift run -c release yunaudio-cli tap-restore Spotify # 擷取撐不撐過重新啟動
swift run -c release yunaudio-cli tone 12 &           # 一個可被擷取的噪音源
swift run -c release yunaudio-cli far-end <pid> 6     # 證明 AEC 的參考訊號
swift run -c release yunaudio-cli aec-route           # 走消除器的路由
swift run -c release yunaudio-cli volume 0.5          # 移動裝置自己的電平
swift run -c release yunaudio-cli soak 30             # 讓一條路由撐半小時
swift run -c release yunaudio-cli capture 10          # 把路由的訊號寫成檔案
swift run -c release yunaudio-cli audio-start         # 半秒內判斷 CoreAudio 起不起來
```

### `soak` —— 唯一跑得夠久的那個

其他每一項都只量幾秒鐘。每分鐘幾 KB 的洩漏、一個會游移的週期率、或者一小時後才放棄的
時鐘鎖定，在那個尺度上全都是看不見的，而它們每一個都會毀掉這個專案存在的目的。

對著真實驅動量六分鐘：

```
cycle rate                    375.0/s, worst deviation 0.1
memory growth                 +4.0 kB/min
allocations on the IO thread  0
processor                     0.40% of one core
path at the end               bit-exact
clock                         locked, 0.999983 – 0.999985 throughout
```

375.0 剛好就是 48000/128。每分鐘 4 kB 是配置器的雜訊而不是成長 —— 結束時的足跡比它
自己的中點還低 —— 而整個程序坐在 4.7 MB。這一項會判定失敗的條件是：記憶體每小時爬超過
一 MB、週期率游移超過 5%、處理器成本增加一個數量級，或者即時契約破掉一次。

### `aec-route` 與 `aec-measure` —— 接縫與深度是兩件事

`aec-route` 是整合檢查。消除器在路徑上時，麥克風屬於 `AUVoiceProcessingIO` 而不是
路由器的聚合裝置，被消除後的訊號要跨過一個無鎖 ring 才到得了 route，所以值得量的是
**那個接縫**：ring 的水位應該保持平的。水位往上爬表示路由器是兩者中較慢的一方、延遲
正在增加；掉到零表示它在餓、音訊有斷點。

量八秒鐘：48 kHz 下 388,096 個 frame、零丟失、−128 frame 的漂移、IO 執行緒上零配置。

那檢查的是管路，不是深度。`aec-measure` 才是量「實際消掉多少」的那個 —— 讓同一條聲學
路徑跑兩次，一次開消除器、一次旁路。

### `far-end` —— 檢查檢視看不出來的事

它證明的是：真實的 frame 有跨過 tap 的 IO 執行緒和消除器之間那個 ring。對著 `tone`
（振幅 0.2）跑，它應該報出 **−14.0 dBFS 的峰值和 −17.0 的 RMS** —— 正弦波的 RMS 比
峰值低 3.01 dB，所以這兩個數字放在一起就說明了降混的電平是對的，而且 ring 沒有動到
取樣值。

### 兩個容易踩的坑

**`afplay` 不是一個可用的測試素材。** 它從來不會出現在 HAL 的行程清單裡，因為它把
音訊交給一個系統行程，而不是自己開一個 client。根本沒有東西可以 tap。

**音訊相關測試要跑 release 建置。** debug 建置每個 IO 週期會報出好幾百次配置，那些
來自 Swift 自己的檢查機具。

## 介面要驗四遍

因為每一種都對其他種能抓到的東西是盲的：

```bash
./App/build-app.sh
YUNAUDIO_FLOWCHECK=1  ./build/YunAudio.app/Contents/MacOS/YunAudioApp   # 行為
YUNAUDIO_RENDER=out   ./build/YunAudio.app/Contents/MacOS/YunAudioApp   # 顏色
YUNAUDIO_SCREENSHOT=out ./build/YunAudio.app/Contents/MacOS/YunAudioApp # 真實視窗
./App/check-strings.sh                                                 # 本地化
./App/build-app.sh --verify                                            # 可出貨性
```

**flow check** 驅動模型走過一個人能走的每一條路徑，並斷言回來的東西。

**離屏繪製**把 view tree 在兩種外觀下各光柵化一次 —— 那是唯一能抓到「在一種主題下
可讀、在另一種下消失」的顏色的方法。

**截圖**拍的是最小尺寸下的實際視窗，包含標題列和那三顆紅綠燈 —— 也就是視窗自己貢獻的
一切，而那是離屏繪製在結構上不可能顯示的。

**`--verify`** 把建好的 app 複製到別的地方、把建置目錄移到拿不到的位置，然後執行它。
SwiftPM 的 `Bundle.module` 會退回去找建置目錄，所以一個從來沒把資源 bundle 複製進去的
app，在建置它的那台機器上完美運作，在其他每一台上一啟動就死 ——
`could not load resource bundle`。除了把建置目錄拿走，沒有任何辦法分辨這兩者。

**字串檢查**會在任何一條沒有經過 `loc()` 的使用者可見字面值上失敗 —— 包好的字面值和
沒包的長得完全一樣，所以除了掃描器沒有東西找得到它們；曾經有四條通過了其他所有檢查，
包括整個偏好設定側邊欄以英文坐在中文內容旁邊。

它也會拒絕**任何一行既不是註解、也不是合法鍵值對的內容**。這一條是後來加的，而理由
量過：一次合併在兩份字串表裡留下了衝突標記，而系統的解析器讀到那一行就停 —— 565 行
鍵值在檔案裡，只解出 531 個鍵，整個 OBS 面板在中文介面下顯示英文，而所有檢查都是綠的，
因為它們用正規表達式撈鍵值，正好跳過了那幾行。
