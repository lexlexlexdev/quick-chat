import AppKit
import Combine
import SwiftUI
import WebKit

struct TranscriptView: NSViewRepresentable {
    let exchanges: [ChatModel.Exchange]
    let source: ReplySource?
    let activity: ReplyActivity

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "copyCode")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        context.coordinator.attach(webView)
        return webView
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.update(exchanges: exchanges, source: source, activity: activity)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "copyCode")
        view.navigationDelegate = nil
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private static let page = Bundle.module.resourceURL!
            .appendingPathComponent("TranscriptAssets", isDirectory: true)
            .appendingPathComponent("transcript.html")
        private weak var view: WKWebView?
        private weak var source: ReplySource?
        private var subscription: AnyCancellable?
        private var turns: [[String: String]] = []
        private var liveText = ""
        private var ready = false
        private var dirty = false
        private var turnsDirty = true
        private var sending = false
        private var scheduled: Task<Void, Never>?

        func attach(_ view: WKWebView) {
            self.view = view
            view.loadFileURL(Self.page, allowingReadAccessTo: Self.page.deletingLastPathComponent())
        }

        func detach() {
            scheduled?.cancel()
            subscription = nil
            view = nil
        }

        func update(exchanges: [ChatModel.Exchange], source: ReplySource?, activity: ReplyActivity) {
            let nextTurns = exchanges.map { exchange in
                var turn = ["id": exchange.id.uuidString, "prompt": exchange.prompt,
                            "reply": exchange.reply, "summary": exchange.reasoningSummary,
                            "status": "complete", "error": "", "activity": "waiting"]
                switch exchange.state {
                case .replying:
                    turn["status"] = "replying"
                    switch activity {
                    case .waiting: break
                    case .thinking: turn["activity"] = "thinking"
                    case .summary(let text):
                        turn["activity"] = "thinking"
                        turn["summary"] = text
                    }
                case .complete: break
                case .stopped: turn["status"] = "stopped"
                case .failed(let error):
                    turn["status"] = "failed"
                    turn["error"] = error
                }
                return turn
            }
            if nextTurns != turns {
                turns = nextTurns
                turnsDirty = true
                dirty = true
            }
            if self.source !== source {
                self.source = source
                subscription = nil
                liveText = ""
                dirty = true
                subscription = source?.snapshots.sink { [weak self] text in
                    guard let self, self.liveText != text else { return }
                    self.liveText = text
                    self.dirty = true
                    self.scheduleUpdate()
                }
            }
            scheduleUpdate()
        }

        private func scheduleUpdate() {
            guard ready, dirty, !sending, scheduled == nil else { return }
            scheduled = Task { [weak self] in
                // Coalesce network deltas before crossing into the WebKit process.
                do { try await Task.sleep(for: .milliseconds(32)) } catch { return }
                guard let self else { return }
                scheduled = nil
                sendUpdate()
            }
        }

        private func sendUpdate() {
            guard let view, ready, dirty, !sending else { return }
            sending = true
            dirty = false
            let turnPayload: Any = turnsDirty ? turns : NSNull()
            turnsDirty = false
            view.callAsyncJavaScript("window.updateTranscript(turns, liveText)",
                                     arguments: ["turns": turnPayload, "liveText": liveText],
                                     in: nil, in: .page) { [weak self] result in
                guard let self else { return }
                self.sending = false
                if case .failure(let error) = result {
                    NSLog("Quick Chat transcript update failed (%@)", String(describing: type(of: error)))
                }
                self.scheduleUpdate()
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            dirty = true
            turnsDirty = true
            sendUpdate()
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            ready = false
            scheduled?.cancel()
            scheduled = nil
            webView.loadFileURL(Self.page, allowingReadAccessTo: Self.page.deletingLastPathComponent())
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            if !ready, url == Self.page, action.targetFrame?.isMainFrame == true {
                decisionHandler(.allow)
                return
            }
            if action.navigationType == .linkActivated, url.scheme == "https" {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "copyCode", message.frameInfo.isMainFrame,
                  message.webView === view, let code = message.body as? String else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
        }
    }
}
