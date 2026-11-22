# Changelog

## 1.0

- Open Quick Chat from the menu bar or a shortcut recorded in Settings. No global shortcut is assigned at install.
- Connect an eligible ChatGPT plan in Settings. Quick Chat uses its own Keychain item and does not use an API key as a fallback.
- Stream replies as Markdown with syntax highlighting. Stop keeps the partial reply visible; hiding the panel keeps the conversation open. Chats are not saved when the app quits.

Build with `./build.sh` using Xcode (verified with Xcode 27.1), then open `build/Quick Chat.app`. The minimum runtime version is macOS 14. Set `CODE_SIGN_IDENTITY` to a development signing identity to keep a stable Keychain identity across local rebuilds.
