from pathlib import Path
import hashlib,json
root=Path.cwd();out=root/'work/transfer-v102-dryrun';source=(root/'macos/Runner/AccessibilityBridge.swift').read_text()
(out/'source-proof.json').write_text(json.dumps({'version':'v102','sourceSha256':hashlib.sha256(source.encode()).hexdigest(),'changes':['remove Flutter channel bridge only','add snapshot and condition diagnostics','replace final transfer button dispatch with false','unconditional return before click-intent publication'],'neverSendMessage':True},indent=2))
s=source.replace('import FlutterMacOS','typealias FlutterResult = (Any?) -> Void')
a=s.index('/// MethodChannel boundary');b=s.index('final class VideoAudioTranscriber',a);s=s[:a]+s[b:]
helper='''
private let jdDryRunDirectory=URL(fileURLWithPath:"/Users/m1air/Desktop/JD Automation/work/transfer-v102-dryrun")
private func jdDryRunRecord(_ data:[String:Any]) {
  var payload=data;payload["time"]=ISO8601DateFormatter().string(from:Date())
  if let bytes=try? JSONSerialization.data(withJSONObject:payload,options:[.sortedKeys]),let text=String(data:bytes,encoding:.utf8) {
    print(text);fflush(stdout)
    let url=jdDryRunDirectory.appendingPathComponent("conditions.jsonl")
    if !FileManager.default.fileExists(atPath:url.path) {FileManager.default.createFile(atPath:url.path,contents:Data())}
    if let h=try? FileHandle(forWritingTo:url) {h.seekToEndOfFile();h.write(Data((text+"\\n").utf8));try? h.close()}
  }
}
private func jdDryRunSnapshot(_ snapshot:TransferDialogSnapshot,_ stage:String) {
  let file=jdDryRunDirectory.appendingPathComponent(stage+".png")
  if let bytes=NSBitmapImageRep(cgImage:snapshot.image).representation(using:.png,properties:[:]) {try? bytes.write(to:file)}
  jdDryRunRecord(["event":"snapshot","stage":stage,"path":file.path,"imageWidth":snapshot.imageWidth,"imageHeight":snapshot.imageHeight,
    "windowBounds":[snapshot.bounds.minX,snapshot.bounds.minY,snapshot.bounds.width,snapshot.bounds.height],
    "lines":snapshot.lines.map {["text":$0.text,"confidence":Double($0.confidence),"frame":[$0.frame.minX,$0.frame.minY,$0.frame.width,$0.frame.height],"source":$0.source]},
    "candidates":transferRowDiagnostics(transferAccountCandidates(in:snapshot))])
}
'''
s+='\n'+helper
# Instrument only the real production transfer method.
a=s.index('  func transferConversation(expectedCustomer:');b=s.index('\n  }\n',a)+5;body=s[a:b]
body=body.replace('      _ = NSRunningApplication(processIdentifier: pid)?','      jdDryRunSnapshot(dialog,"before-hover")\n      jdDryRunRecord(["event":"selected_target","target":target,"frame":[candidate.frame.minX,candidate.frame.minY,candidate.frame.width,candidate.frame.height],"active":candidate.isActive])\n      _ = NSRunningApplication(processIdentifier: pid)?')
body=body.replace('      guard postHover(at:rowPoint) else {','      jdDryRunRecord(["event":"hover_point","global":[rowPoint.x,rowPoint.y],"pixel":[rowSelectionX,candidate.frame.midY]])\n      guard postHover(at:rowPoint) else {')
body=body.replace('      for _ in 0..<12 {','      for iteration in 0..<12 {')
body=body.replace('        dialog = selected','        jdDryRunSnapshot(selected,"after-hover-\\(iteration)")\n        dialog = selected')
needle='''        // Re-anchor to the freshly captured row.'''
body=body.replace(needle,'''        jdDryRunRecord(["event":"button_conditions","iteration":iteration,"target":target,
          "selectedCandidateActive":selectedCandidate.isActive,
          "lines":selected.lines.map {line in ["text":line.text,"exactText":compactTransferText(line.text)=="转接",
            "x":Double(line.frame.midX),"y":Double(line.frame.midY),
            "xLowerPass":line.frame.midX>selected.imageWidth*0.55,
            "xUpperPass":line.frame.midX<selected.imageWidth*0.85,
            "rowPass":jdTransferActionBelongsToRow(action:line.frame,candidate:selectedCandidate)]}])
'''+needle)
body=body.replace('      stage="persist_click_intent"','      jdDryRunRecord(["event":"dry_run_stopped_before_click","wouldClick":[actionPoint.x,actionPoint.y]])\n      finish(["dryRun":true,"transferClicked":false,"wouldClick":[actionPoint.x,actionPoint.y]])\n      return\n      stage="persist_click_intent"')
needle='''let dispatched=actionElement.map { AXUIElementPerformAction($0,kAXPressAction as CFString) == .success } ?? postClick(at:actionPoint)'''
assert needle in body;body=body.replace(needle,'let dispatched=false // HARD DISABLED: NO TRANSFER CLICK IN THIS HARNESS')
assert 'postClick(at:actionPoint)' not in body and 'AXUIElementPerformAction($0,kAXPressAction' not in body
s=s[:a]+body+s[b:]
s+='''
let dryApp=NSApplication.shared
dryApp.setActivationPolicy(.prohibited)
jdDryRunRecord(["event":"permission_check","AX":AXIsProcessTrusted(),"screen":CGPreflightScreenCaptureAccess()])
guard AXIsProcessTrusted(),CGPreflightScreenCaptureAccess() else {exit(2)}
let collector=QianniuAXCollector()
collector.setAutomationEpoch(102,running:true)
collector.listActiveTransferAccounts(expectedCustomer:"jd_41aeec7741d05",automationEpoch:102) {result in
  let fields=result as? [String:Any] ?? [:]
  jdDryRunRecord(["event":"accounts","result":fields])
  guard let accounts=fields["accounts"] as? [String],let target=accounts.first(where:{$0.contains("文文")}) else {exit(3)}
  collector.transferConversation(expectedCustomer:"jd_41aeec7741d05",targetAccount:target,
    attemptId:"dry-run-no-transfer-click",receiptPath:jdDryRunDirectory.appendingPathComponent("dry-run-receipt.json").path,
    automationEpoch:102) {result in
      jdDryRunRecord(["event":"final","result":result as? [String:Any] ?? [:]])
      exit(0)
    }
}
RunLoop.main.run()
'''
(out/'main.swift').write_text(s)
print('Prepared copied v102 native locator with final transfer dispatch hard disabled.')
