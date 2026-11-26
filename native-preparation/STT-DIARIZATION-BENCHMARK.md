# 串流 STT／說話人分段：架構比較與 benchmark 規格

版本：2026-11-26，研究計畫，未執行服務測試。這些 STT 路徑用來評估字幕、匿名分段與可選的文字分析對照；既定核心仍是 Gemini Live 直接接收原始音訊進行理解，不因本比較更改預設。任何送雲測試須先核准公司供應商、區域、合約、資料處理及所需費用；尚未使用憑證、傳送音訊或啟用付費服務。

## 官方文件確認的候選

### AssemblyAI-STT-3.7-Realtime：會議型

- `speech_model=assemblyai-stt-3-7-realtime`，不是 `-agent` 變體。官方面向會議／環境音轉寫，列 32 種語言及 native code switching，包含 Mandarin、Japanese、English；文件未列臺灣華語繁體輸出保證，不能把 Mandarin 覆蓋視作 `zh-TW` 合約。
- 透過 `speaker_labels=true` 啟用即時 diarization；每個 Turn 有主要 `speaker_label`，final words 帶 speaker；`max_speakers` 可設 1–10，超過上限會被合併。turn confidence 為廠商分數，不是已校準的真人身份機率。短回合可能是 `PENDING`、重疊說話的主要 speaker 可能只有一人；標記為未知並由實驗量測。官方說 turn 結束時標籤 final，斷線新 session 的 A/B 不能自動視為原來的 A/B。
- 價格（2026-11-26 官方 PAYG）：Realtime $0.30／小時、speaker diarization 加 $0.12／小時，60 分鐘 session 約 $0.42，另計 LLM、可選加值及網路；WebSocket 開啟的 session 時長計費，空閒也計時，應主動 terminate，忘記終止可到 3 小時自動結束。region、合約與稅費另核對。此模型依官方描述使用會話內 speaker embedding；須有明確聲紋處理許可，不能以「匿名」繞過政策。
- 來源：https://www.assemblyai.com/docs/streaming/label-speakers-and-separate-channels 、https://www.assemblyai.com/docs/faq/language-support-for-real-time-transcription 、https://www.assemblyai.com/blog/real-time-meeting-transcription-live-speaker-labels 、https://www.assemblyai.com/blog/streaming-speaker-diarization 、https://www.assemblyai.com/pricing 。

### AWS Transcribe standard streaming

- 官方資料輸入清單列 Traditional Chinese `zh-TW`、Japanese `ja-JP` 和 English `en-US` 的 batch/streaming。支持單一語言不代表任何區域、多語 language ID、speaker labels 與其他選項都能一起工作：以公司核准 region 測 `IdentifyMultipleLanguages` + `LanguageOptions=zh-TW,en-US,ja-JP` + `ShowSpeakerLabel`，將 API 接受情況和品質分開記錄；不支援則標為不支援，不改配置後冒稱同條件。語言選項每種語言只能列一種 dialect，且不匹配時模型會選最接近的候選；多語識別使用 PCM，不支援其文件列出的 redaction／custom language models 組合。zh-TW 語言表的 redaction 為 no。
- streaming `ShowSpeakerLabel` 回傳匿名 speaker partition；同一台通話程式的分離聲道是 channel identification，不等同 diarization，不能自動映射真名。`SessionResumeWindow` 可設 1–300 分鐘，從 stream 開始時計，不等於連線最大時長；官方另稱存在不可提高的最大 session duration，超過須新建串流，但本次未查到確定數值，需依目標區域及當時文件核實。重連是否保留 label 由測試確認，不推定。
- 2026-11-26 AWS 官方 us-east-1 價目檔 publication 2026-11-21，`USE1-StreamingAudio` 為每秒 $0.0001667，60 分鐘約 $0.60012；AWS 價格頁說基本價格含 speaker diarization／語言識別，每秒計費無最低時間，其他功能及 region 費率另計。這是指定 region 的公開牌價示例，非 Audi 帳號合約報價。價目檔：https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/transcribe/current/us-east-1/index.json
- 來源：https://docs.aws.amazon.com/transcribe/latest/dg/supported-languages.html 、https://docs.aws.amazon.com/transcribe/latest/dg/lang-id-stream.html 、https://docs.aws.amazon.com/transcribe/latest/APIReference/API_streaming_StartStreamTranscription.html 、https://docs.aws.amazon.com/transcribe/latest/dg/diarization.html 、https://docs.aws.amazon.com/transcribe/latest/dg/streaming.html 、https://aws.amazon.com/transcribe/pricing/ 。

### Gemini 比較路徑

- 主路徑：原始音訊直接進 Gemini Live native-audio；衡量其音訊理解、建議證據與品質。原始錄音本機獨立保存。
- 對照：`gemini-3.5-transcribe-live` 以 VERBATIM 產生 finalized transcript，再經獨立文字模型產生靜默結構化建議。該 Live 模型不支援即時 diarization／逐字時間戳，官方列 session 最多 10 分鐘；會話切換需記缺口及去重。官方語言表未列臺灣華語繁體，須評估實際效果；不以此對照聲稱完成原生音訊理解。
- AssemblyAI、AWS 的 STT 輸出若送下游文字推理，屬另一個明示的試驗路徑，須分別取得雲端傳送和成本核准，不改既定主路徑。
- 來源：https://aistudio.google.com/docs/live-api/live-transcribe 、https://aistudio.google.com/docs/live-api/capabilities 、https://aistudio.google.com/docs/pricing#gemini-3.5-transcribe-live 。

## 60 分鐘合成會議 benchmark

### Corpus 與標註

使用事先設計的完全虛構內容及具備評測／使用權的合成聲音，不模仿真實人物。建立一份 60:00 基準 WAV／PCM，16 kHz、16-bit、mono；原始高品質音軌另保留，檔案與標註計算 SHA-256、版本、生成工具和許可。四個合成說話人 A–D，約 45% 臺灣華語、30% 英語、15% 日語、10% 中英日切換；比例是設計目標，標註以實際語音時間為準。穿插短附和、重疊、停頓、數字、專有名詞、口音、遠近距離、背景噪音和不同音量，對難度與重疊單獨標籤。中文逐字、英日詞級人工校對；每句／詞起訖、reference speaker、語言、同時說話的時間範圍、明確不可辨識片段皆留存。生成稿不是時間真值，先人工複核音訊對齊。

切成四段同等覆蓋的約 15 分鐘場景：乾淨單人／輪流、四人輪談、混語／短回合、遠場／重疊與斷線；確保每段都含必要語言及 speaker。僅 60 分鐘合成資料無法證明真人會議準確率，作為工程比較的起點，不作正式發佈承諾。

### 執行條件

1. 產生標準音訊與 gold transcript／RTTM 或等價參考；所有 provider 使用同一音源、時間軸、100 ms chunk、接近 1× 即時播放及相同靜音；依每家要求轉成 raw PCM。保留 SHA、工具及設定版本。
2. 主評測在四家核准後執行：AssemblyAI 3.7 Realtime + diarization、AWS Transcribe streaming + speaker labels、Gemini Live Transcribe VERBATIM、Gemini Live native audio。以各家最適合法配置記錄；無 diarization 的系統在 DER 欄標 N/A，不能當 0 或把文字模型輸出當聲學 diarization。Gemini native 的音訊理解品質另做同音源語義評分。
3. AWS 固定 zh-TW 的基線及三語自動識別分開列；只在 API 接受且公司允許時啟用 speaker label。Assembly 的 max_speakers 先不指定，再以 4 或適度餘裕做敏感度組；所有參數和未知的廠商 server model revision 明列。禁止供應商使用名單、身分映射、聲紋檔或真實會議脈絡。
4. 分別量測無中斷與預先定義的 2 次中斷（例如 20:00、40:00，長度 5 秒及 30 秒）；斷線期間本機仍保存音訊，是否重傳、重複／缺口、重連耗時及新的匿名 session label 全部獨立記錄。Gemini Transcribe 依 10 分鐘上限切段，記邊界對齊方式。不得為了好看靜默刪失敗／重試。
5. 每套完整跑至少 3 次並記每次請求配置、資料接收時間、模型、region、計費區間與實際帳單；同一供應商同一段落比較成對結果。事先設預算上限及 stop conditions，沒有授權時不執行。

### 評分及報告

- 英文 WER：固定大小寫、標點及數字正規化規則；中文和日文 CER：Unicode 正規化、明定標點、數字規則。中文同時報**原字形 CER**及清楚標為正規化後的簡繁等價 CER（例如可審核的固定映射版本），不能把轉換後分數冒充原始繁體輸出品質；保留混語跨邊界、專有名詞及數字錯誤分項。
- DER = (missed speech + false alarm + speaker confusion)／reference speaker time；公開是否納入 overlap、collar（主指標建議 0 秒並含 overlap，另報 0.25 秒及排除 overlap 的敏感度），用全局最佳匿名標籤映射並在每個 session 斷點重算；報未標 speaker／PENDING 比率、短回合錯誤、speaker merge／split、重疊與重新連線後標籤漂移。mapping 只用於離線評分，不用作真人身份比對。
- 延遲以 reference 語句結束的音訊時間映射到本地單調時鐘：首個可讀 partial、final transcript、final speaker label 分開報 p50／p90／p95，分開列網路 RTT、送出緩衝與缺口，記 partial 更新次數與回滾。不得把部分結果誤當 final。
- 費用分解：session/audio 量、speaker add-on、輸出 token、下游推理、重連重送、存儲／網路、稅與合約；列預估與實帳。品質報每語種、條件及 15 分鐘分層，標出樣本數與失敗率；供應商自己公開的 DER 不是本次結果。採成對差值與分段 bootstrap 信賴區間；單一小語料以探索性結果呈現。
- 若比較建議卡，先由人工以證據可追溯、錯誤事實、時機、可行性和是否有助自主表達評分；將 Gemini 原生音訊理解與所有 STT→文字推理的結果分組，保留完整來源及被抑制／忽略建議。嚴禁將沒有證據的猜測寫成引述。

## 尚待確認

企業資料留存與訓練條款、AWS 實際區域／價目及 session 上限、AWS 三語多語識別加 speaker labels 的 API 兼容性、AssemblyAI 華語繁體輸出與 session reset、各服務 speaker 聲紋處理、台灣口音和真人會議條件。沒有送音訊，以上無實測結論。
