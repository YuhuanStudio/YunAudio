# 自動化

底下每一種介面驅動的都是**同一個執行中的應用程式**，用的是同一套詞彙。
`Sources/YunAudioControl` 只定義一次；視窗、命令列、MCP 伺服器和腳本，是它的四個前端。

← [README](../../README.zh-Hant.md) · [English](../automation.md)

## 遠端控制

任何能打開 URL 的東西都可以驅動它：捷徑、Stream Deck、Keyboard Maestro、AppleScript、
從終端機執行 `open`。

```bash
open "yunaudio://routing/start"     # 也有 /stop 與 /toggle
open "yunaudio://mute/on"           # 也有 /off，不帶參數則為切換
open "yunaudio://record/toggle"
open "yunaudio://transcript/start"
open "yunaudio://preset/Voice%20call"
```

不帶參數是切換，因為那是實體按鈕想要的行為；由腳本驅動的東西應該用確定形式，那是
幂等的 —— `mute/on` 執行兩次的結果是靜音，不是取消靜音。無法辨識的動詞會被拒絕而不是
猜測，因為要避免的失敗是「打錯的靜音變成了停止」。

### 從終端機

同樣的動詞，但**有答案回來** —— 那是 URL 做不到的部分。`yunaudio-cli` 是對「已經在跑的
那個應用程式」說話，它自己不開任何硬體。

```bash
yunaudio-cli status                  # 它在做什麼，一行一件事實
yunaudio-cli start                   # 也有 stop、toggle
yunaudio-cli mute on                 # 也有 off，不帶參數則為切換
yunaudio-cli record off
yunaudio-cli transcribe on
yunaudio-cli preset Voice call       # 不需要引號，名稱會被接起來
yunaudio-cli config Podcast
yunaudio-cli script "yun.mute(true); yun.log(yun.status().running)"
yunaudio-cli mute --url              # 印出 URL 而不是送出它
```

`status` 印出的就是腳本透過 `yun.status()` 看到的東西，再加上目前存在的場景與設定組。
指名一個不存在的，會拿到存在的那些的清單 —— 那比「找不到」有用。**無法執行的指令
以 1 結束，無法解析的那一行以 2 結束**，所以 shell 腳本分得出「應用程式拒絕了」和
「你打錯了」。

它透過 MCP 伺服器所用的同一個 Unix socket 抵達應用程式，位置在
`~/Library/Application Support/YunAudio/control.sock`。這也是為什麼「YunAudio 沒有在跑」
是毫秒級回來的，而不是等到超時：沒有人在聽就是 `connect` 失敗，那是一個答案，不是一段
要等完的沉默。

`status` 刻意**不是** URL 或 MIDI 音符可以送的動詞之一：問「現在是什麼狀況」不應該有能力
改變它。其餘全部是一套詞彙 —— `RemoteCommand` —— 四個前端，所以加一次動詞就同時能從
URL、打擊墊、一行 JavaScript 和 shell 用到。

這裡的 `record` 指的是應用程式的錄音器。那個把幾秒鐘路由訊號寫成檔案來量測的動詞是
`capture`。

**不是 App Intents，而且不是沒試過**：捷徑資料庫裡的項目是從 Xcode 自己的建置階段抽出的
中介資料被發現的，而一個由 shell 腳本圍著 SwiftPM 執行檔組出來的應用程式產生不出那些。
它們會編譯、會執行，然後永遠不出現在任何人用得到的地方。

## 讓 agent 驅動它 —— MCP

`yunaudio-mcp` 是一個 Model Context Protocol 伺服器：stdio 上的 JSON-RPC 2.0、零相依、
由你指向它的任何客戶端啟動。

```bash
swift build -c release            # 產生 .build/release/yunaudio-mcp
claude mcp add yunaudio -- "$PWD/.build/release/yunaudio-mcp"
```

或者，對於用檔案設定的客戶端 —— Claude Desktop、Zed，以及任何讀同一種格式的：

```json
{
  "mcpServers": {
    "yunaudio": { "command": "/absolute/path/to/yunaudio-mcp", "args": [] }
  }
}
```

九個工具：`yunaudio_status`、`yunaudio_list_names`、`yunaudio_routing`、
`yunaudio_mute`、`yunaudio_record`、`yunaudio_transcribe`、`yunaudio_apply_scene`、
`yunaudio_apply_setup` 和 `yunaudio_run_script` —— 和 URL scheme 是同一套詞彙，因為
底下就是同一個 `RemoteCommand`。名稱是使用者自己取的，而且有些是翻譯過的，所以要按
名稱套用場景之前，先呼叫 `yunaudio_list_names`。

**YunAudio 必須在跑。** 這個伺服器不持有任何狀態，自己什麼也不知道：它把請求轉發給
應用程式，走的是 `~/Library/Application Support/YunAudio/control.sock` 這個 Unix domain
socket —— 應用程式在啟動時建立它、結束時移除它，並且只讓擁有者可讀。如果沒有人在聽，
每個工具都會立刻這樣回答，而不是等下去。`--socket <path>` 和
`$YUNAUDIO_CONTROL_SOCKET` 可以移動它。

用 socket 而不用 URL scheme，因為 **URL 是單向的**。`open yunaudio://mute/on` 在
Launch Services 收下事件的那一刻就回來了：它沒辦法說麥克風現在是不是靜音的、那個場景
到底存不存在、或者有沒有任何東西聽到了。那對 Stream Deck 的按鍵沒問題，因為有人在看
結果；對 agent 就沒有用，因為沒有人在看 —— 而把狀態讀回來，正是 agent 存在的一半理由。

## 和 OBS 對接

「設定 → 直播」連的是 `obs-websocket` v5，那個東西從 OBS 28 版就內建在裡面了。有兩樣
東西會跨過它，而第二樣正是第一樣存在的原因。

**在這裡把麥克風靜音，同時會靜音 OBS 那一路的副本** —— 如果你要求它這麼做。OBS 對
同一個來源自己的靜音是另一個視窗上的另一個開關，而那產生的失敗正是「沒有人來得及發現」
的那一種。

**同步偏移。** 這個應用程式送出去的每一樣東西，都比畫面晚到 OBS，晚的量剛好就是效果鏈
加上去的延遲 —— 光是人聲隔離就 56 毫秒。OBS 有一個 per-source 的欄位可以填，卻沒有辦法
算出該填什麼。這裡算得出來，精確到 frame，而在此之前它只是顯示出來。48 kHz 下的
2688 個 frame 變成 −56 ms，四捨五入到整毫秒，因為 OBS 自己的對話框就是一個整毫秒的
數字框。

兩件值得直說的事：

- **`obs-websocket` 預設是關的**，所以大多數人遇到的第一件事是連線被拒。這裡回答它的
  方式是給出選單路徑，而不是給一個狀態碼：工具 → WebSocket 伺服器設定。
- **這件事沒有對著真的 OBS 驗證過。** 驗證是拿 obs-websocket 協定文件裡的向量檢查的，
  整個握手也在真實 socket 上對著一個按那份文件所述回答的 stub 伺服器檢查過 —— 但寫這段
  程式的機器上沒有安裝 OBS，而**一個 stub 不能成為關於它所模仿的那個程式的證據**。
  `RESEARCH.md` 說明了要拿真的東西跑一遍需要什麼。

沒有做，而且那是決定而不是缺口：不做原生 OBS 外掛（websocket 已經足夠做完需要的事，
而外掛會把這個專案綁在 OBS 的建置與 ABI 上）、目前不做瀏覽器來源疊圖、也不做六軌錄音
模型 —— `MAX_AUDIO_MIXES` 是 libobs 裡的一個編譯期常數，那讓「六」成為別人的多工器
限制，而不是一個值得照抄的形狀。

### 一個撐得過應用程式重新啟動的擷取

OBS 的 issue #9144 —— 「Application Capture loses audio when application reopens on
macOS」—— 從 2023 年 6 月開到現在，而 OBS 對它的回答是來源屬性裡一個標著
「Restart capture」的按鈕。

macOS 26 加了 `CATapDescription.bundleIDs`，這個應用程式會設它，所以被擷取的應用程式
關掉再開會自己重新接上。量測這件事的時候翻出一個值得知道的事實：旁邊那個
`processRestoreEnabled` 旗標**預設就是 true**，所以它一直都是開著的、而且一直什麼都沒
還原，因為根本沒有任何 bundle identifier 可以拿來還原。**只設那個旗標會是一個沒有任何
效果、但讀起來完全像修好了的改動。**

```bash
swift run -c release yunaudio-cli tap-restore Spotify           # HAL 留下了什麼
swift run -c release yunaudio-cli tap-restore Spotify --watch   # 關掉它然後看著
```
