# Seiren V3 Pro — 燈效協議（完整規格）

全部由高速輪詢 feature report `0x07` 取得（`scripts/featpoll.ps1`，每 3 ms 讀一次，
在 Synapse 操作的同時攔截）。所有欄位皆有多筆獨立樣本佐證。

擷取日期：2026-07-27　樣本數：413 個 unique frame / 120 秒

---

## 1. 通道 ✅

| 項目 | 值 |
|---|---|
| HID collection | UsagePage `0xFF53`, Usage `0x0004`（Interface 3, col05） |
| 送指令 | **Feature report，Report ID `0x07`**，64 bytes（1 + 63） |
| 讀狀態 | 同一個 Feature report（裝置保留最後一筆指令） |

macOS：`IOHIDDeviceSetReport(dev, kIOHIDReportTypeFeature, 0x07, buf, 64)`

---

## 2. 封包結構 ✅

64-byte buffer，`buf[0]` 是 report ID，`buf[1..63]` 是 63-byte payload：

| buf 索引 | payload 索引 | 大小 | 欄位 |
|---|---|---|---|
| 0 | — | 1 | Report ID = `0x07` |
| 1 | 0 | 1 | `status`（送出時填 `0x00`；回讀時 `0x02` = 成功） |
| 2 | 1 | 1 | `transaction_id` |
| 3–4 | 2–3 | 2 | `remaining_packets`（大端，恆為 `0x0000`） |
| 5 | 4 | 1 | `protocol_type`（恆為 `0x00`） |
| 6 | 5 | 1 | `data_size` — 有效參數位元組數 |
| 7 | 6 | 1 | `command_class` |
| 8 | 7 | 1 | `command_id` |
| 9–61 | 8–60 | 53 | `arguments`（只有前 `data_size` bytes 有效，其餘補 0） |
| 62 | 61 | 1 | 保留 |
| **63** | **62** | 1 | **`crc`** |

### `transaction_id`
每筆指令都不同，但**不是單調遞增**（觀察到 `0x07 → 0x12 → 0x0A`，
以及在 `0x00–0x1E` 之間循環）。實作時任意值即可，只要納入 CRC 計算。

---

## 3. CRC ✅ CONFIRMED

```
crc = XOR of buf[2] .. buf[61]      # 即 payload[1..60]，從 transaction_id 開始
放在 buf[63]（payload[62]）
```

⚠️ **與 OpenRazer 不同**：OpenRazer 從 `transaction_id` **之後**才開始 XOR。
這裡**必須包含 `transaction_id`**。移植現成程式碼時這是必改的一行。

### 為什麼能確定 CRC 在 `buf[63]` 而不是 `buf[62]`

在 `command_id = 0x02` 的封包裡，`buf[62]` 與 `buf[63]` **不相等**，
直接分離了這兩個位元組。四筆獨立驗算全部命中 `buf[63]`：

| tid | args | XOR(buf[2..61]) 計算 | 結果 | buf[62] | buf[63] |
|---|---|---|---|---|---|
| `0x15` | `00 00 08 00 00 00` | `15^06^0F^02^08` | `0x16` | `0x00` | **`0x16`** ✅ |
| `0x09` | 同上 | `09^06^0F^02^08` | `0x0A` | `0x00` | **`0x0A`** ✅ |
| `0x04` | 同上 | `04^06^0F^02^08` | `0x07` | `0x00` | **`0x07`** ✅ |
| `0x01` | 同上 | `01^06^0F^02^08` | `0x02` | `0x00` | **`0x02`** ✅ |

在 `command_id = 0x03` / `0x04` 的封包裡，`buf[62]` 與 `buf[63]` 恰好都等於 CRC。
⚠️ 這個不一致還沒解釋清楚（可能是不同指令用了不同長度的送出緩衝區）。
**保險做法：`buf[63]` 填 CRC，`buf[62]` 也填 CRC** —— 這在所有觀察到的封包裡都成立
（`cmd=0x02` 的 `buf[62]=0x00` 是回讀值，不一定等於 Synapse 送出的值）。

---

## 4. 指令集（`command_class = 0x0F`）✅

### 4.1 `0x0F 0x03` — 設定 LED frame

```
data_size = 0x29 (41)
args = [00, 00, 00, 00, 0B] + R0,G0,B0, R1,G1,B1, ... R11,G11,B11
       └──── 固定前綴 ────┘   └────── 12 × RGB = 36 bytes ──────┘
```

- 前綴 `00 00 00 00 0B` 在**全部 400+ 筆樣本中完全不變**。
  `0x0B = 11` 對應 LED 索引上限（0–11），即 **12 顆可定址 LED**。
- RGB 使用完整 0–255 範圍（樣本中可見 `CD FF 00`、`F2 E1 00`、`FF 15 C1`）。
- 這是唯一的顏色寫入指令 —— **所有效果都靠連續送這個指令實現**。

### 4.2 `0x0F 0x04` — 亮度

```
data_size = 0x03
args = [01, 00, level]        level: 0x00 .. 0xFF
```

實測樣本（使用者把滑桿從 10 拉到 100）：
`0x26, 0x30, 0x44, 0x99, 0xDB, 0xEA, 0xFF`，以及 `0x00`。

- **亮度是獨立指令，不會被乘進 RGB** —— 亮度從 10 改到 100 時，
  frame 指令的 RGB 值 `C0 00 00` 完全沒變。
- **`level = 0x00` 就是「關閉燈效」**。樣本中關燈送的正是 `01 00 00`，
  重新開啟則送 `01 00 FF`。沒有另外的 on/off 指令。

### 4.3 `0x0F 0x02` — 設定效果模式（`setChromaEffect`）

```
data_size = 0x06
args = [00, 00, 08, 00, 00, 00]
```

- 這個 command 在 Synapse 原始碼裡就叫 `setChromaEffect`
  （見 `synapse/electron__Protocol__protocol25Const.js`：`setChromaEffect: [15, 2]`）。
- ⚠️ **INFERRED**：args 第 3 個位元組 `0x08` 是效果 ID。但在本次擷取中，
  切換到 Spectrum、切回純色、關燈——**四次觸發送的都是同一組 `00 00 08 00 00 00`**。
  因此 `0x08` 推測是「**主機串流 frame 模式**」而非某個具體效果，
  Synapse 用它來告訴裝置「接下來我會自己推 frame」。
  其他效果 ID 是否存在、以及裝置是否有內建效果，本次無法確認。

---

## 5. 重要結論：效果由主機渲染 ✅

切到 Spectrum 之後，本次擷取到 **961 個不同的 RGB 值**連續串流，
frame 之間間隔約 30–80 ms。顏色軌跡是連續色相環（
`BD0000 → BA0003 → B90006 → ... → AF0320 → ... → 4EFF00`）。

**→ Spectrum 不是韌體效果，是 Synapse 在 PC 上算好顏色再逐幀推送。**

這對 macOS 實作是好消息：

- 你不需要逆向任何「效果指令」——**根本沒有**
- 只要實作 `0x0F 0x03`（寫 frame）+ `0x0F 0x04`（亮度），
  所有動態效果都由你自己的程式碼產生
- 動畫更新率抓 **20–30 fps** 即可（與 Synapse 相當）

> Razer 的 spec 提到高頻 frame 應走 `sendFeatureReportInBatch`，
> 且連續 batch 之間要 sleep 2 ms；若前一筆是 batch，下一筆協議指令前要等 5 ms。
> 詳見 `synapse/electron__SPEC_UsbRzDeviceAction_protocol25_flow.md`。

---

## 6. 實作範例（macOS / C）

```c
// 組一個 64-byte Razer protocol 2.5 封包
static void rz_build(uint8_t buf[64], uint8_t tid, uint8_t cls, uint8_t cmd,
                     const uint8_t *args, uint8_t nargs)
{
    memset(buf, 0, 64);
    buf[0] = 0x07;          // HID report ID
    buf[1] = 0x00;          // status (送出時為 0)
    buf[2] = tid;           // transaction_id
    buf[3] = 0x00;          // remaining_packets hi
    buf[4] = 0x00;          // remaining_packets lo
    buf[5] = 0x00;          // protocol_type
    buf[6] = nargs;         // data_size
    buf[7] = cls;           // command_class
    buf[8] = cmd;           // command_id
    memcpy(&buf[9], args, nargs);

    uint8_t crc = 0;
    for (int i = 2; i <= 61; i++) crc ^= buf[i];   // 含 transaction_id
    buf[62] = crc;
    buf[63] = crc;
}

// 設定 12 顆 LED
void rz_set_frame(IOHIDDeviceRef dev, uint8_t tid, const uint8_t rgb[36])
{
    uint8_t args[41] = { 0x00, 0x00, 0x00, 0x00, 0x0B };
    memcpy(&args[5], rgb, 36);
    uint8_t buf[64];
    rz_build(buf, tid, 0x0F, 0x03, args, 41);
    IOHIDDeviceSetReport(dev, kIOHIDReportTypeFeature, 0x07, buf, 64);
}

// 設定亮度（0 = 關閉燈效）
void rz_set_brightness(IOHIDDeviceRef dev, uint8_t tid, uint8_t level)
{
    uint8_t args[3] = { 0x01, 0x00, level };
    uint8_t buf[64];
    rz_build(buf, tid, 0x0F, 0x04, args, 3);
    IOHIDDeviceSetReport(dev, kIOHIDReportTypeFeature, 0x07, buf, 64);
}

// 進入主機串流 frame 模式（每次要開始推動畫前送一次）
void rz_enter_stream_mode(IOHIDDeviceRef dev, uint8_t tid)
{
    uint8_t args[6] = { 0x00, 0x00, 0x08, 0x00, 0x00, 0x00 };
    uint8_t buf[64];
    rz_build(buf, tid, 0x0F, 0x02, args, 6);
    IOHIDDeviceSetReport(dev, kIOHIDReportTypeFeature, 0x07, buf, 64);
}
```

驗證方式：送完之後用 `IOHIDDeviceGetReport(kIOHIDReportTypeFeature, 0x07, ...)`
讀回來，`payload[0]`（`buf[1]`）應為 `0x02` = 成功。
若為 `0x03` = failed、`0x05` = notSupported、`0xE1` = custom_command_mismatch。

狀態碼完整表（來自 `protocol25Const.js`）：
```
0x00 newCommand   0x01 busy    0x02 success   0x03 failed
0x04 timeout      0x05 notSupported           0xE1 custom_command_mismatch
```

---

## 7. 還沒確認的部分

| 項目 | 狀態 |
|---|---|
| `0x0F 0x02` 的其他效果 ID | 本次四次觸發都送 `0x08`，無法確認是否存在韌體內建效果 |
| `buf[62]` 的真實語意 | 在 `cmd=0x02` 回讀時為 `0x00`，在 `cmd=0x03/0x04` 時等於 CRC |
| ~~12 顆 LED 的實體排列順序~~ | ✅ **已確認**：**index 0 在 6 點鐘位置，順時針繞一圈**，每顆相隔 30°。以 `yunaudio-cli light walk` 逐顆點亮實測。 |
| 前綴 `00 00 00 00 0B` 各 byte 的分工 | 400+ 樣本中恆定，無法從觀察拆解 |

### LED 排列（已確認）

```
            6 (12點)
        7        5
    8                4
    9 (3點)          3 (9點)
   10                2
       11        1
            0 (6點)
```

**index 0 在 6 點鐘，順時針。** 這代表 index 1 與 11 等高、2 與 10 等高，
所以電平表要**依高度**填而不是依 index 填 —— 依 index 會變成繞圈跑馬燈，
依高度才會像真正的電平表一樣從底部往上兩側同時升起。

高度公式：`height(i) = (1 - cos(2π·i/12)) / 2`，0 在底、1 在頂。
