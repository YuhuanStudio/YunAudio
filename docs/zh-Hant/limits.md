# 限制

← [README](../../README.zh-Hant.md) · [English](../limits.md)

## 已排除的方案

**`AUAudioMix`。** macOS 26 內建了一個分級的人聲／環境分離器 —— 它是
`AUSoundIsolation` 那種「開或關」的可調版本，帶一個 Studio 風格（Apple 對
NVIDIA Broadcast 的回答），而且是連續的混合比例而不是一個開關。紙上看，它是這個平台
上最有差異化的東西。

**它不能用在即時路徑上，而且理由是量出來的，不是推論的**：它直接拒絕單聲道與立體聲
輸入、要求五個輸出聲道而不是四個，而且就算兩邊格式都餵對了它仍然無法初始化 ——
因為它需要 `kAUAudioMixProperty_SpatialAudioMixMetadata`，那是相機寫進 Cinematic
素材裡的擷取期中介資料，麥克風沒有任何辦法提供。

它是一個**素材後製用**的 Audio Unit。把單聲道麥克風編碼成 ambisonics 只是算術；
那份中介資料不是。測試把這三個限制全部斷言下來，所以將來某一版 macOS 只要放寬其中
任何一項，這個專案會知道，而不是再也不去看。

**MLX。** 為音高追蹤試過，然後移除。mlx-swift 自己的 README 就寫著：命令列上的
SwiftPM 沒辦法建置它的 Metal shader；而 MLX 在函式庫缺失時**不會退回 CPU** ——
它載不到預設的 metallib，然後把整個程序一起帶走，而且是在一個三元素的乘法上。

除此之外，就算 Metal 正常也一樣成立：在少數幾個 frame 上做 2048 點轉換，是一個
「啟動與同步的成本高於算術本身」的尺度。vDSP 就是 Apple 為這件事寫的。MLX 值得上場
的時機是有一個訓練好的模型要跑，那是另一個功能、另一種建置。

**用 `kAudioSubDeviceInputChannelsKey` 把藍牙麥克風排除在 aggregate 外。** 實測這個
key 是描述而不是選擇：三個輸入要求一個仍得到三個，一個輸入要求零仍得到一個。測試保留
著，將來 HAL 改變就會被發現。macOS 也沒有 iOS
`AVAudioSessionCategoryOptionBluetoothHighQualityRecording` 的對應 API；它明確標成
macOS 不可用。高品質藍牙輸出必須改用另一台裝置供應麥克風，再以真實耳機驗證。

**把 AVFoundation 當成乾淨監聽輸出。** macOS 27 SDK 的空間渲染能力在 AVFAudio，並
不是 Core Audio 裝置屬性。改走 `AVAudioEngine`／`AVAudioEnvironmentNode` 會替換輸出
路徑、增加需要另量的延遲，而且按定義終結位元精確。它最多適合明確標成 processed 的
output-only bus，不是監聽路徑的替代品。

**用 MediaRemote 擴大 now-playing 控制範圍。** 在實測主機上 private framework 與符號
都載入成功，但查詢一律回空字典；同一個播放器同時能以 Apple Events 讀到資料。會靜默失敗
的 private API 不是可支援的 fallback。公開 API 補上缺口以前，整合邊界仍是播放器的
scripting dictionary。

**在目前 shell 組裝的 SwiftPM bundle 裡加 App Intents。** 程式會編譯、會執行，但目前
打包方式不會產生讓 Shortcuts 與系統體驗發現它的 metadata。未來遷移 app packaging 後，
應直接重用現有 remote-command vocabulary；現在複製一份命令只會得到無法被發現的第二介面。

**用 strided vDSP 取代交錯音訊的 routing loop。** 兩條 route、512 frames 的實測是手寫
loop 954 ns，vDSP 1,501 ns，算術完全相同。交錯音訊使存取必然帶 stride，短迴圈的呼叫與
fallback 成本高於純量工作。

**即時神經變聲。** 48 kHz／128 frames 的期限是 2.67 ms；目前 RVC／fish-speech 類完整
pipeline 在排程與裝置延遲以前就需要遠超過 100 ms。除非整條 pipeline 實測能通過 realtime
admission budget，否則只能做離線或明確標成高延遲的處理。

## 現行限制

- 驅動是 ad-hoc 簽章。散布需要 Developer ID 身分與公證。
- 人聲隔離會讓 `AudioUnitRender` 在 IO 執行緒上配置記憶體 —— 每個週期大約 0.3 次，
  來自 Apple 模型內部而不是這裡的程式碼。旁路路徑維持在剛好零。測試中它沒有造成過
  斷音，但它開著的時候即時契約是破的。
- 驅動出錯會把 `coreaudiod` 連同所有掛在上面的系統音訊一起帶下去。上面那條移除指令
  要留在手邊。
- 虛擬裝置的輸入電平控制已經實作，但只驗證到「可以編譯」和「以檢視確認公開方式正確」；
  沒有在真機上從系統設定裡真的拉過它，因為安裝驅動會重啟 `coreaudiod`。
- 回音消除的代價是時鐘鎖定和位元精確，並在來回各增加一個緩衝區的延遲。這不是留待
  以後修的缺陷：消除器必須同時擁有麥克風和喇叭，所以麥克風會離開路由器的聚合裝置，
  時鐘主控變成目的地。用筆電喇叭時值得，用耳機時完全不值得，所以它預設關閉，而且
  介面會在你打開它之前先說清楚代價。
