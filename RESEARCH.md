# 競爭與技術研究

一份給 `TODO.md` 用的原料。六個主題，每一條主張帶可信度記號與可驗證的出處。

## 記號怎麼讀

沿用 `TODO.md` 的規則，多加一個：

- **[V]** —— 已查證：這一輪真的打開了那個來源，並讀到了寫在旁邊的那句話。
- **[M]** —— 二手（搜尋引擎摘要、他人轉述），與已查證的內容吻合，但沒有親自打開原始頁面。
- **[?]** —— 合理但未查證。是線索，不是事實。
- **[本機]** —— 在這台機器上直接讀到的：macOS 27 SDK 的 header，或這個 repo 自己的原始碼。**這一類和 `TODO.md` 的 [本機實測] 同級**，因為它不經過任何人的轉述。

---

## 0. 搜尋覆蓋度 —— 不客氣的版本

這一輪**只用掉 6 次網頁搜尋**。其餘所有證據來自三個不需要搜尋額度的管道，而且它們比搜尋更可靠：

1. **直接 HTTP 抓一手來源** —— GitHub raw 檔案、GitHub API、arXiv 摘要與 HTML 全文、廠商自己的 release notes 頁。讀到的是原文，不是別人的摘要。
2. **本機 macOS 27 SDK 的 header** —— `/Applications/Xcode-beta.app/.../MacOSX27.0.sdk`。這是最強的一手來源，而且**它直接推翻了一條 `TODO.md` 的待查項**（見 6.2）。
3. **這個 repo 自己的原始碼與測試**。

### 查得紮實的

- **OBS 對接（主題 1）**。obs-websocket 的協定文件是逐行讀的（5,798 行），OBS 的 macOS 擷取外掛原始碼、obs-browser 外掛原始碼、libobs 的音軌上限、OBS 的 release notes 與 issue 追蹤都是一手。這一節可以直接當實作規格用。
- **即時神經變聲的延遲數字（主題 4）**。四篇論文的摘要或 HTML 全文、兩個專案的 README，全部是原文裡的毫秒數，包含一篇 **2026 年 6 月**的最新 SOTA。
- **Apple 的 SDK 面（主題 6）**。macOS 26/27 的新音訊 API 是從 header 裡 grep 出來的，不是從發表會摘要抄的。
- **Rogue Amoeba 三隻、BlackHole、eqMac、FineTune、SoundPipe 的近一年（主題 5）**。release notes 原文與 GitHub API 的即時數字。
- **Elgato Wave Link** —— `TODO.md` 說這題「需要一個人拿瀏覽器去看」。**這一輪抓到了**，而且答案不是好消息（見 5.4）。

### 薄的

- **KTV 與直播唱歌（主題 2）**。只完整讀到一篇中文教學全文，其餘是搜尋結果摘要。**中文圈的點歌／評分生態幾乎全部是 Windows 的 .exe，沒有任何可讀的規格或協定文件**，所以這一節的技術細節等級是 [M]／[?]，不是 [V]。
- **錄音室工作流（主題 3）**。只讀到 RME 官方 TotalMix FX 頁面一篇。UAD Console、MOTU、Pro Tools 的延遲補償行為**沒有查到一手文件**，寫在下面的是 [?]。這一節裡唯一是 [本機] 等級的，是「我們自己有沒有做延遲補償」這個問題的答案。
- **Krisp**。只有行銷頁與搜尋摘要，**沒有任何一手技術文件**。它宣稱的「20 ms 以下」沒有論文、沒有 benchmark、沒有可驗證的來源，所以標 [M] 而且不該拿它當設計依據。

### 完全沒查到，明講

- **RØDE UNIFY / Connect 的近況** —— rode.com 對自動抓取回 302 無窮迴圈，搜尋也沒有回傳有用的結果。**這一輪等於沒查**。
- **VoiceMeeter 的近一年**、**Boom 3D**、**Airfoil 與 Farrago 的近一年**（只抓了 Audio Hijack、Loopback、SoundSource 三個 release notes）。
- **KTV 打分演算法的任何公開規格**。全民 K 歌、唱吧那一類的評分是黑盒，沒有可引用的東西。
- **Demucs / Spleeter 在 Apple Silicon 上的實測速度**。只確認了 repo 還活著，沒有找到可信的 M 系列晶片實測數字。
- **CoreML / ANE 跑音訊模型的實測延遲**。這題需要的是在這台機器上量，不是搜尋。

---

## 1. OBS 對接

這一節是六節裡最具體的，而且結論很直接：**obs-websocket v5 足夠我們做到「最完整的對接」，而且不需要寫任何 OBS 外掛**。

### 1.1 obs-websocket v5：能做什麼

版本與現況 [V]：

- 目前版本 **5.7.4**，RPC 版本 **1**。來源：`obs-websocket/CMakeLists.txt` 的 `set(obs-websocket_VERSION 5.7.4)` 與 `set(OBS_WEBSOCKET_RPC_VERSION 1)`。
  <https://raw.githubusercontent.com/obsproject/obs-websocket/master/CMakeLists.txt>
- 自 OBS 28 起隨 OBS 內建，不需要另外安裝。obs-websocket 自己的 GitHub releases 停在 2022 年的 5.0.1 與 4.9.1-compat，因為之後都跟著 OBS 走。 [V]
- **預設是關的**，預設埠 **4455**，預設**要求密碼**。來源：`src/Config.h` 的
  `std::atomic<bool> ServerEnabled = false; std::atomic<uint16_t> ServerPort = 4455; std::atomic<bool> AuthRequired = true;` [V]
  <https://raw.githubusercontent.com/obsproject/obs-websocket/master/src/Config.h>
  → **這是我們的第一個 UX 設計限制**：使用者必須先去 OBS 的「工具 → WebSocket 伺服器設定」打開它並複製密碼。我們的引導流程要把這件事講清楚，而不是連不上就顯示一個錯誤碼。

認證 [V]（協定文件「Creating an authentication string」一節，逐字讀過）：

1. 伺服器在 `Hello`（OpCode 0）裡送 `authentication: { challenge, salt }`。
2. 客戶端算 `base64(sha256(password + salt))` 得到 base64 secret。
3. 再算 `base64(sha256(base64_secret + challenge))`，放進 `Identify`（OpCode 1）的 `authentication`。

**這在 Swift 裡是 CryptoKit 的十行**，沒有第三方相依。連線流程是 HTTP upgrade → `Hello` → `Identify` → `Identified`，之後才能送 request。子協定可以選 `obswebsocket.json`（預設）或 `obswebsocket.msgpack`。

音訊相關的**請求**，全部在 `Inputs Requests` 底下，全部 v5.0.0 就有 [V]（逐條讀過欄位表）：

| 請求 | 欄位 | 對我們的用處 |
|---|---|---|
| `GetInputList` / `GetInputKindList` | — | 列出 OBS 裡的音訊來源與可建立的種類 |
| `GetSpecialInputs` | 回 `desktop1`、`desktop2`、`mic1`–`mic4` | **直接拿到 OBS 的桌面音訊與麥克風槽位名稱**，不必猜 |
| `GetInputMute` / `SetInputMute` / `ToggleInputMute` | `inputMuted: Boolean` | 我們的靜音鍵可以同時靜音 OBS 的那一路 |
| `GetInputVolume` / `SetInputVolume` | `inputVolumeMul`（0–20）或 `inputVolumeDb`（−100–+26） | **兩種單位都收**，我們的推桿可以直接送 dB |
| `GetInputAudioBalance` / `SetInputAudioBalance` | — | 平衡 |
| `GetInputAudioSyncOffset` / `SetInputAudioSyncOffset` | — | **延遲補償的對接點**（見 1.5） |
| `GetInputAudioMonitorType` / `SetInputAudioMonitorType` | `OBS_MONITORING_TYPE_NONE` / `_MONITOR_ONLY` / `_MONITOR_AND_OUTPUT` | OBS 的監聽模式 |
| `GetInputAudioTracks` / `SetInputAudioTracks` | `inputAudioTracks: Object`（軌 → 開關） | **多軌錄音的對接點**（見 1.4） |
| `CreateInput` | `inputName`、`inputKind`、`inputSettings` | **我們可以自己把來源建好**（見 1.3） |
| `CreateSourceFilter` / `SetSourceFilterSettings` / `SetSourceFilterEnabled` | `filterKind` 等 | 可以程式化操作 OBS 自己的濾鏡鏈 |

音訊相關的**事件** [V]：`InputMuteStateChanged`、`InputVolumeChanged`、`InputAudioBalanceChanged`、`InputAudioSyncOffsetChanged`、`InputAudioTracksChanged`、`InputAudioMonitorTypeChanged`，加上輸出類的 `StreamStateChanged`、`RecordStateChanged`、`RecordFileChanged`、`ReplayBufferSaved`、`VirtualcamStateChanged`。

**電平表**：`InputVolumeMeters` 是一個「高流量事件」，**每 50 毫秒**送出所有作用中來源的音量，資料是 `inputs: Array<Object>`。它需要**額外訂閱**：`EventSubscription::InputVolumeMeters` 的值是 `(1 << 16)`，**不包含在 `All` 裡面**（`All` 只含非高流量事件）。 [V]

批次：`RequestBatch`（OpCode 8）預設 `executionType` 是 `SerialRealtime`，也可以選 `SerialFrame`（跟影格對齊）或 `Parallel`，並可設 `haltOnFailure`。 [V]
→ **這是我們同時改多個推桿時該用的東西**，而不是連續送十個 request。

**做不到的**：obs-websocket 沒有任何把音訊樣本送進 OBS 或取出來的能力。它是控制平面，不是資料平面。音訊本身一定要走音訊裝置（我們的虛擬裝置）或 NDI。這一點很重要，因為它決定了架構：**我們送樣本走驅動，送控制走 websocket**，兩者互補而不是二選一。

### 1.2 OBS 在 macOS 上的音訊擷取：那個痛還在，但形狀變了

**變了的部分（這一條必須誠實，因為它削弱了我們的舊賣點）**[V]：

OBS 現在**內建**了一個叫 **`macOS Audio Capture`** 的來源，基於 ScreenCaptureKit，需要 macOS 13 以上，而且**同時支援 Desktop Audio Capture 與 Application Audio Capture**。

- 原始碼：`plugins/mac-capture/mac-sck-audio-capture.m`，裡面的 `ScreenCaptureAudioDesktopStream` 與 `ScreenCaptureAudioApplicationStream` 兩個分支，後者用 `SCContentFilter ... includingApplications:` 挑一個 `SCRunningApplication`。
  <https://raw.githubusercontent.com/obsproject/obs-studio/master/plugins/mac-capture/mac-sck-audio-capture.m>
- 字串表：`SCK.Audio.Name="macOS Audio Capture"`、`ApplicationAudioCapture="Application Audio Capture"`、`DesktopAudioCapture="Desktop Audio Capture"`、`SCK.AudioUnavailable="Audio capture requires macOS 13 or newer."`
  <https://raw.githubusercontent.com/obsproject/obs-studio/master/plugins/mac-capture/data/locale/en-US.ini>
- 加入時間：該檔案的第一個 commit 是 **2023-06-25「mac-capture: Add macOS Audio Capture」**（GitHub commits API）。所以這件事已經三年了。
- 而且在 macOS 13 以上，OBS 會把舊的 `coreaudio_output_capture` **標成 deprecated**：
  `coreaudio_output_capture_info.output_flags |= OBS_SOURCE_DEPRECATED;`
  <https://raw.githubusercontent.com/obsproject/obs-studio/master/plugins/mac-capture/plugin-main.c>

**所以「OBS 在 macOS 沒有 Application Audio Capture、大家都在裝 BlackHole」這句話已經不能再講了。** 如果我們的行銷還在講這句，那是錯的，而且會被抓到。

**沒變的部分（痛還在，而且有一手證據）**：

- **應用程式重開就掉音訊，開了三年沒解**。OBS issue **#9144「Application Capture loses audio when application reopens on MacOS」**，2023-06-24 開，**至今仍是 open**。 [V]（GitHub search API，state=open）
  對照原始碼：那個來源的屬性面板裡有一顆
  `obs_properties_add_button2(props, "reactivate_capture", obs_module_text("SCK.Restart"), reactivate_capture, sc)`，
  字串是 `SCK.Restart="Restart capture"`。**一個要人手動按「重新開始擷取」的按鈕，就是這個缺陷的自白。** [V]
- 其他仍 open 的相關 issue [V]：#11873「Configured macOS Audio Capture Sync Offset Not Recognized on Restart」（2025-02）、#11561（FaceTime 擷取壞掉）、#11240（崩潰）、#11933「mac-capture: Show warning for macOS system effect on audio devices」（2025-03，意思是 macOS 的系統語音處理效果會被套在音訊裝置上而使用者不知道）。
- 權限：SCK 的路徑要「螢幕錄製」權限。已關閉的 issue #10401「[macOS] granting System Audio Recording permission only, macOS Audio Capture cannot be used」顯示光給音訊權限不夠。 [V]
- 社群端仍普遍在用 BlackHole + Aggregate Device 的組合 [M]（搜尋摘要與 OBS 論壇的 BlackHole 資源頁仍在流通）。

**而我們手上有一個 OBS 沒有的東西**（見 6.1）：macOS 26 的 `CATapDescription.processRestoreEnabled`，**專門解決「應用程式重開後把它接回來」**。這正好是 #9144。這是這一輪找到最乾淨的一句賣點，而且兩邊都可驗證。

**一句話的賣點，改成能站得住的版本**：
> OBS 三年前就有 Application Audio Capture 了。它至今仍會在被擷取的應用程式重開後掉音訊，而且要你手動按一顆「Restart capture」。我們的來源是 CoreAudio 的 process tap，用 macOS 26 的 `processRestoreEnabled` 依 bundle ID 自動接回來 —— 而且順便有一條經過我們處理鏈的人聲。

### 1.3 Browser source：我們的歌詞、分數、電平表可以直接疊上去

obs-browser 是 **macOS 官方套件內建**的（README 明說「This plugin is included by default on official packages on Windows, macOS…」）。 [V]
<https://raw.githubusercontent.com/obsproject/obs-browser/master/README.md>

三件對我們有直接用處的事實：

**(a) 可以放本機檔案，不必架 HTTP 伺服器。** browser source 的設定鍵是 `is_local_file`（bool）與 `local_file`（路徑），另有 `url`、`width`、`height`、`fps`、`fps_custom`、`css`、`shutdown`（不可見時關閉）、`restart_when_active`、`reroute_audio`、`webpage_control_level`。 [V]（`obs-browser-plugin.cpp` 的 `obs_data_set_default_*` 與 `obs_properties_add_*`）
→ 我們可以把 overlay 的 HTML 放在 app bundle 裡，然後用 `CreateInput`（`inputKind: "browser_source"`，`inputSettings: {is_local_file: true, local_file: "..."}`）**替使用者把場景建好**。

**(b) 我們可以從外面推事件進那個網頁，而且是官方管道。** obs-browser 在 `obs_module_post_load()` 裡註冊了一個 obs-websocket vendor：

```cpp
auto vendor = obs_websocket_register_vendor("obs-browser");
auto emit_event_request_cb = [](obs_data_t *request_data, obs_data_t *, void *) {
    const char *event_name = obs_data_get_string(request_data, "event_name");
    OBSDataAutoRelease event_data = obs_data_get_obj(request_data, "event_data");
    DispatchJSEvent(event_name, event_data ? obs_data_get_json(event_data) : "{}", nullptr);
};
obs_websocket_vendor_register_request(vendor, "emit_event", emit_event_request_cb, nullptr);
```

[V]（`obs-browser-plugin.cpp` 第 758–777 行）

配上協定文件裡的 `CallVendorRequest`（欄位 `vendorName`、`requestType`、`requestData`）[V]，我們的完整推送鏈是：

```
YunAudio ──websocket──> CallVendorRequest{
                          vendorName:"obs-browser",
                          requestType:"emit_event",
                          requestData:{event_name:"yunLyric", event_data:{...}}}
                        └─> 每一個 browser source 收到 window CustomEvent "yunLyric"
```

網頁端只要 `window.addEventListener('yunLyric', e => …)`。obs-browser 的 README 在可用事件清單最後就寫著「[Any custom event emitted via obs-websocket vendor requests]」。 [V]

**這比架本機 HTTP + WebSocket 伺服器好**：沒有埠、沒有防火牆、沒有「另一個程式也連上來了」的安全問題，而且 overlay 是純靜態檔案。缺點是它綁 obs-websocket 連線；如果使用者沒開 websocket，就退回本機檔案 + 我們自己的 WebSocket（那才需要伺服器）。

**(c) 網頁反過來也能讀 OBS 狀態**：`window.obsstudio.pluginVersion`、`getStatus`（recording / streaming / replaybuffer / virtualcam）、`getCurrentScene`、`getControlLevel`，以及 `obsSceneChanged`、`obsRecordingStarted` 等事件。 [V]

**別人怎麼做**：已存在的 now-playing / 歌詞 overlay 幾乎都是「本機小伺服器 + WebSocket + HTML widget」。`icedream/obs-spotify-lyrics` 的 README 自己就這樣寫：「1. **Lyrics server** that talks to Spotify … then serves a WebSocket for the *HTML widget*　2. **Customizable HTML widget** that connects to above server」。 [V]
<https://raw.githubusercontent.com/icedream/obs-spotify-lyrics/main/README.md>
其他有 LyricDisplay、OBSLyricsBud（OBS 外掛，按鈕控制上／下一句）、amirchev/OBS-Lyrics（Lua 腳本）。 [M]（搜尋摘要，沒有逐一打開）

→ **空門**：這些全部只有歌詞。**沒有一個把「逐字歌詞 + 音高線 + 分數 + 電平 + 調性建議」放在同一張 overlay 上**，因為沒有一個手上有音訊。我們有。

### 1.4 多軌錄音

- OBS 的音軌上限是 **6**：`#define MAX_AUDIO_MIXES 6`（`libobs/media-io/audio-io.h`），同檔 `MAX_AUDIO_CHANNELS 8`。 [V]
- 每個來源要進哪幾軌，可以用 `SetInputAudioTracks`（`inputAudioTracks: Object`，軌 → 開關）程式化設定，並用 `InputAudioTracksChanged` 事件同步。 [V]

**最好的對接方式**（這是設計判斷，不是查到的）：

我們的 per-source stem 有 N 個來源（麥克風、每個被 tap 的 app）。OBS 只有 6 軌。所以正確的作法**不是**把 stem 塞進 OBS，而是：

1. 我們的虛擬裝置**多開幾個 stereo 輸入**（或多個虛擬裝置），一個來源一個。
2. 在 OBS 裡每個都是一個 `coreaudio_input_capture`，用 `CreateInput` + `inputSettings: {"device_id": "<我們的 UID>"}` 建好 —— `device_id` 是 `plugins/mac-capture/mac-audio.c` 裡實際的設定鍵，預設值是 `"default"`。 [V]
3. 用 `SetInputAudioTracks` 把它們分派到軌 1–6，軌 1 留給節目混音。
4. 超過 5 個來源時，我們自己錄（我們本來就會錄 stem），OBS 只拿混音。**這是誠實的分工**：OBS 的 6 軌是硬上限，我們的 stem 不是。

### 1.5 一個沒人做的對接點：`SetInputAudioSyncOffset`

OBS 對每個來源有一個同步偏移量，而且可以透過 websocket 設定與讀取。 [V]

我們**知道自己的處理鏈延遲多少幀**（見 3.3，`EffectChain.latencyFrames` 是把每個 AU 的 `kAudioUnitProperty_Latency` 加起來的）[本機]。所以我們可以在使用者改效果鏈時，**自動把 OBS 那一路的 sync offset 設成我們新的延遲**，讓人聲與畫面／伴奏保持對齊。

**這一件事沒有任何競爭者能做**，因為要做它你得同時知道處理鏈的延遲**和**有 OBS 的控制通道。這是「兩個東西相乘」才有的功能，成本很低。

### 1.6 NDI、虛擬攝影機、virtual audio

- **NDI**：obs-ndi 的後繼者是 **DistroAV**，macOS 用 `brew install --cask distroav/distroav/distroav`。它有三種形態：NDI Source（收）、NDI Output（把 OBS 的節目送出去）、**NDI Filter（又叫 NDI Dedicated Output）—— 把單一來源或場景的音訊送到 NDI**。 [V]
  <https://raw.githubusercontent.com/DistroAV/DistroAV/master/README.md>
  → 對我們有意義的是最後一個：如果哪天要做「把某一路 stem 送到另一台機器」，NDI 是有人用的路，比 VBAN 普及。但這是第二階段的事。
- **虛擬攝影機**：OBS 有 `StartVirtualCam` / `StopVirtualCam` / `GetVirtualCamStatus` 與 `VirtualcamStateChanged`。 [V] 純影像，對我們沒有直接用處，但值得在「我們知道 OBS 在做什麼」的狀態列裡顯示。
- **virtual audio**：就是我們。OBS 那邊看到的是一個 `coreaudio_input_capture`。

### 1.7 對我們來說最值得做的三件事（OBS）

1. **做一個 obs-websocket v5 客戶端，而且把「建場景」也做掉。** 不只是「連上去改音量」，而是一鍵替使用者把來源建好（`CreateInput` 指向我們的裝置）、分派音軌（`SetInputAudioTracks`）、疊上 overlay（`browser_source` + 本機檔案）。理由：協定細節這一節已經全部查清楚，實作沒有未知數；而 OBS 使用者最大的痛是**設定**，不是缺功能。
2. **Overlay 走 `CallVendorRequest → obs-browser → emit_event`。** 理由：不需要伺服器、不需要埠、官方管道、而且是唯一能把「歌詞 + 音高 + 分數 + 電平」放在同一張圖上的路 —— 因為只有我們同時有這四樣東西。
3. **自動同步偏移**：效果鏈延遲改變時，自動送 `SetInputAudioSyncOffset`。理由：成本極小（我們已經算好那個數字），沒有競爭者能做，而且它修的是一個真實的、使用者說不出來但聽得出來的問題。

**刻意不做**：寫 OBS 原生外掛。它會把我們綁進 OBS 的建置與 ABI，而 websocket 已經夠了。**這條要寫進「已定案」。**

---

## 2. KTV 與直播唱歌

**這一節的證據等級比上一節低一個檔次，請照著讀。**

### 2.1 實際的訊號鏈

中文圈的主流作法（來自一篇完整讀過的中文教學與若干搜尋摘要）：

- **硬體聲卡是預設答案，不是軟體。** 直播主買的是外接 USB 聲卡（音效卡），伴奏走 **AUX IN / LINE IN** 實體輸入進聲卡，在聲卡裡跟人聲混合；混響、電音等效果由聲卡的 DSP 做。有一篇教學直接寫「如果需要播放伴奏，AUX IN 或 LINE IN 接口是聲卡的必備功能」。 [M]
- **耳返**（監聽）由聲卡的耳機孔直接給，所以是零延遲的硬體監聽 —— 跟我們在 `DEVICES.md` 裡挖出來的 Seiren play-through 是同一件事。 [M]
- OBS 端的建議數值很粗糙：「採樣率和聲道設置盡量與聲卡設置一致」「麥克風聲和主聲音最大音量數值相差最好不要大於 20」「BGM 音量最好比遊戲聲音小 35 左右」。 [M]
  → 這些是**沒有量測的經驗值**。我們有 BS.1770 的整合響度，可以把「BGM 比人聲小 X」變成一個真的數字（例如伴奏 −20 LUFS、人聲 −16 LUFS）。**這是一個真實的、可以說清楚的差異化。**
- 英文圈的做法沒有查到可靠來源，**這一格是空的**。 [未查證]

### 2.2 歌詞怎麼上直播畫面

中文圈的主流是**兩條路**，都不用 browser source [M]：

1. **窗口捕獲 + 色度鍵**：把酷狗／QQ 音樂／網易雲的桌面歌詞視窗抓進 OBS，用色度鍵去背。
2. **專門的外掛**：例如「OBS 歌詞插件」「聽雲點歌助手」這一類，**全部是 Windows 的 .exe**。

英文圈是 browser source + 小伺服器（見 1.3）。 [V]

→ **macOS 的空門非常大**：中文圈的整套點歌／歌詞／彈幕生態（弹幕点歌、实时字幕、点歌台）在 macOS 上**一個都沒有**。這不是「我們可以做得更好」，是「那邊完全沒有東西」。

### 2.3 點歌、歌單、分數、對唱

- **點歌系統**在中文圈是成熟品類：有「弹幕点歌」（觀眾在聊天室打字點歌）、「自助点歌台」（直播畫面上的點歌介面）。實作全部是 Windows 桌面程式 + 直播平台的彈幕 API。 [M]
  → 對我們的意義：**點歌需要接直播平台的彈幕 API**，那是平台相依、會變、而且中國平台居多。**這是一個產品邊界問題，不是技術問題**，我建議先不碰。
- **分數**：沒有任何公開規格。 [未查證] `TODO.md` 已經定案的方向（旁邊放 MIDI 旋律檔，或用人聲隔離把原唱抽出來量）是對的，而且**我們比別人多一個籌碼**：我們已經有音高顯示與調性偵測，而別人的評分是黑盒。
- **對唱**：`TODO.md` 說「每個來源本來就是分開的，這是結構上白拿的」—— 這句話成立，而且在這一輪找到的所有東西裡，**沒有任何競爭者有 per-source 分離**。這是我們最不對稱的優勢。

### 2.4 版權與伴奏來源

沒有查到任何一手法律或平台政策文件。 [未查證]

但有一個**技術上的事實會影響設計**：中文圈的作法是從音樂 app 播伴奏（酷狗、QQ 音樂、網易雲），也就是**我們 tap 得到的東西**；而歌詞則是從同一個 app 的視窗抓的。我們已經做了 Music 與 Spotify 的 now playing 與 `.lrc`。**把 tap 到的伴奏與 now playing 的中繼資料綁在一起，是我們比「抓視窗截圖」乾淨一個世代的作法**，而且不涉及重新散布音樂內容。

### 2.5 對我們來說最值得做的三件事（KTV）

1. **把「伴奏 vs 人聲的平衡」變成一個量測，而不是一句經驗。** 用我們已經有的 BS.1770 分別量麥克風與被 tap 的伴奏，然後說「伴奏比人聲響 3.2 dB，往下 3 dB」。理由：這正是那些教學在用瞎數字回答的問題，而我們是這個平台上唯一量得出來的。
2. **對唱模式。** 理由：`TODO.md` 說得對，它結構上白拿；而這一輪確認了**沒有任何競爭者有分離的來源**，所以這是別人抄不了的。
3. **overlay 走 OBS browser source（見 1.7 第 2 項），而不是自己畫視窗。** 理由：中文圈現在的作法是「抓別的 app 的視窗 + 色度鍵」，那是一個又醜又脆的解法；我們直接給一張乾淨的 overlay，是直接的升級。

**刻意不做**：接直播平台的彈幕 API 做點歌。理由：平台相依、會變、法遵不明，而且它跟音訊沒有關係 —— 那是另一個產品。

---

## 3. 錄音室的做法

**證據等級：這一節最弱的一節，除了 3.3。** RME 的官方頁是唯一的一手來源；UAD Console 與 MOTU 沒有查到文件。

### 3.1 RME TotalMix FX 的路由矩陣長什麼樣，以及為什麼

從 RME 官方頁逐字讀到的 [V]（<https://rme-audio.de/totalmix-fx.html>）：

- 「The DSP-based TotalMix mixer allows fully independent routing and mixing of input and playback channels to all physical outputs. **Independent stereo submixes** plus a comprehensive **Control Room section**…」
- 「Its unique capability to create **as many independent submixes as output channels available**」
- 「Create **Cue mixes for multiple musicians**」
- 「Built In Control room Section - Cue, **flexible Talkback for all Outputs**」
- 「If you have additional headphones outputs, you can **assign up to 4 mixes as headphones. These will all receive the Talkback signal when activated**.」
- 兩種檢視：mixer（預設，三排：硬體輸入 / 軟體播放 / 硬體輸出）與 **matrix**（X 鍵切過去，M 鍵切回來）。

**為什麼那樣設計**（我的解讀，標 [?]）：三排的形狀直接對應「訊號從哪來 / 電腦給了什麼 / 要送到哪去」，而 matrix 檢視是同一份資料的另一個投影 —— 當輸出多到用推桿看不完時，矩陣才讀得動。**submix 的數量等於輸出的數量**這條規則很優雅：每個實體輸出就是一個獨立的混音，不需要另外的「bus」概念。

我們的 A/B 匯流排是同一件事的兩份特例。**把它一般化成「每個目的地一條 submix」，就是 TotalMix 的模型**，而且我們已經證明「輸出側掛 biquad 級聯可行」（`TODO.md` 第 3 項），所以機制不是新的。

### 3.2 Talkback、cue mix、punch-in/out、comping

- **Talkback**（控制室對錄音室講話）與 **Listenback**（反方向）在 TotalMix 裡是明確的功能，而且「所有輸出都能收到 talkback」。 [V]
- **Cue mix / 耳機分路**：每個歌手一份混音，最多 4 份指定為耳機。 [V]
- **Punch-in / punch-out** 與 **comping**：沒有查到一手文件。 [?] 這兩個是 DAW 的錄音功能（在時間軸上指定區段重錄、多次錄音挑段落），**它們預設你有一條時間軸**。我們沒有時間軸，我們是路由器。
  → **判斷：punch-in 與 comping 不該做。** 它們不是「我們缺的功能」，是「我們不是那種軟體」。要做那個得先做一個 DAW。這一條建議寫進「已定案」。

### 3.3 延遲補償 —— 我們沒有在補償，而且這是一個真的問題 [本機]

事實，全部從這個 repo 的原始碼讀出來：

- `EffectChain` 把每個 AU 的延遲加總：
  `AudioUnitGetProperty(unit, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &latency, &size)`，累加到 `latencyFrames`（`Sources/YunAudioEngine/EffectChain.swift:680–686`）。
- `RoutingEngine` 把它存成 `effectLatencyFrames`（`RoutingEngine.swift:148, 515, 1566`）。
- 這個值**唯一的去處**是 UI：`RouterModel.swift:1971` 把它換算成毫秒顯示。

**沒有任何地方用它去延遲別的路徑。** 也就是說：

- 麥克風經過 11 級效果鏈（含人聲隔離 56 ms），**被 tap 的應用程式音訊沒有經過任何東西**。
- 兩者在混音時相差整條鏈的延遲。**在 KTV 的情境下，這就是「人聲比伴奏晚」**，而且量級是幾十毫秒 —— 唱歌的人聽得出來，而且會下意識搶拍。
- 錄下來的 per-source stem 之間也是錯開的，所以「事後在 DAW 裡重混」會需要手動對齊。

**這是一個正確性問題，不是功能請求。** 而修法很便宜：在 tap 的路徑上放一個延遲線，長度 = `effectLatencyFrames`（減去 tap 自己的延遲）。我們已經知道那個數字。

**而且它可以被斷言**：送一個脈衝進麥克風路徑與 tap 路徑，量兩邊在目的地的到達幀差，斷言它是 0 —— 這正是這個專案的作風。

### 3.4 對照之下我們缺的是什麼

我們有：A/B 匯流排、per-source stem、10 段 EQ、壓縮、閘門、限幅、耳機補償、第三方 AU。

對照 TotalMix，缺的是：

| 缺的 | 值不值得 | 為什麼 |
|---|---|---|
| **延遲補償** | **最值得** | 它是正確性，不是功能（3.3） |
| **每條匯流排一條處理鏈** | 值得 | `TODO.md` 第 3 項已經有結論，機制已證明 |
| **Cue mix（每個目的地一份混音）** | 值得，但先做 3.1 的一般化 | 我們的 A/B 是它的特例 |
| **Talkback** | **不值得** | 它假設有一個控制室和一個錄音室，也就是**兩個房間兩台耳機**。單機直播主沒有第二個房間 |
| **矩陣檢視** | 也許 | 我們的目的地數量還小到用列表看得完；等到「每條匯流排一條鏈」做完再說 |
| **punch-in / comping** | **不值得** | 需要時間軸，見 3.2 |

### 3.5 對我們來說最值得做的三件事（錄音室）

1. **延遲補償。** 理由：唯一一個「不做就是錯的」項目，而且我們已經有那個數字，只差一條延遲線和一個斷言。它同時修好 KTV 的對拍與 stem 的對齊。
2. **把 A/B 一般化成「每個目的地一條 submix + 一條處理鏈」。** 理由：TotalMix 的模型被驗證了三十年；我們的耳機補償已經證明輸出側掛鏈可行；而它一次解決 `TODO.md` 第 3 項與「直播混音跟耳機混音要不一樣」這個需求。
3. **什麼都不做，但把 talkback、punch-in、comping 明確寫進「已定案不做」。** 理由：這三個看起來像「專業功能表上缺的格子」，實際上每一個都要求我們變成另一種軟體。省下的時間比做出來的價值大。

---

## 4. 變聲

### 4.1 即時神經變聲：`TODO.md` 的結論成立，而且現在有 2026 年的數字

`TODO.md` 已定案：「即時神經變聲（fish-speech、RVC）需要遠超過一百毫秒，而這裡的期限是 2.7 ms」。

這一輪去查它還成不成立。**成立，而且更清楚了** —— 現在可以指出**架構上的下限**，不只是「目前很慢」：

| 模型 | 延遲 | 硬體 | 來源 |
|---|---|---|---|
| **Zero-VC**（2026-06，目前最低） | **演算法延遲 20 ms**（單一 20 ms 幀，零 lookahead），**不含推論時間** | RTF 在 Intel Xeon Platinum 8468V 上測 | arXiv 2606.20218，HTML 全文：「reducing algorithmic latency to a single frame (i.e., 20 ms)」「Table 4: Algorithmic latency comparison. Note that algorithmic latency does not include inference latency.」 [V] |
| **StreamVC**（Google，2024） | **70.8 ms** 端到端；最小推論幀 320 samples = **20 ms @16 kHz**；**2 幀 lookahead**；單核 CPU 上每幀運算 **10.8 ms** | Pixel 7（論文說 iPhone 8 表現相近） | arXiv 2401.03078 HTML：「we achieve a low inference latency of 70.8 ms relative to the input signal on the Pixel 7」 [V] |
| **StreamVoice**（2024） | 管線延遲 **124.3 ms**（含 80 ms chunk 等待） | — | arXiv 2401.11053（摘要 [V]；124.3 ms 這個數字來自搜尋摘要，**未在全文中親眼確認** [M]） |
| **LLVC**（Koe AI，2023） | **< 20 ms**，16 kHz，比即時快 2.8 倍 | 消費級 CPU | arXiv 2311.00873 摘要：「has a latency of under 20ms at a bitrate of 16kHz and runs nearly 2.8x faster than real-time on a consumer CPU」 [V] |
| **Seed-VC**（2024） | **演算法延遲 ~300 ms + 裝置延遲 ~100 ms**；官方表格列 **430 ms 延遲、每 chunk 推論 150 ms**；「強烈建議用 GPU」 | — | 官方 README [V] |
| **RVC / so-vits-svc** | 沒有官方延遲數字；Seed-VC 的 README 說自己是「foundationing the real-time voice conversion」自 RVC 而來 | — | GitHub API：RVC 36,781 星、2026-07 仍在動；so-vits-svc 28,155 星、**最後 push 2023-11**（已停更）[V] |

**結論，比 `TODO.md` 更強的版本**：

> 2026 年最好的即時語音轉換，**演算法延遲的理論下限是一個 20 ms 的幀，而且那還不含推論**。我們的期限是 2.7 ms。差距是 7.4 倍，而且它**不是工程問題** —— 那 20 ms 是模型的幀移，縮短它就得重新設計整個模型。所以這條路不是「等硬體變快」會通的。

這一句應該取代 `README.md` 裡「需要一個模型、一條 GPU 管線和遠超過一百毫秒」的說法，因為新版更精確也更難反駁。

### 4.2 能不能在 Apple Silicon 上跑

**沒有查到可信的一手數字。** [未查證] 這題需要在這台機器上量，不是搜尋。

已知的相關事實：

- `TODO.md` 已定案 **MLX 在命令列 SwiftPM 下建不出 Metal shader**，而且不會退回 CPU。這條沒有變。
- CoreML / ANE 有一個結構性的問題值得先想清楚 [?]：ANE 的排程是**批次導向**的，每次推論有固定的送件開銷。在 2.7 ms 的預算裡，那個開銷本身就可能吃光預算 —— 這跟 `TODO.md` 裡「2048 點的轉換是一個『啟動與同步比算術貴』的尺寸」是同一個道理。**在寫任何 CoreML 程式碼之前，該做的是量一次「最小模型的一次 ANE 推論要多久」**，那是一個下午的事，而且答案會決定整個方向。

### 4.3 不對稱：即時走 DSP、離線走神經 —— 這條路是通的

`TODO.md` 已經指出 `AUAudioMix` 「唯一沒有被量測排除的用途是對已錄好的 stem 做離線處理」。

這一輪確認了同一個結構對變聲也成立，而且**更有利**：

- 離線沒有 2.7 ms 的期限，所以上面那張表裡的每一個模型都可以用。
- 我們**已經有 per-source stem**，也就是說離線處理的輸入是乾淨的、單一說話者的、已經分離的 —— 那正是這些模型效果最好的輸入。
- Seed-VC 支援**零樣本歌聲轉換**（README：「zero-shot singing voice conversion」），GPL-3.0。 [V] 對 KTV 是直接相關的。
- 授權要看清楚：Seed-VC 是 **GPL-3.0**，so-vits-svc 是 **AGPL-3.0**，RVC 是 **MIT**。 [V]（GitHub API）我們是 MIT，**GPL/AGPL 的模型程式碼不能連進來**，只能當外部行程呼叫，或者只用權重。**這一條會決定架構，值得先確認。**

### 4.4 傳統 DSP 這邊還有沒有我們沒做的

沒有專門查證，以下標 [?]，但值得記下來當線索：

- **頻譜包絡的其他估計法**：我們用倒頻譜（低 quefrency）。另外兩條主流是 **LPC / 全極點模型**與 **True Envelope**（迭代倒頻譜）。LPC 的優點是它直接給共振峰的極點位置，所以「把第一、第二共振峰移到指定頻率」變成可能 —— 那比整條包絡等比拉伸更接近「換一個人的聲道」。**這是真的差異，而且我們的測試框架（斷言頻譜質心移動）可以直接沿用。**
- **Glottal / 聲源—濾波器分離**：把聲門激發與聲道濾波分開，可以改「嗓音品質」（氣聲、粗糙）而不是只有高低。這是「聽起來像另一個人」剩下的那一半。
- **性別轉換的實際參數**：`README.md` 已經寫了（男 110–130 Hz、女 200–220 Hz、共振峰高 15–20%），這一輪沒有找到更好的數字，也沒有找到反證。

### 4.5 對我們來說最值得做的三件事（變聲）

1. **把 4.1 那張表寫進 `README.md`，取代現在的說法。** 理由：這是零成本的，而且它把一個「我們做不到」的段落變成「這件事在架構上做不到，這是數字」—— 那是這個專案唯一的行銷方式，也是它一直在做的事。
2. **離線神經處理跑在 stem 上。** 理由：`AUAudioMix` 與神經變聲**同時**被同一個結構解鎖，而我們已經有 stem。先做一個「對錄好的 stem 跑外部模型」的管線，兩件事一起收。授權問題要先解（4.3）。
3. **LPC 共振峰估計，做成第二種包絡估計法。** 理由：這是傳統 DSP 這邊唯一一個「可能真的更好」而不是「換個寫法」的東西，它讓我們能指定共振峰的目標頻率而不只是比例，而且它完全在即時預算內。

**刻意不做**：即時神經變聲。理由見 4.1 —— 20 ms 是架構下限，不是效能問題。

---

## 5. 其他 app 做了什麼

### 5.1 Rogue Amoeba（近一年，全部從官方 release notes 讀出來 [V]）

**Audio Hijack**（<https://rogueamoeba.com/audiohijack/releasenotes.php>）：

- **ARK（Audio Routing Kit）**：「Audio Hijack now uses a new audio capture backend called Audio Routing Kit, or "ARK" for short. Thanks to ARK, Audio Hijack can be set up on a new Mac in **seconds, with no restarts or passwords required**.」
  → **`TODO.md` 把這條標 [M]，現在它是 [V]。** 我們的驅動要 sudo 又會重啟 `coreaudiod`，這件事確實已經從中性變成劣勢。
- **Transcribe 區塊**：「convert speech to text from any audio source」，後續版本加了 **99 種語言的語言選擇器**，以及一個隱藏設定「Transcription Metal Acceleration」（Apple Silicon 預設開）。 [V]
  → 逐字稿**不再是我們獨有的**。我們剩下的差異是 **per-source 的說話者歸屬**（不靠聲紋猜）與 **on-device 的 Apple 模型**。這一點要講清楚，不能再泛稱「我們有轉錄」。
- **Speech Denoise 區塊**（更早）。 [V]
- macOS 26 支援：可以擷取 Tahoe 的新 **Phone.app**（VoIP capture）。4.5.9（2026-05-19）加了 **Quo**（原 OpenPhone）。 [V]
- 一個對我們有利的已知問題，是他們自己寫的：「**Known issue with sample rate mismatches**: If an application is playing audio to an external device whose sample rate does not match that of the system's default output device…」會掉音訊。 [V]
  → **這正是我們用時脈鎖定與 `MEASUREMENT.md` 在處理的問題。** 一個 $69 的成熟產品在 release notes 裡承認取樣率不合會掉音訊，而我們有一個會回報「resampled，誤差多大」的自我檢測 —— 這是一個可以直接對比的賣點。
- 4.5.9 起**要求 macOS 14.4 以上**。 [V]

**Loopback**（<https://rogueamoeba.com/loopback/releasenotes.php>）：

- 同樣遷到 ARK，而且有一個**獨立的 ARK plugin**：「Loopback now uses a new audio capture backend called Audio Routing Kit (ARK), as well as a new ARK plugin, for all audio handling… can be set up in seconds, **with no restarts nor configuration changes necessary**」。 [V]
  → 注意：它**還是裝了一個 plugin**，只是不用重啟也不用密碼。2.4.9（2026-04）的說明更精確：ARK 13.1.1「will **prevent the need to enter your administrator password for future updates**」。 [V] 所以「第一次要密碼、之後不用」是比較接近事實的描述。
- 近一年只有維護：2.4.9（2026-04-09）、2.4.10（2026-05-07，修 ARK 的裝置間串音）。 [V]
- **仍然沒有 scripting / AppleScript / Shortcuts 的任何跡象**（release notes 裡完全沒有出現）。`TODO.md` 的 [M] 站得住。 [V-negative]

**SoundSource**（<https://rogueamoeba.com/soundsource/releasenotes.php>）：

- 6.0.0（2025-12-03）：Output Groups、**Supercharged AirPlay Streaming**（送到 HomePod / Sonos，或單一 app 走 AirPlay）、可調的選單列圖示。 [V]
- **6.1.0（2026-07-21，一週前）**：**Audio Unit Refinements**（新裝的 AU 立刻認得、v3 AU 支援改善、大量參數的 generic view 載入快很多、與 Slate VSX 等的相容性）＋ **AirPlay Refinements**（睡眠喚醒後重連、VPN 造成網路拓撲改變時自動重連、AV 同步改善）。 [V]
  → **他們現在的投資方向是 AirPlay 與第三方外掛的相容性**，不是路由能力。這是有用的情報：**AirPlay 是我們完全沒碰的一塊，而它是他們認為值得連續兩版投資的東西。**

**價格**：`TODO.md` 的 $307 這一輪沒有重新查證。 [沿用 V]

### 5.2 免費／開源的那一群 [V]（GitHub API，2026-07-28 當下的數字）

| 專案 | 星數 | 授權 | 最後 push | 近況 |
|---|---|---|---|---|
| **BlackHole** | 19,455 | NOASSERTION（實際是 GPL-3.0） | 2026-07-03 | v0.7.0（2026-06-18）加了 **24 kHz 取樣率**；v0.7.1 只動安裝腳本。**幾乎不動了** |
| **FineTune** | **8,376** | GPL-3.0 | 2026-07-09 | **動得非常快**，見下 |
| **eqMac** | 6,722 | Apache-2.0 | 2026-04-24 | 近期全是修 bug：**v1.8.15「Fixed AirPods causing eqMac to go into a device swap loop and freezing」** |
| **RVC** | 36,781 | MIT | 2026-07-23 | 仍活躍 |
| **so-vits-svc** | 28,155 | AGPL-3.0 | 2023-11-11 | **已停更** |
| **Seed-VC** | 3,891 | GPL-3.0 | 2025-04-20 | 停更中 |

**FineTune 是這一輪最該注意的競爭者。** 它的自我定位就是「Free and open-source alternative to SoundSource」，八個月從 0 到 8,376 星，而且近三個版本的內容是 [V]：

- **v1.9.0（2026-07-09）**：85 個裝置圖示可選、修了 DDC 外接螢幕音量的崩潰。
- **v1.8.0（2026-06-14）**：鍵盤直接輸入音量數值、把 macOS 的音量回饋音還回來（它攔截媒體鍵導致回饋音消失）、**裝置感知的選單列圖示**，以及 **「Bluetooth call mode no longer crackles.」—— 藍牙耳機在 A2DP 與 SCO 之間切換時的爆音**。
- **v1.7.0（2026-05-14）**：全域熱鍵，而且設計得很細：「App Volume Up/Down」作用在**目前正在發聲**的 app，不是最前景的 app。

→ 兩個直接的教訓：
1. **「作用在正在發聲的那個 app」比「作用在最前景的 app」更對**。這是一個小到不會有人寫進規格、但用起來差很多的決定。值得抄。
2. **FineTune 已經在修藍牙的爆音**，而 `TODO.md` 的「AirPods 閒置拆除」還在「這台機器上沒有 AirPods，所以還沒量到」。**別人已經在那條路上了。**

### 5.3 便宜的那一群 [V]

- **SoundPipe**：官網首頁自己寫「Buy - **$10** or `brew install --cask soundpipe`」，定位是「a mixing board for your Mac. Create virtual audio devices that send sound from any app, microphone or input device to any other app or device.」 [V]（<https://soundpipe.app/>）
  → **它已經在 Homebrew 裡了。** `TODO.md` 第 5 項（Homebrew cask）不只是「有人要求」，是「競爭者已經有了」。
- **Soundshine**：「a macOS menu bar app that lets you share your system audio (music, videos, game sounds) as a microphone input in Zoom, Google Meet, FaceTime, Discord」，$11.99 一次買斷。 [V]（<https://www.soundshine.app/>）
  → **這是一個新名字**，`TODO.md` 沒有。它只做一件事，而且那件事正好是我們做的事情的一個切片。

### 5.4 Elgato Wave Link —— `TODO.md` 最高價值的未解問題，答案是壞消息 [V]

`TODO.md` 說：「整份研究裡價值最高的未解問題：它決定『雙混音』這個語彙在這個平台上是已經被佔住，還是一塊空地。」

**已經被佔住了，而且比想像的更徹底。**

- **Wave Link 2.0 有上 macOS**，2.0.7 是 macOS Tahoe 26 的建議版本。 [M]（搜尋結果標題與摘要）
- 但重點是：**Wave Link 3.0.0 在 2026-03-03 出了 macOS 版**，而 **Wave Link 2 已經 End of Life**。官方頁逐字：「Wave Link has now been updated to version 3. This reimagining has all-new features and an improved interface overall. **Wave Link 3 is free, and will also work with a wide variety of microphones, not just those from Elgato.**」 [V]
  <https://help.elgato.com/hc/en-us/articles/44408452111505-Elgato-Wave-Link-3-0-0-macOS-Release-Notes>
- **Wave Link 3.2（macOS）** 的內容 [V]（<https://help.elgato.com/hc/en-us/articles/47158983639825-Elgato-Wave-Link-3-2-macOS-Release-Notes>）：
  - 「**Wave Link no longer runs inside the macOS App Sandbox**, which means many VST and Audio Unit plugins that previously failed to load or ran out-of-process now work correctly, with **lower plugin latency** and improved reliability.」
    → 他們遇到了跟我們一樣的問題（out-of-process AU 的成本），解法是離開沙箱。
  - 「**Improved Siri, Spotlight, and Shortcuts support.** Wave Link actions can now be discovered and run by system services without launching or foregrounding the app.」
    → **他們有 App Intents，我們沒有**（`TODO.md` 已定案 App Intents 對我們不可行，因為 shell script 組出來的 app 產生不了 metadata）。這是一個真實的落差。
  - 「**Virtual mix outputs (e.g. Personal Mix, Chat Mix) are now prefixed with "Elgato Wave Link" in macOS audio settings and third-party apps**」
    → 他們有虛擬裝置，而且是多個具名混音。
  - 還有 Wave FX DSP Equalizer、Sound Check 錄音、undo。
- 產品頁逐字 [V]（<https://www.elgato.com/us/en/s/wave-link>）：「**LIMITLESS ROUTING** Send any audio source to any output mix」「**MIX SMARTER** … Instead of vertical channels, you get a clean **horizontal matrix—sources on the left, mixes on the right**—so you can see where every signal flows」「**UP TO 5 MIXES**」

**這對我們的意義，講白**：

1. **「多混音 + 每個 app 一條 channel + 虛擬裝置 + 免費」在 macOS 上已經有了，而且是 Corsair 在做。** 我們不能再假設那是空地。
2. 但他們的**橫向矩陣**（來源在左、混音在右）恰恰是 3.1 說的 TotalMix 模型。**兩個獨立的產品收斂到同一個形狀，是這個形狀對的很強證據。**
3. 他們**沒有的**（這一輪沒看到任何跡象，標 [V-negative]，意思是「在讀過的頁面裡沒有出現」）：bit-exact 的驗證、BS.1770 響度、per-source 逐字稿、共振峰變聲、時脈鎖定、以及**任何量測**。他們的 release notes 全部是功能與修 bug，沒有一個數字。
4. **他們沒有 OBS 對接。** 這一輪讀過的 Wave Link 頁面裡沒有出現 OBS 或 websocket。這強化了主題 1 的優先度。

### 5.5 Krisp

只有行銷頁與搜尋摘要，**沒有一手技術文件**。宣稱：本機處理、accent conversion 約 200 ms、基本降噪 sub-20 ms、支援 600+ app。 [M]

**不要拿這些數字當設計依據。** 沒有論文、沒有 benchmark、沒有可驗證的來源。唯一可以安全引用的是「Krisp 把降噪、逐字稿、AI 筆記、口音轉換包在一起，而且強調全部在本機」這個**產品形狀**。

### 5.6 沒查到的

RØDE UNIFY / Connect（rode.com 對抓取回 302 無窮迴圈）、VoiceMeeter 近況、Boom 3D、Airfoil、Farrago。**這一格是空的，不是「沒有變化」。**

### 5.7 對我們來說最值得做的三件事（競爭）

1. **重新定位：不要跟 Wave Link 3 比「多混音」，跟所有人比「可驗證」。** 理由：5.4 顯示多混音已經被一個免費的、Corsair 支持的產品佔住；而 5.1–5.5 讀過的所有 release notes 與產品頁裡，**沒有任何一個競爭者提出過一個可以被別人重跑的數字**。`MEASUREMENT.md` 是這個專案唯一沒有人能在一季內抄走的東西。
2. **抄 FineTune 的「作用在正在發聲的 app」。** 理由：小、對、免費、而且是使用者按下熱鍵時真正想要的行為。
3. **Homebrew cask（`TODO.md` 第 5 項）升級優先度。** 理由：SoundPipe 用 $10 已經在 cask 裡了 [V]；FineTune 免費且八個月八千星。**散布的摩擦現在是我們最大的單一劣勢**，而它跟公證是同一件事。

---

## 6. 技術堆疊

這一節的證據等級最高：全部從 **macOS 27 SDK 的 header** 直接讀出來。

### 6.1 我們沒用到的 Apple API，而且應該用 [本機]

**(a) `CATapDescription.processRestoreEnabled`（macOS 26）—— 直接打中 OBS 的三年老 bug**

SDK header 的原文（`CoreAudio.framework/Headers/CATapDescription.h`）:

```objc
/*!	@property processRestoreEnabled
 @abstract
 True if this tap should save tapped processes by bundle ID when they exit,
 and restore them to the tap when they start up again.
 */
@property (atomic, readwrite, getter=isProcessRestoreEnabled) BOOL processRestoreEnabled
API_AVAILABLE(macos(26.0));
```

同一個檔案裡另一個 macOS 26 新增的是 `bundleIDs`（用 bundle ID 而不是 `AudioObjectID` 指定要 tap 的行程）。 [本機]

→ 這正是 OBS issue #9144「Application Capture loses audio when application reopens on MacOS」（open 三年）的解法。**我們有，他們沒有，而且兩邊都可驗證。**

**(b) CoreAudio 內建的語音活動偵測 —— 我們完全沒有用 [本機]**

`AudioHardware.h` 裡有兩個屬性，**沒有任何 `API_AVAILABLE` 標註**（在 macOS 26 與 27 兩個 SDK 裡都在，所以不是新的）：

```
kAudioDevicePropertyVoiceActivityDetectionEnable    = 'vAd+',
kAudioDevicePropertyVoiceActivityDetectionState     = 'vAdS',
```

header 的說明逐字：

> A UInt32 where 0 disables voice activity detection process and non-zero enables it.
> **Voice activity detection can be used with input audio and has echo cancellation.**
> **Detection works when a process mute is used, but not with hardware mute.**

以及 state：

> A read-only UInt32 where 0 indicates no voice currently detected and 1 indicates voice.

`grep -rn "VoiceActivityDetection" Sources/` 的結果是**空的** —— 我們一行都沒用。 [本機]

→ 三個直接的用途：
1. **「你靜音了，但你在說話」**。header 明說偵測在 process mute 下仍然有效。這是 Zoom / Teams 裡最受歡迎的小功能之一，而在這裡它是**兩個屬性**，沒有模型、沒有 CPU、沒有延遲。
2. 它**自帶回音消除**，所以它不會被喇叭的聲音騙到 —— 這比我們現在用 SoundAnalysis 分類器判斷「有沒有人在講話」在結構上更乾淨（雖然 SoundAnalysis 給的是三百類，資訊更多）。
3. 它可以當 AGC 與閘門的**第二個證據來源**，跟現有的分類器互相印證。

**(c) `kAudioDevicePropertySuggestedReferenceDevice`（macOS 27 新增）[本機]**

```
kAudioDevicePropertySuggestedReferenceDevice API_AVAILABLE(macos(27.0)) = 'eord'
```

> A Device UID CFStringRef that suggests which output device to use as a reference for echo cancellation when this input device is used with voice activity detection enabled. If not set, the system uses the system default output device.

→ 這跟我們的回音消除路徑直接相關（`README.md`：「canceller 必須同時擁有麥克風與喇叭」）。**我們的虛擬裝置可以發布這個屬性**，告訴系統該拿哪個輸出當參考 —— 那是一個只有「自己寫驅動」的人做得到的事。值得在 macOS 27 上試。

**(d) `kAudioUnitType_HeadTrackingBinauralRenderer`（macOS 27 新增，`'auht'`）[本機]** —— 頭部追蹤的雙耳算繪。跟我們現在做的事沒有交集，記著就好。

**(e) `kAUAudioMixProperty_EnableSpatialization` —— 一條我們沒試過的槓桿 [本機]**

`TODO.md` 把 `AUAudioMix` 標成「不能即時跑」，三個限制都有斷言。但 SDK header 裡有第二個屬性：

```
@constant kAUAudioMixProperty_EnableSpatialization
    Scope: Global, Value Type: UInt32, Access: Read / Write
    0 - Output format is FOA + mono foreground (Default)
    1 - Enable AUSpatialMixer to render to mono/stereo/surround formats
```

而 `Tests/YunAudioTests/EngineTests.swift` 的 `AudioMixConstraintTests` **只設了 stream format，從來沒有設過這個屬性**（grep 過，`EnableSpatialization` 在整個 repo 裡零次出現）。 [本機]

→ **這不是說 `AUAudioMix` 能即時跑了。** 輸入仍然只吃四聲道 ambisonics，而且 metadata 那一關很可能還在。但「輸出必須是五聲道」這條限制的成因，header 說得很清楚，而且說了有一個開關。**這是一個一小時的重試**，而且如果它動了，那三個斷言裡有一個要改 —— 那正是那些斷言存在的意義。

### 6.2 已經解決的一個 `TODO.md` 待查項：macOS **沒有** AirPods 高品質錄音的對應 API [本機]

`TODO.md` 問：「macOS 26 有 `AVAudioSessionCategoryOptions.bluetoothHighQualityRecording`，但 `AVAudioSession` 是 iOS 的框架，macOS 有沒有 CoreAudio 對應物未經查證。翻半小時 header 就有答案。」

**翻了。答案是沒有。** macOS 27 SDK 全框架 grep 只有三處，全部明確排除 macOS：

```
AVFAudio/Headers/AVAudioSessionTypes.h:635:
  AVAudioSessionCategoryOptionBluetoothHighQualityRecording
  API_AVAILABLE(ios(26.0))
  API_UNAVAILABLE(watchos, tvos, macCatalyst, visionos, macos) = 1 << 19

AVFoundation/Headers/AVCaptureSession.h:569:
  @property(nonatomic) BOOL configuresApplicationAudioSessionForBluetoothHighQualityRecording
  API_AVAILABLE(ios(26.0)) API_UNAVAILABLE(macos, macCatalyst, tvos, visionos);
```

CoreAudio 那邊沒有任何對應的屬性。 [本機]

→ **所以 `TODO.md` 說的那個「結構上的答案」是 macOS 上唯一的答案**：aggregate 讓 AirPods 只當輸出，麥克風由另一個裝置供應。而 `TODO.md` 也記著那個需求訊號是整份研究裡最強的（Show HN 223 分、309 則回應、至少五個專案只為這件事存在）。**這一格現在從「待查」變成「查完了，而且結論是那條路是唯一的路」。**

### 6.3 降噪：什麼能在 2.7 ms 內跑完（答案：都不能，但這問錯了問題）

| 方案 | 演算法延遲 | 運算 | 來源 |
|---|---|---|---|
| **RNNoise** | 幀式處理，48 kHz，`rnnoise_get_frame_size()` 回傳固定幀長；**幀長的實際數值這一輪沒有從原始碼確認**（`FRAME_SIZE` 定義在 grep 不到的地方） | 極輕 | GitHub README [V]；幀長 10 ms 是常識但**未查證** [?] |
| **DeepFilterNet2** | **40 ms**：「we use 20 ms windows, an overlap of 50%, and a look-ahead of two frames resulting in an **overall algorithmic delay of 40 ms**」 | **RTF 0.04**（單執行緒 Core-i5 筆電），48 kHz 全頻帶 | arXiv 2205.05474 摘要 + ar5iv 全文 [V] |
| **DeepFilterNet（demo 論文）** | 同上 | RTF 0.19（單執行緒筆電 CPU） | arXiv 2305.08227 摘要 [V] |
| **AUSoundIsolation**（我們已經在用） | **56 ms**（本機量測） | 不到 IO 期限的四分之一 | `MEASUREMENT.md` [本機實測] |
| **Krisp** | 宣稱基本降噪 < 20 ms | — | 行銷頁 [M]，**不可靠** |

**這張表的正確讀法**：沒有一個神經降噪能塞進 2.7 ms，**而這不重要** —— 因為我們已經在跑 56 ms 的 `AUSoundIsolation`，那不是塞進 IO 期限，是接受一個延遲。所以真正的問題不是「能不能塞進 2.7 ms」，是「**同樣的品質下，誰的延遲最低**」。

而答案很有意思：**DeepFilterNet2 的 40 ms 比 Apple 的 56 ms 低，而且它的 RTF 是 0.04。** [V] 授權是 Apache-2.0 / MIT 雙授權 [?]（README 提到 Apache-2.0，但**模型權重的授權沒有查證**）。

→ 這值得一次實測比較，而且我們**已經有量測工具**（`yunaudio-cli dsp`）。但它會帶進一個 Rust/ONNX 相依，那是一個真實的成本。**先量，再決定。**

### 6.4 分離：Demucs / Spleeter 對 KTV 現實嗎

- 兩個都還活著：`adefossez/demucs` MIT、2,956 星、2026-07-11 push；`deezer/spleeter` MIT、28,341 星、2026-06-18 push。 [V]（GitHub API）
- **在 Apple Silicon 上的實測速度沒有查到。** [未查證]
- **對即時不現實**，這一點不需要查：這一類模型都是整段處理，而且 Demucs 是 U-Net 加 transformer。

→ **但這正好落在 4.3 的不對稱結構裡**：離線對錄好的 stem 跑分離，是可行的，而且 KTV 需要的正是「把原唱從伴奏裡拿掉」與「把原唱的旋律抽出來當評分的基準」（`TODO.md` 第 1 項自己就寫了這個選項）。

### 6.5 VAD：Silero 比 SoundAnalysis 好嗎

- **Silero VAD** 的官方數字 [V]：「One audio chunk (**30+ ms**) takes **less than 1ms** to be processed on a single CPU thread」，訓練涵蓋 6000+ 語言，PyTorch / ONNX。
  <https://raw.githubusercontent.com/snakers4/silero-vad/master/README.md>
- 我們現在用的是 Apple 的三百類聲音分類器，它給的是「這是語音／打字／冷氣」而不只是「有沒有聲音」。

**判斷**：**不要換。** 理由有三個，而且第三個是決定性的：

1. Silero 給的資訊比較少（二元 vs 三百類），而 `README.md` 說得很清楚，我們的 AGC 之所以有效正是因為它知道「typing under your voice」。
2. 它帶一個 PyTorch/ONNX 相依，換來 30 ms 粒度的二元判斷。
3. **如果只要二元判斷，CoreAudio 自己就有（6.1(b)），零相依、零延遲、自帶回音消除。** 在「免費的系統屬性」和「要帶 runtime 的模型」之間，沒什麼好選的。

### 6.6 其他該知道的

- **macOS 26/27 的音訊新東西就這些。** 對 CoreAudio、AudioToolbox、CoreAudioTypes 三個框架的 header 做 `macos(27` 全文 grep，結果只有三個檔案有命中：`AudioHardware.h`（`kAudioDevicePropertySuggestedReferenceDevice`）、`AUComponent.h`（`kAudioUnitType_HeadTrackingBinauralRenderer`）、`AudioUnitProperties.h`（`kReverbRoomType_OutdoorGeneral`）。 [本機]
  → **這是一個有價值的負面結果**：macOS 27 在音訊上幾乎沒動。我們不需要為了「跟上新 API」做任何事。
- Apple 官方的 "Audio Toolbox updates" 與 "AVFAudio updates" 文件頁**最後一次更新停在 2024 年 6 月**（內容是 AUSpatialMixer 的頭部追蹤）。 [V]
  → **不要用 Apple 的 updates 頁當情報來源，它是舊的。** header 才是真的。

### 6.7 對我們來說最值得做的三件事（技術堆疊）

1. **接上 CoreAudio 的 `vAd+` / `vAdS`，第一個功能做「靜音時偵測到你在說話」。** 理由：兩個屬性、零相依、零延遲、自帶回音消除，而且做出來的是一個所有人都認得而且喜歡的功能。這是這一輪投入產出比最高的一項。
2. **`processRestoreEnabled` + `bundleIDs`（macOS 26）。** 理由：它把「被 tap 的 app 重開後自動接回來」變成一個屬性，而那正是 OBS open 了三年的 #9144。功能小，故事大，兩邊都可驗證。
3. **重試 `AUAudioMix`，這次設 `EnableSpatialization = 1`。** 理由：一小時的事，而且它是唯一一條可能鬆動那三個斷言的槓桿。就算失敗，也把「試過了」寫進斷言裡 —— 那正是那個測試套件存在的理由。

---

## 7. 如果只能做五件事

排序依據：**修正錯誤 > 別人抄不走的差異化 > 除掉最大的劣勢 > 新功能**。每一項都說明為什麼它排在別的前面。

### 第一：延遲補償 —— 讓 tap 的路徑對齊麥克風的處理鏈

**為什麼是第一**：因為它不是功能，是**現在就是錯的**。麥克風經過 11 級效果鏈（人聲隔離一級就 56 ms），被 tap 的伴奏一級都沒經過，兩者在混音與錄音裡都錯開。在 KTV 的情境下這叫「人聲比伴奏晚」，而唱歌的人會為此搶拍。

**為什麼便宜**：我們已經算好那個數字（`EffectChain.latencyFrames`，把每個 AU 的 `kAudioUnitProperty_Latency` 加起來），它現在只被拿去顯示。缺的是 tap 路徑上的一條延遲線。

**為什麼符合這個專案**：它可以被斷言 —— 送一個脈衝進兩條路徑，量到達幀差，斷言是 0。`AGENTS.md` 說「A change is done when something measures it」，這一項天生就是那個形狀。

### 第二：OBS 對接的第一版 —— websocket 客戶端 + browser overlay

**為什麼排在第二而不是第一**：因為第一項是修正確性，這一項是加價值。但它排在其他所有新功能前面，理由有三個：

1. **實作沒有未知數。** 主題 1 已經把協定、認證、每一個請求的欄位、事件訂閱的位元值、browser source 的設定鍵、vendor 事件的推送路徑全部查清楚了。這是一份可以直接照著寫的規格。
2. **競爭者沒有。** Wave Link 3 有多混音、有虛擬裝置、有 Shortcuts，**但這一輪讀過的所有頁面裡沒有出現 OBS**。Rogue Amoeba 那一疊也沒有。
3. **它讓其他每一項都有地方顯示。** 歌詞、分數、電平、響度建議 —— 這些現在只能在我們自己的視窗裡看，而直播主在看 OBS。

**第一版的範圍**：連線 + 認證 + 把來源建好 + 音量／靜音雙向同步 + 一張 overlay。**不要**第一版就做完整的場景管理。

### 第三：CoreAudio 的 `vAd+` / `vAdS`，加上「靜音時你在說話」

**為什麼排第三**：它是這一輪投入產出比最高的一項 —— 兩個 CoreAudio 屬性，沒有模型、沒有相依、沒有延遲，而且 header 明說它在 process mute 下仍然有效、而且自帶回音消除。做出來的是一個所有人都認得的功能。

**為什麼不排更前面**：因為它是一個好功能，不是一個結構性的差異。前兩項改變這個產品是什麼；這一項讓人喜歡它。

**順帶**：`processRestoreEnabled` + `bundleIDs`（macOS 26）跟它是同一趟 CoreAudio 的活，應該一起做 —— 那一項直接對上 OBS open 了三年的 #9144。

### 第四：散布 —— 公證 + Homebrew cask，以及 tap-only 模式的設計

**為什麼是第四而不是更後面**：因為證據顯示這已經是我們最大的單一劣勢，而且是**唯一一個會讓前三項白做**的劣勢 —— 沒有人裝得起來，做什麼都沒用。

證據，全部這一輪查證：

- Audio Hijack 的 ARK：「set up on a new Mac in **seconds, with no restarts or passwords required**」[V]。我們要 sudo 而且會重啟 `coreaudiod`。
- SoundPipe 用 **$10** 而且**已經在 Homebrew cask 裡**（`brew install --cask soundpipe`）[V]。
- FineTune 免費、GPL-3.0、八個月 8,376 星、每月出版本 [V]。
- OBS 自己的 SCK 擷取**完全不用驅動** [V]。

**「tap-only 模式」的設計判斷**：`TODO.md` 已經把它列為「值得先探一下」。這一輪的證據把它從「也許」推到「應該」—— 因為我們這個應用程式裡不需要驅動的部分（tap、效果、錄音、轉錄、監聽、OBS 對接、歌詞、響度）已經是絕大多數，而**驅動買到的東西（bit-exact 與時脈鎖定）正好是我們唯一沒人抄得走的東西**。所以正確的形狀是：免安裝的一級模式 + 「裝驅動換到可證明的路徑」這個升級 —— 而升級的說服力來自 `MEASUREMENT.md`。

### 第五：離線神經處理跑在 stem 上

**為什麼是第五**：因為它是唯一一個「新的能力」而不是「修正、對接、除障」，而且它的前置條件（per-source stem）我們已經有了。

**為什麼現在做而不是更早**：因為主題 4 現在有了乾淨的分界線。即時那一邊已經確定關死了 —— **2026 年 6 月的 SOTA（Zero-VC）演算法延遲的理論下限是一個 20 ms 的幀，而且不含推論**，對比我們的 2.7 ms。所以「即時走傳統 DSP、離線走神經」不是妥協，是**經過量測的架構決定**，而這個專案的整個風格就是把這種決定寫下來。

**一趟解鎖兩件事**：同一條離線管線同時讓 `AUAudioMix`（`TODO.md`：「唯一沒有被量測排除的用途是對已錄好的 stem 做離線處理」）、神經變聲、與人聲／伴奏分離（KTV 評分需要的旋律基準）變得可行。

**要先解的一件事**：授權。Seed-VC 是 GPL-3.0、so-vits-svc 是 AGPL-3.0、RVC 是 MIT [V]，而我們是 MIT。這決定了「連進來」還是「當外部行程呼叫」，而那是架構問題，該在寫任何程式碼之前定案。

---

### 落選的，以及為什麼

- **即時神經變聲** —— 20 ms 是架構下限，不是效能問題（4.1）。
- **Talkback / punch-in / comping** —— 每一個都要求我們變成另一種軟體（3.5）。
- **寫 OBS 原生外掛** —— websocket 已經夠了，而外掛會把我們綁進 OBS 的建置與 ABI（1.7）。
- **換掉 SoundAnalysis 改用 Silero VAD** —— 資訊變少、相依變多，而且如果只要二元判斷，CoreAudio 自己就有（6.5）。
- **接直播平台彈幕做點歌** —— 平台相依、會變、法遵不明，而且跟音訊沒有關係（2.5）。
- **跟 Wave Link 3 比多混音** —— 那塊地已經被一個免費的、Corsair 支持的產品佔住了（5.4、5.7）。

---

## 8. OBS：這一輪把研究變成決定與程式碼

前面第 1 節是「OBS 能怎麼接」。這一節是**接了什麼、沒接什麼、以及每一項的理由**，
外加**在這台機器上量到的數字**。

**這台機器上沒有裝 OBS。** 所以下面每一條都標明它被驗證到什麼程度，而且**沒有任何
一條可以宣稱「跟 OBS 對接是通的」**。要驗到那一步，需要一個人執行：

```bash
brew install --cask obs
```

裝好之後要做的事，照順序：打開「工具 → WebSocket 伺服器設定」，勾選啟用、複製密碼；
在偏好設定的「直播」頁填入位址與密碼、按「連線」；在 OBS 建一個
`coreaudio_input_capture` 指向這個 app 的裝置；回來按「送給 OBS」，然後到 OBS 的
「進階音訊屬性」看那一路的同步偏移欄位是不是變成了負的那個毫秒數。

### 8.1 做了什麼

**(a) `CATapDescription.processRestoreEnabled` + `bundleIDs` —— 已接上，已量測**

`RESEARCH.md` 6.1(a) 與 `TODO.md` 第 5 項都把這條留著沒做。現在做了，而且**量到一件
把整條結論翻過來的事**：

```
$ yunaudio-cli tap-restore Spotify
tap uid          0A59DA8D-389C-4C67-BFDB-F4DADA043314
asked to restore com.spotify.client
HAL kept restore true
HAL kept bundles com.spotify.client
```

而且：

| 給 HAL 的東西 | HAL 讀回來的 |
|---|---|
| 什麼都沒設 | `processRestoreEnabled = true`、`bundleIDs = []` |
| 明確設 `false` | `false` |
| `bundleIDs` + `true` | 兩者都留著 |
| 只有 `bundleIDs`、旗標設 `false` | `false`，但 bundleIDs 留著 |

**`processRestoreEnabled` 的預設值就是 `true`。** 也就是說這個 app 從頭到尾建的每一個
tap 都已經開著它，而且什麼都沒還原 —— 因為 `bundleIDs` 預設是空的，沒有東西可以記。
**真正缺的那一半一直是 `bundleIDs`，不是那個旗標。** 只設旗標會是一個「看起來完全像
修好了」的零效果修改。這件事寫進了 `ProcessTapRestoreTests`，所以哪天 macOS 改了預設
值，會有人知道。

還有一條直接對上 OBS #9144 的能力：**可以替一個沒有在跑、甚至沒有裝的 app 建 tap**
（`processIDs: []` + `bundleIDs: ["com.yuhuanstudio.nothing.at.all"]`，HAL 回 `noErr`）。
沒有 `bundleIDs` 就辦不到，因為沒有 process object 可以指。

**還沒驗到的**：「app 重開之後音訊真的回來」需要有人去關掉再打開一個應用程式。
`yunaudio-cli tap-restore <名字> --watch` 就是為此準備的，它會盯著 tap 的 process 清單
掉下去再回來。

**(b) `obs-websocket` v5 客戶端（`Sources/YunAudioOBS/`）**

`URLSessionWebSocketTask` + CryptoKit，**零第三方相依**。協定是逐行讀 obs-websocket
自己產生的 `protocol.md`，不是抄客戶端函式庫。

驗證到什麼程度，分三層講清楚：

1. **認證字串**：用協定文件自己那組 challenge/salt/password（`supersecretpassword`）
   算出來的答案，**文件沒有公布答案**，所以答案是用 Python 的 `hashlib` 與 OpenSSL
   各算一次、兩邊相同才寫進斷言的：
   `1Ct943GAT+6YQUUX47Ia/ncufilbe6+oD6lY+5kaCu4=`。中間值（base64 secret）也單獨斷言，
   否則兩層雜湊哪一層錯都會回報同一個失敗。
2. **完整握手，走真的 socket**：`Tests/YunAudioTests/OBSStubServer.swift` 用
   `Network.framework` 的 `NWProtocolWebSocket` 架了一個**會像 obs-websocket 一樣回話
   的伺服器**，然後這個客戶端對它跑完 `Hello → Identify → Identified → Request →
   RequestResponse`。**六個測試全過**，包括：密碼錯誤要在伺服器直接關連線的情況下變成
   「OBS 拒絕了密碼」而不是逾時；沒有密碼的伺服器不能被強制要求密碼；OBS 說不（狀態碼
   204）要跟傳輸失敗分開；關掉的埠要**立刻**失敗而不是轉圈。
3. **完全沒驗**：真的 OBS。stub 是照文件寫的，文件錯了它就跟著錯。

`EventSubscription::All` 是 **4095**（bit 0–11，含 macOS 版沒人提過的 `Canvases`），
**不含** `InputVolumeMeters`（`1 << 16` = 65536）。這一條有斷言，因為把「全部」寫成
`~0` 的客戶端會意外訂到每 50 毫秒一則的電平事件。

**(c) 同步偏移 —— 這一輪唯一「別人做不到」的東西**

`OBSSyncOffset.forProcessingLatency(frames:sampleRate:)`。斷言：2688 frames @ 48 kHz
= **−56 ms**（就是人聲隔離那 56 ms）；同樣 frame 數 @ 96 kHz = −28 ms；chain 為 0 時
是 0；超過 950 ms 夾在 −950（那是 obs-websocket 文件寫的下限）。四捨五入到整數毫秒，
因為 OBS 的「進階音訊屬性」是整數毫秒的數字框，送一個小數進去等於送一個使用者看到
的是別的數字、而且打不回來的值。

**符號是負的**，而且理由要寫清楚：麥克風**真的**晚了那麼久，OBS 沒辦法讓它早到，但
可以被告知「把這段聲音當成更早發生的」。這個方向**沒有在真的 OBS 上驗證過**。

`stub` 測試把這條從 `RoutingEngine` 的 frame 數一路量到別人協定裡的欄位名：
送出去的 `SetInputAudioSyncOffset.inputAudioSyncOffset` 就是 −56。

**(d) 靜音鏡射與偏好設定頁**

偏好設定多了一個「直播」分頁（`PreferencesWindow.Section.streaming`）。它自動被離線
算繪檢查涵蓋（`PanelRenderer` 跑 `Section.allCases`），深淺兩色都看過了。
文字欄位在算繪分支換成唯讀列 —— 因為 `TextField` 在 `ImageRenderer` 底下畫成一條黃色
禁止標誌，會讓整個分頁的色彩檢查失明。

### 8.2 刻意不做，以及為什麼

- **OBS 原生外掛** —— 1.7 已定案，不改。
- **browser source overlay + 自動建場景**（1.3、1.7 第 1、2 項）。**這一輪不做。**
  理由不是它不好，是**它在這台機器上一個字都驗不了**：要驗它需要 OBS、一個場景、一個
  瀏覽器來源，而且它的產出是一張網頁的外觀。`TODO.md` 說得很清楚，這個專案現在的問題
  是「功能已經多到沒有全部被驗證過」，再加一個完全無法驗證的表面是往反方向走。
  **它應該在有人裝了 OBS、而且願意看著畫面驗收的那一次做。**
- **鏡射 OBS 的電平表**（`InputVolumeMeters`）。訂閱常數留著，但不建介面：那是每 50
  毫秒一則的高流量事件，換來的是**同一件事的第二個真相** —— 這裡自己的電平取樣率更高
  而且量的是處理前的訊號。兩個電平表不一致的時候，沒有人會知道該信哪一個。
- **OBS 的六軌錄音模型。** `MAX_AUDIO_MIXES` 是 libobs 的編譯期常數，是**別人的
  muxer 上限**。這裡的 stem 是檔案，數量沒有上限。把六軌的概念搬進來等於繼承一個
  我們沒有的限制。`OBSRecordingTracks.count = 6` 與 `OBSRequest.setTracks` 留著，
  因為**指派 OBS 的軌**是對的（那是 OBS 的東西），**照著它重新設計自己的錄音**不是。
- **每個來源一條 OBS 濾鏡鏈。** 同樣是兩個真相的問題：這裡有自己的效果鏈，而且知道
  它的延遲；OBS 的濾鏡鏈這裡量不到延遲。同時開兩條，同步偏移那個數字就不再正確。
- **把 OBS 的動詞加進 `RemoteCommand`。** `RemoteCommand` 是這個 app **答應要一直支援**
  的詞彙；obs-websocket 是**別人可以改**的詞彙。混在一起等於把別人的發版節奏放進自己
  的相容性承諾裡。`YunAudioOBS` 因此是獨立的 target，只依賴 `YunAudioControl` 的
  `JSONValue`。

### 8.3 OBS 的音訊介面，逐項對照（誠實版）

| OBS 有的 | 這裡有沒有 | 判斷 |
|---|---|---|
| 每來源推桿（dB）、靜音 | 有（`routeGains` / `routeMutes`，底 −40 dB） | 平手 |
| 每來源 solo | OBS **沒有**；這裡有 | 這裡多 |
| 每來源監聽三態（關／只監聽／監聽並輸出） | **部分** —— 這裡是「每來源一個連續的 dB 送出量」到單一監聽裝置。**「只監聽」表達不出來**，因為靜音會同時掐掉兩條混音 | **真的缺一格**，見 8.4 |
| 每來源同步偏移（ms） | **沒有** —— 只有一個全域的 `alignmentFrames`，而且是自動從鏈的延遲算的 | 這裡的自動比 OBS 的手動好，但**手動覆寫沒有** |
| 每來源平衡 / 單聲道下混 | 沒有 | 小，值得補 |
| 每來源濾鏡鏈 | 沒有（鏈是全域的、只掛麥克風） | 已在 `TODO.md` 第 3 項 |
| 六軌指派 | 沒有，也不要 | 見 8.2 |
| 每匯流排處理 | **這裡有，OBS 沒有**（每個輸出一條 10 段 EQ + 耳機補償） | 這裡多 |
| 每輸出延遲 0–500 ms | **這裡有，OBS 沒有** | 這裡多 |
| 錄音格式／編碼器分離 | 這裡是 wav / flac / aac 三選一，沒有分開的編碼器設定 | OBS 的分離是為了它的 muxer；這裡不需要 |
| 電平表衰減速率、峰值型式（sample / true peak） | 沒有 | **不值得**：那是 OBS 拿來省 CPU 的設定，這裡的電平表已經是 true peak 而且成本已經量過 |

### 8.4 一個小而真實的缺口：「只監聽」

OBS 的 `OBS_MONITORING_TYPE_MONITOR_ONLY` 是「我聽得到，對面聽不到」。這裡表達不出來，
因為 `setMuted(_:for:)` 掐的是 route，而 route 同時餵主混音和監聽。

值不值得補：**值得**，而且很便宜 —— 監聽的 route 索引已經是分開存的
（`monitorRouteIndices`），所以「靜音但保留監聽送出量」就是**只把非監聽的那幾條 route
靜音**。它可以被斷言：靜音之後監聽匯流排的電平不變，主匯流排的變成零。

**沒有在這一輪做**，因為它動的是 `RouterModel` 的靜音語意，而那是別的 agent 正在動的
區域。列進 `TODO.md`。
