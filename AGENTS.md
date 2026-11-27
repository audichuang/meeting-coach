# meeting-coach

- 此 repo 是 public：不寫公司、主管、同事、真實會議內容或本機路徑，測試一律用合成資料。
- iOS 模擬器代號 `MC`：只用名稱以 `MC ` 開頭的模擬器（例如 `MC iPad mini`），其他代號的不碰，用完關機。
- 常駐機 `MC iPad mini` 不用時收在 NAS（`sim-vault park`），清單上看不到是正常的：用前先 `sim-vault ensure "MC iPad mini"` 取回，再用名稱指定 destination；取不回來（例如 NAS 沒掛上）就停下回報，不要新建同名機，同名空機之後被 park 會蓋掉封存。
- App 在 `app/`，建置與測試規則見 `app/CLAUDE.md`；本機 xcodebuild 包 `heavy --`。
- 決定以 `docs/decisions.md` 為準，用詞以 `GLOSSARY.md` 為準。
