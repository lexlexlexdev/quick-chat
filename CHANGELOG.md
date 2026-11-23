# Changelog

## Unreleased

- Read valid ChatGPT reply streams even if the server omits or mislabels `Content-Type`. Report provider errors and unexpected response formats separately.
- Pick GPT-6 Luna or GPT-6.1 Terra and an explicit reasoning level in the chat panel. None is available for both models; the app remembers your selection per model. Configure the global shortcut via **Keyboard Shortcut…** in the menu bar.
- Chats and drafts are stored in local SQLite at `~/Library/Application Support/Quick Chat/history.sqlite3`. History survives restarts and is visible only after connecting the same ChatGPT account registration. Signing out leaves history on disk.
- The global shortcut opens a fresh chat without interrupting replies. Return to any streaming chat through History. **Open Quick Chat** in the menu bar resumes the current chat.
- The waiting indicator shows provider progress and public reasoning summaries when available. Press Enter to send or Shift–Enter for a new line.
- Select text in the popup without dragging the window. Move the popup by dragging the blank space in its header.

## 1.0

- Open Quick Chat from the menu bar or a shortcut recorded in Settings. No global shortcut is assigned at install.
- Connect an eligible ChatGPT plan in Settings. Quick Chat uses its own Keychain item and does not use an API key as a fallback.
- Stream replies as Markdown with syntax highlighting. Stop keeps the partial reply visible; hiding the panel keeps the conversation open. Chats are not saved when the app quits.

Build with `./build.sh` using Xcode (verified with Xcode 27.1), then open `build/Quick Chat.app`. The minimum runtime version is macOS 14. Set `CODE_SIGN_IDENTITY` to a development signing identity to keep a stable Keychain identity across local rebuilds.
