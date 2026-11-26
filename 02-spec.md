# 原生模組與資料流（設計）
1. MeetingSession 控制本機錄製、雲端分析與 speaker 處理的分別同意狀態。公司未核准或有人不同意時不得啟用相應處理。UI 明示錄音狀態、有效音源與中斷。雲端撤回立即停止傳送，獨立處理合法的本機錄音。
2. 單一 AVAudioSession／AVAudioEngine tap → 有界緩衝 → 本機分段寫入與 crash journal。每段以單調時間、原始取樣率、聲道、route、檔案 hash 及提交狀態對齊。保留原音；網路、推論和 DB 不可阻塞即時 callback。獨立衍生支線轉成相容 PCM，背壓時明記缺口或停分析。磁碟不足顯示可見故障並封存已完成片段。
3. 本機／核准的 STT 產生 provisional、final、人工修訂版逐字稿，記 segment ID、時間範圍、模型、語言和信心（無則 nil）。匿名 speaker turn 可跨多個文字片段。重疊發言允許多標籤或未知，更正保留舊值與作者。重新連線不得以同名的 A 視為同一真人。
4. 核准音訊 → 分析 session → 帶證據候選 → 規則驗證 → 先存 DB 再節流。證據過期、重複、可信度不足、冷卻期間寫 suppressed；其餘留一張待呈現。已忽略的不立即回推。資料不足就維持空白。手動收尾可即時整理共識、分歧、待辦；會後摘要引用 transcript revision 與來源時間。
5. Apple Pencil 使用 PKCanvasView，SwiftUI 管理工具與提示。筆畫檔以頁面座標保存，筆劃結束後另存版本，旋轉只更新顯示轉換。手寫、看卡和點回饋皆不可改動錄音生命週期。前景、鎖屏、中斷、route change 要透過可測的 coordinator；申請麥克風、音訊 background mode 並不保證可攔截其他 App 或在中斷中持續錄。
6. ContextImport 將來源、範圍、版本和 hash 對應選取段落。外部文件視為資料，僅把核准的最小片段交給模型；不得執行其中指令。MemoryProposal 保存新增／修訂差異、證據、審核狀態，只有接受才建立下一版記憶。可拒絕、刪除或回溯。

| 持久化實體 | 主鍵／關聯與必要欄位 |
|---|---|
| Project、Meeting、ConsentReceipt | UUID、關聯、scope、授權版本、時間、授權與撤回狀態、資料保留截止 |
| Recording、AudioSegment、StreamGap | meetingID、序號、起訖、相對 URI、hash、格式、來源、缺口原因與恢復狀態 |
| TranscriptRevision、Utterance、SpeakerTurn | 原始與修訂文字、時間、語言、會議局部匿名 ID、confidence、來源、修正歷史 |
| NotePage、InkRevision | meetingID、頁面座標、原始 PKDrawing、修改時間及可選時間錨點 |
| Suggestion、Evidence、SuggestionEvent | meetingID、類別、短標題、完整一句、可審核理由、證據範圍及 transcript 版本、模型／prompt／政策版本、created/suppressed/shown/expanded/dismissed/feedback、事件時間及回饋 |
| Summary、Decision、Action、OpenQuestion | 來源版本、證據引用、負責人與期限可空，人工確認狀態 |
| ContextSource、MemoryProposal | 專案與允許用途、來源版本、引用、變更前後、待審／接受／退回、審核時間 |

事件 append-only；事件 ID 唯一，重送去重。候選與 created 原子儲存；顯示狀態從事件投影。冷卻初值 90 秒、10 分鐘最多三張（可調）。不記錄模型私有思考。原音、衍生分析、筆記和可選身份映射分離。評估機密檔案的 iOS Data Protection 與鎖屏錄音相容性；最小權限、保留期限、可查的匯出及刪除。刪除涵蓋所有衍生檔、索引、歷史及備份政策。

**里程碑及驗收。** M0 保全未提交程式、解開 simulator build。M1 合成音源測重啟、磁碟不足、斷線，已提交原音 hash 相符、缺口可見。M2 真機在外部設備播放合成會議時，同時書寫、旋轉、點卡、鎖屏並量測漏錄、溫度與耗電。同機 Teams 分別測喇叭、耳機、藍牙及麥克風佔用；記原因，不以聽到揚聲器的聲音當系統 loopback。M3 核准企業端點後跑下份 benchmark；重連、抑制、忽略及反饋必須可追溯。M4 會後摘要與記憶提案須可查來源，拒絕後原記憶不變。未獲核准的真實錄音、雲服務、簽章及發布均留待 Audi 決定。

Apple 參考：[音訊 Session](https://developer.apple.com/documentation/avfaudio/avaudiosession)、[PencilKit](https://developer.apple.com/documentation/pencilkit)、[介面材質](https://developer.apple.com/design/human-interface-guidelines/materials)。未來 iPadOS 27 可獨立評估手寫搜尋／選取後送 AI，原墨跡保留、26 版功能隔離；官方範例須真機與 Apple Pencil，[手寫辨識](https://developer.apple.com/documentation/pencilkit/building-a-handwriting-recognition-experience-with-pencilkit)。
