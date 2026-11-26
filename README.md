# Audi 的 iPad 會議教練交接包
2026-11-26。供 Audi 自行接手。解壓後先開啟 **prototype/dist/index.html**；CSS、圖示、畫布與模擬腳本全部內嵌。若瀏覽器限制 file:// 的儲存，於解壓目錄執行 `python3 -m http.server 8765 --bind 127.0.0.1 --directory prototype/dist`，開啟 http://127.0.0.1:8765/ 。不用帳號、API 金鑰、安裝套件或連網。筆跡和示例歷史由目前瀏覽器保存。請用合成資料。
 
- [討論與決策](01-product.md)（產品對話轉寫屬私人內容，不在公開 repo）
- [架構、資料與驗收](02-spec.md)
- [Kurn 與 Meetily 程式碼及授權](03-source-review.md)
- [Gemini、STT、成本與 benchmark](04-audio-and-benchmark.md)
- [本機前置、測試證據、未提交清單及取回方式](05-native-status.md)
- [原型校樣與已知限制](06-prototype.md)
 
原型來源 e8a7e02c2bbbf8386c3666ee598939daa0c14546；兩個 tracked 檔均與已部署封裝逐位元相符。MANIFEST.sha256 列出 repo 內所有檔案（清單自身除外）。在 repo 根目錄執行 `shasum -a 256 -c MANIFEST.sha256`。

原生 checkout 位於 /Users/audichuang/Project/meeting-assistant-kurn，分支 audi/local-preparation，基線 b8d6db1ba9f01639bacbb744ff751c21b59f4aa5。交接前有 7 個已修改、5 個未追蹤 Swift 檔案。native-snapshot/ 保存這 12 個檔案的逐位元副本、追蹤檔 diff 與狀態；native-preparation/ 保存歷史研究、測試／解析日誌、遷移草案及依賴清單。套件快取與模型權重保留在原位置。研究及測試文件按已取得證據整理，數字有標明實測或估算。
