# 會議助手：原生開發前置紀錄

日期：2026-11-26。Kurn 基線 `/Users/audichuang/Project/meeting-assistant-kurn`，本機分支 `audi/local-preparation`，commit `b8d6db1ba9f01639bacbb744ff751c21b59f4aa5`；origin 的 push URL 刻意設為 DISABLED。這是原始來源的獨立本機 checkout，尚非公開 fork，不推送、不上架。

## 授權核對清單（初版，非完整 SBOM）

| 項目 | 基線聲明 | 開發／分發前的動作 |
|---|---|---|
| Kurn | MIT，見 checkout 的 LICENSE | 原始碼複用時保留版權與授權聲明；審核商標、資產與引用程式碼的來源。 |
| FluidAudio | Apache-2.0，見 THIRD_PARTY_NOTICES.md | 保存 LICENSE、NOTICE 及必要修改說明；模型權重另審。 |
| sherpa-onnx | Apache-2.0，見 THIRD_PARTY_NOTICES.md | 核查 ONNX Runtime 與其他轉移依賴；保留各自授權。 |
| whisper.cpp | MIT，見 THIRD_PARTY_NOTICES.md | 核對 XCFramework 下載來源、二進位版本、notice 與權重授權。 |
| NVIDIA Nemotron 部分權重 | OpenMDW-1.1，依 THIRD_PARTY_NOTICES.md 的具體模型 | 使用前逐個核對權重、授權文本與適用限制；不得把 framework 的 Apache 授權當成權重授權。 |
| Bark／Phonon 等部分權重 | CC-BY-4.0，依 THIRD_PARTY_NOTICES.md 的具體模型 | 檢查署名、修改說明及權重版本；其他模型逐一核對。 |
| Gemini API | 雲端服務，非此 repo 的 MIT 程式碼 | 先核對企業合約、資料駐留、留存、可用模型、費率及同意；不把密鑰放在 App。 |
| Meetily | 社群版 MIT；Pro 獨立 | 只參考已核實且授權明確的社群版檔案；不用未授權 Pro 代碼。 |

開發者須從 Package.resolved、binary XCFramework、實際選用模型及 transitives 生成完整 SBOM，核查確切 commit/hash、LICENSE/NOTICE、模型下載來源與必要署名；上述清單並非法律審查或分發許可。

## 與介面無關的實作設計

1. **音訊核心**：以現有 `Kurn/Services/AudioRecorderService.swift` 及 `RecordingOperationJournal`／`RecordingRecovery` 為參考；單一 AVAudioSession coordinator 建立原始輸入 tap，先可靠地送本機寫入，再由獨立受限佇列分流分析。捕捉 callback 不做網路、資料庫、模型推論或阻塞 I/O。保存輸入格式、來源與相對時間；中斷／路由變更記錄缺口，不宣稱無損連續。
2. **恢復及資料安全**：在實作前確認既有 audio sink、檔案保護等級、segment 原子提交和 journal 語義；為磁碟不足、程式中止、重開、鎖屏、route change、media services reset 建立合成資料測試。原音與衍生資料分離；刪除策略包括 journal、索引與備份，企業政策核准前不雲傳。
3. **資料模型**：沿用／評估 `Meeting`、`Recording`、`Transcript`、`Summary` 及現有 migration 版本；新增建議、證據時間範圍、顯示／抑制／忽略／回饋事件、同意紀錄、匯入脈絡、待審記憶提案。版本化 schema；修訂不覆蓋原始逐字稿，信心缺失保持 nil。先設計遷移與刪除測試，再改 SwiftData schema。
4. **可替換分析路徑**：核心組是 PCM → Gemini Live native audio → 經驗證的文字／工具事件 → 有證據的卡片；對照組是 PCM → `gemini-3.5-transcribe-live` VERBATIM final transcript → 文字推理 → 靜默結構化卡片。對照組不能替代直接聽音的核心需求；兩者都需明確政策、同意與實際端點驗證。
5. **測試策略**：fixture 使用合成音訊／合成轉寫；clock／filesystem／network injectable。驗證片段時間單調、source file hash、journal crash recovery、磁碟不足、拒絕同意時禁止啟動雲端、輸出可追溯、duplicate／out-of-order 防重。真實麥克風、鎖屏、Teams 路由、PencilKit 並行、能耗及 Gemini 連線均保留 iPad 實機 POC。

## Live Transcribe 對照的已確認條件

Developer API 官方文件：`gemini-3.5-transcribe-live` 是以 `v1beta` WebSocket/SDK 使用 `TEXT` 回應模態的專用串流轉寫，`input_transcription` 是 finalized；VERBATIM 為預設逐段文字，SMART 可能整理或改寫逐字稿。Live 支援最多 10 分鐘 session，不提供即時 diarization 或逐字時間戳，提供語句層級時間戳。官方語言清單有簡體中文及粵語繁體，但未列臺灣華語繁體；不等於已證實不支援辨識，需實測台灣口音與繁體輸出。Developer API 2026-11-26 公開估算音訊輸入約 $0.005/min、文字輸出約 $0.004/min（假設 25 audio tokens/s、175 text tokens/min），合計約 $0.009/min，尚不含下游推理、重送、稅及企業價格。來源：https://aistudio.google.com/docs/live-api/live-transcribe 和 https://aistudio.google.com/docs/pricing#gemini-3.5-transcribe-live 。

## 範圍與下一步

原型外觀等 Audi 意見；本階段不連接真實會議、不發送私人資料、不改 upstream、不上傳 TestFlight。確認 Xcode 依賴解析後執行不簽章 simulator build；裝置和 runtime 可用時建立獨立 iPad mini 模擬器以驗證，不沿用或改動別人的模擬器。實機錄音、企業帳號與簽章權限不應由純編譯結果推論。

## 重要隱私差距：Kurn 既有聲紋

固定版 `Kurn/Models/Recording.swift` 含 `speakerVoiceprintsData`（label→向量持久化），`Kurn/Models/Speaker.swift` 含 `voiceprintData`，`TranscriptionService` 的結果亦可攜帶 voiceprint；存在 SpeakerIdentityMatcher。這些能力與本產品預設不處理持久或跨會議聲紋的要求有實質差距，不能直接把上游 checkout 視為隱私符合的可使用產品。匿名分群即便暫時以特徵向量運算也需要依公司政策與同意範圍處理；無核准時須禁用或改造會建立、保存及比對聲紋的相關路徑，並以測試證明預設沒有持久聲紋、沒有跨會議身份比對；已存資料的遷移／刪除另設計。此項應在任何真實錄音或真實人士的聲音測試前完成。

## 本次檢查與測試結果

- Mac：Xcode 27.2 (27B52)；安裝 iOS 27.2 simulator runtime；有 iPad mini A17 Pro、mini 6th generation 等裝置類型，但可用裝置清單沒有本專案的 iPad mini 實例。其他專案開機中的模擬器未觸碰。
- Xcode project 設定：主 App `IPHONEOS_DEPLOYMENT_TARGET=26.0`、`SWIFT_VERSION=6.0`、iPhone/iPad；UI 測試 target 為 iOS 26.5／Swift 5.0。以專案實際設定為準，不自行調整。
- KurnCore 合成／純資料測試：`swift test --filter 'ChunkBoundaryTests|TranscriptFusionTests|SpeakerTurnSmoothingTests'` → 39 tests、3 suites、0 failures；`swift test --filter 'SystemFileSystemTests|ReliabilityEventTests'` → 9 tests、2 suites、0 failures。未看到 skipped 報告。以上均在 macOS host 執行，不是 iPad AVAudioEngine、SwiftData 或實機錄音測試。
- `python3 Tools/check_static_policy.py` 通過，沒有新增 violations；基線包含 3 fatal-error 和 3 custom-url-session 項目，非零基線不可誤稱完全無問題。
- `xcodebuild -list -project Kurn.xcodeproj` 解析三個遠端套件與 XCFramework 時停在 Resolve Package Graph，約 3 分鐘無進一步輸出後中止；再試 `xcodebuild -project Kurn.xcodeproj -scheme Kurn -destination 'generic/platform=iOS Simulator' -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO build`，仍停在 Resolve Package Graph，約 1 分鐘後中止。兩次皆非成功 build，根因未確認；後續需確認網路／下載／SwiftPM 狀態，勿把停滯直接歸咎某單一原因。
- checkout 工作樹沒有追蹤檔修改；未新增原生程式、未跑 App、未建立模擬器、未使用真實會議或雲端帳號。尚需完成模擬器 build、錄音／SwiftData 定向測試、iPad 實機及政策審查。

## 2026-11-26：預設身份隱私修正（本機未提交、未發布）

- `SpeakerPrivacyPolicy` 預設禁止自動身份比對，丟棄待持久化的逐字稿輸出聲紋；`saveTranscript` 不再保存新的向量。speaker reconciliation 不讀既有 recording 的聲紋，也不以具名 row 參與自動 label 分配。cross-meeting 候選 fetch、stage 和 apply 均有關閉的防護。`Speaker.displayName` 暫時只顯示匿名標籤，人工標註/同意功能尚未設計；這是刻意的功能限制。
- 既有儲存的聲紋資料沒有掃描或刪除（重轉寫的該 recording 會被清空）；目前程式不代表已完成舊資料清理或完整隱私審計。匿名 diarization 仍可在單次處理內使用暫時特徵；其模型運作及 consent 的要求仍需獨立確認。
- 新增 `SpeakerPrivacyPolicyTests`（3 個合成測試，macOS SwiftPM 通過），新增 `DefaultSpeakerPrivacyTests`（2 個 SwiftData/iOS 整合測試，未執行，待 Xcode build）。政策旗標做過故意改壞驗證，測試如預期失敗，恢復後通過。與既有 chunk/fusion/smoothing/filesystem/reliability 加總 51 tests、0 failures；靜態 policy 通過。原有 CrossMeetingSpeakerMatchTests 和 SpeakerSyncTests 部分明確斷言舊的自動比對／聲紋保存行為，現在與新需求衝突，尚未調整或在 iOS 執行；不能把分支視為測試完畢。
- 隔離的 SourcePackages 工作目錄在 `/Users/audichuang/Project/meeting-assistant-preparation/SourcePackages`；Xcode 能 checkout FluidAudio 0.18.0、sherpa-onnx 2.0.1、onnxruntime-libs 1.28.2，但 Resolve Package Graph 停在二進位 artifact 階段約 100 秒，artifact 仍 0B，之後主動終止。檢查的 12 個 artifact 鎖由本次 xcodebuild 本身持有，未見其他 PID 持有這些鎖。兩個特定 GitHub release assets（Whisper 和 sherpa iOS）的 HEAD 及前 1 MiB Range GET 均 HTTP 200/206 且少於一秒，這僅排除這兩個小請求的全面不可達，不證明整個檔案或所有依賴可下載；根因仍不明。沒有更改全域配置或清除其他快取。
- 後續：解決 artifact 解析後跑不簽章 iPad simulator build，執行新 SwiftData 整合測試及所有相關舊測試，將過時身份測試改成新的隱私預期並保留匿名分段測試；檢查所有資料輸出、舊聲紋清理策略、公司同意與真機聲學路徑。suggestion event 資料模型尚未開始。

## 本輪：建議事件、匿名測試與依賴清單

- 新增 `KurnCore/SuggestionEvents.swift`：候選、簡短理由、證據與逐字稿版本、模型／提示／政策版本、created/suppressed/shown/expanded/dismissed/feedback append-only 領域事件、順序與 ID／時間驗證、持久化資料重建驗證、可配置節流（初始 90 秒與 10 分鐘最多 3 張）。這是純 Swift；尚無 SwiftData 持久化、AI、UI 或後端整合，保存與交易性仍需實作。
- 新增 `SuggestionEventsTests` 10 項合成測試，包含證據非法與解碼驗證、序列化、事件狀態與非法次序、重複、不同 suggestion、倒退時間、抑制與已忽略回饋、節流邊界。故意把 90 秒門檻改壞時測試失敗，恢復後通過。KurnCore 完整 532 tests、56 suites、0 failures（沒有 skipped 報告），host macOS，結果見 `kurncore-tests.log`。
- `CrossMeetingSpeakerMatchTests`、`SpeakerSyncTests`、`ModelTests` 已調整為目前匿名／不進行身份比對的預期，保留 SwiftData in-memory 假資料；新增的 iOS 整合測試及改寫的測試均尚未執行。`swiftc -frontend -parse` 只能確認 Swift 語法，不代表編譯或測試通過。
- [PRIVACY-MIGRATION-PLAN.md](PRIVACY-MIGRATION-PLAN.md) 為聲紋 migration／刪除草案，尚未對既有私人資料執行任何掃描或操作。
- [dependency-inventory.tsv](dependency-inventory.tsv) 擷取固定版本四個 Package.swift 的 12 個 binary target：官方 GitHub release API 列出的總下載大小約 298.1 MiB，各檔名稱、URL 與 manifest 指定 SHA-256 均保留；這是全部宣告，不能斷言 simulator 單一 target 均需要它們；目前沒有全部下載並以實際檔案比對 hash。
- 再次用隔離的專案 SourcePackages 執行 verbose `xcodebuild -resolvePackageDependencies`，三分鐘日誌只有 `Resolve Package Graph`，專案 artifacts 仍為 0B，SwiftPM artifact cache 仍 65 MiB，未觀察到合理下載進度，故只終止本次工作程序。先前 process sample 指向 SwiftPM `BinaryArtifactsManager.download`；HEAD/Range 的兩個小請求成功不代表所有實際 artifact 下載可完成。根因尚未確定；未改全域設定或清除快取。完整日誌 `xcode-resolve.log`。

## STT／diarization 補充研究

AssemblyAI 3.7 Realtime 會議模型、AWS `zh-TW` streaming、Gemini Live Transcribe 與 native audio 核心的來源、費率、限制及 60 分鐘合成 benchmark 見 [STT-DIARIZATION-BENCHMARK.md](STT-DIARIZATION-BENCHMARK.md)。尚未使用憑證或向任何供應商傳送音訊，亦未改變產品預設。
