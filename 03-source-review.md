# 固定版本程式與授權
下表可依永久連結複核。P0 為第一個原生垂直切片，P1 為錄音可靠後的增量，P2 留到使用者實機意見後。

| Kurn | 可沿用與需改造處 |
|---|---|
| [專案設定](https://github.com/carlosmazzei/Kurn/blob/b8d6db1ba9f01639bacbb744ff751c21b59f4aa5/Kurn.xcodeproj/project.pbxproj)、[ContentView](https://github.com/carlosmazzei/Kurn/blob/b8d6db1ba9f01639bacbb744ff751c21b59f4aa5/Kurn/ContentView.swift)、[會議詳細頁](https://github.com/carlosmazzei/Kurn/blob/b8d6db1ba9f01639bacbb744ff751c21b59f4aa5/Kurn/Views/MeetingDetailView.swift) | P0 使用 iPhone/iPad 原生 SwiftUI 導航與生命週期；另有 Watch、Live Activity target。P1 為 iPad 新寫 PencilKit 與單卡互動，macOS 是日後獨立工作。 |
| [錄音服務](https://github.com/carlosmazzei/Kurn/blob/b8d6db1ba9f01639bacbb744ff751c21b59f4aa5/Kurn/Services/AudioRecorderService.swift)、[音源引擎](https://github.com/carlosmazzei/Kurn/blob/b8d6db1ba9f01639bacbb744ff751c21b59f4aa5/Kurn/Services/AudioCaptureEngine.swift)、[Session](https://github.com/carlosmazzei/Kurn/blob/b8d6db1ba9f01639bacbb744ff751c21b59f4aa5/Kurn/Services/CaptureAudioSession.swift) | P0 複用錄音狀態、原音保存與錯誤處理。網路分流、授權、不中斷的有界佇列和路由 POC 需新增。 |
| [schema](https://github.com/carlosmazzei/Kurn/blob/b8d6db1ba9f01639bacbb744ff751c21b59f4aa5/Kurn/Infrastructure/KurnSchema.swift)、[Meeting](https://github.com/carlosmazzei/Kurn/blob/b8d6db1ba9f01639bacbb744ff751c21b59f4aa5/Kurn/Models/Meeting.swift)、[Recording](https://github.com/carlosmazzei/Kurn/blob/b8d6db1ba9f01639bacbb744ff751c21b59f4aa5/Kurn/Models/Recording.swift) | P0 複用 SwiftData 會議、錄音與關聯；P1 另做筆畫、證據、事件流、同意與索引 migration，保留原始版本。 |
| [轉寫](https://github.com/carlosmazzei/Kurn/blob/b8d6db1ba9f01639bacbb744ff751c21b59f4aa5/Kurn/Services/TranscriptionService.swift)、[即時轉寫](https://github.com/carlosmazzei/Kurn/blob/b8d6db1ba9f01639bacbb744ff751c21b59f4aa5/Kurn/Services/LiveTranscriptionService.swift)、[FluidAudio diarizer](https://github.com/carlosmazzei/Kurn/blob/b8d6db1ba9f01639bacbb744ff751c21b59f4aa5/Kurn/Services/FluidAudioDiarizer.swift)、[摘要](https://github.com/carlosmazzei/Kurn/blob/b8d6db1ba9f01639bacbb744ff751c21b59f4aa5/Kurn/Services/SummaryService.swift) | P0 評估裝置上 ASR、分段、會後摘要；真機模型 RAM／速度待量。P1 另建 Live 音訊推理與建議投影。 |
| [speaker 模型](https://github.com/carlosmazzei/Kurn/blob/b8d6db1ba9f01639bacbb744ff751c21b59f4aa5/Kurn/Models/Speaker.swift)、[跨會議比對](https://github.com/carlosmazzei/Kurn/blob/b8d6db1ba9f01639bacbb744ff751c21b59f4aa5/Kurn/Application/TranscriptionCoordinator%2BCrossMeetingSpeakerMatch.swift) | 上游儲存向量、可跨會議比對。P0 保留本機分支的預設禁用策略，單會議匿名分段仍可用。 |
| [匯出格式](https://github.com/carlosmazzei/Kurn/blob/b8d6db1ba9f01639bacbb744ff751c21b59f4aa5/Kurn/Infrastructure/MeetingExportFormat.swift) | Markdown、Obsidian、PDF、DOCX、HTML、純文字。P2 複用 renderer，另外規定證據連結、原音權限與匿名匯出。 |
| [LICENSE](https://github.com/carlosmazzei/Kurn/blob/b8d6db1ba9f01639bacbb744ff751c21b59f4aa5/LICENSE)、[第三方清單](https://github.com/carlosmazzei/Kurn/blob/b8d6db1ba9f01639bacbb744ff751c21b59f4aa5/THIRD_PARTY_NOTICES.md) | Kurn MIT，須保留著作權及授權。框架、權重、商標和資產分別核查；完整依賴與模型清單見 native-preparation。 |

Meetily 以 [固定 tree](https://github.com/Zackriya-Solutions/meetily/tree/2166bc6fe3ba585580f3f94b79cda7e7b91deb76) 核對。以下均是已讀取的 raw 原始碼／SQL，列出關鍵行。不要把桌面裝置擷取能力視為 iPad 能力。

| 證據 | 結論與移植決定 |
|---|---|
| [LICENSE.md](https://github.com/Zackriya-Solutions/meetily/blob/2166bc6fe3ba585580f3f94b79cda7e7b91deb76/LICENSE.md#L1) | 社群版 MIT。保留原作者及授權；不據此取得商業 Pro 原始碼權利。 |
| [package.json](https://github.com/Zackriya-Solutions/meetily/blob/2166bc6fe3ba585580f3f94b79cda7e7b91deb76/frontend/package.json#L41) | Next.js / Tauri 桌面 UI 工具鏈；SwiftUI 重寫。 |
| [recording_manager.rs](https://github.com/Zackriya-Solutions/meetily/blob/2166bc6fe3ba585580f3f94b79cda7e7b91deb76/frontend/src-tauri/src/audio/recording_manager.rs#L5) | 按 OS 分支管理來源與串流；參考狀態機。 |
| [system.rs](https://github.com/Zackriya-Solutions/meetily/blob/2166bc6fe3ba585580f3f94b79cda7e7b91deb76/frontend/src-tauri/src/audio/capture/system.rs#L8) | 系統音訊有 macOS CoreAudio 分支，其他桌面平台走不同路徑；不移植至 iPad。 |
| [worker.rs](https://github.com/Zackriya-Solutions/meetily/blob/2166bc6fe3ba585580f3f94b79cda7e7b91deb76/frontend/src-tauri/src/audio/transcription/worker.rs#L3) | 分塊與 worker 統計；參考背壓與可觀測性。 |
| [provider.rs](https://github.com/Zackriya-Solutions/meetily/blob/2166bc6fe3ba585580f3f94b79cda7e7b91deb76/frontend/src-tauri/src/audio/transcription/provider.rs#L1) | 共同 provider 介面分離 ASR 引擎。Swift 端沿用既有 Kurn 介面。 |
| [whisper_provider.rs](https://github.com/Zackriya-Solutions/meetily/blob/2166bc6fe3ba585580f3f94b79cda7e7b91deb76/frontend/src-tauri/src/audio/transcription/whisper_provider.rs#L1) | 具體 Whisper adapter。模型資產另審。 |
| [parakeet_provider.rs](https://github.com/Zackriya-Solutions/meetily/blob/2166bc6fe3ba585580f3f94b79cda7e7b91deb76/frontend/src-tauri/src/audio/transcription/parakeet_provider.rs#L1) | 具體 Parakeet adapter。評測語言和資源後再選。 |
| [20250916100000_initial_schema.sql](https://github.com/Zackriya-Solutions/meetily/blob/2166bc6fe3ba585580f3f94b79cda7e7b91deb76/frontend/src-tauri/migrations/20250916100000_initial_schema.sql#L2) | SQLite 會議、逐字、分塊、摘要任務等資料表。參考關聯及狀態；保留 SwiftData。 |
| [20251110000001_add_speaker_field.sql](https://github.com/Zackriya-Solutions/meetily/blob/2166bc6fe3ba585580f3f94b79cda7e7b91deb76/frontend/src-tauri/migrations/20251110000001_add_speaker_field.sql#L1) | speaker TEXT migration 註明 audio source。此欄位無法證明四人聲學分群或身份辨識。 |
| [processor.rs](https://github.com/Zackriya-Solutions/meetily/blob/2166bc6fe3ba585580f3f94b79cda7e7b91deb76/frontend/src-tauri/src/summary/processor.rs#L1) | 清理 LLM Markdown 並驗證可見輸出。語言策略要改成使用者可選且保留證據。 |
| [BlockNoteSummaryView.tsx](https://github.com/Zackriya-Solutions/meetily/blob/2166bc6fe3ba585580f3f94b79cda7e7b91deb76/frontend/src/components/AISummary/BlockNoteSummaryView.tsx#L16) | 摘要可呈現處理／完成／錯誤、儲存 Markdown 或 JSON。重寫原生編輯／匯出。 |
| [TranscriptView.tsx](https://github.com/Zackriya-Solutions/meetily/blob/2166bc6fe3ba585580f3f94b79cda7e7b91deb76/frontend/src/components/TranscriptView.tsx#L10) | React 轉寫畫面依 recording、paused、processing 等狀態呈現。SwiftUI 重新表達。 |
| [incremental_saver.rs](https://github.com/Zackriya-Solutions/meetily/blob/2166bc6fe3ba585580f3f94b79cda7e7b91deb76/frontend/src-tauri/src/audio/incremental_saver.rs#L19) | incremental saver 接受音訊塊並 finalize，桌面編碼器依賴另計。參考其恢復思想。 |
| [summary.rs](https://github.com/Zackriya-Solutions/meetily/blob/2166bc6fe3ba585580f3f94b79cda7e7b91deb76/frontend/src-tauri/src/database/repositories/summary.rs#L1) | 摘要 repository 依 meeting 查詢工作狀態。 |
| [20251105120000_add_pro_license_custom_openai.sql](https://github.com/Zackriya-Solutions/meetily/blob/2166bc6fe3ba585580f3f94b79cda7e7b91deb76/frontend/src-tauri/migrations/20251105120000_add_pro_license_custom_openai.sql#L1) | community migration 含 licensing 和 customOpenAIConfig；存在授權資料結構不代表取得 Pro 實作。 |

尚待證明的能力：這次固定版證據可確認音源欄、ASR provider 和編輯器序列化，不足以將完整跨人 diarization、具名辨識或 Pro 匯出格式列為可直接移植模組。若後續需要宣稱某格式或推論器已出貨，應從選單或 command 一路追到 writer／inference call 並做合成 fixture 驗證。
另經逐檔核對，[useCopyOperations.ts #L93](https://github.com/Zackriya-Solutions/meetily/blob/2166bc6fe3ba585580f3f94b79cda7e7b91deb76/frontend/src/hooks/meeting-details/useCopyOperations.ts#L93) 寫入整理過的逐字稿到剪貼簿，[同檔 #L181](https://github.com/Zackriya-Solutions/meetily/blob/2166bc6fe3ba585580f3f94b79cda7e7b91deb76/frontend/src/hooks/meeting-details/useCopyOperations.ts#L181) 寫入摘要 Markdown。speaker migration 明列 mic/system。這是來源分離的直接證據。

