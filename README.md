# Quick Chat

**ChatGPT one shortcut away on macOS.**

<img src="assets/quick-chat.svg" alt="Illustration of the Quick Chat popup with a short conversation and its composer" width="680">

- Open a fresh chat from any app with your own keyboard shortcut.
- Stream Markdown replies with syntax highlighting. Switch chats without interrupting a reply.
- Pick GPT-6 Luna or GPT-6.1 Terra and a reasoning level in the popup. Find past chats in local history.

## Install

[Download Quick Chat for macOS](https://github.com/lexlexlexdev/quick-chat/releases/latest/download/Quick-Chat.dmg)

Requires **macOS 14 or later** and an eligible **ChatGPT plan**. No API key is needed.

1. Open `Quick-Chat.dmg` and drag **Quick Chat** into **Applications**.
2. Open **Quick Chat** from Applications. The app is not notarized by Apple, so macOS may block the first launch.
3. If macOS blocks it, dismiss the alert and go to **System Settings → Privacy & Security**. Under **Security**, click **Open Anyway**, then confirm. This option appears after you try to open the app.

## Get started

1. Open Quick Chat from the menu bar and connect ChatGPT in **Settings**.
2. Choose **Keyboard Shortcut…** from the menu bar menu to record your shortcut. No shortcut is assigned by default.
3. Press <kbd>Enter</kbd> to send or <kbd>Shift</kbd> + <kbd>Enter</kbd> for a new line.

Chat history and drafts stay on your Mac in SQLite. Sign-in credentials are stored in Keychain. Messages you send are processed by ChatGPT.

## Build from source

With Xcode 16 or later installed:

```sh
git clone https://github.com/lexlexlexdev/quick-chat.git
cd quick-chat
./build.sh
open 'build/Quick Chat.app'
```

[Changelog](CHANGELOG.md) · [Third-party notices](Sources/QuickChat/TranscriptAssets/THIRD_PARTY_NOTICES.txt)
