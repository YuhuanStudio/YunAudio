<div align="center">

# YunAudio

**macOS 的選單列音訊路由器，自帶一個虛擬裝置 —— 而且訊號路徑的位元精確可以被證明。**

[![macOS 26+](https://img.shields.io/badge/macOS-26%2B-000000?logo=apple&logoColor=white)](#系統需求)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](https://swift.org)
[![Licence MIT](https://img.shields.io/badge/licence-MIT-blue)](LICENSE)
[![687 tests](https://img.shields.io/badge/tests-687-brightgreen)](#自己驗一遍)
[![no dependencies](https://img.shields.io/badge/dependencies-none-lightgrey)](#系統需求)

[English](README.md) · 繁體中文 · [简体中文](README.zh-Hans.md)

</div>

<img src="docs/images/window-zh-Hant.png" alt="YunAudio 主視窗：裝置、接線盤、分析與處理面板" width="100%">

## 它為什麼存在

Discord 的 WebRTC 引擎會直接伸到 HAL 那一層，跟高階 USB 麥克風搶裝置的控制權，
結果是每秒一次的爆音。把麥克風路由進一個由 Discord 去開啟的虛擬裝置，問題就消失了。

做的過程中發現 macOS 在這個領域有好幾項能力是沒有任何軟體拿出來用的，所以這個專案
就長大了。

## 它跟別人不一樣的地方

<table>
<tr><td width="50%" valign="top">

### 路徑的位元精確是可以證明的

不是「我們覺得應該沒有重採樣」—— 是量出來的，由你自己、在你自己的硬體上量：

```
bit-exact: 261400/261400 samples identical
delay 872 frames
clock lock held at 0.999986 throughout
```

最後那個數字是你麥克風的石英誤差：慢了百萬分之 14，換算成每小時 50 毫秒的漂移 ——
如果沒有人去修正它。

</td><td width="50%" valign="top">

### 因為驅動是自己寫的

CoreAudio 驅動可以用 `GetZeroTimeStamp()` 定義自己的時鐘。這一個把取樣時鐘直接
推導自「這個 app 實際在擷取的那支麥克風」，於是兩個裝置同步前進，HAL 的漂移補償可以
關掉，路徑上沒有任何一段重採樣。

第三方的 loopback 裝置做不到這件事 —— 它根本不知道你在意的是哪支麥克風。

</td></tr>
</table>

**它會告訴你路徑的實話。** 位元精確、已重採樣，還是已處理；實測的來回延遲；時鐘鎖定
現在到底有沒有撐住。你一開人聲隔離，它就會說出來，並且停止聲稱位元精確 —— 因為
處理訊號和「不動它」正好相反。

**響度用廣播標準量。** 峰值表回答的是「會不會削波」，不是「我跟別人一樣大聲嗎」——
Discord 正規化到約 −18 LUFS、YouTube −14、廣播 −23。YunAudio 依 ITU-R BS.1770-4 量：
K 加權、400 毫秒區塊、75% 重疊，以及那個讓停頓不算進去的兩段式閘門。然後它會直接說
你離所選平台還差多少、要往哪個方向調。

**每一個來源都是一個來源。** 每個應用程式一個 process tap，不是全部混成一路 ——
所以 Discord 和 Spotify 可以有不同音量、不同角色、在有人說話時受到不同對待。兩支
麥克風就是兩條 strip、兩個推桿；這也正是為什麼對唱是「兩份實際量到的表演」，而不是
從一份混音裡猜出兩個人。

**兩份混音，不是一份。** 對方聽到什麼，和你聽到什麼，是兩個不同的問題。每個來源在
每條匯流排上都有自己的送出量，每條匯流排也有自己的音色調整與耳機補償。

**KTV 不預設中文歌沒有歌詞。** 先用 Music 自己的歌詞和本機 `.lrc`，再並行去問 LRCLIB、
QQ 音樂、網易雲音樂和 lyrics.ovh；驗證通過的時間軸勝出，並取消還在跑的較慢請求。
評分會說出它的參考是什麼 —— 精確的 MIDI 旋律、擷取到的原唱，或只有調性與時間 ——
因為伴奏本身不含人聲旋律，硬要拿它評分等於在編一個數字。

**直接監聽是真的直接。** 透過通訊軟體聽自己會慢三十毫秒，那已經足以讓人講話打結。
這裡的監聽是同一個聚合裝置上的第二個目的地：一個緩衝區，而且量出來標在畫面上。

**你可以從頻譜上讀出頻率。** 對數座標，所以一個八度在任何位置都是同樣寬度，格線落在
100 Hz、1 kHz、10 kHz —— 而等化器的頻段就座落在分析器畫出來的那些頻率上，看得見的
就伸手可及。

**它會自己調平，而且知道自己在聽什麼。** 自動增益只在 Apple 自己的聲音分類器聽見說話
時才移動電平，所以停頓和打字不會把音量越推越高。同一個分類器也負責讓咳嗽不去壓低音樂。

**逐字稿知道哪句是誰說的。** 每個來源以自己的名字分開記下，全部在本機完成 —— 因為
每個來源本來就是自己的一條路由、自己的一個 ring。不需要語者分離，因為沒有什麼要猜。

**擷取應用程式音訊不需要額外驅動。** `AudioHardwareCreateProcessTap` 從 macOS 14.2
就有了，幾乎沒有軟體在用。被擷取的應用程式關掉再開還在，那正是 OBS 的 issue #9144 ——
2023 年 6 月開到現在，這裡用一個參數回答了它。

**即時路徑不做任何記憶體配置。** 在 release 建置下由一個攔在整個程序每一次配置之前的
掛勾斷言。唯一的例外是被指名的、不是被藏起來的：Apple 的人聲隔離模型自己內部每個週期
大約配置 0.3 次。

一共有二十一項，每一項後面的量測都寫在 **[docs/features.md](docs/features.md)**。

## 各個畫面

<table>
<tr>
<td width="33%" valign="top"><img src="docs/images/tab-sound.png" alt="處理面板"><br><b>聲音</b><br>整理訊號、改變聲音、音色與空間 —— 依「這一級是幹什麼的」分組，而不是依它在訊號裡的位置。</td>
<td width="33%" valign="top"><img src="docs/images/tab-singing.png" alt="唱歌"><br><b>唱歌</b><br>五個來源的同步歌詞、調性偵測與建議移調，以及每支麥克風各自的分數。</td>
<td width="33%" valign="top"><img src="docs/images/tab-recording.png" alt="錄音"><br><b>錄音</b><br>WAV、FLAC 或 AAC，除了混音之外每個來源各一個檔。分軌取自推桿之前。</td>
</tr>
<tr>
<td valign="top"><img src="docs/images/tab-plugins.png" alt="外掛"><br><b>外掛</b><br>把第三方 Audio Unit 放進處理鏈。載不起來的那個會被指名，連拒絕它的那一步一起說。</td>
<td valign="top"><img src="docs/images/tab-scripting.png" alt="腳本"><br><b>腳本</b><br>常駐並且會反應事件的 JavaScript：靜音、開始錄音、有裝置出現。</td>
<td valign="top"><img src="docs/images/tab-hardware.png" alt="硬體"><br><b>裝置</b><br>設定組、每條匯流排的音色、耳機補償、輸出對齊，以及麥克風的燈環。</td>
</tr>
</table>

<table>
<tr>
<td width="30%" valign="top"><img src="docs/images/panel.png" alt="選單列面板"><br><b>選單列面板</b><br>大多數場合需要的東西都在這裡，不用開視窗。</td>
<td width="70%" valign="top">
<img src="docs/images/prefs-diagnostics.png" alt="診斷：完整性檢查"><br>
<b>診斷。</b>完整性檢查是一個按鈕，不只是 CLI 的一個參數。它送一段 24 位元的偽隨機
序列走完你自己的路徑，從 loopback 讀回來，從資料本身還原延遲，再逐一比對每個取樣。
在沒有時鐘鎖定的路徑上，它會報出真正的情況 —— 已重採樣、還原出的延遲、以及轉換的
幅度 —— 而不是通過或失敗。
</td>
</tr>
</table>

## 系統需求

- **macOS 26 或更新。** 即時轉錄需要 macOS 27；在 26 上它會顯示為不可用並說明原因，
  其餘功能全部可用。
- **沒有任何第三方相依。** `Package.swift` 的 `dependencies` 是空陣列，而且有檢查在
  維持這件事。
- 建置需要帶 **macOS 27 SDK** 的 Xcode，因為即時轉錄用到 `AnalyzerInputConverter`。
  腳本會自己去找；手動跑 `swift build` 可能要先 `source ./App/toolchain.sh`，否則錯誤
  訊息會是 `cannot find type 'AnalyzerInputConverter' in scope`，讀起來像打錯字，而不
  像一個差了一年的 SDK。

## 安裝

有兩條路，差別只在一個對話框。

**磁碟映像。** `./package.sh` 會建出 `build/YunAudio-<版本>.dmg`，裡面有應用程式、
虛擬裝置，以及安裝與移除各一個腳本。macOS 第一次開啟時會拒絕，並說無法驗證開發者 ——
那是它對任何沒有經過 Apple 付費公證服務的東西都會說的話，而這個專案沒有那個帳號。
系統設定的「隱私權與安全性」裡有一個**仍要打開**，按一次就夠了。映像裡的
`READ ME FIRST.txt` 會在你看到任何其他東西之前先說明這件事，因為一個沒有解釋在旁邊的
拒絕視窗，就是大多數人放棄的地方。

**或者自己建。** 你自己建出來的執行檔不帶隔離標記，所以上面那些都不適用。

```bash
# 虛擬裝置。安裝會重啟 coreaudiod，所以全系統音訊會中斷一下，
# 而且需要管理員密碼。
./Driver/build-driver.sh --install

# 應用程式。
./App/build-app.sh --run
```

移除驅動：

```bash
sudo rm -rf /Library/Audio/Plug-Ins/HAL/YunAudioDriver.driver
sudo killall coreaudiod
```

**虛擬裝置是選配的。** 擷取其他應用程式、效果鏈、錄音、轉錄、監聽、OBS、MIDI 和腳本，
全部不需要安裝任何東西。裝置買到的是另外一半：**別的應用程式可以把 YunAudio 選成自己
的麥克風**，而且那條路徑是位元精確的。

## 自己驗一遍

一條指令跑完全部，而且會說它**沒有**跑什麼。

```bash
./App/verify.sh --list                        # 階梯，以及每一步的成本
./App/verify.sh                               # 所有不需要音訊硬體的部分
./App/verify.sh --full                        # 再加上會佔用硬體的 flow check
./App/verify.sh --fresh                       # 再加上獨立目錄的乾淨 clone
./App/verify.sh --only=build,tests            # 10 秒
./App/verify.sh --flow="more than one input"  # flow check 的其中一節，44 秒
```

這些步驟是刻意互相看不見的：687 個單元測試、三語言字串表互相比對、每個面板的離屏
繪製、視窗伺服器實際畫出來的真實視窗照片、一個「沒有別人正握著音訊裝置」的斷言、
release 建置的位元精確量測，以及一次驅動整個介面對著真實硬體跑的 flow check。每一種
都抓得到其他抓不到的東西 —— 曾經有一整個功能出貨時連分頁都沒有，只有照片抓到了它。

然後去看 `build/screenshots`。這個關卡能告訴你照片拍了，它不能告訴你照片裡的版面是
錯的。

每一階、以及底下每一個探測工具 —— soak 測試、回音消除的接縫、遠端 ring —— 都在
**[docs/verification.md](docs/verification.md)**。位元精確那個數字背後的方法寫在
**[MEASUREMENT.md](MEASUREMENT.md)**：序列是什麼、為什麼是 24 位元、延遲怎麼從資料
裡還原，以及同樣重要的 —— 這個量測**不能**證明什麼。

## 從別的東西驅動它

| 介面 | 用來做什麼 |
|---|---|
| `yunaudio-cli` | 從終端機或鍵盤巨集驅動正在跑的應用程式 |
| Unix socket，`chmod 600` | CLI 底下的傳輸層，如果你想直接跟它說話 |
| `yunaudio-mcp` | 讓 agent 透過 MCP 驅動這個應用程式 |
| 常駐 JavaScript | 在 app 內部反應事件：靜音、開始錄音、有裝置出現 |
| obs-websocket v5 | 把靜音狀態同步到 OBS，並把 OBS 自己算不出來的同步偏移交給它 |
| CoreMIDI | 實體推桿，帶 soft takeover，所以接手推桿不會讓訊號瞬間跳掉 |

底下是同一套詞彙 —— `Sources/YunAudioControl` 只定義一次。細節在
**[docs/automation.md](docs/automation.md)**。

## 目錄結構

```
Sources/
  YunAudioRT/       os_workgroup 與記憶體配置攔截器的 C 層 ——
                    那些 API 在 Swift 這邊被標成不可用
  YunAudioHAL/      裝置列舉、聚合裝置、process tap、串流格式、時鐘分析
  YunAudioEngine/   IOProc、路由矩陣、時鐘錨點發布、人聲隔離、自我測試
  YunDesign/        YunUI 設計系統，翻成 SwiftUI
  YunAudioControl/  指令詞彙與控制通訊端，由應用程式、命令列與 MCP 伺服器共用
  YunAudioApp/      選單列應用程式
  yunaudio-cli/     驗收工具，以及驅動執行中應用程式的命令列
  yunaudio-mcp/     MCP 伺服器，讓 agent 可以驅動這個應用程式
Driver/             YunAudioDriver.driver —— AudioServerPlugIn
App/                bundle 組裝、圖示，以及 verify.sh
```

## 已知限制

- 驅動是 ad-hoc 簽章。要讓散布不出現首次啟動對話框，需要 Developer ID 身分與公證。
- 人聲隔離會讓 `AudioUnitRender` 在 IO 執行緒上配置記憶體 —— 每個週期大約 0.3 次，
  來自 Apple 模型內部而不是這裡的程式碼。旁路路徑維持在剛好零。測試中它沒有造成過
  斷音，但它開著的時候即時契約是破的。
- 驅動出錯會把 `coreaudiod` 連同所有系統音訊一起帶下去。上面那條移除指令要留在手邊。
- 虛擬裝置的輸入電平控制已經實作，但只以檢視方式驗證過；沒有在真機上從系統設定裡真的
  拉過它，因為安裝驅動會重啟 `coreaudiod`。
- 回音消除的代價是時鐘鎖定和位元精確，並在來回各增加一個緩衝區的延遲。這不是留待以後
  修的缺陷：消除器必須同時擁有麥克風和喇叭，所以麥克風會離開路由器的聚合裝置，時鐘
  主控變成目的地。用筆電喇叭時值得，用耳機時完全不值得，所以它預設關閉，而且介面會在
  你打開它之前先說清楚代價。

更多內容，包括每一件試過而且不成立的事，在 **[docs/limits.md](docs/limits.md)**。

## 文件

三種語言的索引都在 **[docs/](docs/zh-Hant/README.md)**。

| | |
|---|---|
| [MEASUREMENT.md](MEASUREMENT.md) | 位元精確那個數字是怎麼量的，以及它不能證明什麼 |
| [docs/verification.md](docs/verification.md) | 驗收關卡、底下每個探測工具，以及各自的盲點 |
| [docs/features.md](docs/features.md) | 二十一項功能的完整版，每一項後面都附量測 |
| [docs/automation.md](docs/automation.md) | CLI、控制通訊端、MCP、腳本、OBS、MIDI |
| [docs/hardware.md](docs/hardware.md) | Razer HID 控制，以及那個協定是怎麼被確立的 |
| [docs/limits.md](docs/limits.md) | 什麼不能用，以及什麼已經被排除 |
| [DEVICES.md](DEVICES.md) | 這裡每一件硬體到底是什麼，以及每個事實是怎麼查證的 |
| [AGENTS.md](AGENTS.md) | 在這個專案裡工作的協定 |
| [TODO.md](TODO.md) | 接下來什麼值得做，以及每一項配得上多少信任 |
| [RESEARCH.md](RESEARCH.md) | 這些決定背後的競品與 API 研究 |

## 授權

MIT —— 見 [LICENSE](LICENSE)。

虛擬裝置是對著 `<CoreAudio/AudioServerPlugIn.h>` 從零寫的，與 GPL-3.0 的 BlackHole
沒有共用任何程式碼。

## 參與

**[AGENTS.md](AGENTS.md)** 是工作協定，動任何東西之前值得先讀：不變條件是什麼、
哪些事需要人來做、四種介面檢查各自的差別，以及哪些死路已經被量過了。

濃縮版 —— 斷言一個數字而不是一個信念；介面要用四種方式驗，因為每一種都對其他種能抓到
的東西是盲的；以及記住即時路徑不做任何記憶體配置。

```bash
swift build && swift test
"$(xcrun --find swift-format)" lint --recursive Sources Tests
"$(xcrun --find swift-format)" format --in-place --recursive Sources Tests
```

`swift-format` 住在 Xcode 的工具鏈裡而不在 `PATH` 上，所以要透過 `xcrun` 呼叫。
