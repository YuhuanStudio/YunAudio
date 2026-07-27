# Seiren V3 Pro — 功能歸屬對照表（哪些在裝置、哪些在主機）

這份文件回答一個問題：**Synapse 的每個功能，到底是送指令給麥克風，還是在 PC 上做 DSP？**

答案決定你在 macOS 上要「發指令」還是「自己寫 DSP」。

擷取日期：2026-07-27

---

## 總結論

Razer 把功能拆成**三條完全獨立的控制路徑**，彼此不共用協議：

| 路徑 | 傳輸方式 | 負責什麼 |
|---|---|---|
| **A. HID** | Interface 3, UsagePage `0xFF53`, Feature report `0x07` | **只有燈效** |
| **B. USB 控制端點 (EP0)** | UAC2 class request + vendor request | 音量、靜音、取樣率、監聽、虛擬混音、裝置模式 |
| **C. 主機端 DSP** | 完全不碰裝置 | **EQ、降噪、語音閘、人聲清晰度、音量正規化、高通濾波** |

⚠️ **最重要的一點**：Synapse 上那些「聽起來像麥克風功能」的東西 —— EQ、環境降噪、人聲清晰度、音量正規化 —— **全部是 PC 上跑的 THX APO，不是裝置指令**。macOS 上沒有對應的裝置指令可以發，必須自己實作 DSP。

---

## 逐項對照

| Synapse 功能 | 在哪裡執行 | macOS 怎麼做 |
|---|---|---|
| 燈環顏色／效果 | ✅ 裝置韌體 | HID feature report `0x07`（見 REFERENCE.md §6） |
| 麥克風增益 | ✅ 裝置 | UAC2 Feature Unit **7**，或 CoreAudio volume |
| 麥克風靜音 | ✅ 裝置 | UAC2 Feature Unit **7** master mute |
| 耳機輸出音量 | ✅ 裝置 | UAC2 Feature Unit **3** |
| 零延遲監聽（開關／音量） | ✅ 裝置 | UAC2 Feature Unit **10** → Mixer Unit **11** |
| 取樣率切換 | ✅ 裝置 | UAC2 Clock Source **1** |
| 裝置模式（Basic / Advanced） | ✅ 裝置 | EP0 **vendor** request（非標準 UAC2） |
| 虛擬混音通道（9 組立體聲） | ✅ 裝置 | EP0 vendor request + 多聲道 alt setting |
| **EQ（含 presets）** | ❌ **主機 DSP** | 自己實作 |
| **環境降噪 / Ambient Noise Reduction** | ❌ **主機 DSP** | 自己實作 |
| **語音閘 / Voice Gate** | ❌ **主機 DSP** | 自己實作 |
| **人聲清晰度 / Vocal Clarity** | ❌ **主機 DSP** | 自己實作 |
| **音量正規化 / Volume Normalization** | ❌ **主機 DSP** | 自己實作 |
| **高通濾波 / Highpass** | ❌ **主機 DSP** | 自己實作 |
| THX Spatial Audio（播放端） | ❌ 主機 DSP | 自己實作或不做 |

---

## 證據

### B 路徑 — `RzNative_058e_v1.0.12.0.dll`（裝置專屬模組）✅

Synapse 為 Seiren V3 Pro 載入的原生模組（product ID **1422**）。
匯入表顯示它**完全不碰 HID**，走的是 Thesycon USB Audio 驅動 API：

```
TUSBAUDIO_AudioControlRequestGet / TUSBAUDIO_AudioControlRequestSet   ← UAC2 class request
TUSBAUDIO_ClassVendorRequestIn  / TUSBAUDIO_ClassVendorRequestOut     ← EP0 vendor request
TUSBAUDIO_GetSupportedSampleRates / TUSBAUDIO_SetSampleRate
TUSBAUDIO_GetVolume / SetVolume / GetMute / SetMute / GetVolumeMuteInfo
TUSBAUDIO_GetCurrentSampleRate / TUSBAUDIO_GetCurrentStreamFormat
TUSBAUDIO_SetHwChannelHiddenFlags
TUSBAUDIO_LoadFirmwareImageFromFile / GetFirmwareImage / GetFirmwareImageSize
```

匯出函式（= Synapse 能對這台裝置做的**全部**硬體操作）：

```
DeviceInitialize      DeviceTerminate       GetDLLVersion
GetMode               SetMode                              ← Basic / Advanced
GetDeviceVolume       SetDeviceVolume
GetDeviceMute         SetDeviceMute
SetMasterSampleRate
SetMicMonitorEnable   SetMicMonitorLevel                   ← 零延遲監聽
SetMixEnable          SetMixLevel          SetStreamMixMonitor
SetPlaybackExternal
GetLevelMeter         SetLevelMeterEnable  SetLevelMeterPumpInterval
OpenAppsVolume        OpenAudioProperties
FreeMalloc            SetDebugToFile       SetNodeFFIEvent
```

**注意這裡沒有任何 EQ / 降噪 / 閘門相關函式** —— 這就是它們不在裝置端的直接證據。

### C 路徑 — `ThxV3Native_v1.0.41.1.dll`（THX DSP）✅

PDB 路徑：`C:\src\apo2\VSSettings\Src\THXServiceFactory.cpp`
→ **APO2 = Windows Audio Processing Object**，跑在 Windows 音訊引擎裡的主機端 DSP。

匯入表：`KERNEL32, USER32, SHELL32, ole32, SETUPAPI, RPCRT4, ADVAPI32, IPHLPAPI, WS2_32`
→ **沒有任何 USB / HID / Thesycon 相依**。它靠 protobuf over RPC 跟 THX service 溝通
（字串中可見 `.thx.sa.PresetService`、`.thx.sa.RoomService`、`.thx.sa.EmitterService`）。

麥克風處理鏈的完整匯出（每個都有 Get/Set 與 Level 變體）：

```
SetCaptureEQ            SetCaptureEQGains          SetMicEQGains
SetCaptureHighpass      SetCaptureHighpassLevel
SetCaptureNoiseReduction        + Level
SetCaptureVoiceGate             + Level
SetCaptureVocalClarity          + Level
SetCaptureNormalization         + Level
SetCaptureSidetone              + Level  + SetCaptureSidetoneConfig
SetCapturePreset        GetCapturePresetList       SetCapturePreview
SetCaptureVolume        SetCaptureMute             (+ *BySystem 變體)
SetCaptureParam         GetCaptureParam            GetMicParam
```

播放端 THX Spatial（同樣是主機 DSP）：
```
SetRenderEQGains  SetRenderBassBoost  SetRenderTilt  SetRenderNormalization
SetRenderVocalClarity  SetRenderSpatialProcessing  SetRenderRoom / RoomType
SetHRTFState  SetReverbTail  SetDRCEnabled  SetDialogEnhanceEnabled
SetHighShelfGain / SetHighShelfFrequency  SetRenderListeningMode
GetCurrentModeEQGains / SetCurrentModeEQGains   ← std::array<float,10> = 10-band EQ
```

`GetCurrentModeEQGains` 的型別簽章是 `std::array<float,10>` → **THX EQ 是 10 段，浮點增益**。

---

## 裝置內部音訊路由（來自 `RzNative_058e.log`）✅

模組啟動時會把裝置的完整拓撲印出來。這是 UAC2 descriptor 看不到的內部結構：

```
DeviceOutput (3 個):
  Device_HP          Pin 5, ch 0,  2 ch   FU 3   volume  -16384 .. 0     step 1
DeviceInput (3 個):
  Device_Mic         Pin 1, ch 0,  1 ch   FU 7   volume       0 .. 9216  step 1
  Device_MicDry      Pin 1, ch 1,  1 ch   FU 7   volume       0 .. 9216  step 1
  Device_MicPostExp  Pin 1, ch 2,  1 ch   FU 7   volume       0 .. 9216  step 1
AppRecording (3):
  Microphone         Pin 4, ch 0,  1 ch
AppRecordingVirtual (4):
  StreamMix          Pin 6, ch 0,  2 ch
  PlaybackMix        Pin 6, ch 2,  2 ch
AppPlayback (3):
  Headphones         Pin 0, ch 0,  2 ch
AppPlaybackVirtual (18):
  System   Pin 2, ch 0     Music    Pin 2, ch 2     Game     Pin 2, ch 4
  VoiceChat Pin 2, ch 6    Browser  Pin 2, ch 8     SoundEffects Pin 2, ch 10
  Aux1     Pin 2, ch 12    Aux2     Pin 2, ch 14    Aux3     Pin 2, ch 16
```

**三路麥克風輸出很關鍵**：`Device_Mic`（處理後）、`Device_MicDry`（乾訊號）、
`Device_MicPostExp`（**經過裝置內建 expander 之後**）。
這三路對應 UAC2 descriptor 裡 Interface 2 alt 3 的 **3-channel IEEE_FLOAT** 串流 ——
也就是說，開 alt 3 就能同時拿到這三路訊號。

⚠️ **INFERRED**：`Device_MicPostExp` 的存在代表**裝置本身有一顆 expander**（雜訊閘的一種）。
所以並非「所有降噪都在主機」—— 裝置提供了一個硬體 expander tap，
但 Synapse UI 上的「環境降噪 / 語音閘」滑桿控制的是主機端 THX 鏈，不是這顆。
要確認裝置 expander 是否可調、以及怎麼調，需要側錄 EP0 vendor request（見下）。

音量換算（UAC2 標準，1/256 dB）：
- `Device_HP`：`-16384 .. 0` → **-64.0 dB .. 0 dB**
- `Device_Mic`：`0 .. 9216` → **0 dB .. +36.0 dB** 增益

---

## macOS 實作建議

**能直接用系統 API 拿到的（不需逆向）**
- 音量／靜音／取樣率 → CoreAudio（`AudioObjectSetPropertyData`）
- 三路麥克風訊號 → 選 Interface 2 alt 3，取 3-channel stream
- 完整取樣率清單 → `kAudioDevicePropertyAvailableNominalSampleRates`

**需要自己實作 DSP 的（Razer 也是在主機做）**
- EQ（THX 用 10 段浮點增益）
- 降噪、語音閘、人聲清晰度、音量正規化、高通
- 這些你完全自由發揮，不必模仿 Razer 的參數

**需要 USB 逆向的（剩餘未知）**
- `SetMode`（Basic / Advanced）的 EP0 vendor request 格式
- 虛擬混音通道的啟用與音量（`SetMixEnable` / `SetMixLevel`）
- `SetHwChannelHiddenFlags`
- 裝置內建 expander 的參數（若可調）

這些都走 **EP0 vendor control transfer**，不是 HID —— 所以先前規劃的 USBPcap 側錄
仍然有價值，但要抓的是**control transfer**，不是 HID interrupt。
在 macOS 上，這些請求可用 `IOUSBHostDevice` 的 `deviceRequest` 發送。

---

## 附錄：本次分析的檔案

```
dlls/RzNative_058e_v1.0.12.0.dll     裝置專屬模組（product 1422）
dlls/RzAudioUtil_v1.0.3.1.dll        THX 虛擬音訊路由
dlls/ThxV3Native_v1.0.41.1.dll       THX DSP 引擎（APO）
dlls/*.strings.txt                   各 DLL 的字串傾印
logs/RzNative_058e.log               裝置模組執行日誌（含完整內部拓撲）
synapse/electron__Protocol__*.js     protocol25 常數與狀態碼
```

產品 ID 對照：**1422 = Seiren V3 Pro**（`RzNative_058e`），1347 = Seiren V2 X（`RzNative_0543`）
模組下載位置：`https://apps.razer.com/synapse/products/<id>/mw/installer-manifest.json`
