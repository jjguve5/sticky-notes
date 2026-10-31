# Sticky Notes

The always-on-top paper to-do list, on the Ubuntu desktop (Electron) and the iPhone (SwiftUI), kept in sync through a
small PHP backend. To-dos and machines sync; reminders are per device.

- `desktop/`: the Electron app. Sync is set in `sync.json` in its data folder (`~/.config/sticky-notes/`):
  `{ "url": "https://…/sync.php", "token": "…" }`
- `ios/`: the iPhone app. GitHub Actions builds an unsigned IPA (`StickyNotes-ipa` artifact); sign and install it with
  Sideloadly. The server URL and token go in the app's settings (gear).
- `server/`: `sync.php` plus a `config.php` (from `config.example.php`) holding the token. The records live in
  `data/store.php`, which can't be downloaded.

The handwriting font is [Caveat](https://github.com/googlefonts/caveat) (SIL Open Font License).
