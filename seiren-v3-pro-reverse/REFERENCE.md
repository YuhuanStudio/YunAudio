# Razer Seiren V3 Pro — 裝置參考資料

擷取日期：2026-07-27　來源機器：Windows 11，Synapse 4 (RazerAppEngine 4.0.698)

取得方式：全部透過 Windows 原生 API（SetupAPI / USB hub IOCTL / HID API）與 Synapse
`app.asar` 靜態解包取得，**沒有做 USB 封包側錄**。

標記說明：
- ✅ **CONFIRMED** — 直接從裝置或韌體 descriptor 讀出
- ⚠️ **INFERRED** — 由單一樣本或結構推導，尚需第二筆資料佐證

---

## 1. 裝置識別 ✅

| 項目 | 值 |
|---|---|
| VID / PID | `0x1532` / `0x058E` |
| bcdDevice | `0x0100` |
| bcdUSB | `0x0200`（USB 2.0，實測 high-speed） |
| bDeviceClass | `0xEF` / `0x02` / `0x01`（Misc / Common / IAD 複合裝置） |
| bMaxPacketSize0 | 64 |
| Manufacturer | `Razer` |
| Product | `Razer Seiren V3 Pro` |
| Serial | `2022123456` |
| 設定數 | 1（`bConfigurationValue = 1`，bus-powered 標示 `0x80`，MaxPower 100 mA） |

Device descriptor 原始位元組：
```
12 01 00 02 EF 02 01 40 32 15 8E 05 00 01 01 02 03 01
```

---

## 2. 介面配置總覽 ✅

`wTotalLength = 537`，4 個介面。IAD：interface 0–2 群組為 Audio（protocol `0x20` = UAC **2.0**）。

| Interface | Alt | Class | 說明 |
|---|---|---|---|
| 0 | 0 | Audio / AudioControl | 控制平面，含 interrupt IN `0x84` |
| 1 | 0–3 | Audio / AudioStreaming | **播放（host → 裝置）**，耳機回放 |
| 2 | 0–3 | Audio / AudioStreaming | **錄音（裝置 → host）**，麥克風 |
| 3 | 0 | HID | 廠商控制通道（燈效／設定） |

完整 config descriptor 原始檔：`config_desc_0.bin`（537 bytes）

---

## 3. UAC 2.0 音訊拓撲 ✅

```
CLOCK_SOURCE  id=1   Internal programmable, bmControls=0x03
                     → Sample Frequency Control 可讀可寫（host 可設定取樣率）

── 錄音路徑（麥克風 → USB）────────────────────────────────
INPUT_TERMINAL   id=6   type=0x0201 Microphone   3 ch, chConfig=0x07 (FL,FR,FC)
  └─ FEATURE_UNIT id=7  src=6   master:Mute(rw)  ch1-3:Volume(rw)
       └─ OUTPUT_TERMINAL id=8  type=0x0101 USB Streaming   → Interface 2

── 播放路徑（USB → 耳機孔）────────────────────────────────
INPUT_TERMINAL   id=2   type=0x0101 USB Streaming  3 ch, chConfig=0x07
  └─ (經 MIXER_UNIT id=11)
       └─ FEATURE_UNIT id=3  src=11  master:Mute(rw)  ch1-3:Volume(rw)
            └─ OUTPUT_TERMINAL id=4  type=0x0301 Speaker

── 直接監聽路徑 ──────────────────────────────────────────
FEATURE_UNIT id=10  src=6（直接吃麥克風）  master:Mute(rw)  ch1-3:Volume(rw)
MIXER_UNIT   id=11  nrInPins=2, sources=[10, 2], nrChannels=3
```

**這就是零延遲直接監聽（direct monitoring）的實作**：Feature Unit 10 直接從麥克風
Input Terminal 6 取訊號，與 USB 播放訊號（Input Terminal 2）在 Mixer Unit 11 混合後
送到耳機輸出。你的 macOS 軟體要做監聽音量控制，就是操作 **Feature Unit ID 10**。

Feature Unit 控制位元（三個 FU 都一樣）：
- master channel (ch 0)：`bmaControls = 0x00000003` → **Mute 可讀可寫**
- ch1 / ch2 / ch3：`bmaControls = 0x0000000C` → **Volume 可讀可寫**

⚠️ **INFERRED**：MIXER_UNIT id=11 的 raw bytes 為
`10 24 04 0B 02 0A 02 03 07 00 00 3F 00 00 00 00`。按 UAC2 規範解析，
`bmChannelConfig` 落在 offset 8–11 = `0x3F000007`，這個值不符合常見的
spatial-location 編碼；且 `bmMixerControls` 只剩 1 byte，但 6 入 × 3 出需要 18 bits。
Razer 這段 descriptor 寫得不完全合規，實作時建議以實測行為為準，不要硬套規範解析。

---

## 4. 音訊串流格式 ✅

### Interface 1 — 播放（Endpoint `0x01` OUT, Isochronous **Async**, bInterval=3）
搭配 feedback endpoint `0x83` IN（Isochronous Feedback, bInterval=4, 4 bytes）

| Alt | 格式 | 聲道 | 容器 | 有效位元 | wMaxPacketSize |
|---|---|---|---|---|---|
| 1 | PCM | 2 (FL,FR) | 4 bytes | 24 bits | 392 |
| 2 | PCM | 2 (FL,FR) | 4 bytes | 32 bits | 392 |
| 3 | IEEE_FLOAT | 3 | 4 bytes | 32 bits | 588 |

### Interface 2 — 錄音（Endpoint `0x81` IN, Isochronous **Async**, bInterval=3）

| Alt | 格式 | 聲道 | 容器 | 有效位元 | wMaxPacketSize |
|---|---|---|---|---|---|
| 1 | PCM | 1 | 4 bytes | 24 bits | 196 |
| 2 | PCM | 1 | 4 bytes | 32 bits | 196 |
| 3 | IEEE_FLOAT | 3 | 4 bytes | 32 bits | 588 |

**取樣率** ✅ **CONFIRMED — 直接向裝置查詢**

透過 Razer 自帶的 Thesycon API（`RazerSeirenV3Proapi_x64.dll`，API 5.15）
呼叫 `TUSBAUDIO_GetSupportedSampleRates` 取得，裝置回報 `count=2`：

```
支援取樣率 : 48000 Hz, 96000 Hz   （就這兩種，沒有 44.1k / 88.2k / 192k）
目前取樣率 : 48000 Hz
```

與 Windows 音訊引擎的實測一致：
```
[Capture] 1 ch @ 48000 / 96000 Hz，32-bit 容器
[Render]  2 ch @ 48000 / 96000 Hz，32-bit 容器
```

也與 `wMaxPacketSize` 推導吻合（錄音 alt 1：196 B ÷ 4 B ÷ 1 ch = 49 samples
/ 0.5 ms → 96 kHz 加 async 餘裕）。

> 重點：**沒有 44.1 kHz**。macOS 端若送 44.1k 會被迫重採樣，設計時要注意。

**alt 3 的 3 聲道 IEEE_FLOAT 是 Razer 的特殊模式**（雙路輸出／串流分軌），
標準 UAC2 driver 不會用到；macOS 的 `AppleUSBAudio` 只會挑 PCM 的 alt setting。

---

## 5. HID 介面（Interface 3）✅

HID descriptor：`bcdHID = 0x0111`，report descriptor 長度 **273 bytes**，
endpoints `0x82` IN / `0x03` OUT（皆 Interrupt，maxPacket 1024，bInterval=4）。

> 註：raw report descriptor 無法透過 hub IOCTL 取得（HID 驅動已接管該介面，
> hub 回 `ERROR_GEN_FAILURE`）。以下由 `HidP_GetValueCaps` / `HidP_GetButtonCaps`
> 的 preparsed data 重建，語意等價。

Interface 3 底下有 5 個 top-level collection：

| Collection | UsagePage | Usage | Report | 用途 |
|---|---|---|---|---|
| col01 | `0x000C` Consumer | 0x0001 | Input id `0x06`, 2 B | 媒體鍵（8 個 button） |
| col02 | `0x000B` Telephony | 0x0001 | In/Out id `0x08`, 3 B | 電話控制（靜音、掛斷等） |
| col03 | `0x FF90` vendor | 0x0001 | In/Out id `0x55`, 64 B | 廠商通道（interrupt，用途未確認） |
| col04 | `0xFF82` vendor | 0x0001 | In/Out id `0x41`, 1021 B | 大量傳輸，⚠️ 推測為韌體更新 |
| **col05** | **`0xFF53` vendor** | **0x0004** | **Feature id `0x07`, 64 B** | **★ 燈效／設定控制通道** |

### col05 詳細 ✅

```
Feature  reportId=0x07  usagePage=0xFF53  usage=0xF0  bitSize=8  count=63   ← 送指令
Input    reportId=0x07  usagePage=0xFF53  usage=0xF1  bitSize=8  count=63   ← 讀回應
Input    reportId=0x05  usagePage=0xFF53  usage=0xF2  bitSize=8  count=15   ← 事件通知
```

裝置路徑（本機）：
```
\\?\hid#vid_1532&pid_058e&mi_03&col05#8&16ed8a2c&0&0004#{4d1e55b2-f16f-11cf-88cb-001111000030}
```

macOS 上對應：`IOHIDDeviceCreate` 找 VID 0x1532 / PID 0x058E，
PrimaryUsagePage `0xFF53` / PrimaryUsage `0x0004`，
用 `IOHIDDeviceSetReport(kIOHIDReportTypeFeature, 0x07, ...)` 送 63 bytes。

---

## 6. 廠商協議（Razer Protocol 2.5，64-byte 變體）

### 6.1 傳輸層 ✅（來源：Synapse `SPEC_UsbRzDeviceAction_protocol25_flow.md`）

Razer 官方 spec 定義三種長度：

| dataSend 長度 | 實際送出 | 說明 |
|---|---|---|
| 90 | 91 | 自動在 byte 0 前置 reportId |
| 91 | 91 | 已含 report ID，原樣送出 |
| 65 | 65 | 必須明確指定 `protocol: '25'` |

**Seiren V3 Pro 用的是 64 bytes**（1 byte report ID `0x07` + 63 bytes payload），
是上表 65-byte 變體的近親。

互斥鎖流程（多執行緒實作時需注意）：
- `sendFeatureReportMutex` 送出後**持續持有** mutex，必須另外呼叫 `releaseMutex`
- `getFeatureReport` 假設 mutex 已持有，不自行取得或釋放
- 燈效 batch frame 走 `sendFeatureReportInBatch`，在 `finally` 中**一定釋放**
- mutex timeout 500 ms；前一筆是 batch 時，下一筆協議指令前會等 5 ms
- batch 排隊超過 2 筆會直接丟棄該 frame

### 6.2 封包結構 ✅

63-byte payload（不含 report ID）：

| Offset | 大小 | 欄位 |
|---|---|---|
| 0 | 1 | `status` |
| 1 | 1 | `transaction_id` |
| 2 | 2 | `remaining_packets`（big-endian） |
| 4 | 1 | `protocol_type` |
| 5 | 1 | `data_size` |
| 6 | 1 | `command_class` |
| 7 | 1 | `command_id` |
| 8 | 53 | `arguments`（只有前 `data_size` bytes 有效） |
| 61 | 1 | `crc` |
| 62 | 1 | `reserved` |

### 6.3 實際樣本 ✅

從裝置讀回的 feature report 0x07（Synapse 最後一次送出的燈效指令）：

```
00: 07 02 07 00 00 00 29 0F 03 00 00 00 00 0B FF 15
10: C1 FF 15 C1 FF 15 C1 FF 15 C1 FF 15 C1 FF 15 C1
20: FF 15 C1 FF 15 C1 FF 15 C1 FF 15 C1 FF 15 C1 FF
30: 15 C1 00 00 00 00 00 00 00 00 00 00 00 00 29 29
```

解碼：

```
report ID          = 0x07
status             = 0x02   （成功）
transaction_id     = 0x07
remaining_packets  = 0x0000
protocol_type      = 0x00
data_size          = 0x29 = 41
command_class      = 0x0F   ← 燈效
command_id         = 0x03   ← custom frame
arguments (41 B)   = 00 00 00 00 0B  +  12 × (FF 15 C1)
crc                = 0x29
reserved           = 0x29
```

**41 = 5 + 36 = 5 bytes 標頭 + 12 × RGB**
→ ✅ **燈環有 12 顆可定址 LED**，當下顏色全部是 `RGB(255, 21, 193)`（洋紅）。

⚠️ **INFERRED** — 參數 5 bytes 的語意。對照 OpenRazer 的 custom-frame 慣例
（`[row, start_col, stop_col, rgb...]`），`00 00 00 00 0B` 最可能是
`[store, row, start_col, ?, stop_col=0x0B]`，`0x0B = 11` 對應 LED index 0–11 共 12 顆。
需要第二筆不同顏色／不同區段的樣本才能確定各 byte 分工。

### 6.3b 第二筆樣本（燈環設為純紅）✅

```
00: 07 02 12 00 00 00 29 0F 03 00 00 00 00 0B C0 00
10: 00 C0 00 00 C0 00 00 C0 00 00 C0 00 00 C0 00 00
20: C0 00 00 C0 00 00 C0 00 00 C0 00 00 C0 00 00 C0
30: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 3C 3C
```

與第一筆的差異：
- `transaction_id` : `0x07` → `0x12`（**會變動，是真的交易計數器**，不是固定值）
- RGB : `FF 15 C1` → `C0 00 00`（12 組全部相同）
- `crc` : `0x29` → `0x3C`
- **完全不變**：`data_size=0x29`、`command_class=0x0F`、`command_id=0x03`、
  參數前綴 `00 00 00 00 0B`

→ ✅ 確認 `00 00 00 00 0B` 是「寫入全部 12 顆 LED」的固定 frame 標頭。

### 6.4 CRC ✅ CONFIRMED（兩筆獨立樣本）

兩筆樣本的 12 組 RGB 都是同色重複 12 次（偶數），XOR 自我抵銷，
因此 `XOR(buf[3..61])` 兩次都等於 `0x2E`。差異只來自 `transaction_id`：

| 樣本 | transaction_id | `0x2E ^ tid` | 實際 crc |
|---|---|---|---|
| 洋紅 | `0x07` | `0x29` | `0x29` ✅ |
| 純紅 | `0x12` | `0x3C` | `0x3C` ✅ |

**結論：CRC 的計算範圍包含 `transaction_id`。**
即 XOR over payload[1..60]（= buffer bytes [2..61]）。

> 這與 OpenRazer 的標準實作不同 —— OpenRazer 是從 `transaction_id`
> **之後**才開始 XOR。移植既有程式碼時這是必改的一行。

⚠️ 仍未定案：`crc` 與 `reserved` 兩個 byte 在**兩筆樣本中都相等**
（`29 29`、`3C 3C`），所以無法判斷 crc 究竟在 offset 61 還是 62。
實作時建議兩個 byte 都填相同的 CRC 值。

另外因為 buf[3..5] 皆為 0x00、buf[50..61] 也全為 0x00，
XOR 範圍的**起訖邊界**無法從這兩筆再進一步收斂 —— 但「含 transaction_id」
這點是確定的。

### 6.5 亮度 ⚠️ INFERRED — 待驗證

「純紅」送出的是 `C0 00 00` = **RGB(192, 0, 0)**，不是 `FF 00 00`。
第一筆洋紅則是 `FF 15 C1`（含滿值 255）。

推測：**亮度由主機直接乘進 RGB 值**，而非另外一道韌體亮度指令
（`0x0F 0x04` 之類）。若成立，macOS 端完全不需要處理亮度指令。

驗證方式：把 Synapse 亮度滑桿拉到 100%、顏色維持純紅，再讀一次 feature report。
- 若變成 `FF 00 00` → 確認亮度是主機端乘算
- 若仍是 `C0 00 00` → 亮度是獨立指令，需要另外側錄

---

## 7. 尚未取得的資料，以及取得方式

> **先看 `FEATURE-MAP.md`** —— 它回答了最重要的問題：哪些功能是裝置指令、
> 哪些是 Razer 在 PC 上做的 DSP（EQ / 降噪 / 語音閘全部屬於後者，macOS 上要自己寫）。

| 缺什麼 | 為什麼現在拿不到 | 怎麼拿 |
|---|---|---|
| 完整燈效指令集（Spectrum / Breathing / 亮度 / 關閉） | 只能讀到「最後一次送出的」那一筆 | 在 Synapse 改一次設定後重讀 feature report 0x07（**不需重開機**，見下） |
| CRC 範圍確認、參數語意確認 | 單一樣本不足 | 同上 |
| `SetMode`（Basic/Advanced）、虛擬混音、`SetHwChannelHiddenFlags` 的封包格式 | 走 **EP0 vendor control transfer**，不是 HID，且無法從靜態檔案還原 | **USB 封包側錄**（需重開機），要抓的是 control transfer 不是 HID interrupt |
| 裝置內建 expander 的可調參數 | 同上 | 同上 |
| ~~完整取樣率清單~~ | — | ✅ 已取得：48k / 96k（§4） |
| raw HID report descriptor（273 B） | HID 驅動接管，hub 不轉發 | macOS 上 `IOHIDDeviceGetProperty(kIOHIDReportDescriptorKey)` 一行就拿到 |

### 已嘗試但放棄的路徑

透過 `RazerSeirenV3Proapi_x64.dll` 直接呼叫 `TUSBAUDIO_AudioControlRequestGet`
來 dump UAC2 控制項 —— **簽章猜錯導致 access violation**。Thesycon 的 API
沒有公開標頭，含 buffer 指標的函式盲猜參數順序風險過高（錯的簽章會讓 DLL
寫入任意位址），因此停止。

已成功呼叫且安全的部分（`scripts/tusb_safe.ps1`）：
`GetApiVersion`、`EnumerateDevices`、`GetDeviceCount`、`OpenDeviceByIndex`、
`GetCurrentSampleRate`、`GetSupportedSampleRates`。

### 最省力的下一步（不需重開機）

在 Synapse 裡把燈環改成**純紅**，然後重跑 `scripts/featread.ps1`。
拿到第二筆樣本後即可：
1. 確認 CRC 範圍與位置
2. 確認 5 bytes 參數的語意
3. 驗證 12 × RGB 的排列順序

重複幾種效果（純綠、Spectrum、關閉），就能在**完全不側錄封包**的情況下
把燈效指令集補齊 —— 因為每次 Synapse 送完指令，裝置都會把它保留在
feature report 0x07 裡讓你讀回來。

---

## 8. USBPcap 現況（若之後仍要側錄）

- USBPcap 1.5.4 已安裝，`UpperFilters = USBPcap` 已註冊於 USB class
  `{36fc9e60-c465-11cf-8056-444553540000}`
- **但驅動狀態為 `STOPPED`，`\\.\USBPcapN` 控制裝置不存在 → 必須重開機**
- `USBPcapCMD.exe -I` 已執行，回報 `Found standard HWID`
  （root hub `USB\ROOT_HUB30&VID8086&PID7AE0` 原生支援，無需額外設定）
- Wireshark 4.6.7 已安裝（tshark 可用於解析）
- 裝置位置：hub `USB\VID_0B05&PID_1BD6\5&2cf64626&0&7`，**port 2**，USB address 44

重開機後側錄指令（只抓這台，避免音訊 isochronous 洗版）：
```
"C:\Program Files\USBPcap\USBPcapCMD.exe" -d \\.\USBPcap1 --devices 44 --inject-descriptors -o seiren.pcapng
```
（`\\.\USBPcap1` 需依重開機後實際列出的 root hub 調整）

---

## 附錄：檔案清單

```
REFERENCE.md              本文件
raw/config_desc_0.bin     完整 USB configuration descriptor (537 bytes)
raw/feature_0x07.txt      實際讀回的 feature report 樣本
synapse/                  從 app.asar 解出的 Razer 協議文件與 JS
scripts/                  本次使用的所有擷取腳本（可重複執行）
```
