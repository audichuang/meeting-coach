# Gemini Live 核心與控制組（2026-11-26 文件快照）
直接送單聲道 16-bit little-endian PCM；建議衍生 16 kHz，標 audio/pcm;rate=16000，原始音源獨立保存。Live 可取得聲學與語言訊息，但語氣／停頓只可作為觀察線索；多人、同時講話、繁中及臺灣口音準確度未測。把模型說的「誰講了什麼」當候選，回指原音與 final transcript 交叉核對。

Google Developer API 價目列出 gemini-3.8-live、gemini-3.8-live-extended-thinking 和 gemini-3.1-flash-live-preview。依部署平台／region 建立能力表，不把 Developer API 與 Vertex AI 的 ID 或可用性混用。WebSocket BidiGenerateContent／SDK live.connect，設定模型、單一輸出模態、授權的工具與 session。文件示例使用 AUDIO；模型語音回傳為 24 kHz PCM。outputAudioTranscription 是模型回答的轉寫，inputAudioTranscription 是輸入轉寫。原生聽音的靜默卡片優先驗證 emit_suggestion 工具事件，限制 schema、檢查引用及去重；否則評估輸出轉寫經結構化驗證。不得播放回答混入會議，靜音也可能產生輸出費。回傳構造與同意門檻是 POC，不能保證直接要求 TEXT 或任意 JSON 成功。[能力文件](https://aistudio.google.com/docs/live-api/capabilities)｜[協定](https://ai.google.dev/api/live)

未壓縮的 audio-only 上限 15 分鐘，音視訊 2 分鐘；連線壽命約 10 分鐘。啟用 sliding-window 壓縮與 sessionResumption，接收 GoAway、保存最新可用 handle 與已確認偏移。每次重新接線攜帶 handle，失效則建新 session，送經同意的短摘要與未解問題。壓縮會移出舊脈絡；逐字、決議及證據時間軸放在本機。有界重送、序號、缺口紀錄及重連測試避免漏段／重複卡。長會議需實測延遲、費用、可恢復時間窗。[Session 管理](https://aistudio.google.com/docs/live-api/session-management)

Developer API 標價示例每百萬 token：文字入／出 $0.75／$4.50，音訊入／出 $3／$12；官方分鐘概估入 $0.005、出 $0.018。單次送 60 分鐘輸入約 $0.30，若另產生 5 分鐘語音約加 $0.09。此為單次處理的媒體量示例；會話歷史每輪計價、文字、重送、模型輸出、下游分析與企業合約需依實際 usageMetadata／帳單重算。雲端金鑰留在企業後端，App 用短效授權；核對服務區域、保留、存取、日誌、訓練及刪除條款。表列 paid tier 不用於改善產品，不等於零留存或公司已核准。[定價](https://ai.google.dev/gemini-api/docs/pricing)｜[服務條款](https://ai.google.dev/gemini-api/terms)｜[Vertex 資料治理](https://cloud.google.com/vertex-ai/generative-ai/docs/data-governance)

| 60 分鐘控制組 | 如何比較 |
|---|---|
| gemini-3.5-transcribe-live | 專用 TEXT Live WebSocket；以 VERBATIM final 供文字模型生成卡，SMART 可能改寫。10 分鐘 session、沒有即時 speaker／word timestamps；列簡中，未列臺灣繁中。約 $0.54，另計文字推理。 |
| assemblyai-stt-3-7-realtime | 會議版，開 speaker_labels；普通話／日／英可測，繁中需驗證。$0.30/h＋$0.12/h 分段，合計約 $0.42。依連線時間計費，3 小時自動終止。 |
| AWS Transcribe Streaming | zh-TW、ja-JP、en-US 各可 streaming。多語識別和 ShowSpeakerLabel 組合、區域與 session duration 需測；resume window 不等於最大串流時長。us-east-1 價目示例約 $0.60012/h 含基本 speaker label。 |

[完整 benchmark 與價格依據](native-preparation/STT-DIARIZATION-BENCHMARK.md) 含重連、DER、延遲、原字形 CER 和成本分解。60 分鐘合成四人素材，臺灣華語、英文、日文與混語，依情境分四段；用同一 WAV／SHA、校對 gold、speaker RTTM，保留重疊、背景噪音、數字及短回合。每組規劃三次，20/40 分鐘注入 5/30 秒斷線。分報英文 WER、中日 CER、speaker 漏標與混淆、p50/p90/p95、真實帳單、建議品質與時機。未執行付費測試，無實測排名。
