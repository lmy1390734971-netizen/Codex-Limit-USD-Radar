# Third-party notices

## LH-03/codex-token-hud

- Project: https://github.com/LH-03/codex-token-hud
- Version reviewed: v1.2.1, commit `f3fcdcb7e6a71500fc938e362fb81f99be32d863`
- License: MIT

Token Rader follows the referenced project's documented accounting convention that cached input is a subset of input, and that reasoning output is a detail of output rather than an additional token bucket. Token Rader's source code and desktop interface were implemented separately for this project.

The referenced MIT license permits use, modification, and distribution. The upstream license text is available at:

https://github.com/LH-03/codex-token-hud/blob/main/LICENSE

## System.Data.SQLite

- Project: https://system.data.sqlite.org/
- Binary shipped in `indexer/System.Data.SQLite.dll` (v1.0.103.0, x64, .NET Framework)
- License: MIT (System.Data.SQLite) and public domain (the bundled SQLite engine)

System.Data.SQLite is used only as the local on-disk index engine. Token Rader does not proxy or intercept network traffic; Codex continues to connect directly to the official API.
