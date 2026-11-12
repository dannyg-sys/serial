import SwiftUI
import AppKit
import SwiftTerm

/// Wraps SwiftTerm's `TerminalView` (a full VT100/xterm emulator) as a SwiftUI
/// view. Incoming serial bytes are fed into the emulator; keystrokes it produces
/// are written back out to the serial port via the session.
struct SwiftTermView: NSViewRepresentable {
    @ObservedObject var session: SerialSession

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeNSView(context: Context) -> TerminalView {
        let tv = TerminalView(frame: CGRect(x: 0, y: 0, width: 820, height: 480))
        tv.terminalDelegate = context.coordinator
        tv.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.nativeBackgroundColor = NSColor(srgbRed: 0.07, green: 0.08, blue: 0.11, alpha: 1)
        tv.nativeForegroundColor = NSColor(srgbRed: 0.86, green: 0.88, blue: 0.92, alpha: 1)
        tv.caretColor = NSColor(srgbRed: 0.47, green: 0.92, blue: 0.63, alpha: 1)

        context.coordinator.terminalView = tv

        // Wire the session's terminal sinks (invoked on the main thread).
        session.onFeedBytes = { [weak tv] data in tv?.feed(byteArray: ArraySlice(data)) }
        session.onFeedText  = { [weak tv] text in tv?.feed(text: text) }
        session.onClear     = { [weak tv] in tv?.feed(text: "\u{1b}c") }   // RIS reset
        session.currentTermSize = { [weak tv] in
            guard let t = tv?.terminal else { return (cols: 80, rows: 24) }
            return (cols: t.cols, rows: t.rows)
        }

        // Grab keyboard focus once the view is in a window.
        DispatchQueue.main.async { [weak tv] in tv?.window?.makeFirstResponder(tv) }
        return tv
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {}

    final class Coordinator: NSObject, TerminalViewDelegate {
        let session: SerialSession
        weak var terminalView: TerminalView?
        private var resizeWork: DispatchWorkItem?
        init(session: SerialSession) { self.session = session }

        // Bytes produced by the keyboard → write to the serial port.
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            guard session.connectedNow else { return }
            session.sendFromKeyboard(Data(data))
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            session.updateTermSize(cols: newCols, rows: newRows)
            guard session.connectedNow, session.autoSyncSize else { return }
            // Debounce: only push stty once the drag-resize settles.
            resizeWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.session.sendWindowSize() }
            resizeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
        func setTerminalTitle(source: TerminalView, title: String) {}
        func scrolled(source: TerminalView, position: Double) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) { NSSound.beep() }
        func clipboardCopy(source: TerminalView, content: Data) {
            if let s = String(data: content, encoding: .utf8) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(s, forType: .string)
            }
        }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
