import Cocoa
import ApplicationServices
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override init() {
    super.init()
    // Explicit diagnostic mode exits before creating the Flutter UI or starting
    // any automation. It only reads AX identities and sidebar screenshots.
    let arguments = CommandLine.arguments
    if let index = arguments.firstIndex(of: "--jd-readonly-diagnostics"),
       arguments.indices.contains(index + 1) {
      let collector = QianniuAXCollector()
      var samples: [[String: Any]] = []
      for _ in 0..<3 {
        let start = ProcessInfo.processInfo.systemUptime
        let rows = collector.conversationRows()
        let sidebarMs = (ProcessInfo.processInfo.systemUptime - start) * 1000
        let headerStart = ProcessInfo.processInfo.systemUptime
        let identity = collector.activeCustomerIdentity()
        samples.append([
          "sidebarMs": sidebarMs,
          "headerMs": (ProcessInfo.processInfo.systemUptime - headerStart) * 1000,
          "rows": rows.map { ["customer": $0["customer"] ?? "",
                               "unread": $0["unread"] ?? false] },
          "activeIdentity": identity ?? "",
        ])
      }
      let report: [String: Any] = ["accessibilityTrusted": AXIsProcessTrusted(),
        "screenCaptureAllowed": CGPreflightScreenCaptureAccess(),
        "readOnly": true, "samples": samples]
      if let data = try? JSONSerialization.data(withJSONObject: report,
                                                options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: URL(fileURLWithPath: arguments[index + 1]), options: .atomic)
      }
      exit(0)
    }
  }
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
