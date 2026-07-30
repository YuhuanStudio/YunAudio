# 還沒做完的

一份清單，讓一個人和一個 agent 隔一個月接手時看到的是同一張圖。
`AGENTS.md` 講怎麼在這裡工作；這份講什麼值得做，以及什麼已經定案不要再試。

裡面有兩種東西，而且刻意分開：**提案**來自這個專案的擁有者，**發現**來自一次競爭
分析。提案不需要理由。發現需要，而且證據就寫在旁邊 —— 因為產出那些發現的那次分析
中途因搜尋額度死掉，四條研究流裡有一條在自己抓到之前捏造了大約一半的引用，另外兩
條根本沒回報。從那裡救回來的每一條都標了它值得多少信任。

## 記號怎麼讀

- **[V]** —— 已查證：真的有人打開過那個來源。
- **[M]** —— 來自沒有被獨立複查的那一流，但與已查證的內容互相吻合。
- **[?]** —— 合理但未查證。是線索，不是事實。
- **[提案]** —— 直接指定的。不需要證據。
- **[本機實測]** —— 在這台機器上量過。這一類最可信，而且**已經推翻過兩條 [V]**。

---

## 已知問題

### 延遲補償 —— **已修**，而且這一段留著是因為它的形狀值得記得 [本機實測]

當時的狀況：`EffectChain` 把每一級 AU 的延遲加總成 `latencyFrames`，`RoutingEngine`
存成 `effectLatencyFrames` —— 而**那個值唯一的去處是 UI**。沒有任何地方用它去延遲別的
路徑。

現在：`RTGraph.alignmentFrames` 每一條沒經過鏈的 route 各有一條延遲線，
`RoutingEngine` 在起路由與熱抽換時都把鏈的延遲寫進去，flow check 的
`chain alignment` 一節斷言 `applied == chain`。

**還沒做的那一半在外面**：OBS 自己擷取的來源（它的桌面音訊、遊戲擷取、影像）不在這條
延遲線上，因為它們根本不經過這裡。那要靠 OBS 的同步偏移，見第 4 項。

所以麥克風經過整條效果鏈（光是人聲隔離就 56 ms），而被 tap 的應用程式音訊一級都沒
經過。兩者在混音時就差了整條鏈的延遲。**在 KTV 的情境下這正是「人聲比伴奏晚」**，
量級幾十毫秒 —— 唱歌的人聽得出來，而且會下意識搶拍去補。錄下來的 per-source stem
之間也是錯開的，事後在 DAW 裡重混要手動對齊。

修法便宜：在不經過鏈的那些路徑上放一條延遲線，長度就是那個我們已經算好的數字。代
價要講明白：**要嘛對齊，要嘛早到，不能兩者都要。**

**而且它可以被斷言**：送一個脈衝進麥克風路徑與一個 tap 路徑，量兩邊在目的地的到達
幀差，斷言它是 0。修之前那個斷言會失敗，那正是它存在的證據。

### 擷取沒有套件識別碼的行程，會間歇性地靜默失敗 —— **未解，但已經量到形狀** [本機實測]

`AudioHardwareCreateProcessTap` **回傳 `noErr`，同時給回一個空的物件 ID**。擷取因此
沒有發生，而任何一層都不是錯誤。

以前這被報成 `creationFailed(0)`，印出來是「failed with 0」—— `noErr` —— 讀起來像
自相矛盾，把上一個看到它的人送去查「HAL 是不是 tap 用完了」。現在它是獨立的一種結
果，而且**把當時傳進去的兩個參數印出來**，因為原因還不知道，而那兩個參數是唯一能
用來辨認它的東西：

```
AudioHardwareCreateProcessTap returned noErr and no tap for
  process object(s) 803; before: all present; after: all present;
  bundle(s) none; ignored non-bundle identity(s) pid:64291;
  new tap object(s) none
```

已經確定的：

- **不是資源耗盡。** 失敗當下 `kAudioHardwarePropertyTapList` 是 **0 個 tap**。
- **不是行程已經退出。** flow check 的播放器跑 24 秒，建 tap 大約在第 3 秒。
- **有套件識別碼的應用程式沒事。** Discord / Spotify 那一節一直是過的；出問題的只有
  `afplay` 這種命令列工具，它沒有套件，所以被列在合成的 `pid:1234` 身分底下。
- **它是間歇的。** 同一個執行檔連續兩次跑，一次成功（調性 F、信心 100%、afplay 出現
  在 singers 裡）、一次失敗。

順手修掉的一件事，即使它不是這裡的原因也該修：那個合成身分**本來會被當成套件識別碼
交給 HAL**。`AudioApplications.identity(forPID:)` 旁邊的註解說「這種行程照樣可以被
擷取，只有這份清單需要一個 key」—— 那句話在加入跨重啟還原（`bundleIDs` +
`processRestoreEnabled`）之後就不再成立了，而沒有任何地方發現。`ProcessTap` 現在把
`pid:` 開頭的識別碼濾掉：沒有套件的行程本來就不可能有「還原」，因為沒有任何穩定的東
西可以記住它。

**儀器現在已經在 HAL 層**：建 tap 前後各讀一次
`kAudioHardwarePropertyProcessObjectList` 與 `kAudioHardwarePropertyTapList`。下一次
空 ID 會直接說被要求的 process object 在呼叫前後是否都還存在，以及 HAL 是否其實新增
了一個沒交回來的 tap；後者會連系統持有的 `CATapDescription` 一起列出。也修正了一個
會把調查帶歪的名稱：那個數字是 CoreAudio object ID，從來不是 Unix PID，而且被濾掉的
`pid:` 合成身分現在明講是「未交給 HAL」，不再謊稱它是 bundle ID 參數。

現在 API 邊界會處理兩個已經能從那些讀數判定的分支：

- out parameter 是空的、但 tap list 多出**同一份 description UUID** 的物件，就接回
  那個物件。只比 process 或 bundle 不夠，因為另一個應用程式可以在同一段時間 tap
  同一個播放器；UUID 才是這次呼叫的身分。
- process object 呼叫後仍存在、前後 tap list 都讀得到且沒有新物件，等 20 ms 後只重試
  一次。process 已消失、tap list 讀不到或出現不屬於這次 UUID 的物件都不猜。錯誤回傳
  若同時留下自己的 tap 也會銷毀，不再讓一次失敗變成持續複製音訊的洩漏。

純分支與真實 HAL 的 restore 建立測試都已通過；這一輪要跑真實 `afplay` capture 時，
整台 CoreAudio 已經是 `AudioDeviceStart returned success but no IO cycle ran within
750 ms`，`yunaudio-cli audio-start` 也同樣失敗。因此「無 bundle 行程真的恢復出聲」
仍保留為未驗，而不是拿沒執行到 live half 的 flow 綠字冒充證據。

### 停止錄音會在即時執行緒裡 segfault —— **已修**，而且是先前就存在的 [本機實測]

`stopRecordingLocked()` 把 `graph.pointee.recordRing` 設成 nil，然後就釋放錄音器。
但**把 nil 寫進活著的圖，並不會把 IO 執行緒已經讀走的那份指標拿掉** —— 讀取和使用
是兩道指令，中間隔著整個緩衝區的工作。在那個窗口裡釋放，就是在唯一不准出錯的那條
執行緒上 use-after-free。

不是理論：`~/Library/Logs/DiagnosticReports/YunAudioApp-2026-07-29-212916.ips`，
`SIGSEGV` 在 `yun_rt_ring_write`，呼叫者是 `HALC_ProxyIOContext::IOWorkLoop`，位址
帶著 pointer authentication failure 的樣子 —— 已釋放記憶體的長相。

引擎對圖的交換本來就有對的規矩（「等即時執行緒跑完兩個週期，因為可能有一個週期還
握著舊指標」），只是**三個環的拆除都沒套用**：錄音、stem、逐字稿 tap。逐字稿那個最
直接 —— `yun_rt_ring_free` 就緊接在把指標設 nil 之後。

現在三處都走 `letTheRealtimeThreadPast()`。順帶一提，`yun_rt_cell_wait_for_swap` 的
名字是誤導的：它只數週期，不看任何 swap 旗標。

**測試是讀原始碼的**，因為這個窗口只有幾微秒寬，跑了一整輪 flow check 才踩中一次；
想主動觸發的測試會在每一台沒踩中的機器上通過，什麼也證明不了。

### 把問答挪到背景執行緒，帶出兩個缺陷 —— **都已修** [本機實測]

問播放器「唱到哪」以前是在 main actor 上同步做的，量到 20.7 ms 一次、20 Hz，所以
改成 `NowPlaying.positionAsynchronously`。改完之後有兩件事沒跟上：

1. **整個 `NowPlaying` 是 `@MainActor`，而背景佇列去呼叫它。** Swift 6 會在執行期
   檢查，於是應用程式在 `dispatch_assert_queue` 裡 trap —— 唱歌面板第一次問位置就
   當掉。單元測試抓不到這種東西（trap 不可捕捉），所以測試就是**真的從背景佇列去
   呼叫一次**：不是回來，就是把整個測試跑掛掉。相關成員現在都標了 `nonisolated`。

2. **答案會晚到。** 輪詢那邊本來就有「手動載入歌詞時不要問播放器」的防護，但問題送
   出去之後才手動載入 `.lrc` 的話，二十毫秒後那個答案還是會落下來，把歌詞、旋律和
   時鐘一起換成播放器的。實測：手動時鐘讀到 **75.15 秒**、而檔案只有 9 秒，然後不
   動了 —— 因為採納的是一個**暫停中**播放器的位置。同步版本沒有這個窗口。
   `receivePosition` 現在也擋 `isHandRun`。

形狀值得記得：**把一件事變成非同步，等於替每一個「現在還算不算數」的判斷開一扇窗**。

### 燈環換模式時，兩條執行緒可能同時寫 HID —— **已修** [編譯器 + 數值測試]

`LightingController` 的 render loop 在背景執行緒讀 `level`、`isMuted`、`generation`、
`renderMode`、`renderColour`，主執行緒同時寫；五個欄位標成 `nonisolated(unsafe)`，
但這個標記在那個位置**完全沒有效果**，Swift 6 編譯器逐項警告了。最壞的不是一顆 LED
撕裂一幀：舊 loop 可能看不到 generation 已改，換模式後跟新 loop 一起活著，兩條各以
30 Hz 搶同一把 device lock，讓燈光卡頓並延長每一次 HID 操作。

現在 render thread 每幀只拿一次鎖定快照；generation 交接與五個值在同一個
`LightingRenderState` 裡同步。測試斷言 generation 從 N 變成 N+1 後，N 取得 frame 的
結果是 `nil`，而 N+1 同一幀讀到完整的模式、顏色、0.625 電平與 mute 狀態。原本六個
燈光 concurrency warning（五個無效標記加一個非 Sendable device capture）也都消失。

### 硬體驗收前置檢查其實會跑五分鐘 —— **已修** [本機實測]

`verify.sh --full` 原本拿 `yunaudio-cli soak` 當「三秒內確認 CoreAudio 能否啟動」。
但 `soak` 的預設時間是五分鐘，輸出又被 pipe 緩衝；實測等了 **90 秒仍沒有一行**，
看起來跟 `coreaudiod` 卡死完全一樣。這不只浪費時間：人會照驗收腳本的診斷去重啟整台
機器的音訊服務。

現在 CLI 有一個只做這件事的 `audio-start`：建立真實 input → virtual output 路由，
等 **0.5 秒**，以 `cycles > 0` 判定；驗收腳本另設 **10 秒**硬上限。第一次完整驗收量到
它正常結束，接著 bit-exact 與 realtime 0 allocations 都通過。

### 多輸入輸出檢查把效果器留給下一節恢復 —— **已修** [本機實測]

`more than one input and one output` 為了送 440 Hz 測試音會暫時拿掉效果器，但原本在
函式的 `defer` 裡逐個打開。`setEffect` 發佈新 graph 是非同步的，所以這個函式已經回傳、
下一節已經記下 cycle baseline，前一節才開始換 graph；結果 `input trim and master`
報 `audio kept flowing` 失敗，之後直接監聽與完整性檢查也被同一份未定狀態連鎖污染。

現在效果器在該節返回前用一個 `batched` 重建恢復，並等到 route running 且不 busy。
同一個 binary 針對三個原始失敗重跑 **120 秒**：input trim 的 cycle 繼續前進、壞監聽
拿掉後音訊仍流動、完整性檢查比較 **261,384 samples** 並找回 **1,016 frames** 延遲，
三節全過。

### 讀 Voice Activity 建議參照裝置會把 Swift Optional 當 C 緩衝區 —— **已修** [編譯器 + 數值測試]

`AudioObjectGetPropertyData` 原本直接寫進 `CFString?`，編譯器明確警告 Optional 可能含
物件參照，形成 `UnsafeMutableRawPointer` 很可能不正確。這是 ARC 管理的 Swift 容器，
不是 CoreAudio 要的 `CFStringRef *`；一旦系統真的回傳 macOS 27 的建議 echo reference，
結果可能是壞參照或錯誤的 retain/release。

現在走共用的 `AudioObjectID.string`，以 `Unmanaged<CFString>` 接 +1 參照。測試從真實
CoreAudio 裝置讀 UID，斷言回傳內容與 UTF-8 byte count 都逐字相同；原警告消失。

### 即時分析還在呼叫已棄用的 CBLAS 宣告 —— **已修且量過** [release benchmark]

單聲道 analysis fold 的 strided copy 用 `cblas_scopy`，但 target 沒開 Accelerate 13.3
以後的 header，所以每次 build 都警告舊介面已棄用。不能用「反正只是警告」留著，也不
能為了安靜就換掉即時路徑：曾量過這一段，選 CBLAS 是有效能理由的。

release `bench` 的同機 A/B：

- 舊 CBLAS 宣告：**305.4 ns/cycle**
- `vDSP_mmov` 替代：**309.1、311.9 ns/cycle**，所以撤回
- 新 CBLAS 宣告、相同函式：**305.8 ns/cycle**

Package 現在只替 `YunAudioEngine` 的 Clang importer 開
`ACCELERATE_NEW_LAPACK`，仍用適合 bounded frame count 的 32-bit 介面。11 個案例的
checksum 全與基線相同，每一個 realtime allocation 都是 **0**，棄用警告消失。

### 連續拖控制項仍替每一格完整展開偏好設定 —— **已修且量過** [release benchmark]

150 ms 的 writer 原本只合併 JSON encode 與 `UserDefaults.set`；`RouterModel.persist()`
在每一個 slider event 仍先把 captured／excluded `Set`、效果集合、角色與 MIDI binding
展開成新的字串陣列和字典，再把前 99 份丟掉。畫面不是卡在磁碟，而是卡在為不會寫出的
值準備磁碟格式。

現在 event 當下只保留 scalar 與 COW collection snapshot，等 coalescer 確定最後一筆才
materialise。不能單純延後讀 model：那會讓 150 ms 內被刻意排除持久化的 auto-level、
preset restore 或 verification 暫態污染使用者剛才的值；value-semantics 測試先改動原
集合再展開，仍讀回 event 當下內容。

Release，以 64 captured + 64 excluded + 11 effects + 64 roles + 64 MIDI bindings、
100 個連續事件量兩次：

- **15,000 allocations／1.23–1.28 ms**
- → **150 allocations／12.4–12.6 µs**

量測本身也修了一個程序缺陷：allocation tripwire 是 process-wide，Swift Testing 會把
不同 suite 平行跑。Preferences 的 1,699 次配置曾同時被 Formant 與 KTV 各自算進去，
讓兩個零配置門檻一起假紅。所有 tripwire benchmark 現在共用一把 test-only lock；重跑
得到 Formant **0**、KTV 調性 **5**、精確旋律 **10**，不再互相污染。

### 擷取應用程式的啟動前置工作卡住整個介面 —— **已修且量過** [release benchmark]

`RoutingEngine.start` 早已在背景 queue，但它前面的工作沒有：`start()` 先在 main actor
同步列舉所有 CoreAudio 行程、建立每一個 `ProcessTap`、查 tap format、組主混音與監聽
路由，最後才把引擎啟動丟到 queue。列舉本身先前已量到 **27 ms warm／118 ms cold**；
tap 若碰到 HAL 回 `noErr` 卻沒交回物件，還有一次 20 ms 的 bounded retry。按開始、
切換擷取來源或改一個必須重建的設定，畫面都會在真正啟動音訊以前先停住。

現在 main actor 只做一次 `NSWorkspace` 值快照，`engineQueue` 依序做 HAL enumeration →
group → tap → route → echo plan → engine start。不能把 `[ProcessTap]` 建好再帶回 main
判斷：取消時最後一個引用會同步跑 `AudioHardwareDestroyProcessTap`，等於把卡頓換一個
名字搬回去。Stop 或設定改動改為取消該 start generation；舊 tap 在 engine queue
釋放，舊 generation 不發布 app、owner 或 monitor index，也不會在已經過期後才把裝置
啟動。

Release 連續 20 次、這台機器 74 個 running apps：留在 main actor 的 AppKit 快照平均
**1,226,856 ns（1.23 ms）**，低於一幀的 16 ms 門檻。結構測試另斷言 `start()` main
段有 **0 次** `AudioApplications.grouped`、**0 次** `ProcessTap` 建立，worker 各只有
一次 capture planner 與 `engine.start`；Workspace 清單也從同一輪掃兩次減成一次。
662 個單元測試與不碰硬體的 acceptance gate 全綠。真實 flow check 仍等整台
CoreAudio 從「start 成功但 750 ms 沒有 IO cycle」的系統狀態恢復，沒有拿未跑到的
hardware half 冒充驗收。

### 唱歌動畫讓整個主視窗重畫，閒置狀態列也永久喚醒 —— **已修且量過** [release benchmark]

歌詞掃光與歌手音高原本直接由 `MainWindow` 讀取。兩者最高以 20 Hz 發布，所以右側一個
mask 或一個看起來沒變的音名，會連左側裝置、接線盤、分析圖與其他分頁的共同父層一起
失效。現在 KTV 的動態 Observation 邊界是獨立的 `SingingPanel`；結構測試斷言
`MainWindow` 對 `lyricProgress` 與 `singers` 都是 **0 次讀取**。flow check 也已改為
真的載入四行 timed `.lrc`、啟動掃光，並要求唱歌面板保持超過半個 poll rate、整個視窗
低於半個 poll rate；這項需要真實 route 的數字仍等 CoreAudio 恢復後補跑，沒有拿結構
檢查冒充動態量測。

歌手列只畫音名，但先前每一個 autocorrelation hertz 微幅抖動都發布。現在同一個半音內
把 raw hertz 留到 4 Hz 的評分週期更新，跨半音仍立即發布。四秒、80 個 20 Hz 模擬
poll 的數值測試得到**最多 16 次發布**，不是 80 次。

每個來源列原本為 level 與 peak hold 各建一次 `compactMap`，再第三次走訪 clipping；
四個來源、20 Hz 是每秒 **160 個短命陣列**。現在三個結果在一個有界 while pass 中一起
算。Release tripwire 實測 10,000 次 reduction 是**整批 1 次 allocation**、空迴圈基線
0；舊形狀約 20,000 次。

狀態列原本不論有沒有 route 都永久掛著 0.5 秒 timer：停止狀態每天 **172,800 次**
main-run-loop callback。現在 Observation 只在 route running 時建立 timer，停止時是
**nil／0 次喚醒**，mute 與 muted-speaking 仍即時更新。藍牙耳機是否跌到通話品質也不再
由 SwiftUI pill body 同步讀 HAL sample rate；結果在 `engineQueue` 以 2 Hz 更新並快取，
結構測試禁止 `StatusPills` 直接出現 `currentSampleRate` 或
`hasFallenToCallQuality`。

668 個單元測試、124 個套件與不碰硬體的 acceptance gate 全綠；深色唱歌分頁與最小
尺寸淺色真實視窗截圖也已人工檢查，沒有裁切或遺失控制項。硬體 flow 仍因上述全機
CoreAudio 狀態未執行。

### 開面板、刷新 app 與來源 meter 還在做整棵樹的工作 —— **已修且量過** [release benchmark]

第二輪 redraw 修完主視窗後，選單列面板仍把 `peakLevel` 讀在 `PanelView` 自己的 body；
面板打開時，一對 meter 會讓 presets、disclosures、兩個裝置 picker、mixer 與 footer
全部以 20 Hz 重建。現在只有 `PanelLiveCard` 讀 meter。硬體 flow check 已加入兩邊的
數值門檻：開啟 0.6 秒時 `PanelView` 少於 10 次、`PanelLiveCard` 多於 3 次；目前
CoreAudio 全機狀態尚未恢復，所以這組 live 數字沒有冒充已跑。

同一問題還在每個 `RouteStrip`：四個來源會每秒重建 **80 次完整控制列**，包括 mute、
solo、角色、名稱與兩個 fader。現在 `SourceLevelMeter` 是唯一讀 `levels/peakHolds` 的
葉節點；clip latch 也只在 false → true 時發布，不再對已經為 true 的值每 poll 重寫。
flow check 要求父 strip 低於半個 poll rate，而 meter 本身高於四分之一，確保不是靠停掉
動畫作弊。

KTV、轉錄、MIDI 與兩個 mixer 又會反覆把不變的 `activeRoutes` 建成 source dictionary
與多份陣列。現在 route list 的 `didSet` 才重建一次，getter 只讀 COW cache，同時保留
對 `activeRoutes` 的 Observation dependency。16 routes、10,000 次 Release tripwire：

- 每次重組：**300,000 allocations／16,640,333 ns**
- cache：**0 allocations／5,750 ns**

兩者 checksum 相同；另有數值測試斷言 first-seen 順序與不連續 route index 都保留。

AppSourceList 的 `.task` 與 Refresh 按鈕原本仍在 MainActor 跑完整
`AudioApplications.grouped`，既有量測 **12–27 ms warm／118 ms cold**。現在 MainActor
只做約 **1.23 ms** 的一次 AppKit value snapshot，HAL enumeration 在 `engineQueue`；
同時只允許一個 refresh in flight，期間再來的點擊或 selection 變化合併成一個 latest
rerun，不會排出一串相同的 HAL 工作。結構測試斷言 production `refreshApps()` 在 queue
前有 0 次 `AudioApplications.grouped`；同步版本只留給下一行立刻要 assert 結果的 render
與 flow harness。

672 個單元測試、125 個套件與不碰硬體的 acceptance gate 全綠；硬體分頁的真實視窗截圖
已人工檢查，時脈葉節點拆分沒有改變版面。硬體 flow 仍未執行。

### AirPods 閒置拆除 [?] [疑似現行 bug]

路由器持有一個常駐 aggregate。裡面有藍牙裝置時，它可能永遠不被允許閒置；而在
AirPods 上開麥克風會把整個裝置拖進 HFP —— 雙向 16 kHz。

**這台機器上沒有 AirPods，所以還沒量到。** 要做的第一件事是找出這個專案到底有沒有
這個問題：把 AirPods 加進 aggregate、盯著輸出的取樣率與電平，而不是從程式碼的形狀
推論。

已經知道的兩件事，兩條路都堵死了：

- `kAudioSubDeviceInputChannelsKey` **沒有用**（見「已定案」），所以「把藍牙裝置的
  輸入排除在 aggregate 之外」這條最明顯的路不通。
- **macOS 沒有 iOS 那個高品質錄音選項** [本機 SDK]。
  `AVAudioSessionCategoryOptionBluetoothHighQualityRecording` 在 header 裡明確標
  `API_UNAVAILABLE(macos)`，CoreAudio 也沒有對應物。

所以只剩結構性的那條：**aggregate 讓 AirPods 只當輸出，由另一個裝置供應麥克風**，
編解碼就不會降級。SoundSource 6.0 出的就是這個 [V]。

### 所有效果改動都已經是熱抽換 [本機實測] —— 已完成

效果鏈本身：11 個級全開再全關（22 次變更）**0.39 秒，約 18 ms 一次**，IO cycle 計
數器全程沒有倒退過。

上次還走完整重啟的兩項現在也不走了：

- **人聲隔離的混合比例**。以前是一次完整重啟，而且更糟的是它根本沒作用 —— 隔離單
  獨開啟時走的是專用 unit 而不是效果鏈，混合比例只寫進鏈裡，所以在隔離唯一有意義
  的那個組態下，它唯一的旋鈕什麼都沒做，介面照樣顯示新數字。
- **外掛清單**。同一個缺陷的外一層：`start` 和 `updateEffects` 都只在有內建級被打
  開時才建鏈，所以單獨放一個第三方外掛進去，它會載入、會出現在清單裡，然後沒有鏈
  可以跑。

### 兩個失敗只在藍牙耳機睡著時出現 [本機實測]

完整 flow check 目前 **571 ✓ / 14 ✗**。14 個裡有 12 個是回音消除器在輸出為藍牙時
真的拿不到麥克風，另外 2 個是 Barracuda 在裝置掉線那一節中途睡著。都不是程式問題，
但值得找出一個能讓這幾節在藍牙環境下也穩定的寫法。

### 六個英文字一詞兩義，已擋住但還沒消歧義 [本機實測]

字串表去重時發現 18 個 key 寫了兩次，其中 6 個翻譯不同 —— 後面那個會**靜默覆蓋**
前面那個。`Pitch` 同時是效果級和音高，`None` 同時是「不變聲」和「無」。

重複 key 現在是 `check-strings.sh` 的失敗條件，所以不會再累積。去重時保留的是後者，
而檢查下來每一個都剛好是比較好的用詞 —— 這是運氣：規則是「保留現在正在跑的」，只
是它剛好跟「保留正確的」一致。

### 一個起不來的監聽輸出會把整條路由拖下來 [本機實測] —— 已修

`direct monitoring` 那一節連續三次跑出 `1 → 0 routes on PG32UCDM` —— 把一台螢幕的
音訊端點指定成監聽輸出，整條路由就停了，不只是第二路混音。監聽是**附加**的輸出，
送給對面的那一路不該跟著死。比較的組別在同一台機器上：同一節指到 `ASUS PG32UQ` 是
`1 → 3 routes`，一切正常。差別只在挑到哪一台螢幕。

修法就是「starting」那一節對目的地做的事：`RoutingEngine.startLocked` 現在起不來而
當時掛著監聽時，把監聽和送進它的每一條 route 拿掉再起一次。**重試本身就是判斷**——
沒有辦法先問一個輸出「你等一下起不起得來」，所以不帶監聽再蓋一次，就是分辨「這個
監聽不能用」和「這條路由不能用」的那個測試。第二次也失敗就把**第一次**的錯誤丟出去：
那個才是在描述呼叫端真正要的那條路由。

**擋住這件事一年的不是修法，是斷言**：那兩台螢幕會從裝置清單上消失，而現在接著的
裝置沒有一個起不來。現在不靠螢幕了 —— **CoreAudio 不讓一個 aggregate 當另一個
aggregate 的成員**，所以 flow check 自己造一個 private aggregate 當監聽，失敗點跟
螢幕端點一模一樣（在解析 route 的通道時），而且任何一台機器上都成立：

```
the engine said: output channel 0 of com.yuhuanstudio.yunaudio.aggregate.… is not part of the aggregate
```

修之前 7 個 ✗（路由停了、cycle 不再前進、介面完全沒提監聽被丟掉），修之後全過。

同一件事在介面上也講出來了：監聽選單自己回到「關」，旁邊一行紅字說是哪一台、以及
引擎怎麼說的，`lastError` 另外用一句話講給人看。**悄悄消失的監聽正是這個專案一直在
別的地方找到的那個缺陷**，所以它不能只是不見。

flow check 那一邊本來就修了：那一節會把錯誤講出來，並在路由被它弄倒時重新起來。那段
留著 —— 它現在防的是「連主混音都起不來」，而不是監聽。

### 真的在播的音樂被聽成低了五度的調 [本機實測] —— 已修

`the key of real playing music is the key it was built in`：檢查合成的是 F 大調的
I–IV–V–I，聽回來是 **B♭ 大調，信心 100%**。

**不是演算法的問題**：把那段和聲進行的理想 chroma（C=4 D=1 E=1 F=5 G=1 A=2 B♭=2）
直接餵進 Krumhansl-Schmuckler 的相關係數，F 大調 0.980、次高 C 大調 0.622，信心
算出來是 1.0。所以錯的是**送到偵測器的那份 chroma**，不是偵測器。

**也不是取樣點的問題**，雖然當時最像的嫌疑是它。分析環寫在總音量之後、整條處理鏈
之後，看起來很可疑；但把實際的 chroma 印出來以後是這樣：

```
C=5.38 C♯=0.46 D=0.02 D♯=0.05 E=2.83 F=0.12 F♯=0.01 G=2.90 …
```

**乾乾淨淨的一個 C 大三和弦** —— 沒有被高通切掉低音，也沒有被人聲隔離抹掉泛音，
就是進行裡的 V 級本身。（會這樣也合理：鏈只掛在 `routes.first` 的來源上，也就是麥
克風，音樂那條擷取路由根本沒經過它。）同一個取樣點累積九秒之後印出來是
`F=3.18 C=2.56 B♭=1.46 A=1.17`，答 F 大調、信心 100%。

真正的缺陷是**只聽了一格就回答**：`updateSinging` 每四次輪詢摺一次 chroma，而第一
摺就被公布出去，所以答案是「面板打開那一瞬間正在響的那個和弦」。摺到 IV 就答 B♭，
摺到 V 就答 C，答對 F 只能靠運氣。三次跑分別得到 B♭、C、F 就是這個。

**十二個數字分不出「一個和弦」和「一首只彈這個和弦的曲子」**：B♭ 三和弦對 B♭ 大調
的相關係數是 0.834，跟整段進行對 F 大調的 0.959 是同一個量級，而且信心（跟次高的
差距）還有 0.37。所以擋的是**聽了多久**，不是任何對 chroma 的運算 ——
`KeyDetector.leastWindowsForAKey = 20`，在面板每秒摺五次的速率下是四秒。

修完之後開著人聲隔離＋等化器連跑三次，都是 **F 大調、信心 100%**。

---

## 接下來做

依這個專案會得到什麼排序，不是依大小。

### 0. 多輸入多輸出 —— **第一半已完成，第二半是 N 條獨立匯流排** [提案] [本機實測]

**已做**：`additionalSourceUIDs` / `additionalDestinationUIDs`。額外的輸入是聚合裝
置的一般成員，通道進得了 `inputMap`，所以每一支都拿到自己的 `SourceGroup` —— 推
桿、靜音、獨奏、角色、監聽送出全部是白拿的。額外的輸出收到與主要輸出**同一份**混
音，各自有自己的音量（`outputTrims`，疊在來源推桿之上，因為引擎的 master 是整個混
音的單一全域增益，表達不出「這個輸出比那個小聲」）。起不來的額外裝置會被丟掉、路
由存活、而且在界面上具名 —— 和監聽同一套規矩。

flow check 的「more than one input and one output」一節在真實硬體上量過：第二個輸
出 −6.0 dBFS 有訊號、第二個輸入拿到自己的 strip、推桿只動自己、clock master 沒被
搶走、trim 動的時候沒有任何來源推桿跟著動。

**還沒做的**：**每個輸出各自一份獨立的混音**。現在只有兩份（主要 + 監聽），額外的
輸出是主要那份的複本。要做到 N 份，得把 `monitorSends` / `monitorRouteIndices` 從
「監聽」推廣成「任一條匯流排」，`RouteStrip` 那一條監聽推桿變成對 `buses` 的
`ForEach`。這是對的終點，但它會動到監聽在引擎裡的特殊失敗語意（起不來就丟掉、路由
存活），所以是單獨一次改動，不是順手。

**順帶查到並修掉的**：每個來源的推桿以前只活在引擎建出來的 route 增益裡，所以
**每次重開應用程式整個混音器都回到 unity，而且沒有任何地方說過**。現在是
`sourceLevels`，按來源 UID 存。

### EQ 拖曳不再把每個中間值塞給音訊引擎 —— **已修且量過** [release]

每個 graphic EQ pointer event 原本在 MainActor 同步完成整條工作：重建所有 bus 曲線、
計算每一節 biquad coefficient、取得 engine state lock，並向 HAL 重讀 aggregate sample
rate。只要引擎正被 start、graph swap 或 Audio Unit 建立占住，推桿就跟著那把鎖一起凍
住；快速拖過 100 個值也會依序安裝 100 套已經看不到的係數，聲音在手放開後繼續追。

現在 event 只留下 COW 的 `CorrectionSnapshot`，curve build 與 install 都在
`engineQueue`。latest-value applier 先完成已經開始的值，期間只保留最新一筆；測試刻意
擋住第一筆再連續送 100 筆，實際 apply 是 **[0, 99] 共 2 次**，不是 100 次，UI 也只
發布最後的 99。同步 verification 用 generation flush，舊 worker 的完成通知不能蓋過
較新的答案。bus 篩選、profile + graphic cascade 與 1 kHz 的 **+4 dB／−2 dB** 反應另
有數值斷言。

Realtime graph 的 sample rate 與 buffer size 也改為保存 graph 建立時真正使用的值。
`setCorrections` 和 `updateEffects` 現在各是 **0 次 `currentSampleRate`、0 次
`currentBufferFrameSize` HAL 讀取**；係數因此也明確與 graph 的格式相同。監聽延遲
同樣不再由 SwiftUI body 呼叫 `latencyFrames`，在既有 2 Hz path refresh 背景讀取並
快取；裝置清單初次出現時的 Bluetooth 通話品質檢查也一併移出 MainActor。

Release 資源套件 24 個測試全綠；同輪既有基準仍是來源 meter 10,000 次 **1 allocation**、
來源 grouping cache 10,000 次 **0 allocation／5,750 ns**。這階段沒有啟動音訊硬體。

### 1. KTV 的下半 [提案]

已完成：Music 與 Spotify 的 now playing（走 scripting dictionary，不是私有的
MediaRemote）、本機與線上 `.lrc` 逐字歌詞（掃過去的高亮）、音高顯示、**調性偵測與
建議移調**（Krumhansl-Schmuckler，信心度是與第二名的差距而不是相關係數本身）。

歌詞同時問 LRCLIB、QQ 音樂、網易雲音樂與 lyrics.ovh；Music 自己的歌詞先用，本機
`.lrc` 永遠優先。四條請求是並行的，第一份有效時間軸會取消其餘請求。繁簡中文、節目版
與 `Live` 後綴會配對；原曲不會誤拿同名伴奏。Spotify 的黃霄雲〈年少心動雨季〉本機實
測：Spotify 自己沒有歌詞欄位，QQ 找到 **63 行**時間軸，網易雲找到 **61 行**，兩份長
度都約 **265 秒**；LRCLIB 當時只有伴奏版而被正確拒絕。

分數與對唱也已完成。每支麥克風一條 pitch history、一份分數；被擷取的 Spotify／QQ
音樂不會再被列成「歌手」。可信度分三層：

- 同名 `.mid`：精確旋律與逐行分數。
- 已擷取的原唱：自動取歌詞段落內的人聲音高當音訊參考，介面明講它不如 MIDI 精確。
- 只有伴奏或沒有可用旋律：依偵測出的調性、音準、歌詞段落與實際演唱時間評分。伴奏
  有和弦與節拍但沒有原唱旋律，所以不把它冒充精確旋律。

後來找到一個會讓「評分壞掉」看起來完全屬實的錯誤：精確 MIDI 模式把**整首尚未唱到
的未來旋律也當成沉默**。四分鐘的歌只唱完前十秒，即使每一個音都準，畫面也只會顯示
約 4%，直到歌曲結尾才慢慢回到真正的分數。原本的六秒 flow fixture 等到整首結束才
斷言，所以一直是綠的。現在分母只到音訊時鐘的 `elapsed`；真實 process tap 在半途量
到 **96%、3.0 秒旋律／3.0 秒輸入**，結尾是 **96%、6.0 秒旋律、平均誤差 0.06 半音**。
兩個半途數字都已成為 flow assertion，不再只是日誌。

同一條路徑也有一個長時間才會露出的卡頓：調性 fallback 在每個 pitch sample 內建立
一個七元素陣列，且兩種分數每 250 ms 都重排整段歷史。三十分鐘的 release 基線是：

- 調性分數：**4.85 ms、84,421 次配置** → **0.262 ms、5 次配置**。
- 精確旋律：**1.68 ms、68 次配置** → **0.137 ms、10 次配置**。

即時資料現在走「已按時間排序、已知取樣間隔」的入口；一般 API 仍會替亂序輸入排序。
歌詞行以單向游標配對，未來旋律一到就停止掃描。另把每半秒約 3 ms 的 path-quality
HAL 查詢從 main actor 移到 engine queue，頻率仍是 2 Hz；同一個四秒 flow A/B：
面板關閉 **492 → 177 µs/poll**，分析面板 **2.57 → 1.67 ms/poll**，唱歌面板
**3.18 → 2.07 ms/poll**。

多來源本身再查到四個缺口：

- 網易雲常見的 `klyric` 是自己的逐字格式，不是 LRC。以前只要它存在就不再看同一回覆
  裡的標準 `lrc`，所以「有 61 行時間線」仍可能顯示沒歌詞；現在逐字格式 parse 不過會
  接著採用標準時間線。
- 帶時間戳的「純音樂／暫無歌詞」占位曾因為看起來是 timed answer 而贏過所有來源。
  現在內容本身也要不是伴奏占位；只看搜尋標題不夠。
- 切歌取消原本只取消 main actor 外層的 `Task`，`Task.detached` 裡四個 provider 繼續
  跑到 timeout。現在是 structured child，離線測試量到 **4/4 loader 都收到
  `CancellationError`**。
- 解析與正規化沒有共用結果：LRCLIB 15 個候選最多 parse 30 次，QQ／網易雲成功內容
  parse 3 次，中文 query 的兩個 transliteration 對最多 45 個候選重算 90 次。現在分別
  是 **15、1、2**；Shazam 48 kHz × 6 秒 signature 也移除一份 288,000 Float、即
  **1,152,000 bytes** 的中間陣列。

另外修掉 Shazam cooldown 落在 capture block 中間的邊界：舊寫法把整塊丟掉，連
cooldown 結束後的有效後綴一起丟；現在只消耗前綴。

完整 flow 曾把「Yu huan 的 iPhone 麥克風」當成一般備用輸入，光是打開 Continuity
Capture 就會喚醒手機並發出提示。現在不是靠名稱排除，而是讀 CoreAudio 的三個 transport
值：有線 `ccwd`、無線 `ccwl`、舊版 `ccap`。這類輸入仍留在選單供人手動選，但不再進入
首次預設、自動啟動、裝置掉線接手、CLI 自動 clock master、真實視窗攝影或 flow check；
原裝置恢復、AEC/VAD 探測、全裝置 reset 與會寫取樣率的測試也都排除。驗證模式完全
禁用 saved-route auto-start 與偏好設定寫回，`start()` 另有最後一道拒絕，所以 render、
icon、screenshot 與 flow 都不能因為磁碟上留著 auto-start 而開啟它。三個 raw value
與一般 USB／內建輸入的相反行為都有數值斷言。

還沒完成的是**沒有 scripting dictionary 的播放器目前歌曲辨識**。程式已接上公開
ShazamKit，直接吃現有 application tap 的聲音，所以 QQ 音樂、網易雲、瀏覽器都走同一
條路；真實 Spotify〈年少心動雨季〉驗證時，tap 為 **−6.4 dBFS**、259,584 samples
寫入、0 dropped，但 ad-hoc 建置的 Shazam 目錄回 `ShazamCore 102`。這不是音訊或簽名
格式失敗：Apple 要求在 Developer 帳號的 App ID 先啟用 ShazamKit。正式簽章完成前，
這條路徑只顯示可行動的理由，且一次失敗後停止重試；QQ／網易雲的歌詞來源不受影響。
- **調性偵測已經在真的 Spotify 音訊上驗證過。** 不是播放器說「playing」就算：
  flow check 同時量到 Spotify tap **−8.5 dBFS**、analysis ring 寫入
  **244,480 samples**、等待 512、丟棄 **0**，20 個 chroma 視窗合計能量
  **16,704.8**，最後報 C♯、信心 34%。歌曲資訊同一輪讀到歌手、歌名與 146 秒位置，
  所以 `.lrc` 配對與時間線的上游也真的有回答。

這次修的是兩個後來才加進去的回歸，不是補一個從未存在的功能。最初版已經會從
Spotify 讀歌名、歌手、播放位置與長度，再按名稱配本機 `.lrc`；後來把問答挪到背景後，
Spotify 接受 Apple Event 卻不回答時會永久占住串列佇列，`isAskingThePlayer` 也永遠不
會清。現在每次腳本有 **2 秒**上限，timeout、Automation 被拒與其他 Apple Event 錯誤
分開，暫時失敗保留上一首歌與歌詞而不是把面板清空。

另一個回歸在更底下：`AudioDeviceStart` 實測會回 `noErr`，但一次 IOProc 都不呼叫。
當時 preset 後 cycle count 是 **0**，所以 Spotify tap、錄音、分析器一起讀到靜音，看
起來卻只像 KTV 壞掉。每次 start 現在必須在 **750 ms** 內完成至少兩個 IO cycle；
否則先以完全相同的配置重試一次，仍失敗才具名報錯並完整拆除。

又找到一個會讓「第一次有歌詞，重啟後永遠沒有」完全成立的生命週期錯誤。完整
`engine.stop()` 會釋放逐來源 transcript rings，但 app 端的 `sourceTapsOpen` 與來源
UID 快取沒有失效；相同來源再次啟動時，它因此把底層已不存在的 **0 個 tap** 當成仍可
重用。現在完整停止明確清掉 open flag、UID 與 opened count；只有「仍開啟、count 大於
零、來源完全相同」三項同時成立才重用。這個判斷有四組數值斷言，另有結構測試要求
`finishStop()` 一定失效 tap，而且 20 Hz steady poll 不得再讀 engine state lock。

同一條路徑原本每次 50 ms poll 都建立一個 MainActor `Task`，跨過每個 transcriber actor
拿回從開場至今的所有句子，再重新合併與排序整份逐字稿。沒有任何人說話時，一分鐘仍是
**1,200 個 Task、1,200 次完整歷史走訪與排序**。現在 transcriber 只在一句完成時送出
那一句；app 以 UUID 去重、二分搜尋時間位置，停止時才做一次 final catch-up。空閒一分鐘
三者都是 **0**，新增一句只發布一次。callback 的 exactly-once、跨來源時間排序、停止
後補收與 session generation 都由單元或結構測試固定。676 個單元測試、125 個套件與
swift-format lint 全綠；這一階段沒有啟動任何音訊裝置。

### 2. MIDI 的另一半 [本機實測]

CoreMIDI 直接寫、沒有第三方相依、推桿有 soft takeover，這些都做完並測過了。

**但這台機器沒有任何 MIDI 硬體**（`MIDIGetNumberOfSources()` 回 0），所以測試用的
是一個本行程自己發布的虛擬 source。**還沒測到的**：真實硬體的訊息流（running
status、14-bit 高解析 CC 對、多個 source 同時）、以及 MIDI 2.0 往下轉譯那條路。

### 3. 每個來源、每條匯流排各自的處理 [V]

VoiceMeeter 每條匯流排都有完整的參數等化器，所以直播混音可以跟耳機混音調得不一
樣 [V]。這個專案的效果鏈全部是麥克風的人聲鏈，那是刻意的。

耳機補償已經證明了**輸出側掛 biquad 級聯是可行且零配置的**，所以「每條匯流排一條
鏈」現在不是新機制，而是同一個機制多開幾份。值得單獨做一次設計。

### 4. OBS 對接 —— **第一版已完成，但沒有人在真的 OBS 上驗過** [本機實測 + 未驗]

`RESEARCH.md` 第 8 節是這一輪的決定與量測，完整版在那裡。摘要：

**已做**：`Sources/YunAudioOBS/` 是一個 obs-websocket v5 客戶端
（`URLSessionWebSocketTask` + CryptoKit，零第三方相依）；偏好設定多了「直播」分頁；
`OBSSyncOffset` 把效果鏈的延遲換算成 OBS 的同步偏移；麥克風靜音可以鏡射過去。

**驗到哪裡**：認證字串對得上協定文件那組 challenge/salt（答案用 Python 與 OpenSSL
各算一次交叉驗證）；完整握手對著一個用 `Network.framework` 架的 stub 伺服器跑通，
六個測試全過；2688 frames @ 48 kHz 在線上是 −56 ms。

**沒驗到什麼，明講**：**這台機器上沒有裝 OBS**。上面沒有一條可以宣稱對接是通的。
需要一個人跑 `brew install --cask obs`，步驟寫在 `RESEARCH.md` 8 節開頭。

**刻意留著沒做**：browser source overlay 與自動建場景。理由不是不好，是它在這台機器
上一個字都驗不了，而這個專案的問題正是「功能多到沒被驗證過」。等有人裝了 OBS、而且
願意看著畫面驗收的那一次再做。

**要決定的一件事**：OBS 的 websocket 密碼現在**不存檔**，每次連線要重貼。理由是
`UserDefaults` 是家目錄裡的明文檔，而這個 app 自己的控制 socket 是 `chmod 600`。
正確的家是 Keychain，擋路的是這個專案的散布方式：ad-hoc 簽章每次建置身分就變，
keychain 項目會每次啟動都跳授權。**這需要使用者選一邊。**

### 5. CoreAudio 內建的語音活動偵測 —— **已完成，而且量到一件差點錯過的事** [本機實測]

**屬性在 input scope，不在 global scope。** 用 global 問，這台機器上**沒有任何一個
裝置**公布這個偵測器 —— 連內建麥克風都沒有。就是那個讀數讓這件事值得去量而不是去
相信。改問 input scope，八個輸入裝置**全部**公布，而且 `vAd+` 全部可設定。

它真的會觸發，這件事是證明的不是假設的：`yunaudio-cli vad BlackHole --prove` 把合
成語音播進 loopback 裝置的輸出、從同一個裝置的輸入讀回來、路過時量電平，然後斷言
偵測器報告了語音 —— 三次跑三次都是。那個電平表不是裝飾：早期有三分之一的跑次
loopback 什麼都沒帶過去，而沒有電平表的話，那看起來跟「偵測器不會動」一模一樣。

這個證明**不能**放進 flow check。路由正在跑的時候，把 `AVAudioEngine` 指向 aggregate
持有的裝置，`start()` 會從 Objective-C 丟出例外，`try?` 接不住，整個應用程式當場
掛掉，而且後面每一節都靜默地沒有跑。第一版就是這樣。

介面上是「**已靜音，但你在說話**」這顆藥丸，只在那一刻出現，然後自己消失。

同一趟的另一半 —— **已完成，而且量到的東西跟預期相反** [本機實測]

macOS 26 的 `CATapDescription.processRestoreEnabled` 與 `bundleIDs` 現在接上了
（`ProcessTap.init(processIDs:muteBehavior:bundleIDs:)`），而量出來的事實是：

**`processRestoreEnabled` 的預設值本來就是 `true`。** 這個 app 建的每一個 tap 一直
都開著它，也一直什麼都沒還原 —— 因為 `bundleIDs` 預設是空的，沒有東西可以記。
**缺的一直是 `bundleIDs`。** 只設旗標會是一個零效果、看起來完全像修好了的修改。

證據讀的是**系統持有的** description（`kAudioTapPropertyDescription`），不是自己手上
那一份 —— 因為 `kAudioSubDeviceInputChannelsKey` 已經教過一次「HAL 收下然後丟掉」長
什麼樣子。四個斷言在 `ProcessTapRestoreTests`，還有一個 `yunaudio-cli tap-restore`。

順帶量到一條直接對上 #9144 的能力：**可以替一個沒在跑、甚至沒安裝的 app 建 tap**
（只給 `bundleIDs`，`processIDs` 是空的，HAL 回 `noErr`）。

**還沒驗的**：「app 重開之後音訊真的回來」。那需要有人去關掉再打開一個應用程式：
`yunaudio-cli tap-restore <名字> --watch`。

### 6. 腳本介面 [M]

Audio Hijack 的 JavaScript API 是所有評論都特別點名的功能 [M]。而空門是：
**Loopback 完全沒有 scripting、AppleScript 或 Shortcuts** [M]。

`JavaScriptCore` 是 macOS 內建的，所以直譯器免費。工作在於設計一個穩定的物件模型
與事件分派 —— 那是一個關於相容性的承諾，所以它排在比較便宜的項目後面。

### 7. 散布 —— **改走「自己建」，不走公證** [本機實測]

沒有付費的開發者帳號，所以公證與 Homebrew cask 都不在路徑上。這不是退而求其
次：**本機建置的 binary 不帶隔離屬性，Gatekeeper 根本不會介入**，而開源專案本來就
是這樣散布的。要付錢的那條路留給以後真的需要給非技術使用者時再說。

已實測，不是假設：把這個 repo clone 到另一個目錄、從乾淨的 checkout 建，**app 建
得起來、503 個測試通過、`./App/verify.sh` 全綠**。這件事現在是 `--fresh` 一個步
驟，因為它是唯一能抓到「在我這台機器上可以」那一類問題的檢查 —— 沒被 add 的檔
案、剛好存在的路徑、其實不是由腳本產生的建置產物。

---

## 發布檢查表

分成兩個目標，因為擋住它們的是不同的東西。

### 發 beta（給願意自己建的人）

- [ ] **擷取的應用程式沒有變成路由** —— 範圍已經縮小，比原本寫的窄很多。
      **有套件識別碼的應用程式（Discord、Spotify、OBS）沒問題**；出事的只有沒有套件
      的行程（命令列工具），而且是間歇的。招牌功能沒有壞，壞的是它的一個角落。
      詳見上面「擷取沒有套件識別碼的行程」那一段：已排除資源耗盡與行程退出，根因
      未明。**擋不擋 beta 是一個判斷**，因為會踩到的人是拿 `ffmpeg`、`afplay`
      這類東西當來源的人。
- [ ] 完整 flow check 剩下的失敗，是程式就修，是檢查問錯問題就改對並說清楚。
- [ ] **安裝與移除各走一遍全新的機器心智。** `DriverInstaller.uninstall()` 存在，
      但沒有人在真的裝過驅動的機器上驗證過它。**一個拔不掉的驅動比一個裝不上的
      糟得多。**
- [ ] README 加一段「怎麼在你自己的機器上跑起來」，並誠實寫出：macOS 26 起跳、
      驅動要 sudo、Gatekeeper 對下載來的 binary 會擋、驗收方式是 `./App/verify.sh`。
- [ ] `./App/verify.sh --full --fresh` 全綠。

### 開源（推上公開 repo）

- [ ] **git 歷史裡有 Razer 的專有二進位檔，5.2 MB。** 資料夾刪了，commit `e0be295`
      沒有。現在推上去就是在散布別人有版權的檔案。**這是唯一一個不能先發再說的
      項目。** 兩條路：`git-filter-repo` 重寫歷史（172 個 commit 的 SHA 全變），或
      開新 repo 從壓平的歷史開始。建議後者 —— 歷史裡的價值已經萃取進
      `DEVICES.md`，而重寫會讓每一則 commit 訊息的關聯失效，而那些訊息本身就是
      這個專案的文件。
- [ ] LICENSE 已經有了（MIT）。「關於」面板說的和檔案一致。
- [ ] AGENTS.md 已經是給改動者看的；README 需要一段給貢獻者的。

### 刻意不做

TODO 上還開著的 **KTV 下半、MIDI 另一半、OBS 對接**，第一個版本都不做。

這個專案現在的問題不是功能不夠，是**功能已經多到沒有全部被驗證過**。光是今天就從
三個標著「已完成」的功能裡挖出：時鐘鎖復原丟掉整條處理鏈、監聽輸出拖垮主混音、腳
本引擎完全沒有介面。**第一個版本要做的是把已有的東西縮到能保證的範圍，不是再長
大。**

OBS 對接是真的空門（競爭者全都沒有），但它是一個新的外部相依，而 beta 的目的是找
出你不知道的問題，不是增加你要負責的表面。留到 1.0。

---

### 7b. 公證 + Homebrew cask [V] —— 等有付費帳號再說

Audio Hijack 遷到 ARK 之後是「秒裝、不重啟、不要密碼」[M]；SoundPipe $10 而且已經
在 cask 裡 [V]；FineTune 免費、八個月八千星 [V]；OBS 的 ScreenCaptureKit 擷取完全
不用驅動。

**散布的摩擦現在是我們最大的單一劣勢。** 正確的形狀是：一個免安裝的一級模式（tap、
效果、錄音、轉錄、監聽全部不需要驅動），加上「裝驅動換到可證明的 bit-exact 路徑」
這個升級。

FineTune 反應數最高的 issue 就是這個，開站兩天後就有人提 [V]。卡在跟散布同一件事：
驅動是 ad-hoc 簽章，而 cask 要的是公證過的東西。

---

## 定位：不要跟他們比功能，比可驗證 [V]

`RESEARCH.md` 讀完所有競爭者的 release notes 與產品頁之後最重要的一句話：

**沒有任何一個競爭者提出過一個可以被別人重跑的數字。**

Rogue Amoeba 那疊、Wave Link 3、eqMac、Krisp、FineTune、SoundPipe —— 全部是功能清
單與修 bug。Krisp 唯一給的毫秒數只有行銷頁，沒有論文、沒有 benchmark、沒有可驗證的
來源。

`MEASUREMENT.md` 是這個專案唯一沒有人能在一季內抄走的東西。多混音會被抄（已經被
Wave Link 3 免費做掉了），逐字稿會被抄，EQ 會被抄。**「這是我們的方法，你自己跑跑
看」不會。**

## 值得先探一下的

每一項都只需要回答一個問題。

### macOS 有沒有 AirPods 高品質錄音的對應 API？[?]

macOS 26 有 `AVAudioSessionCategoryOptions.bluetoothHighQualityRecording`，但
`AVAudioSession` 是 iOS 的框架，**macOS 有沒有 CoreAudio 對應物未經查證**。翻半小時
header 就有答案。

就算沒有，還有一個結構上的答案沒人包裝得好：aggregate 可以讓 AirPods 只當輸出，而
由**另一個裝置**供應麥克風，這樣編解碼就不會降級。SoundSource 6.0 出的就是這個 [V]。
需求訊號是整份研究裡最強的 —— 一個只做這件事的 app 在 Show HN 拿到 223 分、309 則
回應，而且至少有五個專案只為這件事存在 [V]。

### 圖示的原始檔還是 512，不是 1024 [本機實測]

圖示已經改成程式繪製：`YunIconBadge` 每個 `.icns` 欄位各自以原生解析度畫出來，不
再由一張點陣圖放大十份。但**羽毛本身仍然是一張 512×512 的 PNG**，所以 1024 那格
還是 2 倍放大 —— 比原本的 5.7 倍好很多，但不是零。

要收掉這一項只需要一件事：拿到 1024 以上的原圖，或者更好，拿到向量原稿。放進
`Sources/YunAudioApp/Resources/Icon.png` 就會被吃進去，**不用改任何程式碼** ——
墨跡邊界是啟動時從圖檔量出來的，不是寫死的常數。

### Finder 顯示的圖示還是不能在執行中換 [本機 SDK]

「設定 → 外觀 → 應用程式圖示」已經可以切換，但它**到不了 Finder**。iOS 有
`setAlternateIconName`，macOS 沒有對應 API；唯一能就地換掉 bundle 圖示的辦法是把
自訂圖示寫進 bundle（`NSWorkspace.setIcon`），而那會**破壞程式碼簽章**。這個 app
簽的是麥克風權限，簽章一破代價不是圖示變舊，是麥克風權限被撤銷 —— 為一張圖不值得。

所以現況是：偏好設定改的是**應用程式自己畫出來的**每一個圖示（關於面板、
`NSApp.applicationIconImage`，因此也包含它的警示與通知），Finder 那個要
`./App/make-icon.sh --style <名稱>` 重建。

如果哪天真的要收掉這一項，唯一乾淨的路是**重簽**：換圖示之後就地重新 codesign。
在「自己建」的散布模式下這是可行的（見「7. 散布」），在公證的模式下不是。還沒做，
因為沒人抱怨過。

### tap-only 模式，驅動變成選配 [M]

Rogue Amoeba 遷到 ARK 之後，Audio Hijack 的擷取**不需要改安全性設定、不需要安裝任
何東西、也不需要輸入管理員密碼** [M]。我們的驅動要 sudo 又會重啟 `coreaudiod`，這
件事已經從中性變成劣勢。

這個應用程式做的事情裡有很大一部分 —— tap、效果、錄音、轉錄、監聽 —— 根本不需要
驅動。那個子集能不能成為一級模式、而驅動變成「買到 bit-exact 時脈鎖定路徑」的升級，
是產品問題跟技術問題各半。

### 「只監聽」表達不出來 [本機實測]

OBS 有三態監聽（關／只監聽／監聽並輸出）。這裡是「每來源一個連續的 dB 送出量」到單一
監聽裝置，所以「關」和「監聽並輸出」都表達得出來，**「只監聽」表達不出來** —— 因為
`setMuted(_:for:)` 掐的是 route，而 route 同時餵主混音和監聽。

修法很便宜，而且已經有現成的東西：監聽的 route 索引是分開存的
（`monitorRouteIndices`），所以「靜音但保留監聽」就是**只把非監聽的那幾條 route 靜音**。
可以斷言：靜音之後監聽匯流排的電平不變、主匯流排的變成零。

沒有在 OBS 那一輪做，因為它動的是靜音的語意，而那時別的工作正在同一塊。

### VBAN 網路音訊 [V]

VB-Audio 自家的 UDP 協定：8 進 8 出、規格公開有文件（不像 Dante），而且已經有一個
iOS 遙控 app 在講它 [V]。如果哪天網路音訊變得有趣，這是可行的目標。

### Elgato Wave Link —— **已解，而且是壞消息** [V]

**Wave Link 3.0.0 在 2026-03-03 上了 macOS，免費，而且支援任何麥克風不只 Elgato
自家的。** Wave Link 2 已 End of Life。3.2 版還做了三件跟我們直接相關的事：**離開
App 沙箱**以降低 AU 延遲（他們遇到了跟我們一樣的 out-of-process AU 成本問題）、
**Siri / Spotlight / Shortcuts**（他們有 App Intents，我們定案做不到）、以及**具名
的虛擬混音輸出**（最多五個混音）。

他們的介面是**橫向矩陣：來源在左、混音在右** —— 那正是 RME TotalMix 三十年的模型。
兩個獨立產品收斂到同一個形狀，是這個形狀對的很強證據。

**對我們的意義**：「多混音 + 每個 app 一條 channel + 虛擬裝置 + 免費」在 macOS 上
已經被一個 Corsair 支持的產品佔住了，不能再假設那是空地。

但他們**沒有的**（在讀過的所有頁面裡沒出現）：bit-exact 驗證、BS.1770 響度、
per-source 逐字稿、共振峰變聲、時脈鎖定 —— 以及**任何一個數字**。他們的 release
notes 全部是功能與修 bug。**也沒有 OBS 對接。**

---

## 已定案 —— 沒有新證據就不要再試

每一項都花掉了真實的時間。`README.md` 與 `DEVICES.md` 有完整的寫法；這裡是索引。

- **`kAudioSubDeviceInputChannelsKey` 沒有作用** [本機實測]。header 讀起來像限制，
  實際上是描述：三個輸入的裝置要求只給一個，仍然給三個；一個輸入要求給零，仍然給
  一個。這堵死了「把藍牙耳機的輸入排除在 aggregate 外」這條路。**這個結論本身有斷
  言**，所以哪天 macOS 開始認這個 key，我們會知道。隔壁的
  `kAudioSubDeviceExtraOutputLatencyKey` 是**真的有用**的：要 480 frames 就量到 480。
- **`AUAudioMix`**（macOS 26 那個可調的語音／環境分離器，紙面上是這個平台最有差異
  化的東西）**不能即時跑**。它拒絕單聲道與立體聲輸入、要五聲道輸出、而且需要
  `kAUAudioMixProperty_SpatialAudioMixMetadata` —— 那是相機寫進 Cinematic 資產的擷
  取時 metadata，麥克風給不出來。三個限制都有斷言。**唯一沒有被量測排除的用途是對
  已錄好的 stem 做離線處理。**
- **MLX** 在命令列的 SwiftPM 下建不出它的 Metal shader，而且不會退回 CPU —— 它會載
  不到 metallib 然後把整個行程帶走，在一個三元素的乘法上。另外 2048 點的轉換是一個
  「啟動與同步比算術貴」的尺寸。MLX 要有一個訓練好的模型要跑，才輪得到它。
- **App Intents** 會編譯、會執行、而且永遠不會出現在任何人用得到的地方：Shortcuts
  資料庫裡的項目是靠 Xcode 自己的 build phase 抽出的 metadata 被發現的，而用 shell
  script 包 SwiftPM binary 組出來的 app 產生不了那份 metadata。URL scheme 是答案，
  直到建置方式改變為止。
- **`onOpenURL` 與 `application(_:open:)`** 在沒有視窗的選單列 app 裡都不會觸發，
  而且 `open` 仍然回報成功。底下那層的 Apple Event handler 才行得通。
- **路由迴圈改用 vDSP 反而更慢** [本機實測]。512 frames 兩條路由是 1501 ns 對
  954 ns：Accelerate 的 strided 入口會退回純量，而**交錯音訊永遠是 strided**。手寫
  迴圈留著，理由寫在原地。
- **寫 OBS 原生外掛** [V]。obs-websocket v5 已經夠了 —— 音量、靜音、同步偏移、音軌、
  建立來源、事件訂閱全都在協定裡，而且客戶端只要 `URLSessionWebSocketTask` 加
  CryptoKit。外掛會把這個專案綁進 OBS 的建置與 ABI，換來的東西一樣也沒多。
- **繼承 OBS 的六軌錄音模型** [本機]。`MAX_AUDIO_MIXES` 是 libobs 的編譯期常數，是
  **別人的 muxer 上限**；這裡的 stem 是檔案，沒有那個上限。指派 OBS 的音軌是對的
  （`OBSRequest.setTracks` 留著），照著它重新設計自己的錄音不是。
- **鏡射 OBS 的電平表**（`InputVolumeMeters`，每 50 ms 的高流量事件）。換來的是同一
  件事的第二個真相，而兩個電平表不一致的時候沒有人知道該信哪一個。訂閱常數留著。
- **把 OBS 的動詞加進 `RemoteCommand`**。`RemoteCommand` 是這個 app 答應要一直支援的
  詞彙，obs-websocket 是別人可以改的詞彙。`YunAudioOBS` 因此是獨立的 target。
- **即時神經變聲**（fish-speech、RVC）需要遠超過一百毫秒，而這裡的期限是 2.7 ms。
  今天出貨的每一個即時變聲器做的都是我們做的這件事；差別是這個會講出來。

---

## 已經完成的（免得有人重做）

排除清單 · 設定組（Quick Configs）· 輸出對齊 · 裝置掉線自動接手 · URL 遙控 ·
具名 A/B 匯流排 · 耳機補償（AutoEq）· 十段輸出音色（Razer 的頻段中心）·
即時逐字稿（每個來源分開，不靠聲紋猜）· 擷取隨 app 重開自動接回（`bundleIDs`）·
obs-websocket v5 客戶端與同步偏移 · MIDI learn · 設定視窗（語言／主題／
強調色／緩衝區）· 選單列面板重整 · 底部藥丸狀態列 · 應用程式清單的三個缺陷 ·
V2 X 與 Barracuda 裝置設定檔 · 聲音分頁拆成三區 · 場景預設真的各自不同 ·
效果鏈熱抽換 · IOProc 快 19–49% · 閒置輪詢從 1501 µs 降到 174 µs ·
V3 Pro 的硬體增益與零延遲監聽 · KTV 的歌詞與調性偵測 · `MEASUREMENT.md` ·
`DEVICES.md`

---

## 競爭態勢，研究當下的樣子

留著，因為上面好幾項的排序是它決定的。

**時間比看起來緊** [V]。SoundSource 6.0 在 2025-12-03 出、6.1 在 2026-07-21 出。
兩者之間加了：Output Groups、Quick Configs、偏好裝置順序、每 app 耳機 EQ、定時靜
音、平衡與相位、cough button、最近噪音指示、強制軟體音量控制、「避免 AirPods 與其
他藍牙裝置的音質問題」，以及 6.1 的「不再對藍牙裝置套用不必要的 drift correction」。
那份清單幾乎就是這次研究本來要建議的，他們八個月內出完了。

**FineTune** 2026 年 1 月上線，免費 GPLv3，8,317 星、142 個開放 issue [V]。
**SoundPipe** 用 $10 把 Loopback 砍了十倍 [V]。

**價格，從他們自己的購買頁 [V]**：Audio Hijack $69 + Loopback $99 + SoundSource
$49 + Airfoil $35 + Farrago $55 = **$307**。這個專案已經涵蓋其中三個的一部分。研究
找到最大聲的抱怨是**這一整疊的價格**，不是任何單一個。

**沒覆蓋到的部分，明講而不是糊過去**：直播主那一群（Elgato Wave Link、RØDE
Connect/UNIFY、VoiceMeeter）以及 OBS/Krisp/REAPER 那一群從來沒回報。這裡關於它們的
內容只來自單次搜尋，比其他部分薄。
