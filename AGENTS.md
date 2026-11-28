# meeting-coach

- 此 repo 是 public：不寫公司、主管、同事、真實會議內容或本機路徑，測試一律用合成資料。
- iOS 模擬器代號 `MC`：只用常駐機 `MC iPad mini`，一律經 `scripts/sim.sh`（建置測試 `scripts/sim.sh xcodebuild test …`、手動看畫面 `up`／`down`），不直接下 `xcodebuild -destination`、`simctl boot`、`sim-vault ensure`。腳本會從 NAS 取回、先開機再測、持 lease 防別人關機，閒置 15 分鐘自動收回 NAS；別人在用時它會等，不要另建 `MC iPad mini 2` 之類的第二台：2026-11-27 就有一台被 xcodebuild 自己開關 22 次、PosterBoard 長到 5.7G、留在本機沒收。取不回來（例如 NAS 沒掛上）就停下回報，不要新建同名機，同名空機被 park 會蓋掉封存。
- iPhone 版面檢查用常駐機 `MC iPhone`（iPhone 17、iOS 27.2），同樣只經腳本：`MC_SIM_NAME="MC iPhone" scripts/sim.sh …`；不另建別的 iPhone 或 iPad。
- 派工給別的 agent 時，brief 直接抄 `scripts/sim.sh` 的指令，不另指定模擬器 UDID 或 `-derivedDataPath`（建置快取由腳本固定一份）。
- App 在 `app/`，建置與測試規則見 `app/CLAUDE.md`（其中的 `iPhone 17` 指令是 CI 用；本機改走 `scripts/sim.sh`，它已包 `heavy`）。測試不要加 `CODE_SIGNING_ALLOWED=NO`：未簽章的 app 沒有 Keychain 權限，Keychain／ProviderFactory 的 11 個測試會失敗；預設的 Sign to Run Locally 不需要開發者帳號，CI 也這樣跑。
- CI 是根目錄的 `.github/workflows/ci.yml`（push 到 main 與 PR 觸發；backend、KurnCore、KurnTests 三個 job，不用任何 secret），push 後用 `gh-wait` 等結果。`app/.github/workflows/` 是上游 Kurn 的，GitHub 不會執行，也依賴他們的 secret 與 fastlane，不要沿用或搬出來。
- 決定以 `docs/decisions.md` 為準，用詞以 `GLOSSARY.md` 為準。
- TestFlight：App Store Connect app id `6840169416`（Meeting Coach，`com.audichuang.meetingcoach`），內部群組「自己」、外部群組「家人」。上傳在 `app/` 跑 `BUILD_NUMBER=$(tf next-build --app 6840169416) ./scripts/testflight.sh`；腳本要 `app/Config/Secrets.xcconfig`（只在主 checkout，worktree 要先複製過去），缺值會停。外部群組每個新 marketing version 都要過 Beta App Review；審查用邀請碼在 1Password `meeting-coach-review-invite`。
