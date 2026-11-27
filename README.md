# Meeting Coach

在多人實體會議中，用 iPad mini 錄音、手寫，並即時提示「我現在可以怎麼說」的個人 App。

- `app/`：iPad App，以 [Kurn](https://github.com/carlosmazzei/Kurn)（MIT，© Carlos Mazzei，見 `app/LICENSE` 與 `app/THIRD_PARTY_NOTICES.md`）為基底改造。
- `backend/`：Cloudflare Worker，替 App 保管 OpenAI key、發短效 token 與記帳（建置中）。
- `docs/decisions.md`：產品與技術決定；`docs/adr/`：重大取捨；`GLOSSARY.md`：用詞。

2026-11-26 的交接包（原型、規格、測試日誌）保留在 tag `handoff-2026-11-26`。
