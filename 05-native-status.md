# 原生接手現況
checkout、分支與基線見 README。native-snapshot/status-before.txt 是建立交接資料夾前的 git status；tracked.diff 是 7 個已追蹤檔案相對 HEAD 的差異，files/ 有全部 12 份工作中的 Swift 檔案，包含 5 個未追蹤的新檔。其相對路徑跟專案一致。這是複本；實際工作檔在專案根目錄。重建時先在另一個乾淨的相同基線 checkout 比對再複製，切勿用 patch 覆蓋既有分支。原專案不需要套用任何 patch。

[完整依時間排列的前置紀錄](native-preparation/README.md) 含多輪檢查；靠後日期的更新取代前段「尚未修改」的舊描述。歷史驗證：macOS host KurnCore **532 tests、56 suites、0 failures**，見 [原始日誌](native-preparation/kurncore-tests.log)；其中 10 個 SuggestionEvents、3 個 SpeakerPrivacyPolicy 合成測試。冷卻／隱私政策做過 mutation sanity check。2 個新增 SwiftData 整合測試及修改過的 app 測試未在 iOS 跑過；語法解析不等於 link、執行或簽章。尚未接上建議 DB、真實 AI 或 PencilKit。跨會議個資比對預設關閉，不持久化新聲紋，舊資料未掃描刪除；[遷移草案](native-preparation/PRIVACY-MIGRATION-PLAN.md) 留待審核與合成測試。

**恢復順序**
1. 閱讀 native-snapshot/status-before.txt 與兩份 migration／dependency 文件，於專案根確認 git status --short --branch。先保留現有變更，不需建立新分支或提交。
2. 從 Packages/KurnCore 執行 swift test；針對性測試可用 swift test --filter SuggestionEventsTests 或 --filter SpeakerPrivacyPolicyTests。先前 Xcode 27.2 (27B52)、iOS 27.2 simulator runtime，app deployment target iOS 26。沒有本專案的 iPad mini 模擬器實例。
3. 唯讀基線：三個 package checkout 成功，二進位 artifacts 階段停滯。12 個宣告 target 合計約 298.1 MiB，manifest checksum 與 release URL 見 [TSV](native-preparation/dependency-inventory.tsv)；不能斷言 simulator 需全部。兩個 release 的 HEAD／前 1 MiB 可下載，但完整 artifact 未證實。[Resolve 日誌](native-preparation/xcode-resolve.log) 停在 Resolve Package Graph，根因未定。
4. 之後若要自行續做，沿用 sibling preparation/SourcePackages 的隔離目錄，先作 verbose resolve，確認有具體進度並核對需要的實際 artifact hash。再對 Kurn.xcodeproj / scheme Kurn 執行 simulator build（generic/platform=iOS Simulator，CODE_SIGNING_ALLOWED=NO），建立獨立 iPad mini 模擬器跑 SwiftData 測試。不清全域快取。
5. 先以合成資料驗證匿名政策與 DB 寫入、恢復、節流。最後才做有同意的 iPad mini、Pencil、鎖屏、藍牙、Teams 路由 POC 以及核准供應商 benchmark。簽章、個人／家庭 TestFlight 權限、條款與實際帳號流程尚待 Audi 決定。

