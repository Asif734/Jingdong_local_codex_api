import AVFoundation
import ApplicationServices
import Cocoa
import Darwin
import CryptoKit
typealias FlutterResult = (Any?) -> Void
import ImageIO
import Speech
import Vision

// BEGIN JDNativeWorkRegistry
/// The registry retires logical work immediately. OS work retains its bounded
/// worker until it returns: cancellation must never create replacement threads.
final class JDNativeWorkRegistry {
  private final class Work {
    let generation:Int
    let cancel:()->Void
    var retired=false
    init(_ generation:Int,_ cancel:@escaping ()->Void) {self.generation=generation;self.cancel=cancel}
  }
  private let lock=NSRecursiveLock()
  private let queue=OperationQueue()
  private let contextKey="jd.native.work."+UUID().uuidString
  private var generation=0
  private var epoch:Int?
  private var running=true // Explicit manual inspection before a run is supported.
  private var pending:[UUID:Work]=[:]
  private var vision:[UUID:(Int,()->Void)]=[:]
  private var resources:[UUID:()->Void]=[:]
  private let maxConcurrent:Int
  init(maxConcurrent:Int) {
    self.maxConcurrent=maxConcurrent
    queue.name="jd.native.evidence.bounded"
    queue.maxConcurrentOperationCount=maxConcurrent
    queue.qualityOfService = .userInitiated
  }
  @discardableResult func setEpoch(_ epoch:Int,running:Bool)->Int {
    lock.lock();defer {lock.unlock()}
    if self.epoch==epoch && self.running==running {return 0}
    self.epoch=epoch;self.running=running;generation += 1
    let retired=Array(pending.values);pending.removeAll()
    queue.cancelAllOperations()
    // Keep physically executing Vision registered until perform actually exits.
    let requests=Array(vision.values)
    let resourceCancels=Array(resources.values);resources.removeAll()
    for work in retired {work.retired=true;work.cancel()}
    for request in requests {request.1()}
    for cancel in resourceCancels {cancel()}
    return retired.count
  }
  func enqueue(priority:Operation.QueuePriority = .normal,cancel:@escaping ()->Void,
      work:@escaping (@escaping (@escaping ()->Void)->Void)->Void) {
    lock.lock();defer {lock.unlock()}
    guard (try? withCurrent({true}))==true else {cancel();return}
    let id=UUID(),item=Work(generation,cancel)
    pending[id]=item
    let operation=BlockOperation {
      self.lock.lock()
      let valid = !item.retired && item.generation==self.generation
      self.lock.unlock()
      guard valid else {return}
      Thread.current.threadDictionary[self.contextKey]=item
      defer {Thread.current.threadDictionary.removeObject(forKey:self.contextKey)}
      work {deliver in
        self.lock.lock();defer {self.lock.unlock()}
        guard !item.retired,item.generation==self.generation,self.pending.removeValue(forKey:id) != nil else {return}
        item.retired=true;deliver()
      }
    }
    operation.queuePriority=priority
    queue.addOperation(operation)
  }
  func currentValidity()->()->Bool {
    lock.lock();let expected=generation
    let item=Thread.current.threadDictionary[contextKey] as? Work
    lock.unlock()
    return {
      self.lock.lock();defer {self.lock.unlock()}
      return self.running && self.generation==expected && item?.retired != true
    }
  }
  /// Call on the worker before file mutations or starting nested work.
  func withCurrent<T>(_ body:() throws ->T) throws ->T {
    lock.lock();defer {lock.unlock()}
    guard running else {throw NSError(domain:"JDNativeWorkCancelled",code:1)}
    if let item=Thread.current.threadDictionary[contextKey] as? Work,
       item.retired || item.generation != generation {throw NSError(domain:"JDNativeWorkCancelled",code:1)}
    return try body()
  }
  /// Admission never waits for a semaphore on another GCD worker. All Vision
  /// paths share this physical bound, including collector/transfer helpers.
  func registerVision(cancel:@escaping ()->Void)->UUID? {
    lock.lock();defer {lock.unlock()}
    guard (try? withCurrent({true}))==true,vision.count<maxConcurrent else {cancel();return nil}
    let id=UUID();vision[id]=(generation,cancel);return id
  }
  func unregisterVision(_ id:UUID) {lock.lock();vision.removeValue(forKey:id);lock.unlock()}
  func registerResourceCancellation(_ cancel:@escaping ()->Void)->UUID? {
    lock.lock();defer {lock.unlock()}
    guard (try? withCurrent({true}))==true else {cancel();return nil}
    let id=UUID();resources[id]=cancel;return id
  }
  func unregisterResourceCancellation(_ id:UUID) {lock.lock();resources.removeValue(forKey:id);lock.unlock()}
}
// END JDNativeWorkRegistry
private let jdNativeWork=JDNativeWorkRegistry(maxConcurrent:3)

private func jdPerformVision(_ handler:VNImageRequestHandler,_ requests:[VNRequest]) throws {
  let current=jdNativeWork.currentValidity()
  guard let id=jdNativeWork.registerVision(cancel:{requests.forEach {$0.cancel()}}) else {
    throw NSError(domain:"JDNativeVisionUnavailable",code:1)
  }
  defer {jdNativeWork.unregisterVision(id)}
  try handler.perform(requests)
  guard current() else {throw NSError(domain:"JDNativeWorkCancelled",code:1)}
}

/// Metadata-only conditions share the Dart runtime trace destination. Native
/// workers serialize their appends; failures never change acquisition decisions.
private let jdMediaTraceQueue = DispatchQueue(label: "jd.media.condition.trace")
func jdMediaCondition(stage:String, id:String, expression:String,
  actual:[String:Any], threshold:[String:Any], passed:Bool,
  context:[String:Any] = [:], sourceLine:Int = #line) -> [String:Any] {
  return context.merging(["event":"media.condition", "stage":stage,
    "conditionId":id, "expression":expression, "actual":actual,
    "sourceFile":"macos/Runner/AccessibilityBridge.swift", "sourceLine":sourceLine,
    "threshold":threshold, "passed":passed,
    "outcome":passed ? "pass":"blocked"]) { _,value in value }
}
private func jdRecordMediaCondition(_ fields:[String:Any]) {
  let formatter=ISO8601DateFormatter()
  formatter.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
  let event=fields.merging(["time":formatter.string(from:Date()),
    "pid":Int(ProcessInfo.processInfo.processIdentifier)]) { _,value in value }
  guard JSONSerialization.isValidJSONObject(event),
    var bytes=try? JSONSerialization.data(withJSONObject:event,options:[.sortedKeys]) else {return}
  bytes.append(10)
  let line=bytes
  jdMediaTraceQueue.async {
    let file=FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/JD Automation/runtime.jsonl")
    try? FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
    // O_APPEND keeps each native JSONL record together with concurrent Dart appends.
    let fd=open(file.path,O_WRONLY|O_CREAT|O_APPEND,0o600)
    guard fd>=0 else {return};defer {close(fd)}
    _=line.withUnsafeBytes { write(fd,$0.baseAddress,line.count) }
  }
}

/// A new automation run owns fresh pixels and metadata even when the chat
/// looks unchanged. Legacy callers retain their existing content identity.
func jdCaptureEvidenceID(customer: String, contentHash: String,
                         historyCutoff: String?, automationSessionId: String?) -> String {
  var identity = customer + "|" + contentHash + "|" + (historyCutoff ?? "current")
  if let automationSessionId { identity += "|session:" + automationSessionId }
  return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// Hash only the AX-verified transcript pixels. Sidebar clocks, tool panels
/// and the composer cannot create a new incoming-content observation.
/// Keep the existing capture identity's crop/raster/hash algorithm unchanged.
func jdChatContentSHA256(image: CGImage, region: [String: Double]) -> String? {
  guard let left=region["left"], let right=region["right"],
        let top=region["top"], let bottom=region["bottom"],
        left.isFinite, right.isFinite, top.isFinite, bottom.isFinite,
        left>=0, right<=1, top>=0, bottom<=1, right>left, bottom>top else { return nil }
  let rect=CGRect(x:left*Double(image.width), y:top*Double(image.height),
    width:(right-left)*Double(image.width), height:(bottom-top)*Double(image.height)).integral
  guard let transcript=image.cropping(to:rect),
        let bitmap=CGContext(data:nil,width:transcript.width,height:transcript.height,
          bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),
          bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue),
        let pixels=bitmap.data else { return nil }
  memset(pixels,0,bitmap.bytesPerRow*bitmap.height)
  bitmap.draw(transcript,in:CGRect(x:0,y:0,width:transcript.width,height:transcript.height))
  return SHA256.hash(data:Data(bytes:pixels,count:bitmap.bytesPerRow*bitmap.height))
    .map {String(format:"%02x",$0)}.joined()
}

final class VideoAudioTranscriber {
  private struct Candidate {
    let transcript: String
    let language: String
    let confidence: Double
  }

  func transcribe(path:String,completion:@escaping FlutterResult) {
    let control=JDTransferWorkControl()
    jdNativeWork.enqueue(cancel:{
      control.interrupt()
      DispatchQueue.main.async {completion(["error":"automation_stopped","cancelled":true])}
    }) { finish in
      let current=jdNativeWork.currentValidity()
      let deliver:FlutterResult = {value in
        DispatchQueue.main.async {finish {completion(value)}}
      }
      DispatchQueue.main.async {
        guard current() else {return}
        let url=URL(fileURLWithPath:path).standardizedFileURL
        guard !path.isEmpty,FileManager.default.fileExists(atPath:url.path) else {
          deliver(["error":"audio_missing","message":"The extracted video audio file is missing."]);return
        }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
          deliver(["error":"speech_recognition_not_allowed","message":"Speech permission is not ready."]);return
        }
        self.recognize(url:url,languages:["zh-CN","en-US"],candidates:[],
          control:control,current:current,completion:deliver)
      }
    }
  }

  private func recognize(url: URL, languages: [String],
                         candidates: [Candidate], control:JDTransferWorkControl,
                         current:@escaping ()->Bool,completion: @escaping FlutterResult) {
    guard current(),!control.isInterrupted else {return}
    guard let language = languages.first else {
      let best = candidates.max { left, right in
        if left.confidence == right.confidence {
          return left.transcript.count < right.transcript.count
        }
        return left.confidence < right.confidence
      }
      DispatchQueue.main.async {
        completion([
          "transcript": best?.transcript ?? "",
          "language": best?.language ?? "",
          "confidence": best?.confidence ?? 0,
          "speechDetected": best?.transcript.isEmpty == false,
        ])
      }
      return
    }
    let remaining = Array(languages.dropFirst())
    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)),
          recognizer.isAvailable else {
      recognize(url: url, languages: remaining, candidates: candidates,
                control:control,current:current,completion:completion)
      return
    }
    let request = SFSpeechURLRecognitionRequest(url: url)
    request.shouldReportPartialResults = false
    var finished = false
    var cancellation:UUID?
    let task=recognizer.recognitionTask(with:request) {result,error in
      DispatchQueue.main.async {
      guard current(),!control.isInterrupted,!finished else {return}
      if let result, result.isFinal {
        finished = true
        if let cancellation {control.clearCancellation(cancellation)}
        let transcript = result.bestTranscription.formattedString
          .trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = result.bestTranscription.segments
        let confidence = segments.isEmpty ? 0 :
          segments.reduce(0) { $0 + Double($1.confidence) } /
            Double(segments.count)
        let next = transcript.isEmpty ? candidates : candidates + [Candidate(
          transcript: transcript, language: language, confidence: confidence)]
        self.recognize(url:url,languages:remaining,candidates:next,
          control:control,current:current,completion:completion)
      } else if error != nil {
        finished = true
        if let cancellation {control.clearCancellation(cancellation)}
        self.recognize(url:url,languages:remaining,candidates:candidates,
          control:control,current:current,completion:completion)
      }
      }
    }
    cancellation=control.registerCancellation {task.cancel()}
  }
}

/// Window-only screenshot and Apple Vision diagnostics. This inspector never
/// clicks, types, inserts, or sends anything to Qianniu.
final class QianniuOCRInspector {
  func setAutomationEpoch(_ epoch:Int,running:Bool) {
    let cancelled=jdNativeWork.setEpoch(epoch,running:running)
    failedSendInspectionLock.lock()
    failedSendInspectionBusy=false;lastFailedSendInspectionAt=Date.distantPast
    failedSendInspectionLock.unlock()
    jdRecordMediaCondition(["event":"native.work.epoch","epoch":epoch,
      "running":running,"cancelledPending":cancelled])
  }

  /// A trace barrier flushes all records already appended. Obsolete OS Vision
  /// requests can finish late; export must never wait for their physical exit.
  func drainForExport(completion:@escaping ()->Void) {
    jdMediaTraceQueue.async {DispatchQueue.main.async {completion()}}
  }

  private func submit(_ completion:@escaping FlutterResult,
      priority:Operation.QueuePriority = .normal,work:@escaping (@escaping FlutterResult)->Void) {
    jdNativeWork.enqueue(priority:priority,cancel:{DispatchQueue.main.async {
      completion(["error":"automation_stopped","cancelled":true,
        "message":"Native evidence work was cancelled by Stop or a new run."])
    }}) {finish in
      work {value in
        DispatchQueue.main.async {finish {completion(value)}}
      }
    }
  }

  var viewportContextProvider: (() -> (customer: String, frame: CGRect, bottom: CGFloat)?)?
  var customerIdentityProvider: (() -> String?)?
  var chatFrameProvider: (() -> CGRect?)?
  var messageBottomProvider: (() -> CGFloat?)?
  var onFailedSendInspection: (([String: Any]) -> Void)?
  private let bundleIdentifier = "com.jd.jdmddwb"
  private let failedSendInspectionLock = NSLock()
  private var failedSendInspectionBusy = false
  private var lastFailedSendInspectionAt = Date.distantPast

  /// Reuse captured pixels, but never make incoming OCR wait for pixel scans.
  /// Drop overlapping/obsolete work instead of accumulating queued scans.
  func inspectFailedSends(image: CGImage, windowBounds: CGRect, windowID: CGWindowID,
      transcript: CGRect, customer: String, capturedAt: Date) {
    guard (try? jdNativeWork.withCurrent({true}))==true else {return}
    failedSendInspectionLock.lock()
    guard !failedSendInspectionBusy,
          Date().timeIntervalSince(lastFailedSendInspectionAt) >= 5 else {
      failedSendInspectionLock.unlock(); return
    }
    failedSendInspectionBusy = true
    lastFailedSendInspectionAt = Date()
    failedSendInspectionLock.unlock()
    submit({ [weak self] value in
      if (value as? [String:Any])?["cancelled"] as? Bool == true {return}
      self?.failedSendInspectionLock.lock()
      self?.failedSendInspectionBusy=false
      self?.failedSendInspectionLock.unlock()
      if let payload=value as? [String:Any],payload["cancelled"] == nil {self?.onFailedSendInspection?(payload)}
    }) { completion in
      let candidates = failedSendBubbles(image: image,
          windowBounds: windowBounds, chatFrame: transcript).map {
        let body = recognizeTransferText(in: $0.image, deadline: Date().addingTimeInterval(0.65))
          .map(\.text).joined(separator: "\n")
        return ["bodyText": body, "x": Double($0.point.x), "y": Double($0.point.y),
         "left": Double($0.frame.minX), "top": Double($0.frame.minY),
         "width": Double($0.frame.width), "height": Double($0.frame.height),
         "fingerprint": $0.fingerprint, "windowId": Int(windowID)] as [String: Any]
      }
      guard !candidates.isEmpty else { completion(nil);return }
      completion(["customer":customer,"capturedAtMs":Int(capturedAt.timeIntervalSince1970*1000),"candidates":candidates])
    }
  }

  func requestScreenRecording() -> Bool {
    if CGPreflightScreenCaptureAccess() { return true }
    return CGRequestScreenCaptureAccess()
  }

  func availableWindows() -> [[String: Any]] {
    guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
      .first(where: { !$0.isTerminated })?.processIdentifier else { return [] }
    return windows(pid: pid).map(\.payload)
  }

  func inspect(windowID: CGWindowID?, recognitionLevel: String, completion: @escaping FlutterResult) {
    submit(completion) { [weak self] completion in
      guard let self else { return }
      let response: [String: Any]
      do {
        response = try self.captureAndRecognize(
          windowID: windowID,
          recognitionLevel: recognitionLevel)
      } catch let error as OCRInspectorError {
        response = error.payload
      } catch {
        response = ["error": "ocr_failed", "message": error.localizedDescription]
      }
      DispatchQueue.main.async { completion(response) }
    }
  }

  private func captureFrame(windowID: CGWindowID?, expectedCustomer: String? = nil) throws -> ViewportFrame {
    guard CGPreflightScreenCaptureAccess() else {
      throw OCRInspectorError(
        code: "screen_recording_not_allowed",
        message: "Grant Screen Recording permission to JD Automation, then restart the app.")
    }
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
      .first(where: { !$0.isTerminated }) else {
      throw OCRInspectorError(code: "jd_not_running", message: "JD 咚咚工作台 is not running.")
    }
    let availableWindows = windows(pid: app.processIdentifier)
    guard let window = windowID.flatMap({ selectedID in
      availableWindows.first(where: { $0.id == selectedID })
    }) ?? availableWindows.first(where: { $0.title.contains("咚咚融合工作台") }) else {
      throw OCRInspectorError(
        code: "jd_window_missing",
        message: "No visible JD 咚咚 window was found. Open its customer-service window and retry.")
    }
    guard let context = viewportContextProvider?(),
          expectedCustomer == nil || exactCustomerIdentityMatches(context.customer, expectedCustomer!) else {
      throw OCRInspectorError(code: "snapshot_customer_mismatch", message: "Active AX customer and transcript were not verified.")
    }
    let customer = context.customer, chatFrame = context.frame, bottom = context.bottom
    let snapshotAt = Date()
    guard let image = CGWindowListCreateImage(
      .null,
      .optionIncludingWindow,
      window.id,
      [.boundsIgnoreFraming, .bestResolution]) else {
      throw OCRInspectorError(code: "window_capture_failed", message: "macOS could not capture the JD 咚咚 window.")
    }

    guard let after = viewportContextProvider?(), exactCustomerIdentityMatches(customer, after.customer) else {
      throw OCRInspectorError(code: "snapshot_customer_changed", message: "Customer changed while acquiring pixels.")
    }
    guard abs(after.frame.minX-chatFrame.minX) <= 1, abs(after.frame.minY-chatFrame.minY) <= 1,
          abs(after.frame.width-chatFrame.width) <= 1, abs(after.bottom-bottom) <= 1,
          chatFrame.minX >= window.bounds.minX, chatFrame.maxX <= window.bounds.maxX,
          chatFrame.minY >= window.bounds.minY, bottom <= window.bounds.maxY else {
      throw OCRInspectorError(code: "snapshot_geometry_changed", message: "Transcript layout changed while acquiring pixels.")
    }
    let region: [String: Double] = [
      "left": max(0, min(1, (chatFrame.minX-window.bounds.minX)/window.bounds.width)),
      "right": max(0, min(1, (chatFrame.maxX-window.bounds.minX)/window.bounds.width)),
      "top": max(0, min(1, (chatFrame.minY-window.bounds.minY)/window.bounds.height)),
      "bottom": max(0, min(1, (bottom-window.bounds.minY)/window.bounds.height)),
    ]
    return ViewportFrame(image: image, window: window, customer: customer,
      capturedAt: snapshotAt, chatRegion: region, pid: app.processIdentifier)
  }

  private func captureAndRecognize(windowID: CGWindowID?, recognitionLevel: String) throws -> [String: Any] {
    try recognizeFrame(captureFrame(windowID: windowID), recognitionLevel: recognitionLevel)
  }

  private func recognizeFrame(_ frame: ViewportFrame, recognitionLevel: String, saved:Bool = false,
    diagnosticContext:[String:Any] = [:]) throws -> [String: Any] {
    let image = frame.image, window = frame.window
    let textFirst = recognitionLevel == "text_first"
    var cropBounds = CGRect(x:0,y:0,width:image.width,height:image.height)
    var visionImage = image
    if textFirst,
       let left=frame.chatRegion["left"],let right=frame.chatRegion["right"],
       let top=frame.chatRegion["top"],let bottom=frame.chatRegion["bottom"],
       left < right, top < bottom {
      let crop = CGRect(x:left*Double(image.width),y:top*Double(image.height),
        width:(right-left)*Double(image.width),height:(bottom-top)*Double(image.height)).integral
      if let pixels=image.cropping(to:crop) { visionImage=pixels;cropBounds=crop }
    }
    func windowBox(_ box:CGRect) -> CGRect {
      CGRect(x:(cropBounds.minX+box.minX*cropBounds.width)/CGFloat(image.width),
        y:(CGFloat(image.height)-cropBounds.maxY+box.minY*cropBounds.height)/CGFloat(image.height),
        width:box.width*cropBounds.width/CGFloat(image.width),
        height:box.height*cropBounds.height/CGFloat(image.height))
    }
    var observations: [[String: Any]] = []
    var visualRegions: [[String: Any]] = []
    let request = VNRecognizeTextRequest()
      request.recognitionLevel = recognitionLevel == "fast" ? .fast : .accurate
      request.usesLanguageCorrection = true
      request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]

      // A second English pass recovers short wrapped lines that the mixed
      // language pass can omit. The shared Dart extractor then joins every
      // sender-bounded line using the recent workflow.
      let englishRequest = VNRecognizeTextRequest()
      englishRequest.recognitionLevel = request.recognitionLevel
      englishRequest.usesLanguageCorrection = false
      englishRequest.recognitionLanguages = ["en-US"]

      // Use an independent Chinese pass so a short Chinese bubble cannot be
      // reduced to a Latin placeholder such as `D` by the mixed pass.
      let chineseRequest = VNRecognizeTextRequest()
      chineseRequest.recognitionLevel = request.recognitionLevel
      chineseRequest.usesLanguageCorrection = false
      chineseRequest.recognitionLanguages = ["zh-Hans", "zh-Hant"]

      let rectangles = VNDetectRectanglesRequest()
      rectangles.maximumObservations = 24
      rectangles.minimumSize = 0.06
      rectangles.minimumAspectRatio = 0.25
      rectangles.maximumAspectRatio = 4.0
      rectangles.quadratureTolerance = 18
      let requests:[VNRequest] = textFirst
        ? [request, rectangles] : [request, englishRequest, chineseRequest, rectangles]
      try jdPerformVision(VNImageRequestHandler(cgImage:visionImage,orientation:.up),requests)

      struct RecognizedLine {
        let text: String
        let confidence: Float
        let box: CGRect
        let rotation: Double
      }
      func lines(from results: [VNRecognizedTextObservation]?) -> [RecognizedLine] {
        (results ?? []).compactMap { observation in
          guard let candidate = observation.topCandidates(1).first else { return nil }
          return RecognizedLine(
            text: candidate.string,
            confidence: candidate.confidence,
            box: observation.boundingBox,
            rotation: atan2(Double(observation.topRight.y-observation.topLeft.y),
              Double(observation.topRight.x-observation.topLeft.x))*180/Double.pi)
        }
      }
      func sameVisualLine(_ left: CGRect, _ right: CGRect) -> Bool {
        let intersection = left.intersection(right)
        guard !intersection.isNull else { return false }
        let smallerArea = min(left.width * left.height, right.width * right.height)
        return smallerArea > 0 && intersection.width * intersection.height / smallerArea >= 0.45
      }

      func containsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
          (0x3400...0x9FFF).contains(Int(scalar.value))
        }
      }

      var mergedLines = lines(from: request.results)
      func merge(_ fallbackLines: [RecognizedLine]) {
        for fallback in fallbackLines {
          if let index = mergedLines.firstIndex(where: { sameVisualLine($0.box, fallback.box) }) {
            let current = mergedLines[index]
            let currentHasHan = containsHan(current.text)
            let fallbackHasHan = containsHan(fallback.text)
            let currentLength = current.text.replacingOccurrences(of: " ", with: "").count
            let fallbackLength = fallback.text.replacingOccurrences(of: " ", with: "").count
            if (fallbackHasHan && !currentHasHan) ||
                (fallbackHasHan == currentHasHan &&
                  (fallbackLength > currentLength ||
                    (fallbackLength == currentLength && fallback.confidence > current.confidence))) {
              mergedLines[index] = fallback
            }
          } else {
            mergedLines.append(fallback)
          }
        }
      }
      merge(lines(from: englishRequest.results))
      merge(lines(from: chineseRequest.results))

      let inkBitmap=NSBitmapImageRep(cgImage:image)
      func watermarkInk(_ box:CGRect) -> Bool {
        let x0=max(0,Int(Double(box.minX)*Double(image.width)))
        let x1=min(image.width,Int(Double(box.maxX)*Double(image.width)))
        let y0=max(0,Int(Double(1-box.maxY)*Double(image.height)))
        let y1=min(image.height,Int(Double(1-box.minY)*Double(image.height)))
        guard x1>x0,y1>y0 else { return false }
        var pink=0,dark=0
        for y in stride(from:y0,to:y1,by:max(1,(y1-y0)/12)) {
          for x in stride(from:x0,to:x1,by:max(1,(x1-x0)/24)) {
            guard let c=inkBitmap.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB) else { continue }
            let r=c.redComponent,g=c.greenComponent,b=c.blueComponent
            if r<0.5 && g<0.5 && b<0.5 { dark+=1 }
            if r>0.70 && g>0.65 && b>0.65 && r-g>0.025 && r-b>0.015 { pink+=1 }
          }
        }
        return pink>=4 && dark<=max(1,pink/12)
      }
      observations = mergedLines.map { line -> [String: Any] in
        let box = windowBox(line.box)
        return [
          "text": line.text,
          "confidence": Double(line.confidence),
          "rotationDegrees": line.rotation,
          "isWatermark": watermarkInk(box),
          "x": Double(box.minX),
          "y": Double(1 - box.maxY),
          "width": Double(box.width),
          "height": Double(box.height),
        ]
      }.sorted {
        let leftY = $0["y"] as? Double ?? 0
        let rightY = $1["y"] as? Double ?? 0
        if abs(leftY - rightY) > 0.01 { return leftY < rightY }
        return ($0["x"] as? Double ?? 0) < ($1["x"] as? Double ?? 0)
      }
    visualRegions = (rectangles.results ?? []).map { observation -> [String: Any] in
        let box = windowBox(observation.boundingBox)
        return [
          "x": Double(box.minX),
          "y": Double(1 - box.maxY),
          "width": Double(box.width),
          "height": Double(box.height),
          "confidence": Double(observation.confidence),
        ]
    }

    // A saved viewport already has an immutable PNG on disk. Don't encode
    // and transport another full image just to return its recognized lines.
    var pngBase64 = ""
    if !saved {
      guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        throw OCRInspectorError(code: "png_encoding_failed", message: "Could not encode the captured window image.")
      }
      pngBase64 = png.base64EncodedString()
    }
    let bands = jdIncomingMediaBands(observations: observations,
      customer: frame.customer, chatRegion: frame.chatRegion)
    let pixelMediaRegions = jdUnboundMediaRegions(image: image,
      chatRegion: frame.chatRegion, includeFullCards: true, messageBands: bands,
      onDiagnostic: { condition in
        jdRecordMediaCondition(condition.merging(diagnosticContext) { _,value in value }
          .merging(["customer":frame.customer,"capturedAtMs":Int(frame.capturedAt.timeIntervalSince1970*1000)]) { _,value in value })
      })
    var payload: [String: Any] = [
      "pid": Int(frame.pid),
      "windowId": Int(window.id),
      "windowTitle": window.title,
      "windowBounds": [
        "x": Double(window.bounds.minX), "y": Double(window.bounds.minY),
        "width": Double(window.bounds.width), "height": Double(window.bounds.height),
      ],
      "imageWidth": image.width,
      "imageHeight": image.height,
      "pngBase64": pngBase64,
      "observations": observations,
      "visualRegions": visualRegions,
      "unboundMediaRegions": pixelMediaRegions.filter { $0["proof"] as? String == "explicit_play_overlay" },
      "physicalMediaRegions": pixelMediaRegions.filter { $0["proof"] as? String == "full_card_pixels" },
      "recognizedText": observations.compactMap { $0["text"] as? String }.joined(separator: "\n"),
      "ocrEngine": textFirst ? "apple_vision_text_first" : "apple_vision",
      "activeCustomerId": frame.customer,
      "capturedAtMs": Int(frame.capturedAt.timeIntervalSince1970 * 1000),
      "chatRegion": frame.chatRegion,
    ]
    if !saved,let content=jdChatContentSHA256(image:frame.image,region:frame.chatRegion) {
      payload["chatContentSHA256"]=content
    }
    return payload
  }

  func captureEvidence(expectedCustomer: String?, directory: String,
                       historyCutoff: NSNumber?, historyCutoffs: [String:NSNumber],
                       automationSessionId: String? = nil,
                       completion: @escaping FlutterResult) {
    submit(completion,priority:.veryHigh) { [weak self] completion in
      guard let self else { return }
      self.finishEvidence(completion) {
        let frame = try self.captureFrame(windowID: nil, expectedCustomer: expectedCustomer)
        let cutoff = historyCutoff ?? historyCutoffs[frame.customer]
        guard let content=jdChatContentSHA256(image:frame.image,region:frame.chatRegion) else {
          throw OCRInspectorError(code: "snapshot_invalid_transcript", message: "Transcript pixels are unavailable.")
        }
        let id = jdCaptureEvidenceID(customer: frame.customer, contentHash: content,
          historyCutoff: cutoff?.stringValue, automationSessionId: automationSessionId)
        let folder = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
        try jdNativeWork.withCurrent {try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)}
        let manifest = folder.appendingPathComponent(id + ".json")
        let file = folder.appendingPathComponent(id + ".png")
        if let bytes = try? Data(contentsOf: manifest),
           var existing = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
           FileManager.default.fileExists(atPath: file.path) {
          existing["manifestPath"] = manifest.path
          existing["imagePath"] = file.path
          existing["chatContentSHA256"] = content
          return existing
        }
        guard let png = NSBitmapImageRep(cgImage: frame.image).representation(using: .png, properties: [:]) else {
          throw OCRInspectorError(code: "snapshot_encoding_failed", message: "Could not encode evidence.")
        }
        try jdNativeWork.withCurrent {try png.write(to:file,options:.atomic)}
        var info: [String: Any] = ["evidenceId": id, "customer": frame.customer,
          "imagePath": file.path, "manifestPath": manifest.path,
          "capturedAtMs": Int(frame.capturedAt.timeIntervalSince1970 * 1000),
          "windowId": Int(frame.window.id), "windowTitle": frame.window.title,
          "windowBounds": frame.window.payload, "chatRegion": frame.chatRegion,
          "chatContentSHA256": content,
          "pngSHA256": SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()]
        if let automationSessionId { info["automationSessionId"] = automationSessionId }
        info["imageWidth"] = frame.image.width; info["imageHeight"] = frame.image.height
        if let cutoff { info["historyCutoffMs"] = cutoff }
        if cutoff == nil {
          let chat = frame.chatRegion
          self.inspectFailedSends(image: frame.image, windowBounds: frame.window.bounds,
            windowID: frame.window.id,
            transcript: CGRect(x:frame.window.bounds.minX + (chat["left"] ?? 0)*frame.window.bounds.width,
              y:frame.window.bounds.minY + (chat["top"] ?? 0)*frame.window.bounds.height,
              width:((chat["right"] ?? 1)-(chat["left"] ?? 0))*frame.window.bounds.width,
              height:((chat["bottom"] ?? 1)-(chat["top"] ?? 0))*frame.window.bounds.height),
            customer:frame.customer,capturedAt:frame.capturedAt)
        }
        try jdNativeWork.withCurrent {try JSONSerialization.data(withJSONObject:info).write(to:manifest,options:.atomic)}
        return info
      }
    }
  }

  private func loadEvidence(_ path: String, expectedCustomer: String) throws -> ViewportFrame {
    let manifest = URL(fileURLWithPath: path).standardizedFileURL
    let raw = try Data(contentsOf: manifest)
    guard let info = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
          let customer = info["customer"] as? String, exactCustomerIdentityMatches(customer, expectedCustomer),
          let id = info["evidenceId"] as? String, id.count == 64,
          id.allSatisfy({ $0.isHexDigit }), manifest.lastPathComponent == id + ".json",
          let bounds = info["windowBounds"] as? [String: Any],
          let region = info["chatRegion"] as? [String: Double] else {
      throw OCRInspectorError(code: "evidence_identity_invalid", message: "Evidence identity could not be verified.")
    }
    let file = manifest.deletingLastPathComponent().appendingPathComponent(id + ".png")
    let bytes = try Data(contentsOf: file)
    guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == info["pngSHA256"] as? String,
          let image = NSBitmapImageRep(data: bytes)?.cgImage else {
      throw OCRInspectorError(code: "evidence_integrity_failed", message: "Saved pixels changed or were incomplete.")
    }
    func number(_ key: String) -> Double { (bounds[key] as? NSNumber)?.doubleValue ?? 0 }
    let window = OCRWindow(id: CGWindowID((info["windowId"] as? NSNumber)?.uint32Value ?? 0),
      title: info["windowTitle"] as? String ?? "JD saved evidence",
      bounds: CGRect(x: number("x"), y: number("y"), width: number("width"), height: number("height")))
    return ViewportFrame(image: image, window: window, customer: customer,
      capturedAt: Date(timeIntervalSince1970: ((info["capturedAtMs"] as? NSNumber)?.doubleValue ?? 0)/1000),
      chatRegion: region, pid: 0)
  }

  func inspectEvidence(manifestPath: String, expectedCustomer: String,
                       recognitionLevel: String, liveRegistration: Bool = false,
                       mediaRecognition: Bool = false, completion: @escaping FlutterResult) {
    submit(completion,priority:liveRegistration ? .high : (mediaRecognition ? .normal : .low)) { [weak self] completion in
      guard let self else { return }
      self.finishEvidence(completion) {
        try self.recognizeFrame(self.loadEvidence(manifestPath, expectedCustomer: expectedCustomer),
          recognitionLevel: recognitionLevel, saved:true, diagnosticContext:[
            "manifestPath":manifestPath,
            "evidenceId":URL(fileURLWithPath:manifestPath).deletingPathExtension().lastPathComponent])
      }
    }
  }

  func refineEvidenceText(manifestPath:String,expectedCustomer:String,region:CGRect,
      completion:@escaping FlutterResult) {
    submit(completion,priority:.high) { [weak self] completion in
      guard let self else { return }
      self.finishEvidence(completion) {
        let frame=try self.loadEvidence(manifestPath,expectedCustomer:expectedCustomer)
        guard region.minX >= (frame.chatRegion["left"] ?? 0),
          region.minY >= (frame.chatRegion["top"] ?? 0),
          region.maxX <= (frame.chatRegion["right"] ?? 1),
          region.maxY <= (frame.chatRegion["bottom"] ?? 1),
          region.width>0,region.height>0,region.width<=0.2,region.height<=0.1 else {
          throw OCRInspectorError(code:"text_region_invalid",message:"Text region is outside the saved customer transcript.")
        }
        return ["observations":try jdRefinedTextLines(image:frame.image,region:region)]
      }
    }
  }

  func cropEvidence(manifestPath: String, expectedCustomer: String,
                    destinationDirectory: String?, expectedMediaAt:Date? = nil,
                    clippedMediaKind: String? = nil,
                    region: CGRect, completion: @escaping FlutterResult) {
    submit(completion) { [weak self] completion in
      guard let self else { return }
      self.finishEvidence(completion) {
        let frame = try self.loadEvidence(manifestPath, expectedCustomer: expectedCustomer)
        var diagnosticContext:[String:Any] = ["customer":expectedCustomer,
          "evidenceId":URL(fileURLWithPath:manifestPath).deletingPathExtension().lastPathComponent,
          "manifestPath":manifestPath,"capturedAtMs":Int(frame.capturedAt.timeIntervalSince1970*1000),
          "region":["x":region.minX,"y":region.minY,"width":region.width,"height":region.height]]
        if let expectedMediaAt {
          diagnosticContext["expectedMediaAtMs"]=Int(expectedMediaAt.timeIntervalSince1970*1000)
          let formatter=ISO8601DateFormatter()
          formatter.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
          diagnosticContext["expectedMessageTime"]=formatter.string(from:expectedMediaAt)
        }
        func note(_ id:String,_ expression:String,_ actual:[String:Any],_ threshold:[String:Any],_ passed:Bool,sourceLine:Int = #line) {
          jdRecordMediaCondition(jdMediaCondition(stage:"media.crop",id:id,expression:expression,
            actual:actual,threshold:threshold,passed:passed,context:diagnosticContext,sourceLine:sourceLine))
        }
        note("crop.transcript_bounds", "region.minX >= chat.left && region.minY >= chat.top && region.maxX <= chat.right && region.maxY <= chat.bottom && region.width > 0 && region.height > 0",
          ["x":region.minX,"y":region.minY,"right":region.maxX,"bottom":region.maxY,
            "width":region.width,"height":region.height],frame.chatRegion,
          region.minX >= (frame.chatRegion["left"] ?? 0) && region.minY >= (frame.chatRegion["top"] ?? 0) &&
          region.maxX <= (frame.chatRegion["right"] ?? 1) && region.maxY <= (frame.chatRegion["bottom"] ?? 1) &&
          region.width > 0 && region.height > 0)
        guard region.minX >= (frame.chatRegion["left"] ?? 0), region.minY >= (frame.chatRegion["top"] ?? 0),
              region.maxX <= (frame.chatRegion["right"] ?? 1),
              region.maxY <= (frame.chatRegion["bottom"] ?? 1), region.width > 0, region.height > 0,
              let crop = frame.image.cropping(to: CGRect(
                x: region.minX * CGFloat(frame.image.width), y: region.minY * CGFloat(frame.image.height),
                width: region.width * CGFloat(frame.image.width), height: region.height * CGFloat(frame.image.height)).integral) else {
          throw OCRInspectorError(code: "evidence_crop_invalid", message: "Region is outside the saved transcript.")
        }
        // A nearly uniform chat-background crop is an unresolved candidate,
        // not a customer photograph. Raw frame/ROI remain available for retry.
        let foreground = mediaForegroundFraction(crop)
        let bitmap = NSBitmapImageRep(cgImage: crop)
        let cardPreviewBase64 = bitmap.representation(using: .jpeg,
          properties: [.compressionFactor: 0.8])?.base64EncodedString() ?? ""
        let hasPlayOverlay = looksLikeVideoThumbnail(crop)
        note("crop.foreground", "foregroundFraction >= 0.025 || hasPlayOverlay",
          ["foregroundFraction":foreground,"hasPlayOverlay":hasPlayOverlay],
          ["foregroundFractionMin":0.025,"foregroundPixelRGBDeltaExclusive":24,"samplePixels":1024],
          foreground >= 0.025 || hasPlayOverlay)
        note("crop.loaded_video_cover", "!(hasPlayOverlay && foregroundFraction < 0.025 && clippedMediaKind == nil)",
          ["foregroundFraction":foreground,"hasPlayOverlay":hasPlayOverlay,"clippedMediaKind":clippedMediaKind ?? "none"],
          ["foregroundFractionMin":0.025], !(hasPlayOverlay && foreground < 0.025 && clippedMediaKind == nil))
        if hasPlayOverlay && foreground < 0.025 && clippedMediaKind == nil {
          return ["kind":"video", "reason":"video_cover_still_loading",
            "foregroundFraction":foreground, "captureSource":"frozen-window-crop",
            "playbackOverlayDetected":true, "visualFingerprint":averageImageHash(crop),
            "cardPreviewDataBase64":cardPreviewBase64, "dataBase64":cardPreviewBase64,
            "mimeType":"image/jpeg", "extension":"jpg"]
        }
        var cacheSearch = [[String:Any]]()
        let noteVideo:([String:Any])->Void = { fields in
          if fields["event"] as? String == "media.condition" {
            jdRecordMediaCondition(fields.merging(diagnosticContext.merging(["mediaKind":"video"]){ _,new in new }){ _,new in new })
          } else {
            cacheSearch.append(fields.merging(["kind":"video"]){ _,new in new })
            jdRecordMediaCondition(fields.merging(diagnosticContext){ _,new in new }
              .merging(["event":"media.cache_search","stage":"media.cache_match","mediaKind":"video"]){ _,new in new })
          }
        }
        let noteImage:([String:Any])->Void = { fields in
          if fields["event"] as? String == "media.condition" {
            jdRecordMediaCondition(fields.merging(diagnosticContext.merging(["mediaKind":"image"]){ _,new in new }){ _,new in new })
          } else {
            cacheSearch.append(fields.merging(["kind":"image"]){ _,new in new })
            jdRecordMediaCondition(fields.merging(diagnosticContext){ _,new in new }
              .merging(["event":"media.cache_search","stage":"media.cache_match","mediaKind":"image"]){ _,new in new })
          }
        }

        guard foreground >= 0.025 || hasPlayOverlay else {
          return ["kind": "unverified", "reason": "insufficient_visual_evidence",
            "foregroundFraction": foreground, "captureSource": "frozen-window-crop",
            "cardPreviewDataBase64": cardPreviewBase64]
        }
        // A thumbnail with a same-stem video in the SAME chat cache is stronger
        // evidence than the shape of its play button. Pixel matching still
        // binds it to this immutable, AX-verified customer frame. An original
        // can finish downloading later; its age is not task completion proof.
        let thumbnail = clippedMediaKind == "image" || destinationDirectory == nil ? nil :
          matchingRecentJDCachedImage(visibleImage: crop,
            expectedAt: expectedMediaAt ?? frame.capturedAt, videoThumbnailsOnly: true,
            includeUnlinkedVideoCovers: hasPlayOverlay && clippedMediaKind == nil,
            receptionTitle:frame.window.title, clippedBottom:clippedMediaKind != nil, onSearch:noteVideo)
        func matchImage() -> JDCachedImageCandidate? {
          matchingRecentJDCachedImage(visibleImage: crop,
            expectedAt: expectedMediaAt ?? frame.capturedAt,
            receptionTitle:frame.window.title,clippedBottom:clippedMediaKind != nil,onSearch:noteImage)
        }
        let unknownImage = clippedMediaKind == "unknown" ? matchImage() : nil
        if clippedMediaKind == "unknown" {
          let hits = cacheSearch.filter { ($0["visualMatches"] as? Int ?? 0) > 0 }
          if hits.count > 1 || (hasPlayOverlay && unknownImage != nil) {
            return ["kind":"unverified", "reason":"clipped_media_kind_ambiguous",
              "cacheSearch":cacheSearch, "captureSource":"frozen-window-crop",
              "foregroundFraction":foreground, "cardPreviewDataBase64":cardPreviewBase64]
          }
        }
        if let destinationDirectory, let thumbnail,
           let video = verifiedCompanionVideo(thumbnail: thumbnail.url) ??
             (hasPlayOverlay ? verifiedVisualVideoCompanion(thumbnail:thumbnail.url) : nil),
           let thumbnailValues = try? thumbnail.url.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey]),
           thumbnailValues.fileSize == thumbnail.size, thumbnailValues.contentModificationDate == thumbnail.modified,
           let values = try? video.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
           let size = values.fileSize, size > 0, size <= 100 * 1024 * 1024,
           let modified = values.contentModificationDate {
          let directory = URL(fileURLWithPath: destinationDirectory, isDirectory: true)
          try jdNativeWork.withCurrent {try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)}
          let key = SHA256.hash(data: Data("\(video.path)|\(modified.timeIntervalSince1970)|\(size)".utf8))
            .map { String(format: "%02x", $0) }.joined()
          let target = directory.appendingPathComponent(key).appendingPathExtension(video.pathExtension)
          if !FileManager.default.fileExists(atPath: target.path) {
            let temporary = directory.appendingPathComponent("\(UUID().uuidString).partial")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try FileManager.default.copyItem(at: video, to: temporary)
            let after = try video.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard after.fileSize == size, after.contentModificationDate == modified,
              (try temporary.resourceValues(forKeys: [.fileSizeKey])).fileSize == size else {
              throw OCRInspectorError(code: "video_cache_changed", message: "Video changed while being copied.")
            }
            do {
              try jdNativeWork.withCurrent {try FileManager.default.moveItem(at:temporary,to:target)}
            } catch {
              // A concurrent crop of the same verified source can publish
              // first. The shared file still goes through the size check.
              guard FileManager.default.fileExists(atPath: target.path) else { throw error }
            }
          }
          guard (try target.resourceValues(forKeys: [.fileSizeKey])).fileSize == size else {
            throw OCRInspectorError(code: "video_copy_incomplete", message: "Saved video is incomplete.")
          }
          let png = NSBitmapImageRep(cgImage: crop).representation(using: .png, properties: [:])
          return ["kind": "video", "cacheSearch":cacheSearch, "reason": verifiedCompanionVideo(thumbnail:thumbnail.url) != nil ? "pixel_matched_same_chat_video_companion" : "pixel_matched_unique_video_frame",
            "cardPreviewDataBase64": cardPreviewBase64, "playbackOverlayDetected": hasPlayOverlay,
            "captureSource": "frozen-frame-video-cache", "foregroundFraction": foreground,
            "cacheKey":JDTimedCachedMediaCandidate(url:video,modified:modified,size:size,kind:"video").cacheKey,
            "cacheModifiedAtMs":Int(modified.timeIntervalSince1970*1000),
            "visualFingerprint": averageImageHash(crop), "dataBase64": png?.base64EncodedString() ?? "",
            "video": ["path": target.path, "originalName": video.lastPathComponent,
              "mimeType": ["mov","m4v"].contains(video.pathExtension.lowercased()) ? "video/quicktime" : (video.pathExtension.lowercased() == "webm" ? "video/webm" : "video/mp4")]]
        }
        let matched = clippedMediaKind == "unknown" ? unknownImage :
          (clippedMediaKind == "video" ? nil : matchImage())
        if let cached = matched,let data = try? Data(contentsOf: cached.url), data.count == cached.size,
           jdCompleteOriginalImage(data) != nil,
           let values = try? cached.url.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey]),
           values.fileSize == cached.size, values.contentModificationDate == cached.modified {
          let ext = cached.url.pathExtension.lowercased()
          return ["kind": hasPlayOverlay ? "video" : "image",
            "cacheSearch":cacheSearch,
            "reason": hasPlayOverlay ? "owned_video_cover_original_unavailable" : "pixel_matched_image_original",
            "cardPreviewDataBase64": cardPreviewBase64, "playbackOverlayDetected": hasPlayOverlay,
            "mimeType": ext == "png" ? "image/png" : "image/jpeg",
            "extension": ext, "originalName": cached.url.lastPathComponent,
            "dataBase64": data.base64EncodedString(), "visualFingerprint": cached.fingerprint,
            "captureSource": "jd-image-cache"]
        }
        guard let png = NSBitmapImageRep(cgImage: crop).representation(using: .png, properties: [:]) else {
          throw OCRInspectorError(code: "evidence_crop_encoding_failed", message: "Could not encode saved image region.")
        }
        return ["kind": hasPlayOverlay ? "video" : "image",
          "cardPreviewDataBase64": cardPreviewBase64, "playbackOverlayDetected": hasPlayOverlay,
          "dataBase64": png.base64EncodedString(), "mimeType": "image/png", "extension": "png",
          "visualFingerprint": averageImageHash(crop), "captureSource": "frozen-window-crop",
          "foregroundFraction": foreground, "reason": "visible_crop_only",
          "cacheSearch":cacheSearch,"cacheSelectedButUnreadable":matched != nil]
      }
    }
  }

  private func finishEvidence(_ completion: @escaping FlutterResult,
                              work: () throws -> [String: Any]) {
    let result: [String: Any]
    do { result = try work() }
    catch let error as OCRInspectorError { result = error.payload }
    catch { result = ["error": "evidence_failed", "message": error.localizedDescription] }
    DispatchQueue.main.async { completion(result) }
  }

  private func windows(pid: pid_t) -> [OCRWindow] {
    // CGWindowListCopyWindowInfo returns windows from front to back. Preserve
    // that order: Qianniu's detached reception window floats above its main UI.
    guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
      as? [[String: Any]] else { return [] }
    return raw.compactMap { info -> OCRWindow? in
      guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
            (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
            let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
            let boundsDictionary = info[kCGWindowBounds as String] as? [String: Any],
            let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
            bounds.width >= 300, bounds.height >= 200 else { return nil }
      return OCRWindow(
        id: CGWindowID(id),
        title: info[kCGWindowName as String] as? String ?? "JD 咚咚工作台",
        bounds: bounds)
    }
  }
}

private struct ViewportFrame {
  let image: CGImage
  let window: OCRWindow
  let customer: String
  let capturedAt: Date
  let chatRegion: [String: Double]
  let pid: pid_t
}

private struct OCRWindow {
  let id: CGWindowID
  let title: String
  let bounds: CGRect

  var area: CGFloat { bounds.width * bounds.height }

  var payload: [String: Any] {
    [
      "windowId": Int(id),
      "title": title,
      "x": Double(bounds.minX),
      "y": Double(bounds.minY),
      "width": Double(bounds.width),
      "height": Double(bounds.height),
    ]
  }
}

private struct UnreadScreenshot {
  let bounds: CGRect
  let image: CGImage
}

struct JDRowConfirmationGate {
  var previous:String?
  var requiredChangeFrom:String?
  mutating func observe(selected:Bool,header:String?,expected:String?)->String? {
    guard selected,let header,!header.isEmpty else { previous=nil;return nil }
    if let expected,!exactCustomerIdentityMatches(header,expected) { previous=nil;return nil }
    if let old=requiredChangeFrom,exactCustomerIdentityMatches(header,old) { previous=nil;return nil }
    let stable=previous.map { exactCustomerIdentityMatches($0,header) }==true
    previous=header
    return stable ? header:nil
  }
}

enum JDTransferOpenObservation:Equatable {
  case pending, differentCustomer, confirmed(String)
}

/// A continuation retains a click checkpoint, never a prior header as current
/// identity. Two fresh matching samples establish stability across stages;
/// an independent final exact header/focus/composer proof is still required.
struct JDTransferOpenProof {
  private var gate=JDRowConfirmationGate()
  private(set) var confirmedCustomer:String?
  private(set) var checkpointRetained=true
  init(requiredChangeFrom:String?=nil) {gate.requiredChangeFrom=requiredChangeFrom}

  mutating func observe(selected:Bool,header:String?,expected:String)->JDTransferOpenObservation {
    confirmedCustomer=nil
    guard let header,!header.isEmpty else {
      _=gate.observe(selected:selected,header:nil,expected:expected);return .pending
    }
    guard exactCustomerIdentityMatches(header,expected) else {
      _=gate.observe(selected:selected,header:header,expected:expected);return .differentCustomer
    }
    guard let actual=gate.observe(selected:selected,header:header,expected:expected) else {return .pending}
    confirmedCustomer=actual;return .confirmed(actual)
  }

  mutating func complete(finalHeader:String?,expected:String,focused:Bool,composerEmpty:Bool)->Bool {
    guard let confirmedCustomer,let finalHeader,focused,composerEmpty else {return false}
    guard exactCustomerIdentityMatches(confirmedCustomer,expected),exactCustomerIdentityMatches(finalHeader,expected) else {return false}
    checkpointRetained=false;return true
  }
}

/// Queue/AX budgets are scheduling boundaries. Neither is a business-level
/// missing customer, and a reply-priority yield has never clicked Transfer.
func jdTransferOpenBoundary(epochValid:Bool,interrupted:Bool,budgetExpired:Bool)->String? {
  if !epochValid {return "automation_stopped"}
  if interrupted {return "handoff_yielded_for_reply"}
  return budgetExpired ? "conversation_open_pending":nil
}

func jdTransferOpenShouldClick(locatorCurrent:Bool,targetSelected:Bool,active:String?,expected:String)->Bool {
  guard locatorCurrent,let active else {return false}
  if exactCustomerIdentityMatches(active,expected) {return false}
  // A selected target with a missing/late header is a confirmation wait, not
  // another click. If another chat was served, fresh selection permits a click.
  if targetSelected {return false}
  return true
}

enum JDCooperativeRefreshResult {case complete,pending,invalidated}

/// The actual native candidate-refresh loop and synthetic tests share this
/// cursor. Successful units survive a slice boundary; budget yield never
/// erases a completed scan or restarts its already-refreshed prefix.
struct JDCooperativeRefreshCursor<Value> {
  private(set) var nextIndex=0
  private(set) var values=[Value]()
  mutating func advance<Item>(items:[Item],available:()->Bool,read:(Item)->Value?)->JDCooperativeRefreshResult {
    while nextIndex<items.count {
      guard available() else {return .pending}
      guard let value=read(items[nextIndex]) else {return available() ? .invalidated:.pending}
      values.append(value);nextIndex+=1
    }
    return .complete
  }
}

struct JDReplyStyleNodeReference<Element> {
  let element:Element
  let role:String
  let frame:CGRect?
  let structural:Bool
  let parent:Element?
  let parentChildren:[Element]?
}

struct JDReplyStyleNodeValues {
  let frame:CGRect?
  let subrole:String?
  let title:String?
  let description:String?
  let value:String?
}

/// The transfer opener uses the reply refresher's individual AX attributes,
/// structural geometry and direct-parent membership semantics. Optional text
/// attributes may be absent; customer/composer callers require their own data.
/// Injected readers exercise this exact production loop without live AX.
func jdRefreshReplyStyleNodes<Element>(_ references:[JDReplyStyleNodeReference<Element>],
    available:()->Bool,readString:(Element,String)->String?,readFrame:(Element)->CGRect?,
    readChildren:(Element)->[Element]?,equal:(Element,Element)->Bool)->[JDReplyStyleNodeValues]? {
  var parents=[(element:Element,children:[Element])](),result=[JDReplyStyleNodeValues]()
  for reference in references {
    guard available(),readString(reference.element,kAXRoleAttribute)==reference.role,available() else {return nil}
    let frame=readFrame(reference.element)
    guard available(),!reference.structural || (frame != nil && frame==reference.frame) else {return nil}
    if let parent=reference.parent,let oldChildren=reference.parentChildren {
      let children:[Element]
      if let saved=parents.first(where:{equal($0.element,parent)}) {children=saved.children}
      else {
        guard available(),let current=readChildren(parent),available() else {return nil}
        children=current;parents.append((parent,current))
      }
      guard children.count==oldChildren.count,
        oldChildren.allSatisfy({old in children.contains(where:{equal(old,$0)})}),
        children.contains(where:{equal(reference.element,$0)}) else {return nil}
    }
    func text(_ attribute:String)->String? {
      guard available() else {return nil};return readString(reference.element,attribute)
    }
    let subrole=text(kAXSubroleAttribute),title=text(kAXTitleAttribute)
    let description=text(kAXDescriptionAttribute),value=text(kAXValueAttribute)
    guard available() else {return nil}
    result.append(JDReplyStyleNodeValues(frame:frame,subrole:subrole,title:title,description:description,value:value))
  }
  return available() ? result:nil
}

enum JDTransferActiveOpenCheck:Equatable {
  case ready(String),differentCustomer,pending(String),blocked(String)
}

func jdTransferActiveOpenCheck(expected:String,customer:String?,composerValue:String?,
    focused:Bool,modalBlocked:Bool,available:Bool)->JDTransferActiveOpenCheck {
  guard available else {return .pending("active_verification_yielded")}
  guard let customer else {return .pending("active_identity_unavailable")}
  guard exactCustomerIdentityMatches(customer,expected) else {return .differentCustomer}
  guard !modalBlocked else {return .pending("reception_focus_blocked")}
  guard let composerValue else {return .pending("composer_ax_unavailable")}
  guard composerValue.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {return .blocked("composer_not_empty")}
  guard focused else {return .pending("reception_focus_required")}
  return .ready(customer)
}

private struct JDRowAnchor {
  let token: String
  let key: String
  let pid: pid_t
  let window: AXUIElement
  let element: AXUIElement
  let fingerprint: String
  let shape: [UInt8]
  let seenAt: TimeInterval
}

/// A visible name-band shape locates a row; it never becomes a customer ID.
/// The band excludes message previews, unread pills and the right-hand clock.
private func jdRowShape(_ frame: CGRect, _ snapshot: UnreadScreenshot) -> [UInt8]? {
  let sx = CGFloat(snapshot.image.width) / snapshot.bounds.width
  let sy = CGFloat(snapshot.image.height) / snapshot.bounds.height
  let rectangle = CGRect(x: (frame.minX-snapshot.bounds.minX+frame.width*0.20)*sx,
    y: (frame.minY-snapshot.bounds.minY+frame.height*0.08)*sy,
    width: frame.width*0.54*sx, height: frame.height*0.40*sy).integral
  guard let crop = snapshot.image.cropping(to: rectangle),
        let context = CGContext(data:nil,width:128,height:20,bitsPerComponent:8,
          bytesPerRow:128,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:0) else { return nil }
  context.interpolationQuality = .high
  context.draw(crop,in:CGRect(x:0,y:0,width:128,height:20))
  guard let data = context.data else { return nil }
  let pixels = data.bindMemory(to:UInt8.self,capacity:2560)
  let perimeter = (0..<128).map { Int(pixels[$0]) } + (0..<128).map { Int(pixels[19*128+$0]) }
  let background = perimeter.sorted()[perimeter.count/2]
  var mask=[UInt8](); var ink=0
  for i in 0..<2560 {
    let bit:UInt8 = abs(Int(pixels[i])-background) > Int(Double(max(background,255-background))*0.32) ? 1:0
    mask.append(bit); ink += Int(bit)
  }
  guard ink>8,ink<1900 else { return nil }
  return mask
}
private func jdShapeFingerprint(_ shape:[UInt8]) -> String {
  SHA256.hash(data:Data(shape)).map { String(format:"%02x",$0) }.joined()
}
private func jdRowFingerprint(_ frame:CGRect,_ snapshot:UnreadScreenshot)->String? {
  jdRowShape(frame,snapshot).map(jdShapeFingerprint)
}

/// Visual continuity locates a sidebar row even when JD recreates its AX
/// elements. This never establishes a customer ID; AX chat identity does.
func jdSameRowShape(_ left:[UInt8],_ right:[UInt8])->Bool {
  guard left.count==2560,right.count==2560 else { return false }
  if left==right { return true }
  for dy in -1...1 { for dx in -1...1 {
    var union=0,different=0
    for y in 0..<20 { for x in 0..<128 {
      let xx=x+dx,yy=y+dy
      let a=left[y*128+x]>0
      let b=(xx>=0 && xx<128 && yy>=0 && yy<20) ? right[yy*128+xx]>0:false
      if a || b { union+=1;if a != b { different+=1 } }
    }}
    if union>8 && Double(different)/Double(union)<=0.12 { return true }
  }}
  return false
}

func jdRowLocatorMatches(sameElement:Bool,oldFingerprint:String,oldShape:[UInt8],
                         newFingerprint:String,newShape:[UInt8])->Bool {
  oldFingerprint==newFingerprint || jdSameRowShape(oldShape,newShape)
}

/// Exact candidates win; approximate visual continuity must be unique.
/// No AX pointer equality, OCR text or row preview is identity evidence.
func jdUniqueRowShapeIndex(_ reference:[UInt8],_ candidates:[[UInt8]?])->Int? {
  let exact=candidates.indices.filter { candidates[$0]==reference }
  if !exact.isEmpty { return exact.count==1 ? exact.first:nil }
  let matching=candidates.indices.filter { candidates[$0].map { jdSameRowShape(reference,$0) }==true }
  return matching.count==1 ? matching.first:nil
}

/// The caller first uniquely re-resolves the row from the current snapshot.
/// Only that row's fresh AX frame determines the click, never global row pitch.
func jdRowClickPoint(_ target: CGRect?, in window: CGRect?) -> CGPoint? {
  guard let target, let window,
    [target.origin.x,target.origin.y,target.size.width,target.size.height,
     window.origin.x,window.origin.y,window.size.width,window.size.height].allSatisfy({ $0.isFinite }),
    target.size.width >= 140, target.size.width <= 360,
    target.size.height >= 35, target.size.height <= 100,
    window.size.width > 0, window.size.height > 0, window.contains(target) else { return nil }
  return CGPoint(x:target.midX,y:target.midY)
}

private func jdRowBackground(_ frame: CGRect, _ snapshot: UnreadScreenshot,
                             rightInset: CGFloat = 9) -> [Double]? {
  let sx=CGFloat(snapshot.image.width)/snapshot.bounds.width
  let sy=CGFloat(snapshot.image.height)/snapshot.bounds.height
  var channels=[[Int]](repeating:[],count:3)
  // On a resized sidebar the AX row can include the scroll rail. Sample
  // inside the painted row in window points, before converting to pixels.
  for x in [frame.minX+3,frame.maxX-rightInset] {
    for fraction:CGFloat in [0.2,0.5,0.8] {
      let rectangle=CGRect(x:(x-snapshot.bounds.minX)*sx,
        y:(frame.minY+frame.height*fraction-snapshot.bounds.minY)*sy,width:2,height:2).integral
      guard let pixel=snapshot.image.cropping(to:rectangle),
        let context=CGContext(data:nil,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,
          space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
      context.draw(pixel,in:CGRect(x:0,y:0,width:1,height:1))
      guard let raw=context.data?.bindMemory(to:UInt8.self,capacity:4) else { return nil }
      for i in 0..<3 { channels[i].append(Int(raw[i])) }
    }
  }
  let medians=channels.map { $0.sorted()[$0.count/2] }
  guard channels.enumerated().allSatisfy({ i, values in
    values.filter { abs($0-medians[i])<=6 }.count>=4
  }) else { return nil }
  return medians.map(Double.init)
}

/// JD's observed light theme uses one solid grey selected row. Hover tint,
/// multiple highlights and other themes are not accepted as selection proof.
func jdSelectedRowFromBackgrounds(_ rowColors:[[Double]?],
                                  gutter:[Double]? = nil) -> Int? {
  var colors=rowColors
  var minimumNeutral=248.0
  var gutterLevel:Double?
  if (1...2).contains(rowColors.count),let gutter,gutter.count==3,
    let low=gutter.min(),let high=gutter.max(),low>=247,high-low<=4 {
    // The small-list gutter in the compact layout is neutral RGB 247.
    // Compare against its measured brightness, even if another row is lighter.
    minimumNeutral=247
    gutterLevel=gutter.reduce(0,+)/3
    while colors.count<3 { colors.append(gutter) }
  }
  guard colors.count>=3,colors.allSatisfy({ $0?.count==3 }) else { return nil }
  let levels=colors.map { $0!.reduce(0,+)/3 }
  let baseline=levels.max()!
  guard baseline>=minimumNeutral else { return nil }
  // Focused selection is darker; unfocused JD selection in real captures is
  // 240 against 253. Require a unique, uniform row and relative contrast.
  let candidates=colors.indices.filter { i in
    let rgb=colors[i]!
    return levels[i]>=190 && levels[i]<=242 && baseline-levels[i]>=10 &&
      (gutterLevel.map { $0-levels[i]>=10 } ?? true) && rgb.max()!-rgb.min()!<=16
  }
  func unreadTint(_ rgb:[Double])->Bool {
    rgb[0]>=245 && rgb[1]>=190 && rgb[2]>=190 && rgb[0]-rgb[1]>=15 && rgb[0]-rgb[2]>=15
  }
  guard candidates.count==1,let index=candidates.first,
    levels.indices.filter({ $0 != index }).allSatisfy({ levels[$0]>=minimumNeutral || unreadTint(colors[$0]!) }) else { return nil }
  return index<rowColors.count ? index : nil
}

/// A transfer may spend time recognizing the owned modal while no reply
/// needs the UI. Reply priority cancels only that transfer's current Vision
/// request; it never cancels chat capture or the native reply sender.
private final class JDTransferWorkControl {
  let id=UUID()
  private let lock=NSLock()
  private var interrupted=false
  private var cancellation:(UUID,()->Void)?

  var isInterrupted:Bool { lock.lock();defer {lock.unlock()};return interrupted }

  func interrupt() {
    lock.lock();interrupted=true;let pending=cancellation?.1;cancellation=nil;lock.unlock()
    pending?()
  }

  func registerCancellation(_ cancel:@escaping ()->Void)->UUID? {
    lock.lock()
    if interrupted {lock.unlock();cancel();return nil}
    let id=UUID();cancellation=(id,cancel);lock.unlock();return id
  }

  func clearCancellation(_ id:UUID) {
    lock.lock();defer {lock.unlock()}
    if cancellation?.0==id {cancellation=nil}
  }
}

private let jdTransferRecognitionQueue=DispatchQueue(label:"jd.transfer.recognition",qos:.userInitiated)
private let jdTransferRecognitionSlot=DispatchSemaphore(value:1)

/// Vision cancellation is cooperative. Even an OCR request which finishes late
/// cannot retain the AX/UI queue needed by a ready formal reply or SLA holding.
private func jdRunInterruptibleTransferRecognition(control:JDTransferWorkControl,
    deadline:Date?,perform:@escaping ()->Void)->Bool {
  guard !control.isInterrupted else {return false}
  // A cancelled Vision operation can still finish late. Keep at most one
  // actual recognition job/image retained instead of piling up retries.
  while jdTransferRecognitionSlot.wait(timeout:.now()+0.02) == .timedOut {
    if control.isInterrupted || (deadline.map {Date()>=$0} ?? false) {return false}
  }
  guard !control.isInterrupted && (deadline.map {Date()<$0} ?? true) else {
    jdTransferRecognitionSlot.signal();return false
  }
  let done=DispatchSemaphore(value:0)
  jdTransferRecognitionQueue.async {
    defer {done.signal();jdTransferRecognitionSlot.signal()}
    if !control.isInterrupted && (deadline.map {Date()<$0} ?? true) {perform()}
  }
  while done.wait(timeout:.now()+0.02) == .timedOut {
    if control.isInterrupted || (deadline.map {Date()>=$0} ?? false) {return false}
  }
  return !control.isInterrupted && (deadline.map {Date()<$0} ?? true)
}

private struct TransferTextLine {
  let text: String
  let confidence: Float
  /// Pixel coordinates with a top-left origin, matching the captured image.
  let frame: CGRect
  var source:String="ocr"
  var axOnline:Bool?=nil
  var axElement:AXUIElement?=nil
  var rowFrame:CGRect?=nil
}

/// Decode each captured modal once. Per-row colorAt/NSColor conversions are
/// expensive enough to consume the bounded transfer UI lease on Retina images.
private final class JDTransferPixelBuffer {
  let width:Int
  let height:Int
  let bytes:[UInt8]

  init?(_ image:CGImage) {
    let w=image.width,h=image.height
    width=w;height=h
    guard w>0,h>0 else { return nil }
    var rendered=[UInt8](repeating:0,count:w*h*4)
    let drawn=rendered.withUnsafeMutableBytes { raw -> Bool in
      guard let context=CGContext(data:raw.baseAddress,width:w,height:h,
        bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),
        bitmapInfo:CGBitmapInfo.byteOrder32Big.rawValue|CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
      context.draw(image,in:CGRect(x:0,y:0,width:w,height:h))
      return true
    }
    guard drawn else { return nil }
    bytes=rendered
  }

  func badgeEvidence(in candidate:CGRect)->(green:Int,red:Int) {
    let rect=candidate.integral.intersection(CGRect(x:0,y:0,width:width,height:height))
    guard !rect.isNull,rect.width>=4,rect.height>=4 else { return (0,0) }
    var greenResult=0,redResult=0
    for y in Int(rect.minY)..<Int(rect.maxY) {
      for x in Int(rect.minX)..<Int(rect.maxX) {
        let i=(y*width+x)*4
        let red=Int(bytes[i]),green=Int(bytes[i+1]),blue=Int(bytes[i+2])
        if green>=105 && red<=140 && blue<=240 && green>=red+35 && green+25>=blue { greenResult+=1 }
        if red>=170 && green<=145 && blue<=150 && red>=green+35 { redResult+=1 }
      }
    }
    return (greenResult,redResult)
  }

  func blackGlyphs(in candidate:CGRect)->[UInt8]? {
    let rect=candidate.integral.intersection(CGRect(x:0,y:0,width:width,height:height))
    guard !rect.isNull,rect.width>0,rect.height>0 else { return nil }
    var result=[UInt8]();result.reserveCapacity(Int(rect.width*rect.height))
    for y in Int(rect.minY)..<Int(rect.maxY) {
      for x in Int(rect.minX)..<Int(rect.maxX) {
        let i=(y*width+x)*4
        result.append(bytes[i]<150 && bytes[i+1]<150 && bytes[i+2]<150 ? 1:0)
      }
    }
    return result
  }
}

private struct TransferDialogSnapshot {
  let windowID: CGWindowID
  let bounds: CGRect
  let image: CGImage
  let lines: [TransferTextLine]
  var diagnostics:[String:Any]
  let pixels:JDTransferPixelBuffer?

  init(windowID:CGWindowID,bounds:CGRect,image:CGImage,lines:[TransferTextLine],diagnostics:[String:Any]=[:]) {
    self.windowID=windowID;self.bounds=bounds;self.image=image;self.lines=lines;self.diagnostics=diagnostics
    self.pixels=JDTransferPixelBuffer(image)
  }

  var imageWidth: CGFloat { CGFloat(image.width) }
  var imageHeight: CGFloat { CGFloat(image.height) }

  func globalPoint(for imagePoint: CGPoint) -> CGPoint {
    CGPoint(
      x: bounds.minX + imagePoint.x * bounds.width / max(imageWidth, 1),
      y: bounds.minY + imagePoint.y * bounds.height / max(imageHeight, 1))
  }
}

private struct TransferAccountCandidate {
  let name: String
  let frame: CGRect
  let greenPixelEvidence: Int
  let redPixelEvidence: Int
  var identitySource:String="ocr"
  var axOnline:Bool?=nil
  var rowBounds:CGRect?=nil

  var isActive: Bool {
    axOnline != false && greenPixelEvidence >= 1
  }
}

private struct DownloadedImageCandidate {
  let url: URL
  let modified: Date
  let size: Int
}

private struct DownloadedVideoCandidate {
  let url: URL
  let modified: Date
  let size: Int
}

private struct JDCachedImageCandidate {
  let url: URL
  let modified: Date
  let size: Int
  let fingerprint: String
  let score: Double
  let borderNormalized: Bool
  let strongVisual: Bool
}

private struct JDTimedCachedMediaCandidate {
  let url: URL
  let modified: Date
  let size: Int
  let kind: String

  var cacheKey: String {
    let identity = "\(url.path)|\(modified.timeIntervalSince1970)|\(size)"
    return SHA256.hash(data: Data(identity.utf8))
      .map { String(format: "%02x", $0) }.joined()
  }
}

/// A filesystem progress signal only. This deliberately supplies no customer
/// or message identity and must never authorize cache ownership or admission.
private func jdMediaCacheRevision() -> String? {
  let root = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/JingDong/咚咚工作台",
                           isDirectory: true)
  let keys: Set<URLResourceKey> = [
    .contentModificationDateKey, .fileSizeKey, .isRegularFileKey,
  ]
  guard let enumerator = FileManager.default.enumerator(
    at: root, includingPropertiesForKeys: Array(keys),
    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
  let images = Set(["jpg", "jpeg", "png", "webp"])
  let videos = Set(["mp4", "mov", "m4v", "webm"])
  var entries: [String] = []
  for case let url as URL in enumerator {
    let parent = url.deletingLastPathComponent()
    let folder = parent.lastPathComponent
    let ext = url.pathExtension.lowercased()
    guard parent.deletingLastPathComponent().lastPathComponent.hasPrefix("chat_"),
          (["images","thumbnails"].contains(folder) && images.contains(ext)) ||
            (folder == "videos" && videos.contains(ext)),
          let values = try? url.resourceValues(forKeys: keys),
          values.isRegularFile == true,
          let modified = values.contentModificationDate,
          let size = values.fileSize else { continue }
    entries.append("\(url.path)|\(modified.timeIntervalSince1970)|\(size)")
  }
  return SHA256.hash(data: Data(entries.sorted().joined(separator: "\n").utf8))
    .map { String(format: "%02x", $0) }.joined()
}

/// Resolves cache media from the unread-message clock only when there is one
/// clear recent candidate. The caller separately verifies the active customer
/// and rejects candidates that are equally close to another customer's unread
/// recovery clock.
private func uniquelyTimedRecentJDCachedMedia(
  expectedAt: Date,
  now: Date = Date()
) -> JDTimedCachedMediaCandidate? {
  let root = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/JingDong/咚咚工作台",
                           isDirectory: true)
  let keys: Set<URLResourceKey> = [
    .contentModificationDateKey, .fileSizeKey, .isRegularFileKey,
  ]
  guard let enumerator = FileManager.default.enumerator(
    at: root, includingPropertiesForKeys: Array(keys),
    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
  let imageExtensions = Set(["jpg", "jpeg", "png", "webp"])
  let videoExtensions = Set(["mp4", "mov", "m4v", "webm"])
  var candidates: [JDTimedCachedMediaCandidate] = []

  for case let url as URL in enumerator {
    let parent = url.deletingLastPathComponent()
    let chatDirectory = parent.deletingLastPathComponent().lastPathComponent
    let folder = parent.lastPathComponent
    let ext = url.pathExtension.lowercased()
    let kind: String
    if folder == "images" && imageExtensions.contains(ext) {
      kind = "image"
    } else if folder == "videos" && videoExtensions.contains(ext) {
      kind = "video"
    } else {
      continue
    }
    guard chatDirectory.hasPrefix("chat_"),
          let values = try? url.resourceValues(forKeys: keys),
          values.isRegularFile == true,
          let modified = values.contentModificationDate,
          let size = values.fileSize,
          size > 0, size <= 250 * 1024 * 1024 else { continue }
    // A JD download normally lands within a second or two of the unread turn.
    // Allow small clock/poll jitter and bounded network delay, but never mine
    // older cache history merely because a text-only message arrived later.
    let offset = modified.timeIntervalSince(expectedAt)
    let age = now.timeIntervalSince(modified)
    guard offset >= -5, offset <= 60, age >= -5, age <= 5 * 60 else { continue }
    candidates.append(JDTimedCachedMediaCandidate(
      url: url, modified: modified, size: size, kind: kind))
  }

  // JD also stores a thumbnail image for many videos. Treat the video as the
  // logical media item when both cache entries share the same stem.
  let videoStems = Set(candidates.filter { $0.kind == "video" }
    .map { $0.url.deletingPathExtension().lastPathComponent.lowercased() })
  let logical = candidates.filter {
    $0.kind == "video" ||
      !videoStems.contains($0.url.deletingPathExtension().lastPathComponent.lowercased())
  }.sorted {
    let left = abs($0.modified.timeIntervalSince(expectedAt))
    let right = abs($1.modified.timeIntervalSince(expectedAt))
    if left != right { return left < right }
    return $0.modified > $1.modified
  }
  guard let best = logical.first else { return nil }
  if logical.count > 1 {
    let bestDelta = abs(best.modified.timeIntervalSince(expectedAt))
    let nextDelta = abs(logical[1].modified.timeIntervalSince(expectedAt))
    // Two different cache items with nearly identical clocks cannot safely be
    // assigned to one customer without reading JD's encrypted message DB.
    if nextDelta - bestDelta < 4 { return nil }
  }
  return best
}

private func downloadableImages(in directory: URL) -> [String: DownloadedImageCandidate] {
  let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
  guard let urls = try? FileManager.default.contentsOfDirectory(
    at: directory, includingPropertiesForKeys: Array(keys),
    options: [.skipsHiddenFiles]) else { return [:] }
  let extensions = Set(["jpg", "jpeg", "png", "webp", "heic", "gif"])
  var result: [String: DownloadedImageCandidate] = [:]
  for url in urls where extensions.contains(url.pathExtension.lowercased()) {
    guard let values = try? url.resourceValues(forKeys: keys),
          values.isRegularFile == true else { continue }
    result[url.path] = DownloadedImageCandidate(
      url: url,
      modified: values.contentModificationDate ?? .distantPast,
      size: values.fileSize ?? 0)
  }
  return result
}

/// A separate cancellation owner: replying never cancels transfer or OCR work
/// through this token, and a stale acquisition never inherits a new run.
private final class JDImageOriginalControl {
  let id=UUID()
  private let lock=NSLock()
  private var stopped=false
  var interrupted:Bool { lock.lock();defer{lock.unlock()};return stopped }
  func interrupt() { lock.lock();stopped=true;lock.unlock() }
}

func jdImageOriginalMessageBindingValid(customer:String,messageID:String,messageTimeKey:String,senderAtMs:Int64)->Bool {
  let formatter=ISO8601DateFormatter()
  let clock=formatter.string(from:Date(timeIntervalSince1970:Double(senderAtMs)/1000))
  let allowed=CharacterSet(charactersIn:"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
  guard let encoded=customer.addingPercentEncoding(withAllowedCharacters:allowed),
    !messageID.isEmpty,messageTimeKey=="incoming-time:\(encoded):\(clock)" else {return false}
  return !messageID.hasPrefix("incoming-time:") || messageID==messageTimeKey
}

private struct JDImageOriginalBinding {
  let customer:String, messageID:String, receiptID:String, messageTimeKey:String
  let senderAtMs:Int64
  let epoch:Int
  init?(_ args:[String:Any]) {
    guard let customer=args["expectedCustomer"] as? String,!customer.isEmpty,
      let messageID=args["messageId"] as? String,
      let messageTimeKey=args["messageTimeKey"] as? String,
      let receiptID=args["receiptId"] as? String,!receiptID.isEmpty,
      let time=args["senderAtMs"] as? NSNumber,
      let epoch=args["automationEpoch"] as? NSNumber else {return nil}
    guard jdImageOriginalMessageBindingValid(customer:customer,messageID:messageID,
      messageTimeKey:messageTimeKey,senderAtMs:time.int64Value) else {return nil}
    self.customer=customer;self.messageID=messageID;self.receiptID=receiptID
    self.messageTimeKey=messageTimeKey
    self.senderAtMs=time.int64Value;self.epoch=epoch.intValue
  }
  var payload:[String:Any] { ["customer":customer,"messageId":messageID,
    "messageTimeKey":messageTimeKey,"receiptId":receiptID,"senderAtMs":senderAtMs,"automationEpoch":epoch] }
  func matches(_ other:JDImageOriginalBinding)->Bool {
    customer==other.customer && messageID==other.messageID && messageTimeKey==other.messageTimeKey && receiptID==other.receiptID &&
      senderAtMs==other.senderAtMs && epoch==other.epoch
  }
}

private struct JDImageOriginalDownload {
  let binding:JDImageOriginalBinding
  let before:[String:DownloadedImageCandidate]
  let source:CGImage
  let viewerID:CGWindowID
  var viewerReleased=false
  var lastStable:[String:String]=[:]
}

func jdImageOriginalMayClose(ownerEpoch:Int,requestedEpoch:Int?)->Bool {
  // Run epochs are monotonic. A new run may clean an older retained viewer;
  // a delayed old cleanup can never close a newer run's owned window.
  requestedEpoch == nil || requestedEpoch! >= ownerEpoch
}

private struct JDImageOriginalProof {
  let windowID:CGWindowID, bounds:CGRect, chat:[String:Double], image:CGImage, region:CGRect
  init?(_ args:[String:Any], binding:JDImageOriginalBinding) {
    guard let path=args["manifestPath"] as? String,
      let bytes=try? Data(contentsOf:URL(fileURLWithPath:path)),
      let info=(try? JSONSerialization.jsonObject(with:bytes)) as? [String:Any],
      let id=info["evidenceId"] as? String,id.count==64,id.allSatisfy({$0.isHexDigit}),
      args["evidenceId"] as? String == id,
      URL(fileURLWithPath:path).lastPathComponent==id+".json",
      info["customer"] as? String == binding.customer,
      let session=info["automationSessionId"] as? String,!session.isEmpty,
      let bounds=info["windowBounds"] as? [String:Any],
      let chat=info["chatRegion"] as? [String:Double],
      let window=info["windowId"] as? NSNumber else {return nil}
    let pngURL=URL(fileURLWithPath:path).deletingLastPathComponent().appendingPathComponent(id+".png")
    guard let png=try? Data(contentsOf:pngURL),
      SHA256.hash(data:png).map({String(format:"%02x",$0)}).joined()==info["pngSHA256"] as? String,
      let image=NSBitmapImageRep(data:png)?.cgImage,
      let hash=jdChatContentSHA256(image:image,region:chat),hash==info["chatContentSHA256"] as? String,
      let x=(args["x"] as? NSNumber)?.doubleValue,
      let y=(args["y"] as? NSNumber)?.doubleValue,
      let w=(args["width"] as? NSNumber)?.doubleValue,
      let h=(args["height"] as? NSNumber)?.doubleValue,
      [x,y,w,h].allSatisfy({$0.isFinite}),w>0,h>0,
      x >= (chat["left"] ?? 1), y >= (chat["top"] ?? 1),
      x+w <= (chat["right"] ?? 0)+0.001,y+h <= (chat["bottom"] ?? 0)+0.001 else {return nil}
    func number(_ key:String)->Double {(bounds[key] as? NSNumber)?.doubleValue ?? 0}
    self.windowID=window.uint32Value
    self.bounds=CGRect(x:number("x"),y:number("y"),width:number("width"),height:number("height"))
    self.chat=chat;self.image=image;self.region=CGRect(x:x,y:y,width:w,height:h)
  }
  var crop:CGImage? { image.cropping(to:CGRect(x:region.minX*Double(image.width),
    y:region.minY*Double(image.height),width:region.width*Double(image.width),
    height:region.height*Double(image.height)).integral) }
}

/// A sender-bound context-menu point. Message bounds constrain hit testing;
/// they are never cropped, resized or used as an image-comparison sample.
struct JDMessageImageCopyTarget {
  let point:CGPoint,header:CGRect,bodyTop:Double,bodyBottom:Double
  init?(_ value:[String:Any],chat:[String:Double],imageSize:CGSize) {
    guard imageSize.width>0,imageSize.height>0,
      let h=value["header"] as? [String:Any],
      let c=value["chat"] as? [String:Any] else {return nil}
    func number(_ d:[String:Any],_ key:String)->Double? {(d[key] as? NSNumber)?.doubleValue}
    guard let x=number(value,"pointX"),let y=number(value,"pointY"),
      let hx=number(h,"x"),let hy=number(h,"y"),let hw=number(h,"width"),let hh=number(h,"height"),
      let top=number(value,"bodyTop"),let bottom=number(value,"bodyBottom"),
      [x,y,hx,hy,hw,hh,top,bottom].allSatisfy({$0.isFinite}),hw>0,hh>0,
      let left=chat["left"],let right=chat["right"],let chatTop=chat["top"],let chatBottom=chat["bottom"],
      ["left","right","top","bottom"].allSatisfy({key in
        guard let expected=chat[key],let supplied=number(c,key) else {return false}
        return supplied.isFinite && abs(supplied-expected)<0.000001
      }),hx>=left,hy>=chatTop,hx+hw<=right+0.001,hy+hh<=chatBottom,
      top>=hy+hh,bottom>top,bottom<=chatBottom+0.000001,
      x>=hx,x<right,y>top,y<bottom else {return nil}
    if value["confirmedRegion"] != nil {
      guard let region=value["confirmedRegion"] as? [String:Any],
        let rx=number(region,"x"),let ry=number(region,"y"),
        let rw=number(region,"width"),let rh=number(region,"height"),
        [rx,ry,rw,rh].allSatisfy({$0.isFinite}),rw>0,rh>0,
        rx>=hx,ry>=top,rx+rw<=right+0.000001,ry+rh<=bottom+0.000001,
        (x-rx)*Double(imageSize.width)>=3,(rx+rw-x)*Double(imageSize.width)>=3,
        (y-ry)*Double(imageSize.height)>=3,(ry+rh-y)*Double(imageSize.height)>=3 else {return nil}
    } else {
      guard (x-hx)*Double(imageSize.width)>=2,(x-hx)*Double(imageSize.width)<=16,
        (y-top)*Double(imageSize.height)>=2,(y-top)*Double(imageSize.height)<=20 else {return nil}
    }
    point=CGPoint(x:x,y:y);header=CGRect(x:hx,y:hy,width:hw,height:hh)
    bodyTop=top;bodyBottom=bottom
  }
}

/// Only the blank transcript gutter left of the avatar/header is eligible.
/// It is bounded above the composer and outside every visible popup.
func jdImageCopyGutterIsBlank(image:CGImage,normalizedPoint:CGPoint)->Bool {
  let x=Int(normalizedPoint.x*Double(image.width)),y=Int(normalizedPoint.y*Double(image.height))
  guard x>=3,y>=4,x+3<image.width,y+4<image.height,
    let patch=image.cropping(to:CGRect(x:x-3,y:y-4,width:7,height:9)),
    let bitmap=CGContext(data:nil,width:7,height:9,bitsPerComponent:8,bytesPerRow:28,
      space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue),
    let bytes=bitmap.data?.assumingMemoryBound(to:UInt8.self) else {return false}
  bitmap.draw(patch,in:CGRect(x:0,y:0,width:7,height:9))
  var minChannel=[255,255,255],maxChannel=[0,0,0]
  for index in 0..<63 {
    let rgb=(0..<3).map{Int(bytes[index*4+$0])}
    guard rgb.min()!>=160,rgb.max()!-rgb.min()!<=14 else {return false}
    for c in 0..<3 {minChannel[c]=min(minChannel[c],rgb[c]);maxChannel[c]=max(maxChannel[c],rgb[c])}
  }
  return (0..<3).allSatisfy{maxChannel[$0]-minChannel[$0]<=10}
}

func jdImageCopyDismissPoint(target:JDMessageImageCopyTarget,chat:[String:Double],
    windowBounds:CGRect,imageSize:CGSize,menus:[CGRect],liveImage:CGImage?=nil)->CGPoint? {
  guard imageSize.width>0,imageSize.height>0,windowBounds.width>0,windowBounds.height>0,
    let left=chat["left"],let right=chat["right"],let top=chat["top"],let bottom=chat["bottom"],
    [left,right,top,bottom].allSatisfy({$0.isFinite}) else {return nil}
  let x=left+8/Double(imageSize.width)
  guard x<right,x<=target.header.minX-64/Double(imageSize.width) else {return nil}
  for y in [Double(target.point.y),target.bodyBottom-8/Double(imageSize.height)] {
    guard y>target.bodyTop,y<target.bodyBottom,y>top,y<bottom else {continue}
    let point=CGPoint(x:windowBounds.minX+x*windowBounds.width,
      y:windowBounds.minY+y*windowBounds.height)
    if windowBounds.contains(point) && !menus.contains(where:{$0.insetBy(dx:-8,dy:-8).contains(point)}) &&
      (liveImage.map{jdImageCopyGutterIsBlank(image:$0,normalizedPoint:CGPoint(x:x,y:y))} ?? true) {return point}
  }
  return nil
}

/// Exact labels only: Copy Link/Copy Message and video context actions cannot
/// authorize accepting an image from the system clipboard.
func jdImageContextMenuConfirmsImage(labels:[String],enabled:[Bool])->Bool {
  guard labels.count==enabled.count else {return false}
  let normalized=labels.map{$0.lowercased().filter{!$0.isWhitespace}}
  guard !normalized.contains(where:{$0.contains("视频") || $0.contains("video") || ["播放","play"].contains($0)}) else {return false}
  return normalized.indices.contains{enabled[$0] &&
    ["复制图片","拷贝图片","复制图像","拷贝图像","copyimage","copypicture",
     "保存图片","图片另存为","另存为图片","保存图像","saveimage","saveimageas","savepicture","savepictureas"].contains(normalized[$0])}
}

func jdImageContextCopyChoice(labels:[String],enabled:[Bool])->(index:Int,explicitImage:Bool)? {
  guard labels.count==enabled.count else {return nil}
  let normalized=labels.map{$0.lowercased().filter{!$0.isWhitespace}}
  if normalized.contains(where:{value in
    value.contains("视频") || value.contains("video") || ["播放","play","播放视频"].contains(value)
  }) {return nil}
  let exact=normalized.indices.filter{enabled[$0] &&
    ["复制图片","拷贝图片","复制图像","拷贝图像","copyimage","copypicture"].contains(normalized[$0])}
  if exact.count==1 {return(exact[0],true)}
  if !exact.isEmpty {return nil}
  let generic=normalized.indices.filter{enabled[$0] && ["复制","拷贝","copy"].contains(normalized[$0])}
  return generic.count==1 ? (generic[0],jdImageContextMenuConfirmsImage(labels:labels,enabled:enabled)):nil
}

func jdFullImagePixelDigest(_ image:CGImage)->String? {
  guard image.width>0,image.height>0,
    let bitmap=CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,
      bytesPerRow:image.width*4,space:CGColorSpaceCreateDeviceRGB(),
      bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue),let pixels=bitmap.data else {return nil}
  memset(pixels,0,bitmap.bytesPerRow*bitmap.height)
  bitmap.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
  return SHA256.hash(data:Data(bytes:pixels,count:bitmap.bytesPerRow*bitmap.height))
    .map{String(format:"%02x",$0)}.joined()
}

/// Full copied images use exact dimensions and normalized full-resolution
/// pixels. The thumbnail matcher's perceptual thresholds are not reused here.
func jdCompleteCopiedImageMatches(_ image:CGImage,_ other:CGImage)->Bool {
  image.width==other.width && image.height==other.height &&
    jdFullImagePixelDigest(image).map{$0==jdFullImagePixelDigest(other)} == true
}

func jdContextCopiedImageCanComplete(knownImage:Bool,explicitImageAction:Bool,
    exactImageCacheMatch:Bool,verifiedVideoCover:Bool)->Bool {
  !verifiedVideoCover && (knownImage || explicitImageAction || exactImageCacheMatch)
}

private struct JDImageContextCopy {
  let binding:JDImageOriginalBinding,data:Data,explicitImageAction:Bool,knownImage:Bool
}

private struct JDImageCopyMenu {
  let pid:pid_t,element:AXUIElement,frame:CGRect
  let windowID:CGWindowID?
  let hadParent:Bool
}

private func jdImageCopyMenuWindowID(pid:pid_t,frame:CGRect)->CGWindowID? {
  let windows=CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []
  let matches=windows.compactMap{item->CGWindowID? in
    guard (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value==pid,
      let value=item[kCGWindowBounds as String] as? [String:Any],
      let bounds=CGRect(dictionaryRepresentation:value as CFDictionary),
      abs(bounds.minX-frame.minX)<=4,abs(bounds.minY-frame.minY)<=4,
      abs(bounds.width-frame.width)<=4,abs(bounds.height-frame.height)<=4 else {return nil}
    return (item[kCGWindowNumber as String] as? NSNumber)?.uint32Value
  }
  return matches.count==1 ? matches.first:nil
}

private func jdImageCopyMenuPositivelyAbsent(_ menu:JDImageCopyMenu)->Bool {
  if let id=menu.windowID,
    let windows=CGWindowListCopyWindowInfo(.optionIncludingWindow,id) as? [[String:Any]] {
    if !windows.contains(where:{($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value==id &&
      ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value==menu.pid}) {return true}
  }
  var role:CFTypeRef?
  if AXUIElementCopyAttributeValue(menu.element,kAXRoleAttribute as CFString,&role) == .invalidUIElement {return true}
  if boolAttribute(menu.element,"AXVisible")==false || boolAttribute(menu.element,"AXHidden")==true {return true}
  var size:CFTypeRef?
  if AXUIElementCopyAttributeValue(menu.element,kAXSizeAttribute as CFString,&size) == .success,
    let size,CFGetTypeID(size)==AXValueGetTypeID() {
    var value=CGSize.zero
    if AXValueGetValue(unsafeBitCast(size,to:AXValue.self),.cgSize,&value),value.width<=0 || value.height<=0 {return true}
  }
  if menu.hadParent {
    var parent:CFTypeRef?
    if AXUIElementCopyAttributeValue(menu.element,kAXParentAttribute as CFString,&parent) == .noValue {return true}
  }
  return false
}

private func jdImageCopyMenuStillOwned(_ menu:JDImageCopyMenu)->Bool {
  var pid:pid_t=0
  return AXUIElementGetPid(menu.element,&pid) == .success && pid==menu.pid &&
    stringAttribute(menu.element,kAXRoleAttribute)==kAXMenuRole as String &&
    frameAttribute(menu.element)==menu.frame
}

/// After the physical event, observation is cleanup ownership work. A reply
/// yield/Stop may forbid Copy but cannot abandon a popup already opening.
func jdObserveDispatchedImageContextMenu<Menu>(observe:()->[Menu],pause:()->Void)->Menu? {
  for _ in 0..<16 {
    let menus=observe()
    if menus.count==1 {return menus.first}
    pause()
  }
  return nil
}

private func jdImageCopySourceWindowOwned(windowID:CGWindowID,pid:pid_t)->Bool {
  let windows=CGWindowListCopyWindowInfo(.optionIncludingWindow,windowID) as? [[String:Any]]
  return (windows?.first?[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value==pid
}

private func jdImageCopyPointHitsSource(_ point:CGPoint,windowID:CGWindowID,pid:pid_t)->Bool {
  let windows=CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []
  for window in windows {
    guard ((window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0,
      let data=window[kCGWindowBounds as String] as? [String:Any],
      let bounds=CGRect(dictionaryRepresentation:data as CFDictionary),bounds.contains(point) else {continue}
    return (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value==pid &&
      (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value==windowID
  }
  return false
}

private func jdImageContextMenus(pid:pid_t,available:()->Bool = {true})->[JDImageCopyMenu] {
  let app=AXUIElementCreateApplication(pid);AXUIElementSetMessagingTimeout(app,0.03)
  var roots=[app]+elementArrayAttribute(app,kAXWindowsAttribute)
  var focused:CFTypeRef?
  if AXUIElementCopyAttributeValue(app,kAXFocusedUIElementAttribute as CFString,&focused) == .success,
    let focused,CFGetTypeID(focused)==AXUIElementGetTypeID() {
    roots.append(unsafeBitCast(focused,to:AXUIElement.self))
  }
  var pending=roots.map{($0,0)},seen=[AXUIElement](),menus=[JDImageCopyMenu]()
  while let (element,depth)=pending.popLast(),seen.count<96,available() {
    if seen.contains(where:{CFEqual($0,element)}) {continue};seen.append(element)
    var owner:pid_t=0
    guard AXUIElementGetPid(element,&owner) == .success,owner==pid else {continue}
    let role=stringAttribute(element,kAXRoleAttribute)
    if role==kAXMenuRole as String,let frame=frameAttribute(element),frame.width>0,frame.height>0,
      boolAttribute(element,"AXVisible") != false,boolAttribute(element,"AXHidden") != true {
      var parent:CFTypeRef?
      let hasParent=AXUIElementCopyAttributeValue(element,kAXParentAttribute as CFString,&parent) == .success && parent != nil
      menus.append(JDImageCopyMenu(pid:pid,element:element,frame:frame,
        windowID:jdImageCopyMenuWindowID(pid:pid,frame:frame),hadParent:hasParent))
    }
    // The fresh popup can be an application child or the parent of focus.
    if role != kAXMenuBarRole as String && depth<3 &&
      (menus.isEmpty || role==kAXMenuRole as String || role==kAXMenuItemRole as String) {
      pending.append(contentsOf:elementArrayAttribute(element,kAXChildrenAttribute).map{($0,depth+1)})
    }
    if role==kAXMenuItemRole as String {
      var parent:CFTypeRef?
      if AXUIElementCopyAttributeValue(element,kAXParentAttribute as CFString,&parent) == .success,
        let parent,CFGetTypeID(parent)==AXUIElementGetTypeID() {
        pending.append((unsafeBitCast(parent,to:AXUIElement.self),max(0,depth-1)))
      }
    }
  }
  return menus
}

private func jdImageCopyMenuItems(_ menu:JDImageCopyMenu)->[AXUIElement] {
  var pending=elementArrayAttribute(menu.element,kAXChildrenAttribute),seen=[AXUIElement](),items=[AXUIElement]()
  while let element=pending.popLast(),seen.count<128 {
    if seen.contains(where:{CFEqual($0,element)}) {continue};seen.append(element)
    if stringAttribute(element,kAXRoleAttribute)==kAXMenuItemRole as String,
      let frame=frameAttribute(element),frame.width>0,frame.height>0,
      menu.frame.intersects(frame) {items.append(element)}
    pending.append(contentsOf:elementArrayAttribute(element,kAXChildrenAttribute))
  }
  return items
}

private func jdCloseOwnedImageCopyMenu(_ menu:JDImageCopyMenu)->Bool {
  if jdImageCopyMenuPositivelyAbsent(menu) {return true}
  guard jdImageCopyMenuStillOwned(menu) else {return false}
  guard AXUIElementPerformAction(menu.element,kAXCancelAction as CFString) == .success else {return false}
  for _ in 0..<4 {
    if jdImageCopyMenuPositivelyAbsent(menu) {return true}
    usleep(25_000)
  }
  return false
}

/// Menu pixels can obscure the transcript; compare every unoccluded strip.
/// The sender header itself must stay outside the popup's shadow mask.
func jdContextCopyPixelsMatch(source:CGImage,live:CGImage,chat:[String:Double],
    menu:CGRect,header:CGRect)->Bool {
  guard source.width==live.width,source.height==live.height,
    let l=chat["left"],let r=chat["right"],let t=chat["top"],let b=chat["bottom"],
    [l,r,t,b].allSatisfy({$0.isFinite}),l>=0,r<=1,t>=0,b<=1,r>l,b>t else {return false}
  let transcript=CGRect(x:l,y:t,width:r-l,height:b-t)
  let blocked=transcript.intersection(menu)
  if blocked.isNull || blocked.isEmpty {
    return jdChatContentSHA256(image:source,region:chat)==jdChatContentSHA256(image:live,region:chat)
  }
  guard !header.intersects(blocked),blocked.width*blocked.height<transcript.width*transcript.height*0.65 else {return false}
  let strips=[CGRect(x:l,y:t,width:r-l,height:blocked.minY-t),
    CGRect(x:l,y:blocked.maxY,width:r-l,height:b-blocked.maxY),
    CGRect(x:l,y:blocked.minY,width:blocked.minX-l,height:blocked.height),
    CGRect(x:blocked.maxX,y:blocked.minY,width:r-blocked.maxX,height:blocked.height)]
  let usable=strips.filter{$0.width*Double(source.width)>=2 && $0.height*Double(source.height)>=2}
  guard !usable.isEmpty else {return false}
  return usable.allSatisfy{rect in
    let region=["left":Double(rect.minX),"right":Double(rect.maxX),"top":Double(rect.minY),"bottom":Double(rect.maxY)]
    guard let expected=jdChatContentSHA256(image:source,region:region),
      let actual=jdChatContentSHA256(image:live,region:region) else {return false}
    return expected==actual
  }
}

private func jdExactContextImageCache(data:Data,image:CGImage,expectedAt:Date,now:Date=Date())->(URL,Data,CGImage,Bool)? {
  let root=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/JingDong/咚咚工作台",isDirectory:true)
  let keys:Set<URLResourceKey>=[.contentModificationDateKey,.fileSizeKey,.isRegularFileKey]
  guard let enumerator=FileManager.default.enumerator(at:root,includingPropertiesForKeys:Array(keys),
    options:[.skipsHiddenFiles,.skipsPackageDescendants]),let digest=jdFullImagePixelDigest(image) else {return nil}
  let dataHash=SHA256.hash(data:data)
  var matches=[(URL,Data,CGImage,Double,Bool)]()
  for case let url as URL in enumerator {
    guard url.deletingLastPathComponent().lastPathComponent=="images",
      url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent.hasPrefix("chat_"),
      ["png","jpg","jpeg","webp"].contains(url.pathExtension.lowercased()),
      let values=try?url.resourceValues(forKeys:keys),values.isRegularFile==true,
      let modified=values.contentModificationDate,let size=values.fileSize,size>0,size<=25*1024*1024,
      now.timeIntervalSince(modified)>=(-5),now.timeIntervalSince(modified)<=15*60,
      abs(modified.timeIntervalSince(expectedAt))<=15*60,
      let bytes=try?Data(contentsOf:url,options:.mappedIfSafe),bytes.count==size,
      let original=jdCompleteOriginalImage(bytes),original.width==image.width,original.height==image.height else {continue}
    guard SHA256.hash(data:bytes)==dataHash || jdFullImagePixelDigest(original)==digest else {continue}
    matches.append((url,bytes,original,abs(modified.timeIntervalSince(expectedAt)),verifiedCompanionVideo(thumbnail:url) != nil))
  }
  if let video=matches.first(where:{$0.4}) {return(video.0,video.1,video.2,true)}
  // Several byte-identical copies do not change the actual copied contents.
  return matches.sorted{$0.3<$1.3}.first.map{($0.0,$0.1,$0.2,false)}
}

/// CG identity and AX title/frame must agree. No global keyboard close is ever
/// a fallback: disappearing/mismatched viewers are already outside our owner.
private func jdOwnedImageViewer(pid:pid_t,id:CGWindowID)->AXUIElement? {
  let all=CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []
  guard let item=all.first(where:{($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value==pid &&
    ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value==id &&
    ($0[kCGWindowName as String] as? String)?.contains("图片浏览器")==true}),
    let dict=item[kCGWindowBounds as String] as? [String:Any],
    let bounds=CGRect(dictionaryRepresentation:dict as CFDictionary) else {return nil}
  let app=AXUIElementCreateApplication(pid);AXUIElementSetMessagingTimeout(app,0.05)
  let matched=elementArrayAttribute(app,kAXWindowsAttribute).filter {
    guard stringAttribute($0,kAXTitleAttribute)?.contains("图片浏览器")==true,
      let frame=frameAttribute($0) else {return false}
    return abs(frame.minX-bounds.minX)<2 && abs(frame.minY-bounds.minY)<2 &&
      abs(frame.width-bounds.width)<2 && abs(frame.height-bounds.height)<2
  }
  return matched.count==1 ? matched.first:nil
}

private func jdImageViewerIDs(pid:pid_t)->Set<CGWindowID> {
  let all=CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []
  return Set(all.compactMap { item in
    guard (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value==pid,
      (item[kCGWindowName as String] as? String)?.contains("图片浏览器")==true else {return nil}
    return (item[kCGWindowNumber as String] as? NSNumber)?.uint32Value
  })
}

private func jdImageViewerFrontmost(pid:pid_t,id:CGWindowID)->Bool {
  guard NSWorkspace.shared.frontmostApplication?.processIdentifier==pid else {return false}
  let all=CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []
  let front=all.first {($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value==pid &&
    ($0[kCGWindowLayer as String] as? NSNumber)?.intValue==0}
  return (front?[kCGWindowNumber as String] as? NSNumber)?.uint32Value==id
}

private func jdImageViewerCloseButton(_ viewer:AXUIElement)->AXUIElement? {
  var value:CFTypeRef?
  if AXUIElementCopyAttributeValue(viewer,kAXCloseButtonAttribute as CFString,&value) == .success,
    let value,CFGetTypeID(value)==AXUIElementGetTypeID() {
    return unsafeBitCast(value,to:AXUIElement.self)
  }
  var todo=[viewer],found=[AXUIElement](),seen=0
  while let item=todo.popLast(),seen<256 {
    seen+=1
    let label=[stringAttribute(item,kAXTitleAttribute),stringAttribute(item,kAXDescriptionAttribute)]
      .compactMap{$0}.map{$0.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()}
    if stringAttribute(item,kAXRoleAttribute)==kAXButtonRole as String,
      label.contains(where:{["关闭","关闭窗口","关闭图片","close","close window"].contains($0)}),
      boolAttribute(item,kAXEnabledAttribute) != false {found.append(item)}
    todo.append(contentsOf:elementArrayAttribute(item,kAXChildrenAttribute))
  }
  return found.count==1 ? found.first:nil
}

private func jdCloseOwnedImageViewer(pid:pid_t,id:CGWindowID)->Bool {
  guard jdWindowVisible(pid:pid,windowID:id) else {return true}
  if let viewer=jdOwnedImageViewer(pid:pid,id:id),let button=jdImageViewerCloseButton(viewer),
    jdOwnedImageViewer(pid:pid,id:id) != nil,
    boolAttribute(button,kAXEnabledAttribute) != false,
    AXUIElementPerformAction(button,kAXPressAction as CFString) == .success {
    for _ in 0..<4 {if !jdWindowVisible(pid:pid,windowID:id) {return true};usleep(25_000)}
    if !jdWindowVisible(pid:pid,windowID:id) {return true}
  }
  // Qt can omit AXCloseButton. A measured red traffic-light glyph is the
  // only fallback, scoped twice to the exact owned CG window and its chrome.
  guard jdImageViewerIDs(pid:pid).contains(id),jdImageViewerFrontmost(pid:pid,id:id),
    let bounds=windowBounds(id),
    let image=CGWindowListCreateImage(.null,.optionIncludingWindow,id,[.boundsIgnoreFraming,.bestResolution]),
    let glyph=jdImageViewerCloseGlyph(image:image,windowSize:bounds.size),
    let fresh=CGWindowListCreateImage(.null,.optionIncludingWindow,id,[.boundsIgnoreFraming,.bestResolution]),
    let again=jdImageViewerCloseGlyph(image:fresh,windowSize:bounds.size),
    abs(glyph.x-again.x)<2,abs(glyph.y-again.y)<2,
    jdImageViewerIDs(pid:pid).contains(id),jdImageViewerFrontmost(pid:pid,id:id),windowBounds(id)==bounds else {return false}
  let point=CGPoint(x:bounds.minX+again.x*bounds.width/CGFloat(fresh.width),
    y:bounds.minY+again.y*bounds.height/CGFloat(fresh.height))
  guard point.x>bounds.minX,point.x<bounds.minX+60,
    point.y>bounds.minY,point.y<bounds.minY+38,postClick(at:point) else {return false}
  for _ in 0..<4 {if !jdWindowVisible(pid:pid,windowID:id) {return true};usleep(25_000)}
  return !jdWindowVisible(pid:pid,windowID:id)
}

/// Detect the actual solid red macOS close circle in window chrome. Return
/// measured pixel coordinates; no fixed click location or Escape is used.
func jdImageViewerCloseGlyph(image:CGImage,windowSize:CGSize)->CGPoint? {
  guard windowSize.width>100,windowSize.height>70 else {return nil}
  let sx=Double(image.width)/Double(windowSize.width),sy=Double(image.height)/Double(windowSize.height)
  guard sx>=0.5,sx<=4,sy>=0.5,sy<=4 else {return nil}
  let width=min(image.width,Int(64*sx)),height=min(image.height,Int(38*sy))
  let bitmap=NSBitmapImageRep(cgImage:image)
  var red=Set<Int>()
  for y in 0..<height {for x in 0..<width {
    guard let c=bitmap.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB) else {continue}
    if c.alphaComponent>0.8,c.redComponent>0.65,c.greenComponent<0.52,c.blueComponent<0.52,
      c.redComponent>c.greenComponent*1.45,c.redComponent>c.blueComponent*1.35 {red.insert(y*width+x)}
  }}
  var matches=[CGPoint]()
  while let start=red.first {
    red.remove(start);var todo=[start],component=[Int]()
    while let value=todo.popLast() {
      component.append(value)
      let x=value%width,y=value/width
      for (nx,ny) in [(x-1,y),(x+1,y),(x,y-1),(x,y+1)] where nx>=0 && ny>=0 && nx<width && ny<height {
        let index=ny*width+nx
        if red.remove(index) != nil {todo.append(index)}
      }
    }
    let xs=component.map{$0%width},ys=component.map{$0/width}
    guard let minX=xs.min(),let maxX=xs.max(),let minY=ys.min(),let maxY=ys.max() else {continue}
    let w=Double(maxX-minX+1),h=Double(maxY-minY+1),cx=Double(minX+maxX)/2,cy=Double(minY+maxY)/2
    let fill=Double(component.count)/(w*h)
    guard w/sx>=8,w/sx<=21,h/sy>=8,h/sy<=21,
      abs(w/sx-h/sy)<3,cx/sx>=7,cx/sx<=48,cy/sy>=7,cy/sy<=31,
      fill>0.60,fill<0.91 else {continue}
    let rx=w/2,ry=h/2
    let inside=component.filter { value in
      pow((Double(value%width)-cx)/rx,2)+pow((Double(value/width)-cy)/ry,2)<=1.15
    }.count
    if Double(inside)/Double(component.count)>0.96 {matches.append(CGPoint(x:cx,y:cy))}
  }
  return matches.count==1 ? matches.first:nil
}

/// Search only one owned viewer; descriptions are evidence, geometry is not.
private func jdImageDownloadButton(_ viewer:AXUIElement)->AXUIElement? {
  var todo=[viewer],found=[AXUIElement](),seen=0
  while let item=todo.popLast(),seen<256 {
    seen+=1
    let label=[stringAttribute(item,kAXTitleAttribute),stringAttribute(item,kAXDescriptionAttribute),
      stringAttribute(item,kAXHelpAttribute)].compactMap{$0}.joined(separator:" ")
    let role=stringAttribute(item,kAXRoleAttribute)
    if (role==kAXButtonRole as String || role==kAXMenuItemRole as String),
      label.range(of:#"下载|保存图片|另存为|\bdownload\b|\bsave(?: image| as)?\b"#,options:.regularExpression.union(.caseInsensitive)) != nil,
      boolAttribute(item,kAXEnabledAttribute) != false {found.append(item)}
    todo.append(contentsOf:elementArrayAttribute(item,kAXChildrenAttribute))
  }
  return found.count==1 ? found.first:nil
}

/// The click ROI can be a foreground-tight product photograph while the
/// clipboard original retains broad white margins. Normalize both references
/// identically, only for comparison; the returned original bytes stay intact.
private func jdImageOriginalComparisonContent(_ image:CGImage)->CGImage {
  let scale=min(1,1024/Double(max(image.width,image.height)))
  let width=max(1,Int(Double(image.width)*scale)),height=max(1,Int(Double(image.height)*scale))
  guard let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,
    bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue),
    let memory=context.data else {return image}
  context.setFillColor(NSColor.white.cgColor);context.fill(CGRect(x:0,y:0,width:width,height:height))
  context.draw(image,in:CGRect(x:0,y:0,width:width,height:height))
  let pixels=memory.assumingMemoryBound(to:UInt8.self)
  var left=width,right=0,top=height,bottom=0,count=0
  for y in 0..<height {for x in 0..<width {
    let index=(y*width+x)*4
    if min(pixels[index],pixels[index+1],pixels[index+2])<224 {
      left=min(left,x);right=max(right,x+1);top=min(top,y);bottom=max(bottom,y+1);count+=1
    }
  }}
  guard let flattened=context.makeImage() else {return image}
  guard count>=max(16,width*height/100),right>left,bottom>top else {return flattened}
  left=max(0,left-1);top=max(0,top-1);right=min(width,right+1);bottom=min(height,bottom+1)
  return flattened.cropping(to:CGRect(x:left,y:top,width:right-left,height:bottom-top)) ?? flattened
}

func jdOriginalImageMatches(visible:CGImage,original:CGImage)->Bool {
  let source=jdImageOriginalComparisonContent(visible),candidate=jdImageOriginalComparisonContent(original)
  guard mediaForegroundFraction(source)>=0.06,original.width>=40,original.height>=40 else {return false}
  let ratio=abs(log((Double(source.width)/Double(source.height))/(Double(candidate.width)/Double(candidate.height))))
  if ratio<0.3,normalizedMediaPixelDifference(source,candidate)<0.12,
    mediaStructuralSimilarity(source,candidate)>0.90 {return true}
  // A clipped bubble may prove the contiguous top/bottom of a full original.
  // Low-information blanks and arbitrary shared-cache recency prove nothing.
  if mediaForegroundFraction(source)>=0.12 {
    for fraction in stride(from:0.125,through:0.975,by:0.025) {
      let height=Double(candidate.height)*fraction
      for y in [0.0,Double(candidate.height)-height] {
        guard let crop=candidate.cropping(to:CGRect(x:0,y:y,width:Double(candidate.width),height:height).integral) else {continue}
        let delta=abs(log((Double(source.width)/Double(source.height))/(Double(crop.width)/Double(crop.height))))
        if delta<0.2,normalizedMediaPixelDifference(source,crop)<0.04,
          mediaStructuralSimilarity(source,crop)>0.96 {return true}
      }
    }
  }
  return false
}

/// A progressive JPEG can decode while the file is still incomplete. A stable
/// size alone is not a terminal result; require ImageIO's complete container.
func jdCompleteOriginalImage(_ data:Data)->CGImage? {
  guard !data.isEmpty,data.count<=25*1024*1024,
    let source=CGImageSourceCreateWithData(data as CFData,nil),
    CGImageSourceGetStatus(source) == .statusComplete,
    CGImageSourceGetCount(source)==1,
    CGImageSourceGetStatusAtIndex(source,0) == .statusComplete else {return nil}
  let bytes=[UInt8](data.prefix(12))
  if bytes.starts(with:[137,80,78,71,13,10,26,10]) {
    guard data.suffix(12)==Data([0,0,0,0,73,69,78,68,174,66,96,130]) else {return nil}
  } else if bytes.starts(with:[255,216]) {
    guard data.suffix(2)==Data([255,217]) else {return nil}
  } else if bytes.starts(with:[82,73,70,70]),bytes.count>=12 {
    let count=UInt64(bytes[4]) | UInt64(bytes[5])<<8 | UInt64(bytes[6])<<16 | UInt64(bytes[7])<<24
    guard count+8==UInt64(data.count) else {return nil}
  } else if bytes.starts(with:[71,73,70]) {
    guard data.last==59 else {return nil}
  }
  return CGImageSourceCreateImageAtIndex(source,0,nil)
}

private struct JDIndexedCacheImage {
  let original: URL
  let thumbnail: URL?
  let modified: Date
  let size: Int
}

private final class JDCacheImageIndex: @unchecked Sendable {
  private let lock = NSLock()
  private var snapshots = [String: (TimeInterval, [JDIndexedCacheImage])]()

  func files(root: URL, reuse:Bool) -> [JDIndexedCacheImage] {
    let current=jdNativeWork.currentValidity()
    guard current() else {return []}
    lock.lock()
    defer { lock.unlock() }
    let tick = ProcessInfo.processInfo.systemUptime
    if reuse,let snapshot = snapshots[root.path], tick - snapshot.0 < 2 {
      return snapshot.1
    }
    let fm = FileManager.default
    let fields: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
    let extensions: Set<String> = ["jpg", "jpeg", "png", "webp"]
    func children(_ dir: URL) -> [URL] {
      (try? fm.contentsOfDirectory(at:dir,includingPropertiesForKeys:[.isDirectoryKey],
        options:[.skipsHiddenFiles,.skipsPackageDescendants])) ?? []
    }
    func imageFiles(_ dir:URL) -> [URL] {
      ((try? fm.contentsOfDirectory(at:dir,includingPropertiesForKeys:Array(fields),
        options:[.skipsHiddenFiles,.skipsPackageDescendants])) ?? [])
        .filter { extensions.contains($0.pathExtension.lowercased()) }
    }
    let direct = root.appendingPathComponent("chat",isDirectory:true)
    let localBuckets=children(root).filter { $0.lastPathComponent.hasPrefix("chat_") }
    let accounts = fm.fileExists(atPath:direct.path) ? [root] : children(root)
    let buckets = localBuckets + accounts.flatMap {
      children($0.appendingPathComponent("chat",isDirectory:true))
        .filter { $0.lastPathComponent.hasPrefix("chat_") }
    }
    var data = [JDIndexedCacheImage]()
    for bucket in buckets {
        guard current() else {return []}
        let images=imageFiles(bucket.appendingPathComponent("images",isDirectory:true))
        let thumbnails=Dictionary(grouping:imageFiles(bucket.appendingPathComponent("thumbnails",isDirectory:true)),
          by:{ $0.deletingPathExtension().lastPathComponent })
        for image in images {
          guard current() else {return []}
          guard let v=try? image.resourceValues(forKeys:fields),v.isRegularFile==true,
            let modified=v.contentModificationDate,let size=v.fileSize,
            size>0,size<=25*1024*1024 else { continue }
          let links=thumbnails[image.deletingPathExtension().lastPathComponent] ?? []
          data.append(JDIndexedCacheImage(original:image,
            thumbnail:links.count==1 ? links.first : nil,modified:modified,size:size))
        }
      }
    guard current() else {return []}
    snapshots=snapshots.filter { tick - $0.value.0 < 2 }
    snapshots[root.path]=(ProcessInfo.processInfo.systemUptime,data)
    return data
  }
}
private let jdCacheImageIndex = JDCacheImageIndex()

/// The verified viewport title may narrow filesystem lookup to a known
/// account directory. It never establishes the customer or media identity.
func jdScopedMediaCacheRoot(_ root:URL, receptionTitle:String?) -> URL {
  guard let title=receptionTitle,
    let suffix=title.range(of:"咚咚融合工作台",options:.backwards),
    title[suffix.upperBound...].trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {return root}
  var name=String(title[..<suffix.lowerBound]).trimmingCharacters(in:.whitespacesAndNewlines)
  guard let separator=name.last,["-","–","—"].contains(String(separator)) else {return root}
  name.removeLast()
  name=name.trimmingCharacters(in:.whitespacesAndNewlines)
  guard !name.isEmpty,name != ".",name != "..",!name.contains("/"),
    jdServiceAccountFromAXHeader(name,windowTitle:title)==name else {return root}
  let account=root.appendingPathComponent(name,isDirectory:true)
  guard (try? account.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey]))
    .map({$0.isDirectory==true && $0.isSymbolicLink != true}) == true,
    FileManager.default.fileExists(atPath:account.appendingPathComponent("chat",isDirectory:true).path) else {return root}
  return account
}

func jdCacheMessageTimeTier(secondsAfterMessage:TimeInterval) -> Int {
  if secondsAfterMessage >= 0 && secondsAfterMessage <= 16 { return 0 }
  if secondsAfterMessage > 16 && secondsAfterMessage <= 60 { return 1 }
  return 2
}

/// Finds an original cached image only when its pixels, dimensions, and cache
/// time agree with the sender-bounded image visible in the verified customer
/// conversation. JD keeps multiple customers below the same account cache, so
/// a merely "newest file" lookup is not safe enough.
private func matchingRecentJDCachedImage(
  visibleImage: CGImage,
  expectedAt: Date?,
  now: Date = Date(),
  maximumAge: TimeInterval = 15 * 60,
  videoThumbnailsOnly: Bool = false,
  includeUnlinkedVideoCovers: Bool = false,
  cacheRoot: URL? = nil,
  receptionTitle:String? = nil,
  clippedBottom: Bool = false,
  onSearch:([String:Any])->Void={ _ in }
) -> JDCachedImageCandidate? {
  let current=jdNativeWork.currentValidity()
  guard current() else {return nil}
  let root = cacheRoot ?? FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/JingDong/咚咚工作台",
                           isDirectory: true)
  let scoped = jdScopedMediaCacheRoot(root,receptionTitle:receptionTitle)
  func note(_ id:String,_ expression:String,_ actual:[String:Any],_ threshold:[String:Any],_ passed:Bool,sourceLine:Int = #line) {
    onSearch(jdMediaCondition(stage:"media.cache_match",id:id,expression:expression,
      actual:actual,threshold:threshold,passed:passed,
      context:["cacheRoot":scoped.path,"expectedAtMs":Int((expectedAt ?? now).timeIntervalSince1970*1000)],sourceLine:sourceLine))
  }
  note("cache.clipped_scope", "!clippedBottom || (accountScoped && expectedAt != nil)",
    ["clippedBottom":clippedBottom,"accountScoped":scoped != root,"hasExpectedAt":expectedAt != nil],[:],
    !clippedBottom || (scoped != root && expectedAt != nil))
  if clippedBottom && (scoped == root || expectedAt == nil) { return nil }
  let visibleImage = videoThumbnailsOnly && !clippedBottom ? mediaWithoutChatBorder(visibleImage) : visibleImage
  let visibleFingerprint = averageImageHash(visibleImage)
  guard let visibleBits = UInt64(visibleFingerprint, radix: 16) else { return nil }
  let visibleRatio = Double(visibleImage.width) / Double(max(visibleImage.height, 1))
  let referenceTime = expectedAt ?? now
  let groups = Dictionary(grouping:jdCacheImageIndex.files(root:scoped,reuse:cacheRoot==nil).filter {
    let age = now.timeIntervalSince($0.modified)
    let delta=abs(referenceTime.timeIntervalSince($0.modified))
    let eligible=age >= -5 && delta <= maximumAge && (expectedAt != nil || age <= maximumAge)
    note("cache.time_window", "ageSeconds >= -5 && abs(messageTime-fileTime) <= maximumAge && (hasExpectedAt || ageSeconds <= maximumAge)",
      ["path":$0.original.path,"ageSeconds":age,"messageDeltaSeconds":delta,"hasExpectedAt":expectedAt != nil],
      ["minimumAgeSeconds":-5,"maximumAgeSeconds":maximumAge],eligible)
    return eligible
  }, by:{ expectedAt == nil ? 2 : jdCacheMessageTimeTier(secondsAfterMessage:$0.modified.timeIntervalSince(referenceTime)) })
  func visualCandidate(_ file:JDIndexedCacheImage,tier:Int) -> JDCachedImageCandidate? {
    guard current() else {return nil}
    let url=file.original,modified=file.modified,size=file.size
    let companion = verifiedCompanionVideo(thumbnail:url)
    note("cache.companion_kind", "(hasCompanion == videoThumbnailsOnly) || (videoThumbnailsOnly && includeUnlinkedVideoCovers)",
      ["path":url.path,"hasCompanion":companion != nil,"videoThumbnailsOnly":videoThumbnailsOnly,
        "includeUnlinkedVideoCovers":includeUnlinkedVideoCovers],[:],
      (companion != nil) == videoThumbnailsOnly || (videoThumbnailsOnly && includeUnlinkedVideoCovers))
    if (companion != nil) != videoThumbnailsOnly &&
      !(videoThumbnailsOnly && includeUnlinkedVideoCovers) { return nil }
    let timeDelta=abs(referenceTime.timeIntervalSince(modified))
    let fields:Set<URLResourceKey>=[.contentModificationDateKey,.fileSizeKey]
    guard let actual=try? url.resourceValues(forKeys:fields),
      actual.contentModificationDate==modified,actual.fileSize==size,
      let image=NSImage(contentsOf:url),
      let cgImage=image.cgImage(forProposedRect:nil,context:nil,hints:nil) else {return nil}
    if clippedBottom {
      let originalTime = companion.flatMap {
        try? $0.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate
      } ?? modified
      let delay=originalTime.timeIntervalSince(referenceTime)
      note("cache.clipped_delay", "delaySeconds >= -3 && delaySeconds <= 180",
        ["path":url.path,"delaySeconds":delay],["minimumDelaySeconds":-3,"maximumDelaySeconds":180],delay >= -3 && delay <= 180)
      guard delay >= -3, delay <= 180 else {return nil}
      let thumb = file.thumbnail.flatMap { NSImage(contentsOf:$0) }
      let tile = thumb?.cgImage(forProposedRect:nil,context:nil,hints:nil)
      // Look at the compact, same-stem representation first. Its write time
      // may be much later than the media-file write time.
      guard let fit = tile.flatMap({ jdMatchingClippedMediaBottom(visible:visibleImage,original:$0) })
        ?? jdMatchingClippedMediaBottom(visible:visibleImage,original:cgImage) else {return nil}
      return JDCachedImageCandidate(url:url,modified:modified,size:size,
        fingerprint:averageImageHash(cgImage),score:fit,borderNormalized:false,strongVisual:true)
    }
    var comparedImage=cgImage
    var ratioDelta = abs(log(max(Double(cgImage.width)/Double(max(cgImage.height,1)),0.001)/max(visibleRatio,0.001)))
    // JD can clip a tall video at the transcript's top while retaining its
    // play control. A verified same-stem original plus a strict contiguous
    // cover-fragment match is stronger than the distorted visible ratio.
    // Image-only caches and approximate time proximity never enter this path.
    if videoThumbnailsOnly,includeUnlinkedVideoCovers,
      verifiedCompanionVideo(thumbnail:url) != nil,
      let fragment=jdMatchingVideoCoverFragment(visible:visibleImage,cover:cgImage) {
      comparedImage=fragment;ratioDelta=0
    }
    let fingerprint=averageImageHash(comparedImage)
    var hashDistance:Int
    var borderNormalized=false
    if videoThumbnailsOnly {
      note("cache.video_ratio", "ratioDelta <= 0.40",["path":url.path,"ratioDelta":ratioDelta],
        ["maximumRatioDelta":0.40],ratioDelta<=0.40)
      guard ratioDelta<=0.40,
        let candidateBits=UInt64(fingerprint,radix:16) else {return nil}
      hashDistance=(visibleBits ^ candidateBits).nonzeroBitCount
      // Keep the video-cover association rules independent of image previews.
      let pixelDifference=normalizedMediaPixelDifference(visibleImage,comparedImage)
      let similarity=mediaStructuralSimilarity(visibleImage,comparedImage)
      note("cache.video_pixels", "hashDistance <= 10 && pixelDifference <= 0.16 && structuralSimilarity >= 0.90",
        ["path":url.path,"tier":tier,"hashDistance":hashDistance,"ratioDelta":ratioDelta,
          "pixelDifference":pixelDifference,"structuralSimilarity":similarity],
        ["maximumHashDistance":10,"maximumPixelDifference":0.16,"minimumStructuralSimilarity":0.90],
        hashDistance<=10 && pixelDifference<=0.16 && similarity>=0.90)
      guard hashDistance <= 10, pixelDifference <= 0.16, similarity >= 0.90 else {return nil}
    } else {
      let match = ratioDelta <= 0.40
        ? jdMatchingCachedImagePreview(visible:visibleImage,original:comparedImage,onDiagnostic:{ fields in
            onSearch(fields.merging(["path":url.path,"tier":tier]){ _,new in new })
          })
        : (scoped != root && expectedAt != nil
          ? jdMatchingCachedSidePaddedImage(visible:visibleImage,original:comparedImage)
          : nil)
      note("cache.image_visual_match", "previewMatch != nil || scopedSidePaddedMatch != nil",
        ["path":url.path,"ratioDelta":ratioDelta,"matched":match != nil,"accountScoped":scoped != root],
        ["previewMaximumRatioDelta":0.40],match != nil)
      guard let match else {return nil}
      hashDistance=match.hashDistance;ratioDelta=match.ratioDelta
      borderNormalized=match.borderNormalized
    }
    // Time limits eligibility; it cannot outrank visual proof for a video.
    let score = Double(hashDistance) * 4 + ratioDelta * 30 +
      (videoThumbnailsOnly ? (1-mediaStructuralSimilarity(visibleImage,comparedImage))*100 : timeDelta/5)
    // Out-of-window cache reuse needs stronger visual evidence. A near
    // timestamp by itself cannot qualify or rank these older candidates.
    if tier==2 && expectedAt != nil && !videoThumbnailsOnly && !borderNormalized {
      let difference=normalizedMediaPixelDifference(visibleImage,comparedImage)
      let similarity=mediaStructuralSimilarity(visibleImage,comparedImage)
      note("cache.older_candidate_visual_proof", "hashDistance <= 8 && pixelDifference <= 0.09 && structuralSimilarity >= 0.93",
        ["path":url.path,"tier":tier,"hashDistance":hashDistance,"pixelDifference":difference,"structuralSimilarity":similarity],
        ["maximumHashDistance":8,"maximumPixelDifference":0.09,"minimumStructuralSimilarity":0.93],
        hashDistance<=8 && difference<=0.09 && similarity>=0.93)
      guard hashDistance<=8, difference<=0.09, similarity>=0.93 else {return nil}
    }
    let strong = borderNormalized || (hashDistance<=8 &&
      normalizedMediaPixelDifference(visibleImage,comparedImage)<=0.09 &&
      mediaStructuralSimilarity(visibleImage,comparedImage)>=0.93)
    return JDCachedImageCandidate(url:url,modified:modified,size:size,
      fingerprint:fingerprint,score:score,borderNormalized:borderNormalized,strongVisual:strong)
  }

  func choose(_ candidates:[JDCachedImageCandidate]) -> JDCachedImageCandidate? {
    let ranked = candidates.sorted {
      if $0.score != $1.score { return $0.score < $1.score }
      return $0.modified > $1.modified
    }
    guard let best = ranked.first else { return nil }
    if ranked.count > 1 {
      let next = ranked[1]
      onSearch(jdMediaCondition(stage:"media.cache_match",id:"cache.rank_margin",expression:"secondScore-bestScore >= 8",actual:
        ["bestPath":best.url.path,"secondPath":next.url.path,"bestScore":best.score,
          "secondScore":next.score,"scoreMargin":next.score-best.score,
          "sameFingerprint":next.fingerprint==best.fingerprint],
        threshold:["minimumScoreMargin":8],passed:next.score-best.score>=8)
        .merging(["outcome":"observed","requiresOriginalIdentityCheck":next.score-best.score<8]){ _,new in new })
      // Equal fingerprints are duplicate copies of the same visible content.
      // Different-looking near-ties are unsafe in a shared multi-customer cache.
      if videoThumbnailsOnly && verifiedCompanionVideo(thumbnail:best.url)==nil {
        // Two equally plausible visible covers cannot establish a unique source.
        if ranked.dropFirst().contains(where:{$0.score-best.score < 8}) { return nil }
      } else if videoThumbnailsOnly {
        guard let original = verifiedCompanionVideo(thumbnail: best.url),
              let bytes = try? Data(contentsOf: original, options: .mappedIfSafe) else { return nil }
        let digest = SHA256.hash(data: bytes)
        for contender in ranked.dropFirst() where contender.score-best.score < 8 {
          guard let other = verifiedCompanionVideo(thumbnail: contender.url),
                let otherBytes = try? Data(contentsOf: other, options: .mappedIfSafe),
                SHA256.hash(data: otherBytes) == digest else { return nil }
        }
      } else {
        if clippedBottom && ranked.dropFirst().contains(where:{$0.score-best.score < 8}) {
          let tied=ranked.filter {$0.score-best.score < 8}
          guard jdCachedImageOriginalsIdentical(tied.map(\.url)) else {return nil}
        }
        if next.fingerprint != best.fingerprint && next.score-best.score < 8 {return nil}
        // A border-normalized near tie requires identical original bytes, even
        // when two different screenshots happen to share the same average hash.
        let close=ranked.filter {$0.score-best.score < 8}
        if close.contains(where:{$0.borderNormalized}),close.count>1,
          !jdCachedImageOriginalsIdentical(close.map(\.url)) {return nil}
      }
    }
    return best
  }
  if clippedBottom {
    // A time tier can shortlist candidates, but cannot break a visual tie.
    // Require a unique source across the entire eligible window.
    let files=(0...2).flatMap { groups[$0] ?? [] }
    let matches=files.compactMap { visualCandidate($0,tier:0) }
    let selected=choose(matches)
    onSearch(["candidateCount":files.count,"originalChecks":files.count,
      "visualMatches":matches.count,"accountScoped":true,"clippedBottom":true,
      "outcome":matches.isEmpty ? "no_visual_match" : (selected == nil ? "ambiguous" : "selected")])
    return selected
  }
  var checked=0, originalChecks=0, thumbnailChecks=0
  for tier in 0...2 {
    guard current() else {return nil}
    let files=groups[tier] ?? []
    checked += files.count
    var shortlisted=[JDIndexedCacheImage](), remaining=[JDIndexedCacheImage]()
    for file in files {
      guard current() else {return nil}
      guard !videoThumbnailsOnly, tier<2, let thumb=file.thumbnail,
        let image=NSImage(contentsOf:thumb),
        let tile=image.cgImage(forProposedRect:nil,context:nil,hints:nil),
        let bits=UInt64(averageImageHash(tile),radix:16) else {
        shortlisted.append(file);continue
      }
      thumbnailChecks += 1
      // Use same-stem cached tiles as a cheap first pass. A failed shortlist
      // still checks the originals, and a tile never proves final identity.
      if (bits ^ visibleBits).nonzeroBitCount <= 18 {
        shortlisted.append(file)
      } else {
        remaining.append(file)
      }
    }
    originalChecks += shortlisted.count
    var candidates=shortlisted.compactMap { visualCandidate($0,tier:tier) }
    if !remaining.isEmpty && choose(candidates)?.strongVisual != true {
      originalChecks += remaining.count
      candidates += remaining.compactMap { visualCandidate($0,tier:tier) }
    }
    if !candidates.isEmpty {
      let selected=choose(candidates)
      onSearch(["tier":tier,"candidateCount":checked,"originalChecks":originalChecks,
        "thumbnailChecks":thumbnailChecks,"visualMatches":candidates.count,"accountScoped":scoped != root,
        "sameStemThumbnail":selected.map { result in
          files.contains { $0.original==result.url && $0.thumbnail != nil }
        } ?? false,
        "outcome":selected == nil ? "ambiguous" : "selected"])
      return selected
    }
  }
  onSearch(["candidateCount":checked,"originalChecks":originalChecks,
    "thumbnailChecks":thumbnailChecks,"visualMatches":0,
    "accountScoped":scoped != root,"outcome":"no_visual_match"])

  return nil
}

/// JD 10.4 downloads an incoming video into its own per-chat media cache before
/// rendering the thumbnail. Restrict discovery to that cache shape and a short
/// freshness window so automatic analysis never needs to click inside JD.
private func newestRecentJDCachedVideo(
  now: Date = Date(), maximumAge: TimeInterval = 5 * 60
) -> DownloadedVideoCandidate? {
  let root = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/JingDong/咚咚工作台",
                           isDirectory: true)
  let keys: Set<URLResourceKey> = [
    .contentModificationDateKey, .fileSizeKey, .isRegularFileKey,
  ]
  guard let enumerator = FileManager.default.enumerator(
    at: root, includingPropertiesForKeys: Array(keys),
    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
  let extensions = Set(["mp4", "mov", "m4v", "webm"])
  var candidates: [DownloadedVideoCandidate] = []
  for case let url as URL in enumerator {
    let parent = url.deletingLastPathComponent()
    let chatDirectory = parent.deletingLastPathComponent().lastPathComponent
    guard parent.lastPathComponent == "videos",
          chatDirectory.hasPrefix("chat_"),
          extensions.contains(url.pathExtension.lowercased()),
          let values = try? url.resourceValues(forKeys: keys),
          values.isRegularFile == true,
          let modified = values.contentModificationDate,
          let size = values.fileSize,
          size > 0, size <= 100 * 1024 * 1024 else { continue }
    let age = now.timeIntervalSince(modified)
    guard age >= -5, age <= maximumAge else { continue }
    candidates.append(DownloadedVideoCandidate(
      url: url, modified: modified, size: size))
  }
  return candidates.max(by: { $0.modified < $1.modified })
}

private func windowBounds(_ id: CGWindowID) -> CGRect? {
  guard let raw = CGWindowListCopyWindowInfo(.optionIncludingWindow, id)
          as? [[String: Any]], let info = raw.first,
        let dictionary = info[kCGWindowBounds as String] as? [String: Any]
  else { return nil }
  return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
}

private func jdTransferDialogWindowIDs(pid:pid_t)->Set<CGWindowID> {
  let windows=CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []
  return Set(windows.compactMap { info -> CGWindowID? in
    guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value==pid,
      (info[kCGWindowLayer as String] as? NSNumber)?.intValue==0,
      (info[kCGWindowName as String] as? String)?.contains("请选择转接对象")==true else {return nil}
    return (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value
  })
}

private func jdNewTransferModalID(before:Set<CGWindowID>,after:Set<CGWindowID>)->CGWindowID? {
  let added=after.subtracting(before)
  return added.count==1 ? added.first:nil
}

private func jdTransferModalOwnsForeground(ownedID:CGWindowID?,frontID:CGWindowID?,
                                         ownerPID:pid_t,frontPID:pid_t?)->Bool {
  guard let ownedID,let frontID,frontPID==ownerPID else {return false}
  return ownedID==frontID
}

func jdConsumeTransferModalOwnership(_ pending:inout CGWindowID?,expected:CGWindowID?)->CGWindowID? {
  guard let expected,pending==expected else {return nil}
  pending=nil
  return expected
}

private func jdCloseOwnedTransferModal(pid:pid_t,windowID:CGWindowID?)->Bool {
  let windows=CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []
  let front=windows.first { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value==pid &&
    ($0[kCGWindowLayer as String] as? NSNumber)?.intValue==0 }
  let frontID=(front?[kCGWindowNumber as String] as? NSNumber)?.uint32Value
  guard let windowID,let target=windows.first(where:{
      ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value==pid &&
      ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value==windowID &&
      ($0[kCGWindowName as String] as? String)?.contains("请选择转接对象")==true
    }),
    let dictionary=target[kCGWindowBounds as String] as? [String:Any],
    let bounds=CGRect(dictionaryRepresentation:dictionary as CFDictionary) else {return false}
  let app=AXUIElementCreateApplication(pid)
  AXUIElementSetMessagingTimeout(app,0.05)
  let matched=elementArrayAttribute(app,kAXWindowsAttribute).filter { element in
    guard stringAttribute(element,kAXTitleAttribute)?.contains("请选择转接对象")==true,
      let f=frameAttribute(element) else {return false}
    return abs(f.minX-bounds.minX)<2 && abs(f.minY-bounds.minY)<2 &&
      abs(f.width-bounds.width)<2 && abs(f.height-bounds.height)<2
  }
  if matched.count==1,let modal=matched.first {
    var value:CFTypeRef?
    if AXUIElementCopyAttributeValue(modal,kAXCloseButtonAttribute as CFString,&value) == .success,
      let value,CFGetTypeID(value)==AXUIElementGetTypeID() {
      let close=unsafeBitCast(value,to:AXUIElement.self)
      if boolAttribute(close,kAXEnabledAttribute) != false,
        AXUIElementPerformAction(close,kAXPressAction as CFString) == .success {return true}
    }
    var actions:CFArray?
    _=AXUIElementCopyActionNames(modal,&actions)
    if (actions as? [String] ?? []).contains("AXCancel"),
      AXUIElementPerformAction(modal,"AXCancel" as CFString) == .success {return true}
  }
  // Qt can omit AXCloseButton. Click only a freshly verified X glyph in this
  // exact modal. A global Escape can reach the reception page after the first
  // close, so it is deliberately never a transfer-cleanup fallback.
  guard jdTransferModalOwnsForeground(ownedID:windowID,frontID:frontID,ownerPID:pid,
      frontPID:NSWorkspace.shared.frontmostApplication?.processIdentifier),
    let image=CGWindowListCreateImage(.null,.optionIncludingWindow,windowID,[.boundsIgnoreFraming,.bestResolution]),
    let point=jdTransferCloseGlyph(image:image),
    jdTransferDialogWindowIDs(pid:pid).contains(windowID),windowBounds(windowID)==bounds else {return false}
  return postClick(at:CGPoint(x:bounds.minX+point.x*bounds.width/CGFloat(image.width),
    y:bounds.minY+point.y*bounds.height/CGFloat(image.height)))
}

/// The actual modal X is two connected diagonal strokes, not a guessed corner
/// coordinate. Returns image coordinates; this helper has no UI side effects.
func jdTransferCloseGlyph(image:CGImage)->CGPoint? {
  guard let pixels=JDTransferPixelBuffer(image) else {return nil}
  let w=image.width,h=image.height
  let search=CGRect(x:Double(w)*0.88,y:Double(h)*0.018,width:Double(w)*0.10,height:min(Double(h)*0.13,Double(w)*0.10))
  guard let mask=pixels.blackGlyphs(in:search),!mask.isEmpty else {return nil}
  let r=search.integral.intersection(CGRect(x:0,y:0,width:w,height:h)),sw=Int(r.width),sh=Int(r.height)
  let points=mask.indices.filter {mask[$0]>0}
  guard let minX=points.map({$0%sw}).min(),let maxX=points.map({$0%sw}).max(),
    let minY=points.map({$0/sw}).min(),let maxY=points.map({$0/sw}).max() else {return nil}
  let gw=maxX-minX+1,gh=maxY-minY+1
  guard gw>=6,gh>=6,abs(gw-gh)<=max(3,gw/4),gw<=Int(Double(w)*0.05),gh<sh else {return nil}
  let tolerance=max(1,gw/6)
  var diagonal=0,offDiagonal=0
  for p in points {
    let x=p%sw-minX,y=p/sw-minY
    if abs(x-y)<=tolerance || abs((gw-1-x)-y)<=tolerance {diagonal+=1}else {offDiagonal+=1}
  }
  guard diagonal>=max(10,gw),offDiagonal<=max(2,diagonal/5) else {return nil}
  return CGPoint(x:r.minX+CGFloat(minX+maxX)/2,y:r.minY+CGFloat(minY+maxY)/2)
}

private func namedWindowBounds(pid: pid_t, containing title: String) -> CGRect? {
  guard let raw = CGWindowListCopyWindowInfo(
    [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
          as? [[String: Any]] else { return nil }
  for info in raw where
    (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid &&
    ((info[kCGWindowName as String] as? String)?.contains(title) == true) {
    guard let dictionary = info[kCGWindowBounds as String] as? [String: Any]
    else { continue }
    if let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary) {
      return bounds
    }
  }
  return nil
}

private func compactTransferText(_ value: String) -> String {
  value.trimmingCharacters(in: .whitespacesAndNewlines)
    .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
}

private func recognizeTransferText(in image: CGImage, deadline: Date? = nil,
                                  control:JDTransferWorkControl?=nil) -> [TransferTextLine] {
  let request=VNRecognizeTextRequest()
  request.recognitionLevel = .accurate
  request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
  request.usesLanguageCorrection = false
  // Transfer work is interrupted by an actual ready reply/20s SLA request.
  // Legacy non-transfer callers keep their original short recognition bound.
  let recognitionDeadline=deadline ?? (control==nil ? Date().addingTimeInterval(0.65):nil)
  var cancel:DispatchWorkItem?
  if let recognitionDeadline {
    let remaining=recognitionDeadline.timeIntervalSinceNow
    if remaining<=0 {return []}
    let cancellation=DispatchWorkItem {request.cancel()}
    cancel=cancellation
    DispatchQueue.global(qos:.userInitiated).asyncAfter(deadline:.now()+remaining,execute:cancellation)
  }
  let registration=control?.registerCancellation {request.cancel()}
  defer {
    cancel?.cancel()
    if let registration {control?.clearCancellation(registration)}
  }
  if let control,registration==nil || control.isInterrupted {return []}
  if let control {
    guard jdRunInterruptibleTransferRecognition(control:control,deadline:recognitionDeadline,perform:{
      try? jdPerformVision(VNImageRequestHandler(cgImage:image,orientation:.up),[request])
    }) else {return []}
  } else {
    try? jdPerformVision(VNImageRequestHandler(cgImage:image,orientation:.up),[request])
  }
  if control?.isInterrupted==true {return []}
  let width=CGFloat(image.width),height=CGFloat(image.height)
  return (request.results ?? []).compactMap { observation in
    guard let candidate=observation.topCandidates(1).first else {return nil}
    let box=observation.boundingBox
    return TransferTextLine(text:candidate.string.trimmingCharacters(in:.whitespacesAndNewlines),
      confidence:candidate.confidence,frame:CGRect(x:box.minX*width,y:(1-box.maxY)*height,
        width:box.width*width,height:box.height*height))
  }.sorted {
    if abs($0.frame.midY-$1.frame.midY)>height*0.015 {return $0.frame.midY<$1.frame.midY}
    return $0.frame.minX<$1.frame.minX
  }
}

/// Account strings originate exclusively in AX values/labels. Unknown or
/// conflicting per-row identities/statuses never authorize a transfer.
private struct JDAXTransferAccount {
  let name:String
  let label:AXNode
  let row:AXNode
  let online:Bool?
  let action:AXNode?
}

private func jdAXTransferText(_ node:AXNode)->String? {
  [node.value,node.description,node.title].compactMap { $0?.trimmingCharacters(in:.whitespacesAndNewlines) }.first { !$0.isEmpty }
}

private func jdAXTransferStatus(_ node:AXNode)->Bool? {
  let statuses=[node.value,node.description,node.title,node.help].compactMap { $0 }
    .flatMap { $0.components(separatedBy:.newlines) }.map { $0.trimmingCharacters(in:.whitespacesAndNewlines).lowercased() }
  let active:Set<String>=["在线","空闲","可接待","online","available"]
  let inactive:Set<String>=["离线","忙碌","不在线","不可接待","offline","busy","unavailable"]
  if statuses.contains(where:inactive.contains) { return false }
  return statuses.contains(where:active.contains) ? true:nil
}

private func jdAXTransferName(_ node:AXNode)->String? {
  guard [kAXStaticTextRole as String,kAXRowRole as String,kAXCellRole as String,kAXGroupRole as String].contains(node.role),
    let raw=jdAXTransferText(node) else { return nil }
  let parts=raw.components(separatedBy:.newlines).map { $0.trimmingCharacters(in:.whitespacesAndNewlines) }.filter { !$0.isEmpty }
  guard let name=parts.first,name.count>=2,name.count<=64,
    !name.contains("…"),!name.contains("..."),
    !name.hasPrefix("默认咨询组"),
    name.range(of:#"^\d+(?:/\d+)?$"#,options:.regularExpression)==nil else { return nil }
  let excluded:Set<String>=["请选择转接对象","指定客服","指定咨询组","搜索账号/名字","转接","备注原因","关闭","取消","在线","空闲","可接待","离线","忙碌","不可接待","online","offline","available","unavailable","busy","账号","客服账号","客服昵称","昵称","暂无客服","没有在线客服"]
  guard !excluded.contains(name),!excluded.contains(name.lowercased()) else { return nil }
  // A composite AX row is accepted only when its remaining fields are
  // explicit status words. Never split an arbitrary canvas description.
  if parts.count>1 && !parts.dropFirst().allSatisfy({ excluded.contains($0) }) { return nil }
  return name
}

private func jdAXTransferAccounts(_ nodes:[AXNode],below:CGFloat)->[JDAXTransferAccount] {
  let labels=nodes.filter { node in
    guard let frame=node.frame else { return false }
    return frame.minY>=below && jdAXTransferName(node) != nil
  }
  var result=[JDAXTransferAccount](),bindings=[Data:String](),ambiguous=Set<Data>()
  for label in labels {
    guard let name=jdAXTransferName(label),let labelFrame=label.frame else { continue }
    let containers=nodes.filter { n in
      [kAXRowRole as String,kAXCellRole as String,kAXGroupRole as String].contains(n.role) &&
      (label.path==n.path || label.path.hasPrefix(n.path+"/"))
    }.sorted { $0.path.count>$1.path.count }
    for row in containers {
      let descendants=nodes.filter { $0.path==row.path || $0.path.hasPrefix(row.path+"/") }
      let explicit=descendants.filter { n in
        (n.identifier?.range(of:#"(?:account|staff|agent)[._-]?(?:id|name)|客服账号"#,options:.regularExpression) != nil) ||
          ([n.title,n.description].compactMap { $0 }.contains("客服账号") && n.value?.isEmpty==false)
      }
      let sources=explicit.isEmpty ? descendants:explicit
      let names=Set(sources.compactMap(jdAXTransferName).map { Data($0.utf8) })
      guard names.count==1,names.contains(Data(name.utf8)) else { continue }
      let aligned=descendants.filter { n in
        guard let f=n.frame else { return false }
        return abs(f.midY-labelFrame.midY)<=max(16,labelFrame.height*1.5)
      }
      let statuses=aligned.compactMap(jdAXTransferStatus)
      let online:Bool?=statuses.isEmpty ? nil : (statuses.allSatisfy { $0 } ? true:false)
      let actions=aligned.filter { n in n.role==kAXButtonRole as String &&
        [n.value,n.description,n.title].compactMap { $0 }.contains("转接") &&
        n.actions.contains(kAXPressAction as String) && (n.frame?.minX ?? 0)>=labelFrame.maxX }
      let key=Data(name.utf8)
      if let prior=bindings[key],prior != row.path {
        ambiguous.insert(key);result.removeAll { Data($0.name.utf8)==key };break
      }
      if bindings[key]==nil && !ambiguous.contains(key) {
        bindings[key]=row.path
        result.append(JDAXTransferAccount(name:name,label:label,row:row,online:online,
          action:actions.count==1 ? actions.first:nil))
      }
      break
    }
  }
  return result
}

/// Read all declared AX child relations in the owned transfer modal. A painted
/// Qt canvas may expose no rows; that capability failure is explicit and is the
/// ONLY scope in which OCR is permitted to supply staff names.
private func transferAXLabels(pid:pid_t,bounds:CGRect,image:CGImage,deadline:Date?)->(labels:[TransferTextLine],diagnostics:[String:Any]) {
  let end=min(deadline ?? Date().addingTimeInterval(0.25),Date().addingTimeInterval(0.25))
  var diagnostics:[String:Any]=["identitySource":"accessibility","axNodeCount":0,"axAccountCount":0]
  func unavailable(_ reason:String)->([TransferTextLine],[String:Any]) {
    diagnostics["ocrFallbackReason"]=reason;return ([],diagnostics)
  }
  guard AXIsProcessTrusted() else { return unavailable("ax_permission_unavailable") }
  let app=AXUIElementCreateApplication(pid)
  AXUIElementSetMessagingTimeout(app,0.05)
  let windows=elementArrayAttribute(app,kAXWindowsAttribute)
  let named=windows.filter { stringAttribute($0,kAXTitleAttribute)?.contains("请选择转接对象")==true }
  let matched=named.isEmpty ? windows.filter { element in
    guard let f=frameAttribute(element) else { return false }
    return abs(f.minX-bounds.minX)<4 && abs(f.minY-bounds.minY)<4 &&
      abs(f.width-bounds.width)<4 && abs(f.height-bounds.height)<4
  }:named
  guard matched.count==1,let window=matched.first else { return unavailable("ax_transfer_window_unavailable") }
  var pending:[(AXUIElement,String,Int)]=[(window,"transfer",0)]
  var visited=[AXUIElement](),nodes=[AXNode](),relations=Set<String>()
  while let (element,path,depth)=pending.popLast() {
    if visited.contains(where:{CFEqual($0,element)}) { continue }
    guard Date()<end,nodes.count<600,depth<24 else { return unavailable("ax_transfer_read_budget_exceeded") }
    visited.append(element);AXUIElementSetMessagingTimeout(element,0.04)
    var names:CFArray?;_ = AXUIElementCopyAttributeNames(element,&names)
    let exposed=Set(names as? [String] ?? [])
    var children=[AXUIElement]()
    for relation in ["AXRows",kAXChildrenAttribute,"AXContents","AXVisibleRows","AXVisibleChildren","AXChildrenInNavigationOrder"] where exposed.contains(relation) {
      guard Date()<end else { return unavailable("ax_transfer_read_budget_exceeded") }
      relations.insert(relation)
      var raw:CFTypeRef?
      guard AXUIElementCopyAttributeValue(element,relation as CFString,&raw) == .success,let raw else { continue }
      let linked:[AXUIElement]
      if CFGetTypeID(raw)==AXUIElementGetTypeID() { linked=[unsafeBitCast(raw,to:AXUIElement.self)] }
      else { linked=raw as? [AXUIElement] ?? [] }
      for child in linked where !children.contains(where:{CFEqual($0,child)}) { children.append(child) }
    }
    var actions:CFArray?;_ = AXUIElementCopyActionNames(element,&actions)
    let node=AXNode(element:element,path:path,role:stringAttribute(element,kAXRoleAttribute) ?? "AXUnknown",
      subrole:stringAttribute(element,kAXSubroleAttribute),identifier:stringAttribute(element,kAXIdentifierAttribute),
      title:stringAttribute(element,kAXTitleAttribute),description:stringAttribute(element,kAXDescriptionAttribute),
      value:stringAttribute(element,kAXValueAttribute),help:stringAttribute(element,kAXHelpAttribute),frame:frameAttribute(element),
      actions:actions as? [String] ?? [],children:children)
    nodes.append(node);diagnostics["axNodeCount"]=nodes.count
    for (i,child) in children.enumerated().reversed() { pending.append((child,"\(path)/\(i)",depth+1)) }
  }
  diagnostics["axNodeCount"]=nodes.count;diagnostics["axRelationsRead"]=relations.sorted()
  let group=nodes.filter { jdAXTransferText($0)?.hasPrefix("默认咨询组")==true }.min { ($0.frame?.height ?? .infinity)<($1.frame?.height ?? .infinity) }
  if let group,let expanded=boolAttribute(group.element,"AXExpanded") {
    diagnostics["groupExpanded"]=expanded
  }
  let search=nodes.first { $0.description=="搜索账号/名字" }
  let floor=group?.frame?.maxY ?? search?.frame?.maxY ?? bounds.minY
  let accounts=jdAXTransferAccounts(nodes,below:floor)
  diagnostics["axAccountCount"]=accounts.count
  guard !accounts.isEmpty else { return unavailable("ax_staff_rows_not_exposed") }
  let sx=CGFloat(image.width)/max(1,bounds.width),sy=CGFloat(image.height)/max(1,bounds.height)
  func local(_ frame:CGRect)->CGRect { CGRect(x:(frame.minX-bounds.minX)*sx,y:(frame.minY-bounds.minY)*sy,width:frame.width*sx,height:frame.height*sy) }
  var labels=[TransferTextLine]()
  for account in accounts {
    guard let frame=account.label.frame else { continue }
    labels.append(TransferTextLine(text:account.name,confidence:1,frame:local(frame),source:"accessibility",axOnline:account.online,rowFrame:account.row.frame.map(local)))
  }
  for node in nodes {
    guard let text=jdAXTransferText(node),let frame=node.frame else { continue }
    if text.hasPrefix("默认咨询组") || ["请选择转接对象","转接","备注原因"].contains(text) {
      labels.append(TransferTextLine(text:text,confidence:1,frame:local(frame),source:"accessibility",
        axElement:node.role==kAXButtonRole as String && node.actions.contains(kAXPressAction as String) ? node.element:nil))
    }
  }
  return (labels,diagnostics)
}

private func resolveTransferDialogLabels(ax:(labels:[TransferTextLine],diagnostics:[String:Any]),requireAction:Bool=false,ocr:()->[TransferTextLine])->(labels:[TransferTextLine],diagnostics:[String:Any]) {
  if !ax.labels.isEmpty && (!requireAction || ax.labels.contains(where:{$0.text=="转接" && $0.axElement != nil})) { return ax }
  let ocr=ocr()
  var diagnostics=ax.diagnostics
  if !ax.labels.isEmpty {
    // Staff identities stay AX-authored even when a painted action button
    // needs OCR. Never replace an available AX name with an OCR spelling.
    diagnostics["actionSource"]="ocr";diagnostics["ocrFallbackReason"]="ax_transfer_action_not_exposed"
    return (ax.labels+ocr.filter { ["转接","备注原因"].contains(compactTransferText($0.text)) },diagnostics)
  }
  diagnostics["identitySource"]="ocr"
  return (ocr,diagnostics)
}

private func transferDialogLabels(pid:pid_t,bounds:CGRect,image:CGImage,deadline:Date?,requireAction:Bool=false,control:JDTransferWorkControl?=nil)->(labels:[TransferTextLine],diagnostics:[String:Any]) {
  let ax=transferAXLabels(pid:pid,bounds:bounds,image:image,deadline:deadline)
  return resolveTransferDialogLabels(ax:ax,requireAction:requireAction) { recognizeTransferText(in:image,deadline:deadline,control:control) }
}

/// Only detect whether the list body has painted rows. This never supplies a
/// customer or staff identity; it prevents toggling an already expanded group.
private func transferListHasPaintedRows(_ dialog:TransferDialogSnapshot)->Bool {
  let top=min(dialog.imageHeight-1,(177/dialog.bounds.height)*dialog.imageHeight)
  let rect=CGRect(x:dialog.imageWidth*0.08,y:top,width:dialog.imageWidth*0.66,
    height:max(0,dialog.imageHeight-top-dialog.imageHeight*0.04)).integral
  guard rect.height>8,let crop=dialog.image.cropping(to:rect) else { return false }
  return mediaForegroundFraction(crop)>=0.015
}

enum JDTransferGroupState {case collapsed,expanded,unknown}

/// Infer only the disclosure glyph's shape. Names, account counts and an
/// empty canvas are not evidence that a group is collapsed.
func jdTransferChevronState(_ mask:[UInt8],width:Int,height:Int)->JDTransferGroupState {
  guard width>=4,height>=4,mask.count==width*height else {return .unknown}
  let points=mask.indices.filter {mask[$0]>0}
  guard points.count>=8,Double(points.count)/Double(mask.count)<0.70 else {return .unknown}
  if height>=Int(Double(width)*1.3) {
    let middle=points.filter {$0/width>=height/3 && $0/width<height*2/3}.map {Double($0%width)}
    let ends=points.filter {$0/width<height/4 || $0/width>=height*3/4}.map {Double($0%width)}
    if !middle.isEmpty && !ends.isEmpty,
      middle.reduce(0,+)/Double(middle.count)-ends.reduce(0,+)/Double(ends.count)>Double(width)*0.24 {return .collapsed}
  }
  if width>=Int(Double(height)*1.3) {
    let middle=points.filter {$0%width>=width/3 && $0%width<width*2/3}.map {Double($0/width)}
    let ends=points.filter {$0%width<width/4 || $0%width>=width*3/4}.map {Double($0/width)}
    if !middle.isEmpty && !ends.isEmpty,
      middle.reduce(0,+)/Double(middle.count)-ends.reduce(0,+)/Double(ends.count)>Double(height)*0.24 {return .expanded}
  }
  return .unknown
}

private func jdTransferGroupDisclosure(_ dialog:TransferDialogSnapshot)->(state:JDTransferGroupState,point:CGPoint?) {
  guard let group=dialog.lines.first(where:{compactTransferText($0.text).contains("默认咨询组")}),
    let pixels=dialog.pixels else {return (.unknown,nil)}
  let scale=dialog.imageWidth/max(1,dialog.bounds.width)
  let area=CGRect(x:max(0,group.frame.minX-32*scale),y:max(0,group.frame.midY-12*scale),
    width:min(54*scale,dialog.imageWidth-max(0,group.frame.minX-32*scale)),height:24*scale).integral
  guard let mask=pixels.blackGlyphs(in:area),!mask.isEmpty else {return (.unknown,nil)}
  let w=Int(area.width),h=Int(area.height)
  guard mask.count==w*h else {return (.unknown,nil)}
  var seen=[Bool](repeating:false,count:mask.count)
  for seed in mask.indices where mask[seed]>0 && !seen[seed] {
    var work=[seed],head=0,x0=seed%w,x1=x0,y0=seed/w,y1=y0;seen[seed]=true
    while head<work.count {
      let p=work[head];head+=1;let x=p%w,y=p/w
      x0=min(x0,x);x1=max(x1,x);y0=min(y0,y);y1=max(y1,y)
      for yy in max(0,y-1)...min(h-1,y+1) {for xx in max(0,x-1)...min(w-1,x+1) {
        let next=yy*w+xx;if mask[next]>0 && !seen[next] {seen[next]=true;work.append(next)}
      }}
    }
    let cw=x1-x0+1,ch=y1-y0+1
    guard cw>=Int(3*scale),ch>=Int(3*scale),cw<=Int(14*scale),ch<=Int(14*scale) else {continue}
    var component=[UInt8](repeating:0,count:cw*ch)
    for p in work {component[(p/w-y0)*cw+p%w-x0]=1}
    let state=jdTransferChevronState(component,width:cw,height:ch)
    if state != .unknown {
      if let ax=dialog.diagnostics["groupExpanded"] as? Bool,ax != (state == .expanded) {return (.unknown,nil)}
      return (state,CGPoint(x:area.minX+CGFloat(x0+x1)/2,y:area.minY+CGFloat(y0+y1)/2))
    }
  }
  return (.unknown,nil)
}

/// A fresh capture may reuse only the unchanged OCR group label. The arrow
/// and its collapsed/expanded state always come from the new pixels. Account
/// identities, AX elements and action coordinates are never reused here.
private func transferDialogReusingGroupLabel(_ fresh:TransferDialogSnapshot,
                                           _ old:TransferDialogSnapshot)->TransferDialogSnapshot? {
  guard old.windowID==fresh.windowID,old.bounds==fresh.bounds,
    old.image.width==fresh.image.width,old.image.height==fresh.image.height,
    let group=old.lines.first(where:{$0.source=="ocr" && $0.axElement==nil &&
      $0.confidence>=0.35 && $0.text.replacingOccurrences(of:#"\s+"#,with:"",options:.regularExpression).contains("默认咨询组")}),
    let before=old.pixels,let after=fresh.pixels else {return nil}
  let band=group.frame.insetBy(dx:-2,dy:-2).integral
    .intersection(CGRect(x:0,y:0,width:fresh.imageWidth,height:fresh.imageHeight))
  guard !band.isNull,band.width>0,band.height>0,
    let a=before.blackGlyphs(in:band),let b=after.blackGlyphs(in:band),
    a.contains(1),a==b else {return nil}
  var diagnostics=old.diagnostics
  diagnostics.removeValue(forKey:"groupExpanded")
  diagnostics["groupLabelRecognitionReused"]=true
  return TransferDialogSnapshot(windowID:fresh.windowID,bounds:fresh.bounds,
    image:fresh.image,lines:[group],diagnostics:diagnostics)
}

private func captureTransferDialog(pid: pid_t, deadline: Date? = nil, recognize: Bool = true, requireAction:Bool=false,control:JDTransferWorkControl?=nil,windowID:CGWindowID?=nil) -> TransferDialogSnapshot? {
  guard CGPreflightScreenCaptureAccess(),
        let raw = CGWindowListCopyWindowInfo(
          [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
          as? [[String: Any]] else { return nil }
  let candidates = raw.compactMap { info -> (CGWindowID, CGRect, String)? in
    guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
          (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
          let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
          windowID == nil || windowID == number,
          let dictionary = info[kCGWindowBounds as String] as? [String: Any],
          let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
          bounds.width >= 320, bounds.width <= 1_100,
          bounds.height >= 260, bounds.height <= 1_100 else { return nil }
    return (CGWindowID(number), bounds,
            info[kCGWindowName as String] as? String ?? "")
  }
  let ordered = candidates.sorted {
    let leftTitle = $0.2.contains("请选择转接对象")
    let rightTitle = $1.2.contains("请选择转接对象")
    if leftTitle != rightTitle { return leftTitle }
    return $0.1.width * $0.1.height < $1.1.width * $1.1.height
  }
  for candidate in ordered {
    guard let image = CGWindowListCreateImage(
      .null, .optionIncludingWindow, candidate.0,
      [.boundsIgnoreFraming, .bestResolution]) else { continue }
    if let deadline, Date() >= deadline { return nil }
    let recognition = recognize ? transferDialogLabels(pid:pid,bounds:candidate.1,image:image,deadline:deadline,requireAction:requireAction,control:control) : (labels:[TransferTextLine](),diagnostics:[String:Any]())
    let lines=recognition.labels
    let hasVerifiedTitle = candidate.2.contains("请选择转接对象") ||
      lines.contains { compactTransferText($0.text).contains("请选择转接对象") }
    guard hasVerifiedTitle else { continue }
    return TransferDialogSnapshot(
      windowID: candidate.0, bounds: candidate.1, image: image, lines: lines,diagnostics:recognition.diagnostics)
  }
  return nil
}

/// Reuse only identities whose entire rendered name band is unchanged. The
/// wider band catches appended names/suffixes as well as l/I/1 glyph changes.
/// A freshly captured image always supplies the status badge and click geometry.
private func transferNamesUnchanged(_ old: TransferDialogSnapshot,
                                    _ fresh: TransferDialogSnapshot,
                                    allowReopenedWindow:Bool=false) -> Bool {
  guard (allowReopenedWindow || old.windowID==fresh.windowID),
    old.bounds.size==fresh.bounds.size,
    (allowReopenedWindow || old.bounds==fresh.bounds),
    old.image.width==fresh.image.width,old.image.height==fresh.image.height,
    let oldPixels=old.pixels,let freshPixels=fresh.pixels else { return false }
  let names=transferAccountCandidates(in:old)
  guard !names.isEmpty else { return false }
  return names.allSatisfy { name in
    let row=name.rowBounds ?? jdTransferRowBounds(frame:name.frame,otherFrames:names.map(\.frame),
      imageWidth:old.imageWidth,imageHeight:old.imageHeight)
    let left=max(0,min(name.frame.minX-2,old.imageWidth*0.18))
    let band=CGRect(x:left,y:row.minY,width:old.imageWidth*0.96-left,height:row.height)
    guard let a=oldPixels.blackGlyphs(in:band),let b=freshPixels.blackGlyphs(in:band),a.contains(1) else { return false }
    return a==b
  }
}

private func transferDialogReusingNames(_ fresh:TransferDialogSnapshot,
                                        _ old:TransferDialogSnapshot,
                                        allowReopenedWindow:Bool=false)->TransferDialogSnapshot? {
  guard !old.lines.contains(where:{$0.source=="accessibility"}),
    transferNamesUnchanged(old,fresh,allowReopenedWindow:allowReopenedWindow) else { return nil }
  // AX elements and action locations are never carried across modal instances.
  let names=old.lines.filter { $0.axElement==nil && !["转接","备注原因"].contains(compactTransferText($0.text)) }
  return TransferDialogSnapshot(windowID:fresh.windowID,bounds:fresh.bounds,
    image:fresh.image,lines:names,diagnostics:old.diagnostics)
}

private struct JDTransferNameCache {
  let customer:String
  let pid:pid_t
  let epoch:Int?
  let seenAt:TimeInterval
  let snapshot:TransferDialogSnapshot

  func reusing(_ fresh:TransferDialogSnapshot,customer:String,pid:pid_t,epoch:Int?,now:TimeInterval)->TransferDialogSnapshot? {
    guard exactCustomerIdentityMatches(self.customer,customer),self.pid==pid,self.epoch==epoch,
      now>=seenAt,now-seenAt<=60 else { return nil }
    return transferDialogReusingNames(fresh,snapshot,allowReopenedWindow:true)
  }
}

private func transferAccountName(from compact: String,
                                 line: TransferTextLine,
                                 imageWidth: CGFloat) -> String? {
  // AX supplies a literal account identity. OCR cleanup must never rewrite it.
  if line.source=="accessibility" { return line.text }
  // Vision sometimes merges the small Latin Grozziie logo inside the avatar
  // with the Chinese account name. Keep the real name from its stable marker.
  if let marker = compact.range(of: "格志打印机") {
    return String(compact[marker.lowerBound...])
  }
  // A standalone logo sits farther left than a normal account label and must
  // not become a transfer target by itself.
  guard line.frame.minX > imageWidth * 0.18 else { return nil }
  return compact
}

/// A staff row is bounded by its adjacent name-row midpoints. Font-relative
/// outer limits keep a solitary row from borrowing a distant row's marker.
private func jdTransferRowBounds(frame:CGRect,otherFrames:[CGRect],imageWidth:CGFloat,imageHeight:CGFloat,explicit:CGRect?=nil)->CGRect {
  let center=frame.midY,half=max(8,frame.height*1.35)
  var top=max(0,center-half),bottom=min(imageHeight,center+half)
  for other in otherFrames {
    let delta=other.midY-center
    if abs(delta)<=max(2,min(other.height,frame.height)*0.45) { continue }
    if delta<0 { top=max(top,(other.midY+center)/2) }
    else { bottom=min(bottom,(other.midY+center)/2) }
  }
  if let explicit,explicit.minY<=center,explicit.maxY>=center {
    top=max(top,explicit.minY);bottom=min(bottom,explicit.maxY)
  }
  return CGRect(x:0,y:top,width:imageWidth,height:max(0,bottom-top))
}

private func jdTransferActionBelongsToRow(action:CGRect,candidate:TransferAccountCandidate)->Bool {
  let row=candidate.rowBounds ?? jdTransferRowBounds(frame:candidate.frame,otherFrames:[],imageWidth:CGFloat.greatestFiniteMagnitude,imageHeight:CGFloat.greatestFiniteMagnitude)
  let overlap=action.intersection(row)
  return action.height>0 && row.height>0 && action.midY>=row.minY && action.midY<row.maxY &&
    !overlap.isNull && overlap.height>=action.height*0.8 &&
    abs(action.midY-candidate.frame.midY)<=max(8,candidate.frame.height*1.2)
}

private func transferBadgePixelEvidence(line: TransferTextLine,
                                        image: CGImage,rowBounds:CGRect?=nil,
                                        pixels:JDTransferPixelBuffer?=nil) -> (green: Int, red: Int) {
  let width=CGFloat(image.width),height=CGFloat(image.height)
  let row=rowBounds ?? jdTransferRowBounds(frame:line.frame,otherFrames:[],imageWidth:width,imageHeight:height,explicit:line.rowFrame)
  let nameRelative=CGRect(x:line.frame.minX-width*0.045,y:row.minY,width:width*0.043,height:row.height)
  let dialogRelative=CGRect(x:width*0.165,y:row.minY,width:width*0.045,height:row.height)
  guard let pixels=pixels ?? JDTransferPixelBuffer(image) else { return (0,0) }
  // No mirroring: both AX/Vision frames and captured bitmap rows use top-left.
  let nearName=pixels.badgeEvidence(in:nameRelative)
  let stableBand=pixels.badgeEvidence(in:dialogRelative)
  // Red samples remain diagnostic only; prefer the band with more green.
  return nearName.green>=stableBand.green ? nearName:stableBand
}

private func transferAccountCandidates(
  in dialog: TransferDialogSnapshot
) -> [TransferAccountCandidate] {
  let width = dialog.imageWidth
  let height = dialog.imageHeight
  let groupBottom = dialog.lines.first(where: {
    compactTransferText($0.text).contains("默认咨询组")
  })?.frame.maxY ?? height * 0.31
  let ignored = [
    "请选择转接对象", "指定客服", "指定咨询组", "搜索账号/名字",
    "转接", "备注原因", "默认咨询组", "在线", "离线", "忙碌", "空闲", "暂无客服", "没有在线客服", "暂无在线客服", "暂无数据",
  ]
  var seen = Set<String>()
  let eligible=dialog.lines.filter { line in
    let compact=compactTransferText(line.text)
    guard let accountName=transferAccountName(from:compact,line:line,imageWidth:width) else { return false }
    return line.confidence>=0.35 && line.frame.midY>(line.source=="accessibility" ? 0:groupBottom+height*0.025) &&
      line.frame.midY<height*0.96 && line.frame.minX>width*0.08 && line.frame.midX<width*0.64 &&
      line.frame.height>=8 && line.frame.height<=128 && accountName.count>=2 && accountName.count<=48 &&
      !ignored.contains(where:{compact.contains($0)}) && accountName.range(of:#"^\d+/\d+$"#,options:.regularExpression)==nil
  }
  return eligible.compactMap { line -> TransferAccountCandidate? in
    let compact = compactTransferText(line.text)
    guard let accountName = transferAccountName(
      from: compact, line: line, imageWidth: width) else { return nil }
    guard line.confidence >= 0.35,
          line.frame.midY > (line.source=="accessibility" ? 0 : groupBottom + height * 0.025),
          line.frame.midY < height * 0.96,
          line.frame.minX > width * 0.08,
          line.frame.midX < width * 0.64,
          line.frame.height >= 8,
          line.frame.height <= 128,
          accountName.count >= 2, accountName.count <= 48,
          !ignored.contains(where: { compact.contains($0) }),
          accountName.range(of: #"^\d+/\d+$"#, options: .regularExpression) == nil,
          seen.insert(customerIdentityKey(accountName)).inserted else {
      return nil
    }
    let bounds=jdTransferRowBounds(frame:line.frame,otherFrames:eligible.map(\.frame),imageWidth:width,imageHeight:height,explicit:line.rowFrame)
    let evidence = transferBadgePixelEvidence(line: line, image: dialog.image,rowBounds:bounds,pixels:dialog.pixels)
    return TransferAccountCandidate(
      name: accountName,
      frame: line.frame,
      greenPixelEvidence: evidence.green,
      redPixelEvidence: evidence.red,identitySource:line.source,axOnline:line.axOnline,rowBounds:bounds)
  }
}

private func transferRowDiagnostics(_ candidates:[TransferAccountCandidate])->[[String:Any]] {
  candidates.map { row in
    ["name":row.name,"identitySource":row.identitySource,"active":row.isActive,
      "axOnline":row.axOnline.map {$0 as Any} ?? NSNull(),
      "greenPixels":row.greenPixelEvidence,"redPixels":row.redPixelEvidence,
      "nameCenterY":Double(row.frame.midY),
      "rowTop":row.rowBounds.map {Double($0.minY) as Any} ?? NSNull(),
      "rowBottom":row.rowBounds.map {Double($0.maxY) as Any} ?? NSNull()]
  }
}

private func unreadScreenshot(pid: pid_t, matching target: CGRect) -> UnreadScreenshot? {
  guard CGPreflightScreenCaptureAccess(),
        let raw = CGWindowListCopyWindowInfo(
          [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
          as? [[String: Any]] else { return nil }
  // CGWindowName is sometimes empty even while AX exposes the named JD
  // reception window. Select the actual AX window by geometry as well as PID;
  // requiring the CG title silently disabled unread detection in that case.
  let candidates = raw.filter {
    ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid &&
    ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
  }
  let info = candidates.max { left, right in
    func score(_ value: [String: Any]) -> CGFloat {
      guard let dictionary = value[kCGWindowBounds as String] as? [String: Any],
            let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary)
      else { return -.infinity }
      let overlap = bounds.intersection(target)
      let overlapRatio = overlap.isNull ? 0 :
        (overlap.width * overlap.height) / max(1, target.width * target.height)
      let titleMatch = (value[kCGWindowName as String] as? String)?
        .contains("咚咚融合工作台") == true
      return overlapRatio + (titleMatch ? 0.05 : 0)
    }
    return score(left) < score(right)
  }
  guard let info,
        let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
        let dictionary = info[kCGWindowBounds as String] as? [String: Any],
        let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
        let image = CGWindowListCreateImage(
          .null, .optionIncludingWindow, CGWindowID(id),
          [.boundsIgnoreFraming, .bestResolution]) else { return nil }
  return UnreadScreenshot(bounds: bounds, image: image)
}

private func unreadBadgeEvidence(frame: CGRect, windowBounds: CGRect,
                             image: CGImage) -> (pixels: Int, bounds: CGRect?) {
  guard windowBounds.width > 0, windowBounds.height > 0 else { return (0, nil) }
  let scaleX = CGFloat(image.width) / windowBounds.width
  let scaleY = CGFloat(image.height) / windowBounds.height
  let localX = (frame.minX - windowBounds.minX + frame.width * 0.65) * scaleX
  let localY = (frame.minY - windowBounds.minY) * scaleY
  let width = frame.width * 0.35 * scaleX
  let height = frame.height * scaleY
  let bitmap = NSBitmapImageRep(cgImage: image)

  let rect = CGRect(x: localX, y: localY, width: width, height: height)
  let minX = max(0, Int(rect.minX)), maxX = min(image.width, Int(rect.maxX))
  let minY = max(0, Int(rect.minY)), maxY = min(image.height, Int(rect.maxY))
  guard minX < maxX, minY < maxY else { return (0, nil) }
  var pixels = 0
  var redLeft = maxX, redRight = minX, redTop = maxY, redBottom = minY
  for y in stride(from: minY, to: maxY, by: 2) {
    for x in stride(from: minX, to: maxX, by: 2) {
      guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
      let red = Int(color.redComponent * 255)
      let green = Int(color.greenComponent * 255)
      let blue = Int(color.blueComponent * 255)
      if red >= 185 && green <= 125 && blue <= 125 && red >= green + 60 {
        pixels += 1
        redLeft = min(redLeft, x); redRight = max(redRight, x)
        redTop = min(redTop, y); redBottom = max(redBottom, y)
      }
    }
  }
  guard pixels >= 8 else { return (pixels, nil) }
  let badge = CGRect(x: redLeft, y: redTop,
                     width: redRight - redLeft + 2, height: redBottom - redTop + 2)
    .insetBy(dx: -3, dy: -3)
    .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
  return (pixels, badge)
}

func unreadRedPixels(frame: CGRect, windowBounds: CGRect, image: CGImage) -> Int {
  // AX/window captures share a top-left origin. Mirroring inspected unrelated
  // customers/toolbar pixels and made grey/read rows appear unread.
  unreadBadgeEvidence(frame: frame, windowBounds: windowBounds, image: image).pixels
}

/// The red JD badge shows elapsed time as mm:ss. Read it only inside a row
/// already proven unread by its red pixels; a grey wall-clock label must not
/// backdate a new-message deadline.
/// Re-recognize only an already bounded low-confidence customer bubble.
/// Does not capture a screen, inspect customer identity, or read red clocks.
func jdRefinedTextLines(image:CGImage,region:CGRect) throws -> [[String:Any]] {
  let rect=CGRect(x:region.minX*CGFloat(image.width),y:region.minY*CGFloat(image.height),
    width:region.width*CGFloat(image.width),height:region.height*CGFloat(image.height)).integral
  guard let crop=image.cropping(to:rect),crop.width>=6,crop.height>=6,
    let context=CGContext(data:nil,width:crop.width*4,height:crop.height*4,bitsPerComponent:8,
      bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
  context.interpolationQuality = .high
  context.draw(crop,in:CGRect(x:0,y:0,width:context.width,height:context.height))
  guard let enlarged=context.makeImage() else { return [] }
  let request=VNRecognizeTextRequest();request.recognitionLevel = .accurate
  request.recognitionLanguages=["zh-Hans","en-US"];request.usesLanguageCorrection=true
  let cancel=DispatchWorkItem { request.cancel() }
  DispatchQueue.global(qos:.userInitiated).asyncAfter(deadline:.now()+0.8,execute:cancel)
  defer { cancel.cancel() }
  try jdPerformVision(VNImageRequestHandler(cgImage:enlarged,options:[:]),[request])
  return (request.results ?? []).compactMap { observation in
    guard let text=observation.topCandidates(1).first,text.confidence>=0.45 else { return nil }
    let b=observation.boundingBox
    return ["text":text.string,"confidence":Double(text.confidence),
      "x":Double(region.minX+b.minX*region.width),"y":Double(region.minY+(1-b.maxY)*region.height),
      "width":Double(b.width*region.width),"height":Double(b.height*region.height)]
  }
}

func jdParseRedClockAXText(_ raw: String) -> Int? {
  let text=raw.trimmingCharacters(in:.whitespacesAndNewlines)
    .replacingOccurrences(of:#"\s+"#,with:"",options:.regularExpression)
    .replacingOccurrences(of:"：",with:":")
  if text.range(of:#"^[0-9]{1,2}:[0-9]{2}$"#,options:.regularExpression) != nil {
    let parts=text.split(separator:":")
    if let m=Int(parts[0]),let seconds=Int(parts[1]),seconds<60,m*60+seconds<=600 { return m*60+seconds }
  }
  // AX supplies exact strings, not recognized pixels. No glyph substitutions.
  // Unitless values are accepted only on AX nodes overlapping the red pill.
  guard text.range(of:#"^[0-9]{1,3}(?:秒|s|sec|secs|second|seconds)?$"#,
    options:[.regularExpression,.caseInsensitive]) != nil else { return nil }
  let digits=text.prefix { $0.isASCII && $0.isNumber }
  return Int(digits).flatMap { $0<=600 ? $0:nil }
}

func jdRedClockPill(_ badge:CGRect?) -> Bool {
  guard let badge,badge.height>=12 else { return false }
  return badge.width>=badge.height*1.35
}

private func normalizedCustomerIdentity(_ value: String) -> String {
  value.trimmingCharacters(in: .whitespacesAndNewlines)
    .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
}

private func exactCustomerIdentityMatches(_ left: String, _ right: String) -> Bool {
  left.trimmingCharacters(in: .whitespacesAndNewlines).utf8.elementsEqual(
    right.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
}

private func customerIdentityKey(_ value: String) -> String {
  Data(value.trimmingCharacters(in: .whitespacesAndNewlines).utf8).base64EncodedString()
}

private func cleanedRowCustomerIdentity(_ raw: String) -> String? {
  var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
  text = text.replacingOccurrences(
    of: #"\s+(?:20\d{2}[-/.]\d{1,2}[-/.]\d{1,2}\s+)?\d{1,2}:\d{2}(?::\d{2})?\s*$"#,
    with: "", options: .regularExpression)
    .trimmingCharacters(in: .whitespacesAndNewlines)
  guard !text.isEmpty, text.count <= 80,
        !text.contains("..."), !text.contains("…"),
        text.rangeOfCharacter(from: .alphanumerics) != nil else { return nil }
  let compact = text.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
  let ignored: Set<String> = [
    "在线咨询", "留言", "排序", "清除", "紧凑布局", "客服助手", "暂无选中的会话",
    "今日接待量", "平均响应时长", "30S应答率", "今日促成下单金额", "工作台版本",
  ]
  guard !ignored.contains(compact),
        text.range(of: #"^\d{1,2}:\d{2}(?::\d{2})?$"#,
                   options: .regularExpression) == nil else { return nil }
  return text
}

private struct OCRInspectorError: Error {
  let code: String
  let message: String

  var payload: [String: Any] { ["error": code, "message": message] }
}

struct JDTranscriptAXGeometry {
  let path:String
  let role:String
  let frame:CGRect
  let labels:[String]
}

/// Editor ownership is structural evidence. A customer image/emoji inside the
/// transcript cannot become chrome merely because its text resembles a tool.
/// Some JD versions put recent emoji above the ordinary labeled toolbar; the
/// common editor container's actual top bounds both rows without a fixed crop.
func jdTranscriptEditorChromeTop(chat:CGRect,transcriptPath:String?,transcriptFrame:CGRect?,
    composerPath:String,composerFrame:CGRect,nodes:[JDTranscriptAXGeometry])->CGFloat? {
  let names:Set<String>=["选择表情","发送图片","发送视频","发送文件","屏幕截图","字体设置"]
  func descendant(_ path:String,of parent:String)->Bool {path==parent || path.hasPrefix(parent+"/")}
  func parent(_ path:String)->String {path.lastIndex(of:"/").map{String(path[..<$0])} ?? ""}
  func valid(_ frame:CGRect)->Bool {
    [frame.minX,frame.minY,frame.width,frame.height].allSatisfy{$0.isFinite} &&
      frame.width>0 && frame.height>0 && frame.minX>=chat.minX-1 && frame.maxX<=chat.maxX+1 &&
      frame.minY>=chat.minY && frame.maxY<=chat.maxY+1
  }
  guard valid(composerFrame),!composerPath.isEmpty else {return nil}
  let top=transcriptFrame?.minY ?? chat.minY
  let tools=nodes.filter { node in
    guard valid(node.frame),node.frame.minY>top,node.frame.maxY<=composerFrame.minY+1,
      transcriptPath.map({!descendant(node.path,of:$0)}) ?? true else {return false}
    if node.role=="AXToolbar" {return true}
    return (transcriptPath != nil || parent(node.path)==parent(composerPath)) &&
      ["AXButton","AXMenuButton","AXPopUpButton"].contains(node.role) &&
      node.labels.contains {names.contains($0.trimmingCharacters(in:.whitespacesAndNewlines))}
  }
  var tops=tools.map(\.frame.minY)
  // Qt also exposes a flat editor variant: shortcut tiles, the resize divider,
  // ordinary toolbar and composer are siblings of the transcript. Require the
  // complete repeated tile lane + actual divider + several labeled tools,
  // rather than inferring chrome from emoji characters or an arbitrary crop.
  let siblings=tools.filter {parent($0.path)==parent(composerPath) && $0.role != "AXToolbar"}
  let labels=Set(siblings.flatMap(\.labels).filter{names.contains($0)})
  if labels.count>=3,let toolbarTop=siblings.map(\.frame.minY).min() {
    let icon=siblings.map(\.frame.height).sorted()[siblings.count/2]
    let aligned=siblings.allSatisfy {abs($0.frame.minY-toolbarTop)<=icon*0.35}
    let dividers=nodes.filter {
      $0.role=="AXGrowArea" && parent($0.path)==parent(composerPath) && valid($0.frame) &&
        $0.frame.width>=composerFrame.width*0.90 && $0.frame.height<=icon*0.40 &&
        $0.frame.minY>top && $0.frame.maxY<=toolbarTop && toolbarTop-$0.frame.maxY<=icon*1.2
    }
    if aligned {
      for divider in dividers {
        let squares=nodes.filter { node in
          let f=node.frame
          return node.role=="AXStaticText" && parent(node.path)==parent(composerPath) && valid(f) &&
            (transcriptPath.map{!descendant(node.path,of:$0)} ?? true) &&
            f.width>=icon*0.8 && f.width<=icon*2 && f.height>=icon*0.8 && f.height<=icon*2 &&
            abs(f.width-f.height)<=max(2,f.width*0.12) && f.maxY<=divider.frame.minY &&
            divider.frame.minY-f.maxY<=f.height
        }
        for seed in squares {
          let row=squares.filter {
            abs($0.frame.minY-seed.frame.minY)<=max(2,seed.frame.height*0.12) &&
              abs($0.frame.width-seed.frame.width)<=seed.frame.width*0.12 &&
              abs($0.frame.height-seed.frame.height)<=seed.frame.height*0.12
          }.sorted{$0.frame.minX<$1.frame.minX}
          guard row.count>=8,let first=row.first,let last=row.last,
            abs(first.frame.minX-composerFrame.minX)<=icon*0.75,
            last.frame.maxX-first.frame.minX>=composerFrame.width*0.65,
            last.frame.maxX<=composerFrame.maxX+1 else {continue}
          let steps=zip(row.dropFirst(),row).map{$0.frame.minX-$1.frame.minX}
          guard let low=steps.min(),let high=steps.max(),low>=seed.frame.width,
            high<=seed.frame.width*1.6,high-low<=max(2,seed.frame.width*0.12) else {continue}
          tops.append(row.map(\.frame.minY).min()!)
        }
      }
    }
  }
  for node in nodes {
    guard ["AXGroup","AXSplitGroup","AXScrollArea"].contains(node.role),valid(node.frame),
      descendant(composerPath,of:node.path),node.path != composerPath,
      node.frame.minY>top,node.frame.minY<composerFrame.minY,
      node.frame.minX<=composerFrame.minX+1,node.frame.maxX>=composerFrame.maxX-1,
      node.frame.maxY>=composerFrame.maxY-1,
      // The whole chat split also owns the transcript and is never an editor
      // boundary. Accept only a distinct composer/control subtree.
      transcriptPath.map({!descendant($0,of:node.path)}) ?? true,
      tools.contains(where:{descendant($0.path,of:node.path) && node.frame.contains($0.frame)}) else {continue}
    tops.append(node.frame.minY)
  }
  return tops.min()
}

func jdTranscriptContentBottom(composerTop:CGFloat,scrollBottom:CGFloat?,toolbarTops:[CGFloat],
    editorChromeTop:CGFloat?=nil)->CGFloat {
  min(composerTop,scrollBottom ?? composerTop,toolbarTops.min() ?? composerTop,editorChromeTop ?? composerTop)
}

/// A title can corroborate a literal AX header, never supply a missing one.
/// Account spelling, internal whitespace and l/I/1 remain unchanged.
func jdServiceAccountFromAXHeader(_ header: String?, windowTitle: String?) -> String? {
  guard let account = header?.trimmingCharacters(in: .whitespacesAndNewlines),
        !account.isEmpty, account.count <= 80,
        !["当前客服账号", "当前客服", "source", "source_account", "account",
          "unknown", "未确认", "京麦", "咚咚融合工作台"].contains(account.lowercased()),
        let title = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
        let suffix = title.range(of: "咚咚融合工作台", options: .backwards),
        title[suffix.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
  var prefix = String(title[..<suffix.lowerBound])
    .trimmingCharacters(in: .whitespacesAndNewlines)
  guard let separator = prefix.last, ["-", "–", "—"].contains(String(separator)) else { return nil }
  prefix.removeLast()
  prefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
  return prefix == account ? account : nil
}

private struct AXNode {
  let element: AXUIElement
  let path: String
  let role: String
  let subrole: String?
  let identifier: String?
  let title: String?
  let description: String?
  let value: String?
  let help: String?
  let frame: CGRect?
  let actions: [String]
  let children: [AXUIElement]

  var text: String? {
    [title, value, description].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { !$0.isEmpty }
  }
}

/// Only candidate AX handles survive a lease. The action path refreshes their
/// hierarchy, geometry and values; no cached frame/header authorizes input.
private final class JDTransferOpenScan {
  let pid:pid_t
  let window:AXUIElement
  let windowFrame:CGRect
  let createdAt=ProcessInfo.processInfo.systemUptime
  var pending:[(element:AXUIElement,path:String,depth:Int)]
  var nodes=[AXNode]()
  var complete=false
  var refreshCursor=JDCooperativeRefreshCursor<AXNode>()
  var projection:[AXNode]?
  init(pid:pid_t,window:AXUIElement,frame:CGRect) {
    self.pid=pid;self.window=window;windowFrame=frame
    pending=[(window,"app/reception",0)]
  }
}

private final class JDTransferOpenSession {
  let epoch:Int?
  var lastUsed=ProcessInfo.processInfo.systemUptime
  var scan:JDTransferOpenScan?
  var rowToken:String?
  var rowKey:String?
  var proof:JDTransferOpenProof?
  var selectionWasRequired=false
  var resumedSelection=false
  var activeNodes:[AXNode]?
  init(epoch:Int?) {self.epoch=epoch}
}

/// Wait for the observed state, not a fixed 150ms assumption. Injectable for
/// offline regression tests; production still checks actual macOS foreground.
private func jdPrepareSendForeground(expectedPID: pid_t,
    running: () -> Bool, foreground: () -> pid_t?, activate: () -> Void,
    deadline:TimeInterval?=nil,
    now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    pause: () -> Void = { usleep(50_000) }) -> String? {
  guard running() else { return "automation_stopped" }
  guard deadline.map({now()<$0}) ?? true else {return "send_preclick_budget_exceeded"}
  if foreground() != expectedPID {
    activate()
    let activationLimit=min(now()+0.6,deadline ?? .greatestFiniteMagnitude)
    while running(), foreground() != expectedPID, now() < activationLimit { pause() }
  }
  guard running() else { return "automation_stopped" }
  guard deadline.map({now()<$0}) ?? true else {return "send_preclick_budget_exceeded"}
  return foreground() == expectedPID ? nil : "send_not_frontmost"
}

/// An already-correct header does not mean the reception owns focus. The
/// opener's activation contract is tested independently of macOS UI actions.
func jdPrepareOpenReception(allowActivation:Bool,deadline:TimeInterval,
    running:()->Bool,identityMatches:()->Bool,focused:()->Bool,
    activationIsSafe:()->Bool,activate:()->Void,
    now:()->TimeInterval={ProcessInfo.processInfo.systemUptime},
    pause:()->Void={usleep(40_000)}) -> String? {
  guard running() else {return "automation_stopped"}
  guard now()<deadline else {return "conversation_open_timeout"}
  guard identityMatches() else {return "conversation_changed"}
  // Passive reads retain their old no-activation behavior.
  guard allowActivation else {return nil}
  if !focused() {
    guard activationIsSafe() else {return "open_reception_blocked"}
    activate()
    let limit=min(deadline,now()+0.6)
    while running(),now()<limit,!focused() {pause()}
  }
  guard running() else {return "automation_stopped"}
  guard now()<deadline else {return "conversation_open_timeout"}
  guard focused() else {return "open_reception_not_focused"}
  return identityMatches() ? nil:"conversation_changed"
}

/// Identity and exact content ownership, never "composer happens to be nonempty".
private func jdMayClearInsertedReply(expected: String, active: String?, inserted: String,
    current: String, clicked: Bool) -> Bool {
  guard !clicked, !inserted.isEmpty, let active else { return false }
  return exactCustomerIdentityMatches(expected, active) &&
    Array(inserted.utf8) == Array(current.utf8)
}

/// Atomic replacement plus file/directory synchronization precedes every
/// external click intent. A failed durable write never authorizes a click.
private func jdWriteDurableJournal(_ value:[String:Any],to url:URL)->Bool {
  do {
    let data=try JSONSerialization.data(withJSONObject:value)
    try data.write(to:url,options:.atomic)
    let handle=try FileHandle(forWritingTo:url)
    defer {try? handle.close()}
    try handle.synchronize()
    let directory=Darwin.open(url.deletingLastPathComponent().path,O_RDONLY)
    guard directory>=0 else {return false}
    defer {Darwin.close(directory)}
    return Darwin.fsync(directory)==0
  } catch {return false}
}

func jdReceptionWindowMatches(expected:CGRect,frontmost:CGRect?)->Bool {
  guard expected.width>0,expected.height>0,let actual=frontmost,
    actual.width>0,actual.height>0 else {return false}
  return abs(actual.minX-expected.minX)<4 && abs(actual.minY-expected.minY)<4 &&
    abs(actual.width-expected.width)<4 && abs(actual.height-expected.height)<4
}

enum JDSendComposerReading:Equatable {
  case unreadable,empty,text(String)
}
func jdSendComposerReading(_ value:String?)->JDSendComposerReading {
  guard let value else { return .unreadable }
  let text=value.trimmingCharacters(in:.whitespacesAndNewlines)
  return text.isEmpty ? .empty:.text(text)
}

/// A new request cannot reuse an old uncertain transfer merely because a text
/// area exists. Every current ownership component must be positive AX proof.
func jdCurrentReceptionOwnershipBlock(expected:String,active:String?,enabled:Bool?,
    composerValue:String?,focused:Bool,sourceAccount:String?,blocked:Bool)->String? {
  guard !expected.isEmpty,let active,exactCustomerIdentityMatches(expected,active) else {return "ownership_customer_unconfirmed"}
  guard focused else {return "ownership_reception_not_focused"}
  guard !blocked else {return "customer_not_receiving"}
  guard enabled == true else {return enabled == false ? "customer_not_receiving":"ownership_enabled_unconfirmed"}
  guard let composerValue else {return "ownership_composer_unreadable"}
  guard composerValue.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {return "composer_not_empty"}
  guard let sourceAccount,!sourceAccount.isEmpty,
    !["当前客服账号","当前客服","source","source_account","account","unknown","未确认","京麦","咚咚融合工作台"].contains(sourceAccount.lowercased()) else {return "ownership_source_account_unconfirmed"}
  return nil
}
func jdSendPreclickDeadline(queuedAt:TimeInterval,queuedWallMs:Int64,requestedMs:Int64?,maximum:TimeInterval=6)->TimeInterval {
  let requested=requestedMs.map { max(0,Double($0-queuedWallMs)/1000) } ?? maximum
  return queuedAt+min(maximum,requested)
}

/// Applies only to an early, journaled holding send. Use a monotonic boundary
/// once admitted; neither a wall-clock change nor a late yield can replay Click.
final class JDHoldingClickGate {
  let attemptId: String
  let epoch: Int
  private let customer: String
  private let notBefore: TimeInterval
  private let deadline: TimeInterval
  private let lock = NSLock()
  private var yielded = false
  private var committed = false

  init?(customer: String, attemptId: String?, epoch: Int?, requireRedClock: Bool,
        notBeforeMs: Int64, queuedAt: TimeInterval, queuedWallMs: Int64,
        deadline: TimeInterval) {
    guard requireRedClock, notBeforeMs > 0, !customer.isEmpty,
          let attemptId, !attemptId.isEmpty, let epoch else { return nil }
    let remaining = max(0, (Double(notBeforeMs) - Double(queuedWallMs)) / 1000)
    guard remaining <= 2.25, queuedAt + remaining < deadline else { return nil }
    self.customer = customer
    self.attemptId = attemptId
    self.epoch = epoch
    notBefore = queuedAt + remaining
    self.deadline = deadline
  }

  func requestYield(customer: String, attemptId: String, epoch: Int) -> Bool {
    guard exactCustomerIdentityMatches(self.customer, customer),
          self.attemptId == attemptId, self.epoch == epoch else { return false }
    lock.lock(); defer { lock.unlock() }
    guard !committed else { return false }
    yielded = true
    return true
  }

  var yieldRequested: Bool {
    lock.lock(); defer { lock.unlock() }
    return yielded
  }

  func waitUntilDue(now: () -> TimeInterval, runCurrent: () -> Bool,
                    pause: (TimeInterval) -> Void) -> String? {
    while true {
      if !runCurrent() { return "automation_stopped" }
      if yieldRequested { return "holding_yielded_to_formal" }
      let current = now()
      if current >= deadline { return "send_preclick_budget_exceeded" }
      if current >= notBefore { return nil }
      pause(min(0.025, notBefore - current))
    }
  }

  /// Serialize a yield's acknowledgment against the actual physical dispatch.
  /// The caller keeps its run lock held for this short, nonblocking closure.
  func commit(now: TimeInterval, runCurrent: Bool, dispatch: () -> Void) -> String? {
    lock.lock(); defer { lock.unlock() }
    guard runCurrent else { return "automation_stopped" }
    guard !yielded else { return "holding_yielded_to_formal" }
    guard !committed else { return "holding_click_already_committed" }
    guard now < deadline else { return "send_preclick_budget_exceeded" }
    guard now >= notBefore else { return "holding_click_not_due" }
    committed = true
    dispatch()
    return nil
  }
}

/// AX discovery and conservative capture for JD Dingdong (Qianniu-style desktop).
/// It uses structural traits only; install-specific labels must be learned from Inspect Tree output.
final class QianniuAXCollector {
  var onCapture: (([String: Any]) -> Void)?
  var onDiagnostic: (([String: Any]) -> Void)?
  private let automationLock = NSLock()
  private var automationEpoch = 0
  private var automationRunning = false
  private var earlyHoldingSends: [String: JDHoldingClickGate] = [:]
  private var transferWorkControls=[UUID:(epoch:Int?,control:JDTransferWorkControl)]()
  private var imageOriginalControls=[UUID:(epoch:Int,control:JDImageOriginalControl)]()
  private var imageOriginalPermissionsPrepared=false
  func setImageOriginalPermissionsPrepared(_ ready:Bool) {
    automationLock.lock();imageOriginalPermissionsPrepared=ready;automationLock.unlock()
  }
  private func imageOriginalPermissionsReady()->Bool {
    automationLock.lock();defer{automationLock.unlock()};return imageOriginalPermissionsPrepared
  }
  private let imageOriginalLock=NSLock()
  private var imageOriginalDownloads=[String:JDImageOriginalDownload]()
  private var imageContextCopies=[String:JDImageContextCopy]()
  private let imageOriginalFileQueue=DispatchQueue(label:"jd.image-original.files",qos:.utility)
  // Queue-confined and retained after an unsuccessful close. Every yield,
  // Stop and next acquisition retries only this exact window, never a chat.
  private var pendingImageOriginalViewer:(pid:pid_t,id:CGWindowID,epoch:Int)?
  private var pendingImageCopyMenus=[(menu:JDImageCopyMenu,epoch:Int,
    proof:JDImageOriginalProof,target:JDMessageImageCopyTarget,binding:JDImageOriginalBinding)]()

  private func closeOwnedImageCopyMenu(_ menu:JDImageCopyMenu,proof:JDImageOriginalProof,
      target:JDMessageImageCopyTarget,binding:JDImageOriginalBinding)->Bool {
    if jdCloseOwnedImageCopyMenu(menu) {return true}
    let visible=jdImageContextMenus(pid:menu.pid)
    guard jdImageCopyMenuStillOwned(menu),
      NSWorkspace.shared.frontmostApplication?.processIdentifier==menu.pid,
      let nodes=receptionNodes(pid:menu.pid),
      activeCustomerIdentity(nodes:nodes).map({exactCustomerIdentityMatches($0,binding.customer)})==true,
      windowBounds(proof.windowID)==proof.bounds,
      jdImageCopySourceWindowOwned(windowID:proof.windowID,pid:menu.pid),
      let live=CGWindowListCreateImage(.null,.optionIncludingWindow,proof.windowID,[.boundsIgnoreFraming,.bestResolution]) else {return false}
    let controls=nodes.filter{[kAXTextAreaRole as String,kAXButtonRole as String,kAXMenuButtonRole as String].contains($0.role)}
      .compactMap{$0.frame}
    guard let point=jdImageCopyDismissPoint(target:target,chat:proof.chat,windowBounds:proof.bounds,
        imageSize:CGSize(width:proof.image.width,height:proof.image.height),menus:[menu.frame]+visible.map{$0.frame}+controls,liveImage:live),
      jdImageCopyPointHitsSource(point,windowID:proof.windowID,pid:menu.pid),
      postClick(at:point) else {return false}
    for _ in 0..<4 {
      if jdImageCopyMenuPositivelyAbsent(menu) {return true}
      usleep(25_000)
    }
    return false
  }

  private func closePendingImageOriginalViewer(expectedEpoch:Int? = nil)->Bool {
    if !pendingImageCopyMenus.isEmpty {
      pendingImageCopyMenus=pendingImageCopyMenus.filter{owned in
        !jdImageOriginalMayClose(ownerEpoch:owned.epoch,requestedEpoch:expectedEpoch) ||
          !closeOwnedImageCopyMenu(owned.menu,proof:owned.proof,target:owned.target,binding:owned.binding)
      }
      if !pendingImageCopyMenus.isEmpty {return false}
    }
    guard let owned=pendingImageOriginalViewer else {return true}
    guard jdImageOriginalMayClose(ownerEpoch:owned.epoch,requestedEpoch:expectedEpoch) else {return false}
    guard jdCloseOwnedImageViewer(pid:owned.pid,id:owned.id) else {return false}
    imageOriginalLock.lock()
    for token in Array(imageOriginalDownloads.keys) where imageOriginalDownloads[token]?.viewerID==owned.id {
      imageOriginalDownloads[token]?.viewerReleased=true
    }
    imageOriginalLock.unlock()
    pendingImageOriginalViewer=nil;return true
  }

  func requestImageAcquisitionYield(epoch:Int?)->Bool {
    automationLock.lock()
    let work=imageOriginalControls.values.filter {epoch==nil || $0.epoch==epoch}.map(\.control)
    automationLock.unlock()
    work.forEach{$0.interrupt()}
    queue.async {[weak self] in _=self?.closePendingImageOriginalViewer(expectedEpoch:epoch)}
    return !work.isEmpty
  }

  func awaitImageAcquisitionRelease(epoch:Int?,interrupted:Bool,completion:@escaping FlutterResult) {
    guard let epoch else {completion(["interrupted":interrupted,"viewerReleased":false]);return}
    queue.async {[weak self] in
      let released=self?.closePendingImageOriginalViewer(expectedEpoch:epoch) ?? false
      DispatchQueue.main.async {completion(["interrupted":interrupted,"viewerReleased":released])}
    }
  }

  private func beginTransferWork(_ epoch:Int?)->JDTransferWorkControl {
    let control=JDTransferWorkControl()
    automationLock.lock()
    transferWorkControls[control.id]=(epoch,control)
    let stale=epoch.map {!automationRunning || automationEpoch != $0} ?? false
    automationLock.unlock()
    if stale {control.interrupt()}
    return control
  }

  private func endTransferWork(_ control:JDTransferWorkControl) {
    automationLock.lock();defer {automationLock.unlock()}
    if transferWorkControls[control.id]?.control===control {transferWorkControls.removeValue(forKey:control.id)}
  }

  func requestTransferInspectionYield(automationEpoch epoch:Int?)->Bool {
    automationLock.lock()
    if let epoch,!automationRunning || automationEpoch != epoch {automationLock.unlock();return false}
    let controls=transferWorkControls.values.filter {$0.epoch==epoch}.map(\.control)
    automationLock.unlock()
    controls.forEach {$0.interrupt()}
    return !controls.isEmpty
  }

  func requestHoldingSendYield(customer: String, attemptId: String, epoch: Int?) -> Bool {
    guard let epoch else { return false }
    automationLock.lock()
    let control = automationRunning && automationEpoch == epoch ? earlyHoldingSends[attemptId] : nil
    automationLock.unlock()
    return control?.requestYield(customer: customer, attemptId: attemptId, epoch: epoch) ?? false
  }

  private func registerHoldingSend(_ gate: JDHoldingClickGate) -> Bool {
    automationLock.lock(); defer { automationLock.unlock() }
    guard automationRunning, automationEpoch == gate.epoch,
          earlyHoldingSends[gate.attemptId] == nil else { return false }
    earlyHoldingSends[gate.attemptId] = gate
    return true
  }

  private func endHoldingSend(_ gate: JDHoldingClickGate) {
    automationLock.lock(); defer { automationLock.unlock() }
    if earlyHoldingSends[gate.attemptId] === gate { earlyHoldingSends[gate.attemptId] = nil }
  }

  private func commitHoldingClick(_ gate: JDHoldingClickGate, dispatch: () -> Void) -> String? {
    automationLock.lock(); defer { automationLock.unlock() }
    return gate.commit(now: ProcessInfo.processInfo.systemUptime,
      runCurrent: automationRunning && automationEpoch == gate.epoch &&
        earlyHoldingSends[gate.attemptId] === gate, dispatch: dispatch)
  }

  private var latestSendAttempt: [String: String] = [:]
  // Queue-confined ownership; discarded before any physical click. This is
  // never inferred from an arbitrary matching draft typed by a person.
  private var unsentInsertedReply: (pid: pid_t, customer: String, text: String)?
  // Never owned by ordinary pre-click cleanup. A clicked/unknown input is
  // evidence and must survive both polling and later delivery attempts.
  private var unknownInsertedReply:(pid:pid_t,customer:String,text:String)?
  private func recoverOwnUnsentReply(nodes: [AXNode], pid: pid_t,
      readValue: (AXUIElement) -> String? = { stringAttribute($0,kAXValueAttribute) },
      clearValue: ((AXUIElement) -> Bool)? = nil) -> String {
    guard let own = unsentInsertedReply, own.pid == pid else { return "not_owned" }
    guard let active = activeCustomerIdentity(nodes:nodes),
      exactCustomerIdentityMatches(active, own.customer) else { return "customer_changed" }
    guard let field = nodes.first(where: { $0.role == kAXTextAreaRole as String }),
      let value = readValue(field.element) else { return "composer_unavailable" }
    if value.isEmpty { unsentInsertedReply=nil; return "already_empty" }
    guard jdMayClearInsertedReply(expected:own.customer, active:active,
      inserted:own.text, current:value, clicked:false) else {
      unsentInsertedReply=nil; return "text_changed_preserved"
    }
    var settable=DarwinBoolean(false)
    let cleared: Bool
    if let clearValue { cleared=clearValue(field.element) }
    else { cleared=AXUIElementIsAttributeSettable(field.element,kAXValueAttribute as CFString,&settable) == .success &&
      settable.boolValue &&
      AXUIElementSetAttributeValue(field.element,kAXValueAttribute as CFString,"" as CFTypeRef) == .success }
    guard cleared, readValue(field.element)?.isEmpty == true else { return "clear_failed" }
    unsentInsertedReply=nil; return "own_text_cleared"
  }

  private let receiptWatchQueue = DispatchQueue(label: "jd.delivery.receipt-watch", qos: .utility)
  private var pendingTransferDialogID: CGWindowID?
  /// Queue-confined one-shot ownership. Native error cleanup consumes the
  /// same token as Dart cancellation, before dispatching any close action.
  /// A later cancel therefore cannot close the reception page underneath it.
  private func closeTransferSelection(pid:pid_t,windowID:CGWindowID?)->Bool {
    guard let windowID=jdConsumeTransferModalOwnership(&pendingTransferDialogID,expected:windowID) else {return true}
    pendingTransferCustomer=nil;pendingTransferSnapshot=nil
    guard jdWindowVisible(pid:pid,windowID:windowID) else {return true}
    if jdCloseOwnedTransferModal(pid:pid,windowID:windowID) {return true}
    // No close was dispatched. Preserve ownership for a later targeted
    // cleanup, rather than inventing a successful modal disappearance.
    if jdTransferDialogWindowIDs(pid:pid).contains(windowID) {pendingTransferDialogID=windowID}
    return false
  }
  func setAutomationEpoch(_ epoch: Int, running: Bool) {
    automationLock.lock();let previousEpoch=automationEpoch;automationEpoch=epoch;automationRunning=running
    let retired=transferWorkControls.values.filter {!running || $0.epoch != epoch}.map(\.control)
    let images=imageOriginalControls.values.filter {!running || $0.epoch != epoch}.map(\.control)
    automationLock.unlock()
    retired.forEach {$0.interrupt()}
    images.forEach {$0.interrupt()}
    queue.async {[weak self] in _=self?.closePendingImageOriginalViewer(expectedEpoch:previousEpoch)}
    imageOriginalLock.lock()
    imageOriginalDownloads=imageOriginalDownloads.filter {running && $0.value.binding.epoch==epoch}
    imageContextCopies=imageContextCopies.filter {running && $0.value.binding.epoch==epoch}
    imageOriginalLock.unlock()
  }
  private func allowsAutomation(_ epoch: Int?) -> Bool {
    guard let epoch else { return true } // Explicit manual/legacy callers retain their contract.
    automationLock.lock(); defer { automationLock.unlock() }
    return automationRunning && automationEpoch == epoch
  }
  @discardableResult
  private func writeDeliveryReceipt(_ path: String?, attemptId: String?, customer: String,
      state: String, error: String? = nil, sendClickedAtMs:Int64?=nil) -> Bool {
    if path == nil && attemptId == nil { return true }
    guard let path, let attemptId, !attemptId.isEmpty,
          URL(fileURLWithPath: path).lastPathComponent == attemptId + ".json" else { return false }
    var value: [String: Any] = ["attemptId": attemptId, "customer": customer,
      "state": state, "timeMs": Int(Date().timeIntervalSince1970 * 1000)]
    // Late receipt watchers replace the state but retain the actual click
    // boundary. Recovery must never substitute the earlier attempt creation.
    let url=URL(fileURLWithPath:path)
    var clicked=sendClickedAtMs
    if clicked==nil,let bytes=try? Data(contentsOf:url),
      let prior=(try? JSONSerialization.jsonObject(with:bytes)) as? [String:Any],
      prior["attemptId"] as? String==attemptId,prior["customer"] as? String==customer,
      let saved=prior["sendClickedAtMs"] as? NSNumber,saved.int64Value>0 {
      clicked=saved.int64Value
    }
    if let clicked,clicked>0 {value["sendClickedAtMs"]=clicked}
    if let error { value["error"] = error }
    return jdWriteDurableJournal(value,to:url)
  }

  @discardableResult
  private func writeTransferReceipt(_ path:String?,attemptId:String?,customer:String,target:String,state:String,clicked:Bool,error:String?=nil)->Bool {
    if path==nil && attemptId==nil {return true}
    guard let path,let attemptId,!attemptId.isEmpty,
      URL(fileURLWithPath:path).lastPathComponent==attemptId+".json" else {return false}
    var value:[String:Any]=["attemptId":attemptId,"customer":customer,"targetAccount":target,
      "state":state,"transferClicked":clicked,"ownerPid":ProcessInfo.processInfo.processIdentifier,"timeMs":Int64(Date().timeIntervalSince1970*1000)]
    if let error {value["error"]=error}
    return jdWriteDurableJournal(value,to:URL(fileURLWithPath:path))
  }

  private var failedSendRetries: [String: (attempts: Int, next: Date)] = [:]

  private let bundleIdentifier = "com.jd.jdmddwb"
  private let queue = DispatchQueue(label: "jd.ax.capture", qos: .userInitiated)
  // Optional account routing probes must not queue ahead of a native reply.
  private let serviceAccountReadQueue = DispatchQueue(label: "jd.ax.service-account", qos: .userInitiated)
  // JD's cache tree can be slow to enumerate. It must not block the serial
  // AX queue used to send a time-bound customer holding message.
  private let videoCacheQueue = DispatchQueue(label: "jd.ax.video-cache", qos: .userInitiated)
  private var timer: DispatchSourceTimer?
  private var seenFingerprints = Set<String>()
  private var lastActiveConversation: String?
  private var pendingTransferCustomer: String?
  private var pendingTransferSnapshot: TransferDialogSnapshot?
  private var transferNameCache:JDTransferNameCache?
  private let rowAnchorLock=NSLock()
  private var rowAnchors=[String:JDRowAnchor]()
  private var pendingRowConfirmations=[String:(old:String?,seenAt:TimeInterval,epoch:Int?)]()
  private var transferOpenSessions=[String:JDTransferOpenSession]()
  private var rowTokensByKey=[String:String]()
  private var canonicalRowKeys=[String:String]()


  func status() -> [String: Any] {
    let pid = runningPID()
    return [
      "trusted": AXIsProcessTrusted(),
      "running": pid != nil,
      "pid": pid.map(Int.init) as Any,
      "bundleIdentifier": bundleIdentifier,
      "captureRunning": timer != nil,
    ]
  }

  /// Reads the operator's actual AX account header without opening a chat,
  /// invoking Vision or changing reception status.
  func readCurrentServiceAccount(completion: @escaping FlutterResult) {
    serviceAccountReadQueue.async { [weak self] in
      guard let self else { return }
      func finish(_ account: String? = nil, reason: String? = nil,
                  pid: pid_t? = nil, windowTitle: String? = nil,
                  headerPath: String? = nil) {
        var payload: [String: Any] = [
          "verified": account != nil,
          "account": account as Any? ?? NSNull(),
          "source": "accessibility_account_header",
          "observedAtMs": Int64(Date().timeIntervalSince1970 * 1000),
        ]
        if let reason { payload["reason"] = reason }
        if let pid { payload["pid"] = Int(pid) }
        if let windowTitle { payload["windowTitle"] = windowTitle }
        if let account { payload["windowTitleAccount"] = account }
        if let headerPath { payload["headerPath"] = headerPath }
        DispatchQueue.main.async { completion(payload) }
      }
      guard AXIsProcessTrusted() else {
        finish(reason: "accessibility_not_trusted"); return
      }
      guard let pid = self.runningPID() else {
        finish(reason: "jd_not_running"); return
      }
      guard let nodes = self.receptionNodes(pid: pid),
            let reception = nodes.first(where: {
              $0.role == kAXWindowRole as String &&
                $0.title?.contains("咚咚融合工作台") == true
            }), let window = reception.frame else {
        finish(reason: "reception_header_unavailable", pid: pid); return
      }
      // This is the same account-header selector used for native reception
      // ownership, independent of whether a customer chat is selected.
      let candidate = self.currentServiceAccount(in: reception, nodes: nodes,
                                                 excluding: "")
      guard let header = nodes.first(where: { node in
        guard node.role == kAXStaticTextRole as String,
              node.text == candidate, let frame = node.frame else { return false }
        return frame.minX >= window.minX &&
          frame.maxX <= window.minX + window.width * 0.32 &&
          frame.minY >= window.minY && frame.maxY <= window.minY + 115
      }) else {
        finish(reason: "service_account_header_unavailable", pid: pid); return
      }
      func freshText(_ node: AXNode) -> String? {
        [stringAttribute(node.element, kAXTitleAttribute),
         stringAttribute(node.element, kAXValueAttribute),
         stringAttribute(node.element, kAXDescriptionAttribute)]
          .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
          .first(where: { !$0.isEmpty })
      }
      let title = stringAttribute(reception.element, kAXTitleAttribute)
      guard let account = jdServiceAccountFromAXHeader(freshText(header),
                                                       windowTitle: title),
            freshText(header) == account,
            self.runningPID() == pid else {
        finish(reason: "service_account_header_unconfirmed", pid: pid,
               windowTitle: title); return
      }
      finish(account, pid: pid, windowTitle: title, headerPath: header.path)
    }
  }

  func requestAccessibility() -> Bool {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
  }

  /// Captures a validated image-bubble region from the Qianniu window when its
  /// embedded web view does not expose image bytes through the pasteboard.
  func captureImageRegion(expectedCustomer: String, windowID: CGWindowID,
                          normalizedX: Double, normalizedY: Double,
                          normalizedWidth: Double, normalizedHeight: Double,
                          expectedMediaAt: Date? = nil,
                          allowActivationForVideoDetection: Bool = false,
                          completion: @escaping FlutterResult) {
    queue.async { [weak self] in
      guard let self else { return }
      func finish(_ payload: [String: Any]) {
        DispatchQueue.main.async { completion(payload) }
      }
      let expected = expectedCustomer.trimmingCharacters(in: .whitespacesAndNewlines)
      guard AXIsProcessTrusted(), !expected.isEmpty,
            normalizedX >= 0, normalizedY >= 0,
            normalizedWidth > 0, normalizedHeight > 0,
            normalizedX + normalizedWidth <= 1,
            normalizedY + normalizedHeight <= 1,
            activeCustomerIdentity().map({ exactCustomerIdentityMatches($0, expected) }) == true else {
        finish(["error": "image_crop_precondition_failed",
                "message": "The expected customer or image region could not be verified."])
        return
      }
      guard let fullImage = CGWindowListCreateImage(
              .null, .optionIncludingWindow, windowID,
              [.boundsIgnoreFraming, .bestResolution]) else {
        finish(["error": "image_crop_window_failed",
                "message": "Could not capture the selected JingMai window."])
        return
      }
      let crop = CGRect(
        x: CGFloat(normalizedX) * CGFloat(fullImage.width),
        y: CGFloat(normalizedY) * CGFloat(fullImage.height),
        width: CGFloat(normalizedWidth) * CGFloat(fullImage.width),
        height: CGFloat(normalizedHeight) * CGFloat(fullImage.height)).integral
      guard crop.width >= 40, crop.height >= 40,
            let image = fullImage.cropping(to: crop),
            activeCustomerIdentity().map({ exactCustomerIdentityMatches($0, expected) }) == true,
            let png = NSBitmapImageRep(cgImage: image)
              .representation(using: .png, properties: [:]) else {
        finish(["error": "image_crop_verification_failed",
                "message": "The image region or active customer changed during capture."])
        return
      }
      // Exact content matching wins over a visual play-button guess. Video
      // companion thumbnails are excluded by matchingRecentJDCachedImage.
      if let cached = matchingRecentJDCachedImage(
           visibleImage: image, expectedAt: expectedMediaAt),
         activeCustomerIdentity().map({ exactCustomerIdentityMatches($0, expected) }) == true,
         let data = try? Data(contentsOf: cached.url),
         data.count == cached.size,
         let verifiedValues = try? cached.url.resourceValues(
           forKeys: [.contentModificationDateKey, .fileSizeKey]),
         verifiedValues.fileSize == cached.size,
         verifiedValues.contentModificationDate == cached.modified,
         let cachedImage = NSImage(data: data),
         let cachedCGImage = cachedImage.cgImage(
           forProposedRect: nil, context: nil, hints: nil) {
        let ext = cached.url.pathExtension.lowercased()
        let mime = ext == "png" ? "image/png" :
          (ext == "webp" ? "image/webp" : "image/jpeg")
        finish([
          "kind": "image",
          "mimeType": mime,
          "extension": ext,
          "originalName": cached.url.lastPathComponent,
          "dataBase64": data.base64EncodedString(),
          "visualFingerprint": averageImageHash(cachedCGImage),
          "captureSource": "jd-image-cache",
        ])
        return
      }
      var videoDetected = looksLikeVideoThumbnail(image)
      // JD renders the play control in a separate overlay layer that is absent
      // from a window-only capture. When JD is frontmost, hover the verified
      // bubble and inspect a bounded composite crop solely for classification.
      let previouslyFrontmost = NSWorkspace.shared.frontmostApplication
      let jdPID = runningPID()
      var activatedForRetry = false
      if !videoDetected && allowActivationForVideoDetection,
         previouslyFrontmost?.processIdentifier != jdPID,
         let jdPID,
         let jdApp = NSRunningApplication(processIdentifier: jdPID) {
        activatedForRetry = jdApp.activate(options: [.activateIgnoringOtherApps])
        if activatedForRetry { usleep(200_000) }
      }
      defer {
        if activatedForRetry,
           let previous = previouslyFrontmost,
           !previous.isTerminated {
          _ = previous.activate(options: [.activateIgnoringOtherApps])
        }
      }
      if !videoDetected,
         NSWorkspace.shared.frontmostApplication?.processIdentifier == runningPID(),
         let bounds = windowBounds(windowID) {
        let screenCrop = CGRect(
          x: bounds.minX + bounds.width * normalizedX,
          y: bounds.minY + bounds.height * normalizedY,
          width: bounds.width * normalizedWidth,
          height: bounds.height * normalizedHeight).integral
        _ = postHover(at: CGPoint(x: screenCrop.midX, y: screenCrop.midY))
        if let composite = CGWindowListCreateImage(
             screenCrop, .optionOnScreenOnly, kCGNullWindowID,
             [.boundsIgnoreFraming, .bestResolution]) {
          videoDetected = looksLikeVideoThumbnail(composite)
        }
      }
      finish([
        "kind": videoDetected ? "video" : "image",
        "mimeType": "image/png",
        "extension": "png",
        "dataBase64": png.base64EncodedString(),
        "visualFingerprint": averageImageHash(image),
        "captureSource": "verified-window-crop",
      ])
    }
  }

  func recentMediaCacheRevision(completion: @escaping FlutterResult) {
    videoCacheQueue.async {
      let revision = jdMediaCacheRevision()
      DispatchQueue.main.async {
        completion(revision.map { ["revision": $0] } ?? [:])
      }
    }
  }

  /// Checks JD's local media cache for a newly detected customer turn even
  /// when a pale/low-contrast thumbnail produced no Vision rectangle. This is
  /// intentionally clock-bounded and ambiguity-rejecting; it never returns a
  /// merely "newest" file from the shared multi-customer cache.
  func captureRecentCachedMedia(expectedCustomer: String,
                                expectedMediaAt: Date?,
                                destinationDirectory: String,
                                completion: @escaping FlutterResult) {
    videoCacheQueue.async { [weak self] in
      guard let self else { return }
      func finish(_ payload: [String: Any]) {
        DispatchQueue.main.async { completion(payload) }
      }
      let expected = expectedCustomer.trimmingCharacters(in: .whitespacesAndNewlines)
      guard AXIsProcessTrusted(), !expected.isEmpty,
            let expectedMediaAt,
            activeCustomerIdentity().map({ exactCustomerIdentityMatches($0, expected) }) == true else {
        finish(["kind": "none", "reason": "customer_or_clock_unverified"])
        return
      }
      guard let cached = uniquelyTimedRecentJDCachedMedia(expectedAt: expectedMediaAt) else {
        finish(["kind": "none", "reason": "no_unique_recent_cache_media"])
        return
      }
      let common: [String: Any] = [
        "cacheKey": cached.cacheKey,
        "cacheModifiedAtMs": Int(cached.modified.timeIntervalSince1970 * 1000),
        "captureSource": cached.kind == "video" ? "jd-video-cache" : "jd-image-cache",
      ]
      if cached.kind == "image" {
        guard let data = try? Data(contentsOf: cached.url),
              data.count == cached.size,
              let image = NSImage(data: data),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              activeCustomerIdentity().map({ exactCustomerIdentityMatches($0, expected) }) == true else {
          finish(["kind": "none", "reason": "cache_image_changed"])
          return
        }
        let ext = cached.url.pathExtension.lowercased()
        let mime = ext == "png" ? "image/png" :
          (ext == "webp" ? "image/webp" : "image/jpeg")
        finish(common.merging([
          "kind": "image",
          "mimeType": mime,
          "extension": ext,
          "originalName": cached.url.lastPathComponent,
          "dataBase64": data.base64EncodedString(),
          "visualFingerprint": averageImageHash(cgImage),
        ]) { _, new in new })
        return
      }

      let destination = URL(fileURLWithPath: destinationDirectory, isDirectory: true)
        .standardizedFileURL
      guard FileManager.default.fileExists(atPath: destination.path) else {
        finish(["kind": "none", "reason": "video_destination_missing"])
        return
      }
      var file = destination.appendingPathComponent(cached.url.lastPathComponent)
      if FileManager.default.fileExists(atPath: file.path) {
        file = destination.appendingPathComponent(
          "\(UUID().uuidString).\(cached.url.pathExtension)")
      }
      do {
        try FileManager.default.copyItem(at: cached.url, to: file)
      } catch {
        finish(["kind": "none", "reason": "cache_video_copy_failed"])
        return
      }
      guard activeCustomerIdentity().map({ exactCustomerIdentityMatches($0, expected) }) == true,
            let values = try? file.resourceValues(forKeys: [.fileSizeKey]),
            values.fileSize == cached.size else {
        try? FileManager.default.removeItem(at: file)
        finish(["kind": "none", "reason": "cache_video_changed"])
        return
      }
      let ext = file.pathExtension.lowercased()
      let mime = ext == "mov" || ext == "m4v" ? "video/quicktime" :
        (ext == "webm" ? "video/webm" : "video/mp4")
      finish(common.merging([
        "kind": "video",
        "path": file.path,
        "originalName": cached.url.lastPathComponent,
        "mimeType": mime,
        "size": cached.size,
      ]) { _, new in new })
    }
  }

  /// Copies a freshly received video from JD's local per-chat media cache.
  /// AX and the sender-bounded OCR rectangle verify the active incoming bubble,
  /// but this method deliberately performs no clicks or keyboard actions in JD.
  func downloadVideoAt(expectedCustomer: String, windowID: CGWindowID,
                       normalizedX: Double, normalizedY: Double,
                       normalizedWidth: Double, normalizedHeight: Double,
                       destinationDirectory: String,
                       completion: @escaping FlutterResult) {
    videoCacheQueue.async { [weak self] in
      guard let self else { return }
      func finish(_ payload: [String: Any]) {
        DispatchQueue.main.async { completion(payload) }
      }
      let expected = expectedCustomer.trimmingCharacters(in: .whitespacesAndNewlines)
      let destination = URL(fileURLWithPath: destinationDirectory, isDirectory: true)
        .standardizedFileURL
      guard AXIsProcessTrusted(), !expected.isEmpty,
            normalizedX >= 0, normalizedY >= 0,
            normalizedWidth > 0, normalizedHeight > 0,
            normalizedX + normalizedWidth <= 1,
            normalizedY + normalizedHeight <= 1,
            activeCustomerIdentity().map({ exactCustomerIdentityMatches($0, expected) }) == true,
            runningPID() != nil, windowBounds(windowID) != nil,
            FileManager.default.fileExists(atPath: destination.path) else {
        finish(["error": "video_download_precondition_failed",
                "message": "Keep the verified customer video visible while its local cache is inspected."])
        return
      }
      guard let cached = newestRecentJDCachedVideo() else {
        finish(["error": "video_download_not_found",
                "message": "No fresh video was found in JD's local media cache; the conversation was left untouched."])
        return
      }
      var file = destination.appendingPathComponent(cached.url.lastPathComponent)
      if FileManager.default.fileExists(atPath: file.path) {
        file = destination.appendingPathComponent(
          "\(UUID().uuidString).\(cached.url.pathExtension)")
      }
      do {
        try FileManager.default.copyItem(at: cached.url, to: file)
      } catch {
        finish(["error": "video_copy_failed",
                "message": "JD's cached video could not be copied into private storage."])
        return
      }
      guard activeCustomerIdentity().map({ exactCustomerIdentityMatches($0, expected) }) == true,
            let values = try? file.resourceValues(forKeys: [.fileSizeKey]),
            let size = values.fileSize, size == cached.size else {
        try? FileManager.default.removeItem(at: file)
        finish(["error": "video_copy_verification_failed",
                "message": "The cached video changed during copying; the partial copy was removed."])
        return
      }
      let ext = file.pathExtension.lowercased()
      let mime = ext == "mov" || ext == "m4v" ? "video/quicktime" :
        (ext == "webm" ? "video/webm" : "video/mp4")
      finish([
        "kind": "video",
        "path": file.path,
        "originalName": file.lastPathComponent,
        "mimeType": mime,
        "size": size,
        "captureSource": "jd-video-cache",
      ])
    }
  }

  /// Uses copy only to classify the selected Qianniu item. No clipboard
  /// content is returned and the user's previous clipboard is restored.
  func classifyMessageAt(expectedCustomer: String, windowID: CGWindowID,
                         normalizedX: Double, normalizedY: Double,
                         completion: @escaping FlutterResult) {
    queue.async { [weak self] in
      guard let self else { return }
      func finish(_ payload: [String: Any]) {
        DispatchQueue.main.async { completion(payload) }
      }
      let expected = expectedCustomer.trimmingCharacters(in: .whitespacesAndNewlines)
      guard AXIsProcessTrusted(), !expected.isEmpty,
            normalizedX >= 0, normalizedX <= 1,
            normalizedY >= 0, normalizedY <= 1,
            activeCustomerIdentity().map({ exactCustomerIdentityMatches($0, expected) }) == true,
            let pid = runningPID(),
            let jdApp = NSRunningApplication(processIdentifier: pid) else {
        finish(["kind": "unavailable", "reason": "jingmai_unavailable"])
        return
      }
      let previouslyFrontmost = NSWorkspace.shared.frontmostApplication
      let activatedForImageCheck = previouslyFrontmost?.processIdentifier != pid
      if activatedForImageCheck {
        _ = jdApp.activate(options: [.activateIgnoringOtherApps])
        usleep(300_000)
      }
      defer {
        if activatedForImageCheck,
           let previous = previouslyFrontmost,
           !previous.isTerminated {
          _ = previous.activate(options: [.activateIgnoringOtherApps])
        }
      }
      guard let raw = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID)
              as? [[String: Any]],
            let info = raw.first,
            let dictionary = info[kCGWindowBounds as String] as? [String: Any],
            let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else {
        finish(["kind": "unavailable", "reason": "window_missing"])
        return
      }
      let pasteboard = NSPasteboard.general
      let snapshot = PasteboardSnapshot(pasteboard)
      defer { snapshot.restore(to: pasteboard) }
      pasteboard.clearContents()
      let point = CGPoint(x: bounds.minX + bounds.width * normalizedX,
                          y: bounds.minY + bounds.height * normalizedY)
      guard postClick(at: point), postCommandC() else {
        finish(["kind": "unavailable", "reason": "copy_failed"])
        return
      }
      usleep(300_000)
      let types = pasteboard.types ?? []
      let imageTypes: Set<NSPasteboard.PasteboardType> = [
        .png, .tiff, NSPasteboard.PasteboardType("public.jpeg"), .fileURL,
      ]
      let kind: String
      var visualFingerprint = ""
      var copiedPNG: Data?
      if types.contains(where: { imageTypes.contains($0) }) {
        kind = "image"
        let imageData = pasteboard.data(forType: .png) ??
          pasteboard.data(forType: .tiff) ??
          pasteboard.data(forType: NSPasteboard.PasteboardType("public.jpeg"))
        if let imageData, let image = NSImage(data: imageData),
           let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
          visualFingerprint = averageImageHash(cgImage)
          copiedPNG = NSBitmapImageRep(cgImage: cgImage)
            .representation(using: .png, properties: [:])
        } else if let fileURL = pasteboard.string(forType: .fileURL),
                  let url = URL(string: fileURL),
                  let image = NSImage(contentsOf: url),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
          visualFingerprint = averageImageHash(cgImage)
          copiedPNG = NSBitmapImageRep(cgImage: cgImage)
            .representation(using: .png, properties: [:])
        }
      } else if pasteboard.string(forType: .string) != nil {
        kind = "text"
      } else {
        kind = "unknown"
      }
      var payload: [String: Any] = [
        "kind": kind,
        "types": types.map(\.rawValue),
        "visualFingerprint": visualFingerprint,
      ]
      if let copiedPNG {
        payload["mimeType"] = "image/png"
        payload["extension"] = "png"
        payload["dataBase64"] = copiedPNG.base64EncodedString()
      }
      finish(payload)
    }
  }

  /// Opens a verified buyer image in JD's 图片浏览器 and downloads the original.
  /// Only a newly created image in Downloads is returned; the viewer is closed
  /// before the result crosses the Flutter boundary.
  func downloadImageAt(expectedCustomer: String, windowID: CGWindowID,
                       normalizedX: Double, normalizedY: Double,
                       completion: @escaping FlutterResult) {
    queue.async { [weak self] in
      guard let self else { return }
      func finish(_ payload: [String: Any]) {
        DispatchQueue.main.async { completion(payload) }
      }
      let expected = expectedCustomer.trimmingCharacters(in: .whitespacesAndNewlines)
      guard AXIsProcessTrusted(), !expected.isEmpty,
            normalizedX >= 0, normalizedX <= 1,
            normalizedY >= 0, normalizedY <= 1,
            activeCustomerIdentity().map({ exactCustomerIdentityMatches($0, expected) }) == true,
            let pid = runningPID(),
            NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
            let sourceBounds = windowBounds(windowID) else {
        finish(["error": "image_download_precondition_failed",
                "message": "The active customer, JD focus, or source window could not be verified."])
        return
      }
      let downloads = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Downloads", isDirectory: true)
      let before = downloadableImages(in: downloads)
      let sourcePoint = CGPoint(
        x: sourceBounds.minX + sourceBounds.width * normalizedX,
        y: sourceBounds.minY + sourceBounds.height * normalizedY)
      guard postDoubleClick(at: sourcePoint) else {
        finish(["error": "image_viewer_open_failed",
                "message": "Could not open the verified JD image bubble."])
        return
      }
      var viewer: CGRect?
      for _ in 0..<16 {
        usleep(125_000)
        viewer = namedWindowBounds(pid: pid, containing: "图片浏览器")
        if viewer != nil { break }
      }
      guard let viewerBounds = viewer else {
        finish(["error": "image_viewer_missing",
                "message": "JD did not expose its 图片浏览器 window."])
        return
      }
      var viewerClosed = false
      defer {
        if !viewerClosed {
          _ = closeJDImageViewer(pid: pid, bounds: viewerBounds)
        }
      }
      // In JD 9.95 the download control is the rightmost item in the centered
      // bottom toolbar. Keep this coordinate scoped to the verified viewer.
      let downloadPoint = CGPoint(
        x: viewerBounds.minX + viewerBounds.width * 0.590,
        y: viewerBounds.minY + viewerBounds.height * 0.944)
      guard postClick(at: downloadPoint) else {
        finish(["error": "image_download_click_failed",
                "message": "Could not press the JD image download control."])
        return
      }
      var downloaded: URL?
      // Keep JD's modal viewer open for no more than one second after the
      // download click. The Flutter layer falls back to a screenshot if the
      // original file does not become available within this bounded window.
      for _ in 0..<8 {
        usleep(125_000)
        let after = downloadableImages(in: downloads)
        downloaded = after.values
          .filter { candidate in
            guard let old = before[candidate.url.path] else { return true }
            return candidate.modified > old.modified || candidate.size != old.size
          }
          .sorted { $0.modified > $1.modified }
          .first?.url
        if downloaded != nil { break }
      }
      viewerClosed = closeJDImageViewer(pid: pid, bounds: viewerBounds)
      guard viewerClosed else {
        finish(["error": "image_viewer_close_failed",
                "message": "The JD image was captured, but 图片浏览器 could not be closed safely."])
        return
      }
      guard let file = downloaded,
            let data = try? Data(contentsOf: file),
            !data.isEmpty, data.count <= 25 * 1024 * 1024 else {
        finish(["error": "image_download_not_found",
                "message": "No new JD image appeared in Downloads."])
        return
      }
      let ext = file.pathExtension.lowercased()
      let mime = ext == "png" ? "image/png" :
        (ext == "webp" ? "image/webp" : "image/jpeg")
      let visualFingerprint: String
      if let image = NSImage(data: data),
         let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
        visualFingerprint = averageImageHash(cgImage)
      } else {
        visualFingerprint = SHA256.hash(data: data).description
      }
      finish([
        "kind": "image",
        "mimeType": mime,
        "extension": ext.isEmpty ? "jpg" : ext,
        "originalName": file.lastPathComponent,
        "dataBase64": data.base64EncodedString(),
        "visualFingerprint": visualFingerprint,
        "captureSource": "jd-image-viewer-download",
      ])
    }
  }

  /// Acquires one original under a fresh sender-bound proof. All UI ownership
  /// is surrendered before completion; slow file arrival belongs to poll only.
  func copyImageFromMessageContext(_ args:[String:Any],completion:@escaping FlutterResult) {
    guard let binding=JDImageOriginalBinding(args),let targetArgs=args["target"] as? [String:Any],
      targetArgs["confirmedRegion"] == nil || args["knownImage"] as? Bool == true,
      let header=targetArgs["header"] as? [String:Any] else {
      completion(["state":"source_changed","reason":"invalid_context_message_binding"]);return
    }
    // Reuse immutable manifest integrity only. This is a sender header, not
    // a fallback image crop, and no crop is used for content comparison.
    var proofArgs=args
    for key in ["x","y","width","height"] {proofArgs[key]=header[key]}
    guard let proof=JDImageOriginalProof(proofArgs,binding:binding),
      let target=JDMessageImageCopyTarget(targetArgs,chat:proof.chat,
        imageSize:CGSize(width:proof.image.width,height:proof.image.height)) else {
      completion(["state":"source_changed","reason":"context_target_or_evidence_invalid"]);return
    }
    let control=JDImageOriginalControl()
    automationLock.lock();imageOriginalControls[control.id]=(binding.epoch,control);automationLock.unlock()
    queue.async {[weak self] in
      guard let self else {return}
      defer {self.automationLock.lock();self.imageOriginalControls.removeValue(forKey:control.id);self.automationLock.unlock()}
      func running()->Bool {!control.interrupted && self.allowsAutomation(binding.epoch)}
      var imageActionProven=false
      func finish(_ state:String,_ reason:String,_ extra:[String:Any]=[:]) {
        var payload=binding.payload;payload["state"]=state;payload["reason"]=reason
        if imageActionProven {payload["imageConfirmed"]=true}
        payload["copyPoint"]=["x":target.point.x,"y":target.point.y]
        payload.merge(extra){_,new in new}
        DispatchQueue.main.async {completion(payload)}
      }
      guard self.closePendingImageOriginalViewer(expectedEpoch:binding.epoch) else {
        finish("modal_blocked","owned_image_modal_cleanup_pending");return
      }
      guard running(),self.imageOriginalPermissionsReady(),AXIsProcessTrusted(),let pid=self.runningPID() else {
        finish("pending","image_copy_not_ready_or_yielded");return
      }
      func ownerCurrent()->Bool {
        running() && NSWorkspace.shared.frontmostApplication?.processIdentifier==pid &&
          self.activeCustomerIdentity().map{exactCustomerIdentityMatches($0,binding.customer)}==true &&
          windowBounds(proof.windowID)==proof.bounds &&
          jdImageCopySourceWindowOwned(windowID:proof.windowID,pid:pid)
      }
      func snapshot()->CGImage? {CGWindowListCreateImage(.null,.optionIncludingWindow,proof.windowID,[.boundsIgnoreFraming,.bestResolution])}
      guard ownerCurrent(),let live=snapshot(),
        jdChatContentSHA256(image:live,region:proof.chat)==jdChatContentSHA256(image:proof.image,region:proof.chat) else {
        finish("source_changed","customer_window_or_pixels_changed");return
      }
      let before=jdImageContextMenus(pid:pid,available:running)
      guard before.isEmpty else {finish("pending","existing_context_menu_preserved");return}
      let point=CGPoint(x:proof.bounds.minX+target.point.x*proof.bounds.width,
        y:proof.bounds.minY+target.point.y*proof.bounds.height)
      guard ownerCurrent() else {
        finish("source_changed","context_owner_changed_before_click");return
      }
      guard jdImageCopyPointHitsSource(point,windowID:proof.windowID,pid:pid) else {
        finish("pending","context_target_window_occluded");return
      }
      // Discovering pre-existing menus may take long enough for a new bubble
      // to move the target. Recheck the full transcript immediately before
      // dispatch; Dart must re-locate the sender rather than reuse this hit.
      guard let latest=snapshot(),
        jdChatContentSHA256(image:latest,region:proof.chat)==jdChatContentSHA256(image:proof.image,region:proof.chat) else {
        finish("source_changed","context_pixels_moved_before_click");return
      }
      guard running(),postRightClick(at:point) else {
        finish("pending","context_right_click_not_dispatched");return
      }
      var freshMenus=[JDImageCopyMenu]()
      let selected=jdObserveDispatchedImageContextMenu(observe:{
        let all=jdImageContextMenus(pid:pid)
        for menu in all where !freshMenus.contains(where:{CFEqual($0.element,menu.element)}) {freshMenus.append(menu)}
        return all.filter{$0.frame.insetBy(dx:-24,dy:-24).contains(point)}
      },pause:{usleep(50_000)})
      self.pendingImageCopyMenus=freshMenus.map{($0,binding.epoch,proof,target,binding)}
      guard let menu=selected else {
        let released=self.closePendingImageOriginalViewer(expectedEpoch:binding.epoch)
        finish(released ? "pending":"modal_blocked",running() ? "image_context_menu_not_exposed_or_ambiguous":"acquisition_yielded");return
      }
      var menuReleased=false
      func close()->Bool {
        menuReleased=self.closeOwnedImageCopyMenu(menu,proof:proof,target:target,binding:binding)
        if menuReleased {
          self.pendingImageCopyMenus.removeAll{CFEqual($0.menu.element,menu.element)}
          // A submenu opened by our popup also belongs to this event.
          menuReleased=self.closePendingImageOriginalViewer(expectedEpoch:binding.epoch)
        }
        return menuReleased
      }
      defer {if !menuReleased {_=close()}}
      func fail(_ reason:String) {finish(close() ? "pending":"modal_blocked",reason)}
      guard running() else {fail("acquisition_yielded");return}
      let items=jdImageCopyMenuItems(menu)
      let labels=items.map{[stringAttribute($0,kAXTitleAttribute),stringAttribute($0,kAXDescriptionAttribute)]
        .compactMap{$0}.first ?? ""}
      let enabled=items.map{boolAttribute($0,kAXEnabledAttribute) != false}
      let menuMask=CGRect(x:(menu.frame.minX-proof.bounds.minX-8)/proof.bounds.width,
        y:(menu.frame.minY-proof.bounds.minY-8)/proof.bounds.height,
        width:(menu.frame.width+16)/proof.bounds.width,height:(menu.frame.height+16)/proof.bounds.height)
      guard ownerCurrent(),let current=snapshot(),jdContextCopyPixelsMatch(source:proof.image,live:current,
        chat:proof.chat,menu:menuMask,header:target.header) else {
        fail("message_pixels_changed_before_copy");return
      }
      imageActionProven=jdImageContextMenuConfirmsImage(labels:labels,enabled:enabled)
      guard let choice=jdImageContextCopyChoice(labels:labels,enabled:enabled) else {
        fail(running() ? "image_copy_action_not_verified":"acquisition_yielded");return
      }
      let pasteboard=NSPasteboard.general
      let savedVersion=pasteboard.changeCount
      let saved=PasteboardSnapshot(pasteboard)
      var restoreVersion:Int?
      defer {
        if let version=restoreVersion,pasteboard.changeCount==version {saved.restore(to:pasteboard)}
      }
      guard ownerCurrent(),pasteboard.changeCount==savedVersion else {fail("context_source_or_clipboard_changed_before_copy");return}
      pasteboard.clearContents();let version=pasteboard.changeCount;restoreVersion=version
      guard AXUIElementPerformAction(items[choice.index],kAXPressAction as CFString) == .success else {
        fail("copy_action_not_dispatched");return
      }
      var data:Data?
      for _ in 0..<8 {
        guard running() else {break}
        if pasteboard.changeCount != version {
          restoreVersion=pasteboard.changeCount
          data=pasteboard.data(forType:.png) ?? pasteboard.data(forType:.tiff) ??
            pasteboard.data(forType:NSPasteboard.PasteboardType("public.jpeg"))
          if data != nil {break}
        }
        usleep(40_000)
      }
      guard let bytes=data,!bytes.isEmpty,bytes.count<=25*1024*1024,
        pasteboard.changeCount != version,ownerCurrent() else {
        fail(running() ? "fresh_copied_image_unavailable":"acquisition_yielded");return
      }
      // The verified menu action already owns this original message. A newer
      // message arriving after Copy must not discard that message's bytes.
      guard close(),ownerCurrent() else {
        finish(menuReleased ? "source_changed":"modal_blocked","message_changed_or_menu_cleanup_unconfirmed");return
      }
      // Clipboard restoration occurs before returning the token, and decoding
      // or cache enumeration starts only on the later file-only poll.
      if let own=restoreVersion,pasteboard.changeCount==own {saved.restore(to:pasteboard)}
      restoreVersion=nil
      let token=UUID().uuidString
      self.imageOriginalLock.lock()
      let nowMs=Int64(Date().timeIntervalSince1970*1000)
      self.imageContextCopies=self.imageContextCopies.filter{
        $0.value.binding.epoch==binding.epoch && nowMs-$0.value.binding.senderAtMs<180_000
      }
      guard nowMs-binding.senderAtMs<180_000 else {
        self.imageOriginalLock.unlock();finish("pending","context_copy_expired");return
      }
      self.imageContextCopies[token]=JDImageContextCopy(binding:binding,data:bytes,
        explicitImageAction:choice.explicitImage,knownImage:args["knownImage"] as? Bool == true)
      self.imageOriginalLock.unlock()
      let lifetime=max(0,Double(binding.senderAtMs+180_000-nowMs)/1000)
      self.imageOriginalFileQueue.asyncAfter(deadline:.now()+lifetime) {[weak self] in
        guard let self else {return}
        self.imageOriginalLock.lock();defer{self.imageOriginalLock.unlock()}
        if self.imageContextCopies[token]?.binding.matches(binding)==true {
          self.imageContextCopies.removeValue(forKey:token)
        }
      }
      finish("pending","context_copy_captured",["token":token,"copyMethod":"context_menu","clipboardChanged":true,
        "copyMenuTitle":labels[choice.index]])
    }
  }

  func acquireImageOriginal(_ args:[String:Any],completion:@escaping FlutterResult) {
    guard let binding=JDImageOriginalBinding(args) else {
      completion(["state":"source_changed","reason":"invalid_message_binding"]);return
    }
    let control=JDImageOriginalControl()
    automationLock.lock();imageOriginalControls[control.id]=(binding.epoch,control);automationLock.unlock()
    queue.async { [weak self] in
      guard let self else {return}
      defer {
        self.automationLock.lock();self.imageOriginalControls.removeValue(forKey:control.id);self.automationLock.unlock()
      }
      func running()->Bool {!control.interrupted && self.allowsAutomation(binding.epoch)}
      func finish(_ state:String,_ reason:String?,_ extra:[String:Any]=[:]) {
        var payload=binding.payload;payload["state"]=state
        if let reason {payload["reason"]=reason}
        payload.merge(extra){_,new in new}
        DispatchQueue.main.async {completion(payload)}
      }
      guard self.closePendingImageOriginalViewer(expectedEpoch:binding.epoch) else {finish("modal_blocked","owned_viewer_close_unconfirmed");return}
      guard running() else {finish("pending","acquisition_yielded");return}
      guard self.imageOriginalPermissionsReady() else {finish("pending","permission_not_prepared");return}
      guard let proof=JDImageOriginalProof(args,binding:binding),let source=proof.crop,
        source.width>=40,source.height>=40 else {finish("source_changed","evidence_integrity_or_region_changed");return}
      guard AXIsProcessTrusted(),let pid=self.runningPID(),
        NSWorkspace.shared.frontmostApplication?.processIdentifier==pid,
        self.activeCustomerIdentity().map({exactCustomerIdentityMatches($0,binding.customer)})==true,
        let bounds=windowBounds(proof.windowID),bounds==proof.bounds,
        let windows=CGWindowListCopyWindowInfo(.optionIncludingWindow,proof.windowID) as? [[String:Any]],
        (windows.first?[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value==pid,
        let live=CGWindowListCreateImage(.null,.optionIncludingWindow,proof.windowID,[.boundsIgnoreFraming,.bestResolution]),
        jdChatContentSHA256(image:live,region:proof.chat)==jdChatContentSHA256(image:proof.image,region:proof.chat),
        running() else {finish("source_changed","customer_window_or_pixels_changed");return}
      // A white loading tile cannot justify opening another object below it.
      guard mediaForegroundFraction(source)>=0.06 else {finish("pending","image_not_loaded");return}
      let beforeViewers=jdImageViewerIDs(pid:pid)
      guard beforeViewers.isEmpty else {finish("pending","existing_image_viewer_preserved");return}
      // Require a true card-sized region. A full transcript-width synthetic
      // placeholder cannot safely provide a center click into a small image.
      let point=CGPoint(x:bounds.minX+proof.region.midX*bounds.width,
        y:bounds.minY+proof.region.midY*bounds.height)
      guard running(),self.activeCustomerIdentity().map({exactCustomerIdentityMatches($0,binding.customer)})==true,
        let latest=CGWindowListCreateImage(.null,.optionIncludingWindow,proof.windowID,[.boundsIgnoreFraming,.bestResolution]),
        jdChatContentSHA256(image:latest,region:proof.chat)==jdChatContentSHA256(image:proof.image,region:proof.chat),
        postDoubleClick(at:point) else {finish("source_changed","source_changed_before_click");return}
      var owned:CGWindowID?
      for _ in 0..<16 {
        let fresh=jdImageViewerIDs(pid:pid).subtracting(beforeViewers)
        if fresh.count==1 {owned=fresh.first;break}
        // Even on Stop, finish observing the already dispatched open so its
        // newly created viewer can be closed by identity, never by Escape.
        usleep(50_000)
      }
      guard let owned else {finish("pending",running() ? "image_viewer_not_exposed":"acquisition_yielded");return}
      self.pendingImageOriginalViewer=(pid,owned,binding.epoch)
      var closed=false
      defer {if !closed {_=self.closePendingImageOriginalViewer(expectedEpoch:binding.epoch)}}
      func close()->Bool {closed=self.closePendingImageOriginalViewer(expectedEpoch:binding.epoch);return closed}
      guard jdImageViewerIDs(pid:pid).contains(owned),jdImageViewerFrontmost(pid:pid,id:owned),running() else {
        let released=close();finish(released ? "pending":"modal_blocked","viewer_identity_unconfirmed");return
      }
      // Verify close capability before touching clipboard or initiating work.
      let axClose=jdOwnedImageViewer(pid:pid,id:owned).flatMap{jdImageViewerCloseButton($0)} != nil
      let glyphClose:Bool
      if let bounds=windowBounds(owned),let image=CGWindowListCreateImage(.null,.optionIncludingWindow,owned,[.boundsIgnoreFraming,.bestResolution]) {
        glyphClose=jdImageViewerCloseGlyph(image:image,windowSize:bounds.size) != nil
      } else {glyphClose=false}
      guard axClose || glyphClose else {
        let released=close();finish(released ? "pending":"modal_blocked","owned_viewer_close_unavailable");return
      }
      let pasteboard=NSPasteboard.general
      var copied:Data?,copiedImage:CGImage?
      do {
        let saved=PasteboardSnapshot(pasteboard)
        defer {saved.restore(to:pasteboard)}
        guard running(),jdImageViewerFrontmost(pid:pid,id:owned),jdImageViewerIDs(pid:pid).contains(owned) else {
          let released=close();finish(released ? "pending":"modal_blocked","acquisition_yielded");return
        }
        pasteboard.clearContents();let version=pasteboard.changeCount
        if postCommandC() {
          for _ in 0..<6 {
            if !running() {break}
            if pasteboard.changeCount != version {break}
            usleep(50_000)
          }
          if running(),pasteboard.changeCount != version,
            jdImageViewerFrontmost(pid:pid,id:owned),jdImageViewerIDs(pid:pid).contains(owned) {
            let data=pasteboard.data(forType:.png) ?? pasteboard.data(forType:.tiff) ??
              pasteboard.data(forType:NSPasteboard.PasteboardType("public.jpeg"))
            if let data,data.count<=25*1024*1024,
              let image=jdCompleteOriginalImage(data),
              jdOriginalImageMatches(visible:source,original:image),
              let png=NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) {
              copied=png;copiedImage=image
            }
          }
        }
      }
      if let copied,let image=copiedImage {
        let released=close()
        guard running(),released else {finish(released ? "pending":"modal_blocked",released ? "acquisition_yielded":"owned_viewer_close_unconfirmed");return}
        finish("ready",nil,["kind":"image","contentComplete":true,"mimeType":"image/png","extension":"png",
          "captureSource":"jd-image-viewer-copy","dataBase64":copied.base64EncodedString(),
          "pixelWidth":image.width,"pixelHeight":image.height,"visualFingerprint":averageImageHash(image)])
        return
      }
      guard running(),jdImageViewerFrontmost(pid:pid,id:owned),
        let current=jdOwnedImageViewer(pid:pid,id:owned),let download=jdImageDownloadButton(current) else {
        let released=close();finish(released ? "pending":"modal_blocked",running() ? "verified_download_control_unavailable":"acquisition_yielded");return
      }
      let directory=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads",isDirectory:true)
      let before=downloadableImages(in:directory)
      guard running(),jdImageViewerFrontmost(pid:pid,id:owned),jdOwnedImageViewer(pid:pid,id:owned) != nil,
        AXUIElementPerformAction(download,kAXPressAction as CFString) == .success else {
        let released=close();finish(released ? "pending":"modal_blocked","download_action_unconfirmed");return
      }
      let token=UUID().uuidString
      self.imageOriginalLock.lock()
      self.imageOriginalDownloads[token]=JDImageOriginalDownload(binding:binding,before:before,source:source,viewerID:owned)
      self.imageOriginalLock.unlock()
      let didClose=close()
      finish(didClose ? "pending":"modal_blocked",didClose ? "download_triggered":"owned_viewer_close_unconfirmed",["token":token])
    }
  }

  /// File-only and resumable: a slow download is not a failed customer task.
  /// No UI operation, active customer lookup or window cleanup is permitted here.
  func pollImageOriginal(_ args:[String:Any],completion:@escaping FlutterResult) {
    guard let binding=JDImageOriginalBinding(args) else {
      completion(["state":"source_changed","reason":"invalid_message_binding"]);return
    }
    imageOriginalFileQueue.async { [weak self] in
      guard let self else {return}
      let token=args["token"] as? String ?? ""
      func finish(_ state:String,_ reason:String?,_ extra:[String:Any]=[:]) {
        var value=binding.payload;value["state"]=state;value["token"]=token
        if let reason {value["reason"]=reason};value.merge(extra){_,new in new}
        DispatchQueue.main.async {completion(value)}
      }
      guard self.allowsAutomation(binding.epoch) else {finish("pending","automation_stopped");return}
      guard self.imageOriginalPermissionsReady() else {finish("pending","permission_not_prepared");return}
      self.imageOriginalLock.lock();let copied=self.imageContextCopies[token];self.imageOriginalLock.unlock()
      if let copied {
        guard copied.binding.matches(binding) else {finish("source_changed","context_copy_token_owner_mismatch");return}
        guard Int64(Date().timeIntervalSince1970*1000)-binding.senderAtMs<180_000 else {
          self.imageOriginalLock.lock();self.imageContextCopies.removeValue(forKey:token);self.imageOriginalLock.unlock()
          finish("pending","context_copy_expired",["imageConfirmed":copied.knownImage || copied.explicitImageAction]);return
        }
        guard let image=jdCompleteOriginalImage(copied.data),image.width>=40,image.height>=40 else {
          self.imageOriginalLock.lock();self.imageContextCopies.removeValue(forKey:token);self.imageOriginalLock.unlock()
          finish("source_changed","copied_image_incomplete_or_invalid");return
        }
        let cached=jdExactContextImageCache(data:copied.data,image:image,
          expectedAt:Date(timeIntervalSince1970:Double(binding.senderAtMs)/1000))
        if cached?.3 == true {
          self.imageOriginalLock.lock();self.imageContextCopies.removeValue(forKey:token);self.imageOriginalLock.unlock()
          finish("source_changed","copied_video_cover_not_image");return
        }
        guard jdContextCopiedImageCanComplete(knownImage:copied.knownImage,
          explicitImageAction:copied.explicitImageAction,exactImageCacheMatch:cached != nil,
          verifiedVideoCover:cached?.3 == true) else {
          finish("pending","copied_media_type_unverified",["token":token]);return
        }
        let complete=cached?.2 ?? image
        guard self.allowsAutomation(binding.epoch),
          let png=NSBitmapImageRep(cgImage:complete).representation(using:.png,properties:[:]) else {
          finish("pending","automation_stopped");return
        }
        guard Int64(Date().timeIntervalSince1970*1000)-binding.senderAtMs<180_000 else {
          self.imageOriginalLock.lock();self.imageContextCopies.removeValue(forKey:token);self.imageOriginalLock.unlock()
          finish("pending","context_copy_expired",["imageConfirmed":true]);return
        }
        self.imageOriginalLock.lock();self.imageContextCopies.removeValue(forKey:token);self.imageOriginalLock.unlock()
        finish("ready",nil,["kind":"image","contentComplete":true,"imageConfirmed":true,
          "mimeType":"image/png","extension":"png","originalName":cached?.0.lastPathComponent ?? "jd-context-copied-image.png",
          "captureSource":cached == nil ? "jd-message-context-copy":"jd-message-context-copy-cache",
          "copyMethod":"context_menu","cacheMatched":cached != nil,"cacheMatchProof":cached == nil ? "not_required_for_owned_copy":"exact_full_image_pixels",
          "dataBase64":png.base64EncodedString(),"pixelWidth":complete.width,"pixelHeight":complete.height,
          "visualFingerprint":averageImageHash(complete)])
        return
      }
      self.imageOriginalLock.lock();let stored=self.imageOriginalDownloads[token];self.imageOriginalLock.unlock()
      guard var stored,stored.binding.matches(binding) else {finish("source_changed","download_token_unavailable");return}
      guard stored.viewerReleased else {finish("modal_blocked","owned_viewer_close_unconfirmed");return}
      let directory=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads",isDirectory:true)
      let changed=downloadableImages(in:directory).values.filter { item in
        guard item.size>0,item.size<=25*1024*1024 else {return false}
        guard let before=stored.before[item.url.path] else {return true}
        return item.modified>before.modified || item.size != before.size
      }
      var stable=[String:String](),matches=[(URL,Data,CGImage)]()
      for item in changed {
        let signature="\(item.size):\(item.modified.timeIntervalSince1970)"
        stable[item.url.path]=signature
        guard stored.lastStable[item.url.path]==signature,
          let bytes=try? Data(contentsOf:item.url),bytes.count==item.size,
          let image=jdCompleteOriginalImage(bytes),
          jdOriginalImageMatches(visible:stored.source,original:image) else {continue}
        matches.append((item.url,bytes,image))
      }
      stored.lastStable=stable
      self.imageOriginalLock.lock()
      if self.imageOriginalDownloads[token] != nil {self.imageOriginalDownloads[token]=stored}
      self.imageOriginalLock.unlock()
      guard matches.count==1,let selected=matches.first else {
        finish("pending",matches.count>1 ? "download_content_ambiguous":"download_file_pending");return
      }
      guard self.allowsAutomation(binding.epoch),
        let png=NSBitmapImageRep(cgImage:selected.2).representation(using:.png,properties:[:]) else {
        finish("pending","automation_stopped");return
      }
      self.imageOriginalLock.lock();self.imageOriginalDownloads.removeValue(forKey:token);self.imageOriginalLock.unlock()
      finish("ready",nil,["kind":"image","contentComplete":true,"mimeType":"image/png","extension":"png",
        "originalName":selected.0.lastPathComponent,"captureSource":"jd-image-viewer-download",
        "dataBase64":png.base64EncodedString(),"pixelWidth":selected.2.width,"pixelHeight":selected.2.height,
        "visualFingerprint":averageImageHash(selected.2)])
    }
  }

  func start() {
    guard timer == nil else { return }
    let source = DispatchSource.makeTimerSource(queue: queue)
    source.schedule(deadline: .now(), repeating: .milliseconds(700), leeway: .milliseconds(150))
    source.setEventHandler { [weak self] in self?.poll() }
    timer = source
    source.resume()
  }

  func stop() {
    timer?.cancel()
    timer = nil
  }

  /// Read-only AX readiness, deliberately independent of Vision/OCR.
  func checkDeliveryReadiness(expectedCustomer: String, requireCurrentOwnership:Bool = false,
      completion: @escaping FlutterResult) {
    queue.async { [weak self] in
      guard let self else { return }
      var payload: [String: Any]
      if let pid = runningPID(), let nodes = self.receptionNodes(pid: pid),
          self.activeCustomerMatches(expectedCustomer, nodes: nodes) {
        if requireCurrentOwnership {
          let reception=nodes.first(where:{$0.role==kAXWindowRole as String && $0.title?.contains("咚咚融合工作台")==true})
          let source=reception.map {self.currentServiceAccount(in:$0,nodes:nodes,excluding:expectedCustomer)}
          // Read the account again from that exact AX header node rather than
          // accepting a cached/template account string from another path.
          let accountNode=nodes.first(where:{$0.role==kAXStaticTextRole as String && $0.text==source})
          let freshSource=accountNode.flatMap { node -> String? in
            [stringAttribute(node.element,kAXTitleAttribute),stringAttribute(node.element,kAXValueAttribute),
             stringAttribute(node.element,kAXDescriptionAttribute)].compactMap {$0?.trimmingCharacters(in:.whitespacesAndNewlines)}.first(where:{!$0.isEmpty})
          }
          // Re-read the current header/composer after the full snapshot and
          // source-account read. A switched or detached Qt tree cannot prove
          // that the earlier customer's reception is still current.
          let currentNodes=self.freshSendNodes(nodes,deadline:ProcessInfo.processInfo.systemUptime+0.5)
          let composer=currentNodes?.first(where:{$0.role==kAXTextAreaRole as String})
          let active=currentNodes.flatMap {self.activeCustomerIdentity(nodes:$0)}
          let reason=jdCurrentReceptionOwnershipBlock(expected:expectedCustomer,active:active,
            enabled:composer.flatMap {boolAttribute($0.element,kAXEnabledAttribute)},
            composerValue:composer.flatMap {stringAttribute($0.element,kAXValueAttribute)},
            focused:self.receptionHasFocus(pid:pid,nodes:currentNodes ?? []),sourceAccount:freshSource,
            blocked:currentNodes.map {self.deliveryBlockReason($0) != nil} ?? true)
          if let reason {
            payload=["error":reason,"ready":false,"ownershipConfirmed":false,
              "message":"Current reception ownership could not be proved through exact AX evidence."]
          } else {
            payload=["ready":true,"ownershipConfirmed":true,"customer":expectedCustomer,
              "currentCustomer":active!,"activeCustomerId":active!,"sourceAccount":freshSource!,
              "ownershipProof":"current_enabled_empty_reception_ax","observedAtMs":Int64(Date().timeIntervalSince1970*1000)]
          }
        } else if let reason = self.deliveryBlockReason(nodes) {
          payload = ["error": reason, "message": "JD does not currently permit replies in this customer's composer."]
        } else { payload = ["ready": true, "customer": expectedCustomer] }
      } else { payload = ["error": "delivery_readiness_unconfirmed", "message": "Exact active customer was not verified."] }
      DispatchQueue.main.async { completion(payload) }
    }
  }

  private func deliveryBlockReason(_ nodes: [AXNode]) -> String? {
    // This account-status control is different from a historical customer's
    // offline bubble. Do not insert a reply when the operator is offline.
    if nodes.contains(where:{ $0.role == kAXButtonRole as String &&
      ($0.text?.hasPrefix("离线时无法收发消息") ?? false) }) { return "operator_offline" }
    if nodes.contains(where: { $0.role == kAXSheetRole as String || $0.subrole == "AXDialog" }) {
      return "delivery_readiness_unconfirmed"
    }
    guard let composer = nodes.first(where: { $0.role == kAXTextAreaRole as String }),
          let frame = composer.frame else { return "delivery_readiness_unconfirmed" }
    if boolAttribute(composer.element, kAXEnabledAttribute) == false { return "customer_not_receiving" }
    // Only current composer notices. Historical transfer/system bubbles above
    // the composer must never be mistaken for current reception ownership.
    let notices = nodes.compactMap { node -> String? in
      guard node.role == kAXStaticTextRole as String, let box = node.frame,
            box.minY >= frame.minY - 24, box.minY <= frame.maxY,
            box.minX >= frame.minX, box.maxX <= frame.maxX else { return nil }
      return node.text
    }
    return jdReceptionNoticeBlocksDelivery(notices) ? "customer_not_receiving" : nil
  }

  private func outgoingFailureSnapshot(_ nodes: [AXNode], pid: pid_t) -> (available: Bool, failure: FailedSendBubble?) {
    guard let composer = nodes.first(where: { $0.role == kAXTextAreaRole as String }),
          let composerFrame = composer.frame,
          let split = nodes.filter({ $0.role == kAXSplitGroupRole as String && composer.path.hasPrefix($0.path + "/") })
            .max(by: { $0.path.count < $1.path.count }), let chat = split.frame,
          let screenshot = unreadScreenshot(pid: pid,
            matching: nodes.first(where: { $0.role == kAXWindowRole as String })?.frame ?? chat.union(composerFrame))
      else { return (false, nil) }
    let transcript = CGRect(x: chat.minX, y: chat.minY, width: chat.width,
        height: max(0, composerFrame.minY - chat.minY))
    // Reuse AX geometry/PID capture: CGWindowName can be empty on this JD.
    // Pixel geometry only; no Vision request, recognition, or full-window PNG.
    return (true, failedSendBubbles(image: screenshot.image, windowBounds: screenshot.bounds,
      chatFrame: transcript, onlyLatestOutgoing: true).max(by: { $0.frame.maxY < $1.frame.maxY }))
  }

  /// Performs one explicitly requested send. The expected conversation is
  /// opened and verified before insertion, then verified again before the
  /// physical Send control is clicked. No caller can omit the expected ID.
  func sendDraftOnce(expectedCustomer: String, reply: String,
                     mediaPaths: [String] = [], attemptId: String? = nil, receiptPath: String? = nil,
                     mediaRevision:Int?=nil,mediaGuardPath:String?=nil,
                     automationEpoch: Int? = nil, requireRedClock: Bool = false,
                     preClickDeadlineMs:Int64?=nil,
                     holdingClickNotBeforeMs:Int64?=nil,
                     completion: @escaping FlutterResult) {
    let queuedAt=ProcessInfo.processInfo.systemUptime
    let queuedWallMs=Int64(Date().timeIntervalSince1970*1000)
    let preClickDeadline=jdSendPreclickDeadline(queuedAt:queuedAt,queuedWallMs:queuedWallMs,requestedMs:preClickDeadlineMs)
    let holding = holdingClickNotBeforeMs.flatMap {
      JDHoldingClickGate(customer: expectedCustomer, attemptId: attemptId, epoch: automationEpoch,
        requireRedClock: requireRedClock, notBeforeMs: $0, queuedAt: queuedAt,
        queuedWallMs: queuedWallMs, deadline: preClickDeadline)
    }
    if let holding, !registerHoldingSend(holding) {
      // A duplicate cannot overwrite the live operation's receipt.
      completion(["error": "holding_attempt_unavailable", "clickDispatched": false,
                  "message": "The holding attempt is duplicate or its run is no longer active."])
      return
    }
    queue.async { [weak self] in
      guard let self else { return }
      defer { if let holding { self.endHoldingSend(holding) } }
      var clickIntent = false
      var observedCustomer: String?
      var recoverInsertedText: (() -> String)?
      let sendStartedAtMs=Int64(Date().timeIntervalSince1970*1000)
      var sendClickedAtMs:Int64?
      var stageStarted=Date()
      var stageElapsedMs:[String:Int]=[:]
      var sendStage = "preflight"
      func enterSendStage(_ stage:String) {
        stageElapsedMs[sendStage,default:0] += Int(Date().timeIntervalSince(stageStarted)*1000)
        stageStarted=Date();sendStage=stage
      }
      var axRefreshAttempts=0
      var activationAttempts = 0
      var reusedOwnInsertion = false
      var fullSnapshotReads=0,lightSnapshotReads=0
      var postClickDeadline:TimeInterval?
      var confirmationAXValueFailures=0
      func finish(_ original: [String: Any]) {
        var payload=original
        if !clickIntent,ProcessInfo.processInfo.systemUptime>=preClickDeadline,
          payload["error"] as? String != "automation_stopped",
          payload["error"] as? String != "holding_yielded_to_formal",payload["sent"] as? Bool != true {
          payload["error"]="send_preclick_budget_exceeded"
          payload["message"]="The shared pre-click UI budget expired; nothing was clicked."
        }
        let phase = payload["sent"] as? Bool == true ? "submitted" :
          (payload["error"] as? String == "send_platform_rejected" ? "rejected" : (clickIntent ? "unknown" : "not_sent"))
        self.writeDeliveryReceipt(receiptPath, attemptId: attemptId, customer: expectedCustomer,
          state: phase, error: payload["error"] as? String,sendClickedAtMs:sendClickedAtMs)
        var response=payload
        response["sendStartedAtMs"]=sendStartedAtMs
        response["queueWaitMs"]=max(0,sendStartedAtMs-queuedWallMs)
        response["preClickBudgetRemainingMs"]=max(0,Int((preClickDeadline-ProcessInfo.processInfo.systemUptime)*1000))
        response["sendClickedAtMs"]=sendClickedAtMs.map {$0 as Any} ?? NSNull()
        stageElapsedMs[sendStage,default:0] += Int(Date().timeIntervalSince(stageStarted)*1000)
        response["stageElapsedMs"]=stageElapsedMs
        response["sendStage"]=sendStage
        response["axRefreshAttempts"]=axRefreshAttempts
        response["activationAttempts"]=activationAttempts
        response["reusedOwnInsertion"]=reusedOwnInsertion
        response["fullSnapshotReads"]=fullSnapshotReads;response["lightSnapshotReads"]=lightSnapshotReads
        response["preClickDeadlineMs"]=preClickDeadlineMs.map {$0 as Any} ?? NSNull()
        response["confirmationAXValueFailures"]=confirmationAXValueFailures
        response["postClickComposerPreserved"]=clickIntent && payload["sent"] as? Bool != true
        if payload["sent"] as? Bool == true {self.unknownInsertedReply=nil}
        response["clickDispatched"]=clickIntent
        response["foregroundPid"]=NSWorkspace.shared.frontmostApplication?.processIdentifier as Any? ?? NSNull()
        response["foregroundBundleId"]=NSWorkspace.shared.frontmostApplication?.bundleIdentifier as Any? ?? NSNull()
        // Every pre-click exit after our insertion must release only our own
        // unchanged text. Never clean an ambiguous post-click transaction.
        if !clickIntent, payload["sent"] as? Bool != true, let recoverInsertedText {
          response["composerRecovery"] = recoverInsertedText()
        }
        response["expectedCustomer"]=expectedCustomer
        response["activeCustomerId"]=observedCustomer as Any? ?? NSNull()
        response["identitySource"]="ax_header_toolbar"
        DispatchQueue.main.async { completion(response) }
      }
      guard self.allowsAutomation(automationEpoch) else {
        finish(["error": "automation_stopped", "message": "This automation run was stopped; no send was allowed."]); return
      }
      if holdingClickNotBeforeMs != nil, holding == nil {
        finish(["error": "invalid_holding_send_window", "message": "The holding click window was invalid. Nothing was inserted or clicked."]); return
      }
      if holding?.yieldRequested == true {
        finish(["error": "holding_yielded_to_formal", "message": "The untouched holding reply yielded before preparation."]); return
      }
      guard ProcessInfo.processInfo.systemUptime<preClickDeadline else {
        finish(["error":"send_preclick_budget_exceeded","message":"The shared UI deadline expired in the native queue; no UI action was started."]);return
      }
      guard self.writeDeliveryReceipt(receiptPath, attemptId: attemptId, customer: expectedCustomer, state: "prepared") else {
        finish(["error": "send_receipt_unavailable", "message": "The durable send journal could not be prepared; nothing was inserted."]); return
      }
      let expected = expectedCustomer.trimmingCharacters(in: .whitespacesAndNewlines)
      let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !expected.isEmpty, !text.isEmpty else {
        finish(["error": "invalid_send_request", "message": "Expected customer and reply are required."])
        return
      }
      guard AXIsProcessTrusted(), let pid = runningPID() else {
        finish(["error": "jd_unavailable", "message": "JD 咚咚 or Accessibility access is unavailable."])
        return
      }
      guard mediaPaths.isEmpty else {
        finish(["error": "outbound_media_disabled",
                "message": "JD automation is text-only; photos, videos, and files are disabled."])
        return
      }
      let allowedExtensions = Set(["png", "jpg", "jpeg", "webp", "gif", "mp4", "mov"])
      let requestedMedia = Array(mediaPaths.prefix(3)).map {
        URL(fileURLWithPath: $0).standardizedFileURL
      }
      guard requestedMedia.count == mediaPaths.count,
            requestedMedia.allSatisfy({
              FileManager.default.fileExists(atPath: $0.path) &&
                allowedExtensions.contains($0.pathExtension.lowercased())
            }) else {
        finish(["error": "invalid_media_attachment",
                "message": "One or more approved media files are missing, unsupported, or exceed the three-file limit."])
        return
      }

      var baseline:[AXNode]?
      func scopedNodes() -> [AXNode]? {
        let limit=clickIntent ? (postClickDeadline ?? ProcessInfo.processInfo.systemUptime+3):preClickDeadline
        guard ProcessInfo.processInfo.systemUptime<limit else {return nil}
        var nodes:[AXNode]?
        if let saved=baseline,let fresh=self.freshSendNodes(saved,deadline:limit) {
          nodes=fresh;lightSnapshotReads+=1
        } else {
          fullSnapshotReads+=1;nodes=self.receptionNodes(pid:pid,deadline:limit)
        }
        nodes=jdRefreshSendSnapshot(initial:nodes,expected:expected,
          canRefresh:{!clickIntent && ProcessInfo.processInfo.systemUptime<limit && self.allowsAutomation(automationEpoch) && NSWorkspace.shared.frontmostApplication?.processIdentifier==pid},
          identity:{self.activeCustomerIdentity(nodes:$0)},
          ready:{$0.contains(where:{$0.role==kAXTextAreaRole as String})},
          read:{axRefreshAttempts+=1;fullSnapshotReads+=1;return self.receptionNodes(pid:pid,deadline:limit)},
          now:{ProcessInfo.processInfo.systemUptime},pause:{usleep(30_000)})
        if let nodes {baseline=nodes}
        observedCustomer=nodes.flatMap {self.activeCustomerIdentity(nodes:$0)}
        return nodes
      }

      guard jdSendMediaContextCurrent(path:mediaGuardPath,customer:expectedCustomer,revision:mediaRevision) else {
        finish(["error":"media_context_changed","message":"Media changed before insertion; regenerate the unsent reply."]);return
      }
      guard let opened = scopedNodes(), activeCustomerMatches(expected, nodes: opened) else {
        finish(["error": "expected_conversation_missing",
                "message": "The exact active JD customer \(expected) was not verified; nothing was inserted or sent."])
        return
      }

      if requireRedClock {
        guard let red = self.activeCustomerHasRedClock(expectedCustomer:expected,pid:pid,nodes:baseline,deadline:clickIntent ? postClickDeadline:preClickDeadline) else {
          finish(["error":"red_clock_unavailable","message":"Could not verify the current customer's red clock; holding was not sent."]); return
        }
        guard red else {
          finish(["error":"red_clock_cleared","message":"The red clock has cleared; holding was not sent."]); return
        }
      }
      if let reason = self.deliveryBlockReason(opened) {
        finish(["error": reason, "message": "JD currently blocks replies to this customer; the draft was preserved."])
        return
      }
      guard CGPreflightScreenCaptureAccess() else {
        finish(["error": "send_confirmation_unavailable", "message": "Screen recording permission is required to detect JD rejection markers; nothing was inserted."])
        return
      }
      guard var composer = opened.first(where: { $0.role == kAXTextAreaRole as String }) else {
        finish(["error": "pre_insert_verification_failed",
                "message": "Could not verify \(expected) and its composer after opening the chat."])
        return
      }
      guard let beforeRecovery=stringAttribute(composer.element,kAXValueAttribute) else {
        finish(["error":"composer_ax_value_unavailable","message":"The composer value could not be read; no insertion was allowed."]);return
      }
      if let unknown=self.unknownInsertedReply,unknown.pid==pid,exactCustomerIdentityMatches(unknown.customer,expected),!beforeRecovery.isEmpty {
        finish(["error":"composer_has_unconfirmed_reply","message":"A prior clicked reply still occupies this composer; it was preserved for reconciliation."]);return
      }
      if let own = self.unsentInsertedReply, own.pid == pid,
        exactCustomerIdentityMatches(own.customer,expected),
        Array(own.text.utf8) == Array(text.utf8),
        jdMayClearInsertedReply(expected:expected,active:observedCustomer,
          inserted:own.text,current:beforeRecovery,clicked:false) {
        reusedOwnInsertion = true
      } else { _ = self.recoverOwnUnsentReply(nodes:opened,pid:pid) }
      guard let existingValue=stringAttribute(composer.element,kAXValueAttribute) else {
        finish(["error":"composer_ax_value_unavailable","message":"The composer value became unreadable; nothing was inserted."]);return
      }
      let existing=existingValue.trimmingCharacters(in:.whitespacesAndNewlines)
      guard existing.isEmpty || reusedOwnInsertion else {
        finish(["error": "composer_not_empty",
                "message": "JD's composer already contains text. It was left unchanged."])
        return
      }
      // AX identity is independent of keyboard/mouse focus. Confirm activation
      // BEFORE inserting, so delayed/denied activation cannot strand a reply.
      enterSendStage("activation")
      func prepareForeground() -> String? {
        guard ProcessInfo.processInfo.systemUptime<preClickDeadline else { return "send_preclick_budget_exceeded" }
        let preparation=jdPrepareSendForeground(expectedPID:pid,
          running:{ self.allowsAutomation(automationEpoch) },
          foreground:{ NSWorkspace.shared.frontmostApplication?.processIdentifier },
          activate:{
            activationAttempts += 1
            DispatchQueue.main.sync {
              _ = NSRunningApplication(processIdentifier:pid)?.activate(options:[.activateIgnoringOtherApps])
            }
          },deadline:preClickDeadline)
        if let preparation {return preparation}
        guard let current=baseline else {return "send_reception_not_frontmost"}
        // Never raise the reception over another JD modal or write behind it.
        return self.receptionHasFocus(pid:pid,nodes:current) ? nil:"send_reception_not_frontmost"
      }
      if let reason = prepareForeground() {
        finish(["error":reason,"message":"JD foreground was not ready before insertion.",
          "activationAttempts":activationAttempts]); return
      }
      enterSendStage("insertion")
      // Check the fresh AX identity and composer again immediately before writing.
      guard self.allowsAutomation(automationEpoch), let preInsert = scopedNodes(),
        activeCustomerMatches(expected, nodes: preInsert),
        let freshComposer = preInsert.first(where: { $0.role == kAXTextAreaRole as String }),
        let freshValue = stringAttribute(freshComposer.element,kAXValueAttribute),
        (freshValue.isEmpty || (reusedOwnInsertion && Array(freshValue.utf8) == Array(text.utf8))) else {
        finish(["error":"pre_insert_verification_failed","message":"Customer or composer changed before insertion; nothing was inserted."]); return
      }
      composer = freshComposer
      if holding?.yieldRequested == true {
        finish(["error": "holding_yielded_to_formal", "message": "The holding reply yielded before typing."]); return
      }
      func clearOwnInsertedText() -> Bool {
        guard let current = scopedNodes(), self.activeCustomerMatches(expected,nodes:current),
          let field=current.first(where: { $0.role == kAXTextAreaRole as String }),
          stringAttribute(field.element,kAXValueAttribute) == text else { return false }
        var settable=DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(field.element,kAXValueAttribute as CFString,&settable) == .success &&
          settable.boolValue && AXUIElementSetAttributeValue(field.element,kAXValueAttribute as CFString,"" as CFTypeRef) == .success
      }
      var insertedByThisAttempt = false
      recoverInsertedText = {
        guard insertedByThisAttempt else { return "not_inserted" }
        // The send deadline forbids further clicks. A separate 250ms cleanup
        // may only re-read existing AX elements and clear our exact unsent
        // text. It never starts another full traversal or touches unknown input.
        guard let saved=baseline,
          let current=self.freshSendNodes(saved,deadline:ProcessInfo.processInfo.systemUptime+0.25) else {return "ax_unavailable"}
        return self.recoverOwnUnsentReply(nodes:current, pid:pid)
      }
      if requestedMedia.isEmpty {
        if !reusedOwnInsertion {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(composer.element, kAXValueAttribute as CFString, &settable) == .success,
              settable.boolValue,
              AXUIElementSetAttributeValue(composer.element, kAXValueAttribute as CFString, text as CFTypeRef) == .success else {
          finish(["error": "composer_not_settable",
                  "message": "JingMai did not allow safe AX insertion; nothing was sent."])
          return
        }
        }
        insertedByThisAttempt = true
        self.unsentInsertedReply = (pid:pid, customer:expected, text:text)
      } else {
        // Qianniu's rich composer does not expose image insertion through AX.
        // Paste only caller-verified local files, then append the reply text.
        // Preserve the user's clipboard and verify the expected conversation
        // throughout the operation.
        _ = NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateIgnoringOtherApps])
        usleep(180_000)
        _ = AXUIElementSetAttributeValue(composer.element, kAXFocusedAttribute as CFString,
                                         kCFBooleanTrue)
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard)
        defer { snapshot.restore(to: pasteboard) }
        let beforePaste = composerVisualFingerprint(pid: pid, frame: composer.frame)
        for mediaURL in requestedMedia {
          pasteboard.clearContents()
          let inserted: Bool
          if ["png", "jpg", "jpeg", "webp", "gif"].contains(mediaURL.pathExtension.lowercased()),
             let image = NSImage(contentsOf: mediaURL) {
            inserted = pasteboard.writeObjects([image])
          } else {
            inserted = pasteboard.writeObjects([mediaURL as NSURL])
          }
          guard inserted, postCommandV() else {
            finish(["error": "media_paste_failed",
                    "message": "JingMai did not accept an approved media attachment; nothing was sent."])
            return
          }
          usleep(550_000)
          guard let current = scopedNodes(), activeCustomerMatches(expected, nodes: current) else {
            finish(["error": "media_customer_verification_failed",
                    "message": "The active customer changed while inserting media; nothing was sent."])
            return
          }
        }
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string), postCommandV() else {
          finish(["error": "reply_paste_failed",
                  "message": "The reply text could not be appended after media; nothing was sent."])
          return
        }
        usleep(350_000)
        let afterPaste = composerVisualFingerprint(pid: pid, frame: composer.frame)
        guard beforePaste != nil, afterPaste != nil, beforePaste != afterPaste else {
          finish(["error": "media_insert_unverified",
                  "message": "JingMai did not visibly confirm the media insertion; nothing was sent."])
          return
        }
      }

      enterSendStage("inserted_text_verification")
      guard let verified = scopedNodes(), activeCustomerMatches(expected, nodes: verified),
            let verifiedComposer = verified.first(where: { $0.role == kAXTextAreaRole as String }),
            (requestedMedia.isEmpty
              ? stringAttribute(verifiedComposer.element, kAXValueAttribute) == text
              : true),
            let send = verified.first(where: {
              ($0.role == kAXButtonRole as String || $0.role == kAXMenuButtonRole as String) &&
                $0.title == "发送"
            }), send.frame != nil else {
        _ = clearOwnInsertedText()
        finish(["error": "pre_send_verification_failed",
                "message": "Customer, inserted text, or Send control verification failed. Only the verified customer's unchanged inserted text may be cleared."])
        return
      }

      if let holding {
        enterSendStage("holding_wait_until_due")
        if let reason = holding.waitUntilDue(now: { ProcessInfo.processInfo.systemUptime },
          runCurrent: { self.allowsAutomation(automationEpoch) },
          pause: { usleep(useconds_t(max(1, $0 * 1_000_000))) }) {
          finish(["error": reason, "message": "The holding reply did not reach the final click check."]); return
        }
      }

      // A coordinate click is used only after bringing Qianniu frontmost and
      // re-verifying the exact customer and composer state.
      enterSendStage("final_customer_verification")
      guard let finalNodes = scopedNodes(), activeCustomerMatches(expected, nodes: finalNodes) else {
        finish(["error": "final_customer_verification_failed",
                "message": "The expected customer was no longer active; nothing was sent."])
        return
      }
      if let reason = self.deliveryBlockReason(finalNodes) {
        _ = clearOwnInsertedText()
        finish(["error": reason, "message": "JD reception changed before Send; nothing was sent."])
        return
      }
      enterSendStage("final_click_verification")
      // Keep every safety gate, but report the actual failed gate. A matching
      // AX header does not imply foreground/composer/Send readiness.
      guard self.allowsAutomation(automationEpoch) else {
        finish(["error":"automation_stopped","message":"Stopped after insertion; nothing was clicked."]); return
      }
      // A single in-place focus recovery retains the verified inserted reply.
      // Do not reopen a chat or wait for the next ten-second retry to send it.
      if let reason = prepareForeground() {
        finish(["error":reason,"message":"Foreground could not be restored before Send.",
          "activationAttempts":activationAttempts]); return
      }
      let renderDeadline = ProcessInfo.processInfo.systemUptime + 0.5
      var readyNodes = scopedNodes()
      while let current = readyNodes,
        self.allowsAutomation(automationEpoch),
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
        activeCustomerMatches(expected,nodes:current),
        let field = current.first(where:{ $0.role == kAXTextAreaRole as String }),
        stringAttribute(field.element,kAXValueAttribute) == text,
        !current.contains(where:{ ($0.role == kAXButtonRole as String || $0.role == kAXMenuButtonRole as String) &&
          $0.title == "发送" && boolAttribute($0.element,kAXEnabledAttribute) != false && $0.frame != nil }),
        ProcessInfo.processInfo.systemUptime < renderDeadline {
        usleep(50_000); readyNodes=scopedNodes()
      }
      guard self.allowsAutomation(automationEpoch) else {
        finish(["error":"automation_stopped","message":"Stopped while Send was settling."]); return
      }
      guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
        finish(["error":"send_not_frontmost","message":"Foreground changed during final Send verification."]); return
      }
      guard let clickNodes = readyNodes else {
        finish(["error":"send_ax_unavailable","message":"Fresh AX snapshot unavailable before Send."]); return
      }
      guard activeCustomerMatches(expected, nodes:clickNodes) else {
        finish(["error":"final_customer_verification_failed","message":"Fresh AX customer changed before Send."]); return
      }
      guard let clickComposer = clickNodes.first(where: { $0.role == kAXTextAreaRole as String }) else {
        finish(["error":"send_composer_missing","message":"Composer disappeared before Send."]); return
      }
      guard stringAttribute(clickComposer.element,kAXValueAttribute) == text else {
        finish(["error":"send_composer_changed","message":"Composer text changed before Send; preserve external edits."]); return
      }
      guard let clickSend = clickNodes.first(where: {
        ($0.role == kAXButtonRole as String || $0.role == kAXMenuButtonRole as String) && $0.title == "发送"
      }) else {
        finish(["error":"send_button_missing","message":"Exact Send button disappeared."]); return
      }
      guard boolAttribute(clickSend.element,kAXEnabledAttribute) != false else {
        finish(["error":"send_button_disabled","message":"Send button became disabled."]); return
      }
      guard let clickFrame = clickSend.frame, clickFrame.width > 0, clickFrame.height > 0 else {
        finish(["error":"send_button_frame_missing","message":"Fresh Send button geometry unavailable."]); return
      }
      let point=CGPoint(x:clickFrame.midX,y:clickFrame.midY)
      guard let down=CGEvent(mouseEventSource:nil,mouseType:.leftMouseDown,mouseCursorPosition:point,mouseButton:.left),
        let up=CGEvent(mouseEventSource:nil,mouseType:.leftMouseUp,mouseCursorPosition:point,mouseButton:.left) else {
        finish(["error":"send_click_failed","message":"Could not create the verified Send event."]); return
      }
      guard jdSendMediaContextCurrent(path:mediaGuardPath,customer:expectedCustomer,revision:mediaRevision) else {
        finish(["error":"media_context_changed","message":"Media changed before click; nothing was sent."]);return
      }
      if requireRedClock {
        guard let red = self.activeCustomerHasRedClock(expectedCustomer:expected,pid:pid,nodes:baseline,deadline:clickIntent ? postClickDeadline:preClickDeadline) else {
          finish(["error":"red_clock_unavailable","message":"Could not verify the current customer's red clock; holding was not sent."]); return
        }
        guard red else {
          finish(["error":"red_clock_cleared","message":"The red clock has cleared; holding was not sent."]); return
        }
      }
      guard ProcessInfo.processInfo.systemUptime<preClickDeadline else {
        finish(["error":"send_preclick_budget_exceeded","message":"The shared pre-click UI budget expired; nothing was clicked."]);return
      }
      guard self.receptionHasFocus(pid:pid,nodes:clickNodes) else {
        finish(["error":"send_reception_not_frontmost","message":"A different JD window or modal owns focus; nothing was clicked."]);return
      }
      if holding?.yieldRequested == true {
        finish(["error": "holding_yielded_to_formal", "message": "The holding reply yielded before click intent."]); return
      }
      clickIntent = true
      guard self.writeDeliveryReceipt(receiptPath, attemptId: attemptId, customer: expected, state: "click_intent") else {
        clickIntent = false
        finish(["error": "send_receipt_unavailable", "message": "Could not persist click intent; nothing was clicked."]); return
      }
      guard ProcessInfo.processInfo.systemUptime<preClickDeadline,self.allowsAutomation(automationEpoch) else {
        clickIntent=false
        finish(["error":"send_preclick_budget_exceeded","message":"The shared budget/run ended before dispatch; nothing was clicked."]);return
      }
      func dispatchClick() {
        self.unsentInsertedReply = nil
        self.unknownInsertedReply=(pid:pid,customer:expected,text:text)
        enterSendStage("click_dispatched")
        down.post(tap: .cghidEventTap)
        sendClickedAtMs=Int64(Date().timeIntervalSince1970*1000)
        up.post(tap: .cghidEventTap)
      }
      if let holding {
        if let reason = self.commitHoldingClick(holding, dispatch: dispatchClick) {
          clickIntent = false
          finish(["error": reason, "message": "The holding click was canceled before dispatch."]); return
        }
      } else {
        dispatchClick()
      }
      self.writeDeliveryReceipt(receiptPath, attemptId: attemptId, customer: expected, state: "clicked",sendClickedAtMs:sendClickedAtMs)
      if let attemptId { self.automationLock.lock(); self.latestSendAttempt[expected] = attemptId; self.automationLock.unlock() }

      // A dispatched click has an uncertain outcome until successful reads
      // positively prove an empty composer. Missing AXValue is never empty.
      postClickDeadline=ProcessInfo.processInfo.systemUptime+3
      var lastComposerText:String?
      repeat {
        usleep(150_000)
        guard self.allowsAutomation(automationEpoch) else {break}
        guard let after=scopedNodes(),activeCustomerMatches(expected,nodes:after),
          let field=after.first(where:{$0.role==kAXTextAreaRole as String}) else {
          if let actual=observedCustomer,!exactCustomerIdentityMatches(actual,expected) {break}
          continue
        }
        let reading=jdSendComposerReading(stringAttribute(field.element,kAXValueAttribute))
        switch reading {
        case .unreadable:confirmationAXValueFailures+=1;continue
        case .text(let value):lastComposerText=value;continue
        case .empty:break
        }
        usleep(250_000)
        guard let settled=scopedNodes(),activeCustomerMatches(expected,nodes:settled),
          let settledComposer=settled.first(where:{$0.role==kAXTextAreaRole as String}) else {continue}
        let settledReading=jdSendComposerReading(stringAttribute(settledComposer.element,kAXValueAttribute))
        guard settledReading == .empty else {
          if settledReading == .unreadable {confirmationAXValueFailures+=1};continue
        }
        let rejection=self.outgoingFailureSnapshot(settled,pid:pid)
        if let failed=rejection.failure {
          finish(["error":"send_platform_rejected","message":"JD shows a failed outgoing bubble after Send. The draft remains queued.","rejectedFingerprint":failed.fingerprint]);return
        }
        if let reason=self.deliveryBlockReason(settled) {
          finish(["error":reason,"message":"JD blocked the reply after submission; the draft remains queued."]);return
        }
        guard rejection.available else {break}
        if let attemptId,let receiptPath {self.observeLateRejection(expected:expected,attemptId:attemptId,receiptPath:receiptPath,pid:pid)}
        let redAfter=self.activeCustomerHasRedClock(expectedCustomer:expected,pid:pid,nodes:settled,deadline:postClickDeadline)
        finish(["sent":true,"customer":expected,"reply":text,
          "redClockPresentAfterSend":redAfter.map {$0 as Any} ?? NSNull(),
          "redClockObservedAtMs":Int64(Date().timeIntervalSince1970*1000),
          "confirmation":"composer_readable_and_empty_twice_no_visible_rejection","mediaCount":requestedMedia.count]);return
      } while ProcessInfo.processInfo.systemUptime<(postClickDeadline ?? 0)
      finish(["error":"send_unconfirmed", "message":"Send was dispatched but could not be confirmed. The composer, draft and click journal were preserved; no automatic retyping is authorized.",
        "composerStillMatchesReply":lastComposerText==text])
    }
  }

  private func observeLateRejection(expected: String, attemptId: String, receiptPath: String, pid: pid_t) {
    // Read-only follow-up. Never reopen/switch a customer or click during this
    // watch. A later marker is uncertainty, not proof to retype a fresh reply.
    for delay in [1.0, 3.0, 8.0] {
      receiptWatchQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
        guard let self else { return }
        self.automationLock.lock(); let latest = self.latestSendAttempt[expected]; self.automationLock.unlock()
        guard latest == attemptId,
              let nodes = self.receptionNodes(pid: pid), self.activeCustomerMatches(expected, nodes: nodes) else { return }
        if self.outgoingFailureSnapshot(nodes, pid: pid).failure != nil {
          self.writeDeliveryReceipt(receiptPath, attemptId: attemptId, customer: expected,
            state: "late_rejection_uncertain", error: "visible_rejection_requires_attribution")
          self.automationLock.lock(); self.latestSendAttempt.removeValue(forKey: expected); self.automationLock.unlock()
        }
      }
    }
  }

  /// Called only after the background OCR pass found an existing red icon.
  /// Normal sends retain their original serial queue and verification routine.
  func retryFailedOutgoingMessage(expectedCustomer: String,
      candidate: [String: Any], automationEpoch: Int? = nil, completion: @escaping FlutterResult) {
    queue.async { [weak self] in
      guard let self else { return }
      func finish(_ payload: [String: Any]) { DispatchQueue.main.async { completion(payload) } }
      let expected = expectedCustomer.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !expected.isEmpty, AXIsProcessTrusted(), CGPreflightScreenCaptureAccess(),
            let pid = self.runningPID(),
            NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
            let x = candidate["x"] as? Double, let y = candidate["y"] as? Double,
            let left = candidate["left"] as? Double, let top = candidate["top"] as? Double,
            let width = candidate["width"] as? Double, let height = candidate["height"] as? Double,
            [x, y, left, top, width, height].allSatisfy({ $0.isFinite }),
            width > 0, height > 0,
            let fingerprint = candidate["fingerprint"] as? String, !fingerprint.isEmpty,
            let windowID = candidate["windowId"] as? NSNumber else {
        finish(["retried": false]); return
      }
      let point = CGPoint(x: x, y: y)
      let frame = CGRect(x: left, y: top, width: width, height: height)
      let key = sha256(expected + "\u{1f}" + fingerprint)
      let previous = self.failedSendRetries[key]
      if let previous, previous.next > Date() { finish(["retried": false]); return }
      func snapshot() -> [AXNode]? {
        var nodes: [AXNode] = []
        self.walk(AXUIElementCreateApplication(pid), path: "app", depth: 0,
            maxDepth: 22, maxNodes: 5_000) { node, _ in nodes.append(node) }
        guard let window = nodes.first(where: {
          $0.role == kAXWindowRole as String && $0.title?.contains("咚咚融合工作台") == true
        }) else { return nil }
        return nodes.filter { $0.path == window.path || $0.path.hasPrefix(window.path + "/") }
      }
      func safeToClick(_ nodes: [AXNode]) -> Bool {
        guard self.allowsAutomation(automationEpoch), self.activeCustomerMatches(expected, nodes: nodes),
              self.deliveryBlockReason(nodes) == nil,
              !nodes.contains(where: { $0.role == kAXSheetRole as String ||
                $0.subrole == "AXDialog" || $0.subrole == "AXSystemDialog" }),
              let composer = nodes.first(where: { $0.role == kAXTextAreaRole as String }),
              let composerFrame = composer.frame,
              (stringAttribute(composer.element, kAXValueAttribute) ?? "").isEmpty,
              let split = nodes.filter({ $0.role == kAXSplitGroupRole as String &&
                composer.path.hasPrefix($0.path + "/") }).max(by: { $0.path.count < $1.path.count }),
              let chat = split.frame else { return false }
        return chat.contains(point) && chat.contains(frame) && frame.maxY < composerFrame.minY
      }
      guard let nodes = snapshot(), safeToClick(nodes),
            let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
              as? [[String: Any]],
            let row = rows.first(where: {
              ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID.uint32Value &&
              ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
            }),
            let raw = row[kCGWindowBounds as String] as? [String: Any],
            let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary),
            bounds.contains(frame),
            let image = CGWindowListCreateImage(.null, .optionIncludingWindow,
                CGWindowID(windowID.uint32Value), [.boundsIgnoreFraming, .bestResolution]) else {
        finish(["retried": false]); return
      }
      // Revalidate only the candidate's small region, not the entire chat.
      let region = frame.union(CGRect(x: point.x - 24, y: point.y - 24, width: 48, height: 48))
        .insetBy(dx: -8, dy: -8).intersection(bounds)
      guard failedSendBubbles(image: image, windowBounds: bounds, chatFrame: region).contains(where: {
        $0.fingerprint == fingerprint &&
        abs($0.point.x - point.x) < 2 && abs($0.point.y - point.y) < 2
      }), let finalNodes = snapshot(), safeToClick(finalNodes),
         NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
        finish(["retried": false]); return
      }
      let visible = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
        as? [[String: Any]] ?? []
      let owner = visible.first { row in
        guard let raw = row[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary) else { return false }
        return bounds.contains(point)
      }?[kCGWindowOwnerPID as String] as? NSNumber
      guard self.allowsAutomation(automationEpoch), owner?.int32Value == pid, postClick(at: point) else {
        finish(["retried": false]); return
      }
      let attempts = previous?.attempts ?? 0
      self.failedSendRetries[key] = (attempts + 1,
          Date().addingTimeInterval(failedSendRetryDelay(attempts: attempts)))
      // Icon disappearance is not proof of delivery. The regular OCR capture
      // reconciles a matching bubble only after JD exposes its receipt.
      finish(["retried": true, "customer": expected])
    }
  }

  /// Hashes the visible composer before and after paste. This does not inspect
  /// customer media content; it only proves that Qianniu visibly changed the
  /// verified composer before the single Send action is allowed.
  private func composerVisualFingerprint(pid: pid_t, frame: CGRect?) -> String? {
    guard let frame, CGPreflightScreenCaptureAccess(),
          let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
            as? [[String: Any]] else { return nil }
    for row in rows where (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid {
      guard let number = row[kCGWindowNumber as String] as? NSNumber,
            let dictionary = row[kCGWindowBounds as String] as? [String: Any],
            let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
            bounds.intersects(frame),
            let image = CGWindowListCreateImage(.null, .optionIncludingWindow,
                                                CGWindowID(number.uint32Value),
                                                [.boundsIgnoreFraming, .bestResolution]) else { continue }
      let scaleX = CGFloat(image.width) / max(bounds.width, 1)
      let scaleY = CGFloat(image.height) / max(bounds.height, 1)
      let local = CGRect(x: (frame.minX - bounds.minX) * scaleX,
                         y: (frame.minY - bounds.minY) * scaleY,
                         width: frame.width * scaleX,
                         height: frame.height * scaleY).integral
        .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
      guard local.width >= 20, local.height >= 20,
            let crop = image.cropping(to: local),
            let data = NSBitmapImageRep(cgImage: crop)
              .representation(using: .png, properties: [:]) else { continue }
      return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    return nil
  }

  private func hasActiveCustomerHeader(_ nodes: [AXNode]) -> Bool {
    nodes.contains { node in
      node.role == kAXButtonRole as String &&
      [node.title, node.description, node.value].compactMap { $0 }.contains {
        ["拨打电话", "举报与拉黑", "⌃R快捷转接"].contains($0)
      }
    }
  }

  private func activeCustomerMatches(_ expected: String, nodes: [AXNode]) -> Bool {
    guard let actual = activeCustomerIdentity(nodes: nodes) else { return false }
    return exactCustomerIdentityMatches(actual, expected)
  }

  /// Reads the signed-in service account from the reception window's account
  /// header. This label is exposed by AX even though transfer rows are not.
  private func currentServiceAccount(in reception: AXNode,
                                     nodes: [AXNode],
                                     excluding customer: String) -> String {
    guard let window = reception.frame else { return "当前客服账号" }
    let ignored = ["接待", "未授权", "搜索", "官方", "联系人", "工具", "数据", "待办"]
    let candidates = nodes.compactMap { node -> (String, CGRect)? in
      guard node.role == kAXStaticTextRole as String,
            let text = node.text?.trimmingCharacters(in: .whitespacesAndNewlines),
            let frame = node.frame,
            !text.isEmpty, text.count >= 2, text.count <= 40,
            !exactCustomerIdentityMatches(text, customer),
            !ignored.contains(where: { text == $0 || text.hasPrefix($0 + " ") }),
            frame.minX >= window.minX,
            frame.maxX <= window.minX + window.width * 0.32,
            frame.minY >= window.minY,
            frame.maxY <= window.minY + 115 else { return nil }
      return (text, frame)
    }
    return candidates.sorted {
      if abs($0.1.minY - $1.1.minY) > 2 { return $0.1.minY < $1.1.minY }
      return $0.1.minX < $1.1.minX
    }.first?.0 ?? "当前客服账号"
  }

  func inspectTree(maxDepth: Int) -> [String: Any] {
    guard AXIsProcessTrusted() else { return ["error": "accessibility_not_trusted", "tree": "Grant Accessibility access, then retry."] }
    guard let pid = runningPID() else { return ["error": "jd_not_running", "tree": "JD 咚咚工作台 is not running."] }
    let app = AXUIElementCreateApplication(pid)
    var lines: [String] = ["bundle=\(bundleIdentifier) pid=\(pid)"]
    var count = 0
    walk(app, path: "app", depth: 0, maxDepth: min(maxDepth, 30), maxNodes: 4_000) { node, depth in
      count += 1
      lines.append(String(repeating: "  ", count: depth) + describe(node))
    }
    let output = lines.joined(separator: "\n")
    return ["pid": Int(pid), "nodeCount": count, "tree": output]
  }

  private func runningPID() -> pid_t? {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
      .first(where: { !$0.isTerminated })?.processIdentifier
  }

  /// Traverse only Dingdong's reception window. Walking every JD window at
  /// each verification multiplies capture and send latency. Resolve the
  /// window afresh each time; never cache the active customer for sending.
  private func receptionNodes(pid: pid_t,deadline:TimeInterval?=nil) -> [AXNode]? {
    let remaining=deadline.map { $0-ProcessInfo.processInfo.systemUptime } ?? 1.5
    guard remaining>0 else { return nil }
    let budget=min(1.5,remaining)
    let root = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(root,Float(min(0.15,budget)))
    if let window = elementArrayAttribute(root, kAXWindowsAttribute).first(where: {
      stringAttribute($0, kAXTitleAttribute)?.contains("咚咚融合工作台") == true
    }) {
      var nodes: [AXNode] = []
      let complete = walk(window, path: "app/reception", depth: 0,
          maxDepth: 22, maxNodes: 5_000, timeBudget: budget) {
        node, _ in nodes.append(node)
      }
      return complete ? nodes : nil
    }
    // Preserve support for JD builds that omit AXWindows.
    var nodes: [AXNode] = []
    let complete = walk(root, path: "app", depth: 0, maxDepth: 22,
        maxNodes: 5_000, timeBudget: budget) {
      node, _ in nodes.append(node)
    }
    guard complete, let window = nodes.first(where: {
      $0.role == kAXWindowRole as String &&
        ($0.title?.contains("咚咚融合工作台") == true)
    }) else { return nil }
    return nodes.filter { $0.path == window.path || $0.path.hasPrefix(window.path + "/") }
  }

  private func freshSendNodes(_ baseline:[AXNode],deadline:TimeInterval)->[AXNode]? {
    guard ProcessInfo.processInfo.systemUptime<deadline,
      let composer=baseline.first(where:{$0.role==kAXTextAreaRole as String}),let composerFrame=composer.frame,
      let split=baseline.filter({$0.role==kAXSplitGroupRole as String && composer.path.hasPrefix($0.path+"/")}).max(by:{$0.path.count<$1.path.count}),let chat=split.frame else { return nil }
    var refreshed=[AXNode](),parents=[String:[AXUIElement]]()
    let byPath=Dictionary(uniqueKeysWithValues:baseline.map {($0.path,$0)})
    for node in baseline {
      let structural=[kAXWindowRole as String,kAXSplitGroupRole as String,kAXTextAreaRole as String,kAXSheetRole as String].contains(node.role)
      let button=node.role==kAXButtonRole as String || node.role==kAXMenuButtonRole as String
      let relevantText=node.role==kAXStaticTextRole as String && node.frame.map { f in
        f.minX>=chat.minX && f.maxX<=chat.maxX &&
          ((f.minY>=chat.minY-100 && f.maxY<=chat.minY+70) || f.minY>=composerFrame.minY-24)
      }==true
      guard structural || button || relevantText else {refreshed.append(node);continue}
      guard ProcessInfo.processInfo.systemUptime<deadline else { return nil }
      AXUIElementSetMessagingTimeout(node.element,Float(min(0.06,max(0.001,deadline-ProcessInfo.processInfo.systemUptime))))
      guard stringAttribute(node.element,kAXRoleAttribute)==node.role else { return nil }
      let frame=frameAttribute(node.element)
      if structural && (frame==nil || frame != node.frame) { return nil }
      if let slash=node.path.lastIndex(of:"/") {
        let parentPath=String(node.path[..<slash])
        if let parent=byPath[parentPath] {
          let children=parents[parentPath] ?? elementArrayAttribute(parent.element,kAXChildrenAttribute)
          parents[parentPath]=children
          guard children.count==parent.children.count,
            parent.children.allSatisfy({old in children.contains(where:{CFEqual(old,$0)})}),
            children.contains(where:{CFEqual(node.element,$0)}) else {return nil}
        }
      }
      refreshed.append(AXNode(element:node.element,path:node.path,role:node.role,subrole:stringAttribute(node.element,kAXSubroleAttribute),
        identifier:node.identifier,title:stringAttribute(node.element,kAXTitleAttribute),
        description:stringAttribute(node.element,kAXDescriptionAttribute),value:stringAttribute(node.element,kAXValueAttribute),
        help:node.help,frame:frame,actions:node.actions,children:node.children))
    }
    return ProcessInfo.processInfo.systemUptime<deadline ? refreshed:nil
  }

  private func receptionHasFocus(pid:pid_t,nodes:[AXNode])->Bool {
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier==pid,
      let window=nodes.first(where:{$0.role==kAXWindowRole as String && ($0.title?.contains("咚咚融合工作台")==true)}),let expected=window.frame else {return false}
    let app=AXUIElementCreateApplication(pid);AXUIElementSetMessagingTimeout(app,0.06)
    var focused:CFTypeRef?
    let result=AXUIElementCopyAttributeValue(app,kAXFocusedWindowAttribute as CFString,&focused)
    if result == .success,let focused,CFGetTypeID(focused)==AXUIElementGetTypeID(),!CFEqual(focused,window.element) {return false}
    // Some Qt versions omit AXFocusedWindow. The first on-screen, normal
    // window of this PID must still be this reception, never a transfer modal.
    guard let raw=CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]],
      let top=raw.first(where:{($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value==pid && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue==0}),
      let dictionary=top[kCGWindowBounds as String] as? [String:Any],
      let actual=CGRect(dictionaryRepresentation:dictionary as CFDictionary) else {return false}
    return jdReceptionWindowMatches(expected:expected,frontmost:actual)
  }

  private func openedReceptionFocus(pid:pid_t,expected:String,nodes:[AXNode],
      allowActivation:Bool,deadline:TimeInterval,automationEpoch:Int?) -> [String:Any] {
    let began=ProcessInfo.processInfo.systemUptime
    var activated=false
    var current=nodes
    func sameReceptionIsTop()->Bool {
      guard !current.contains(where:{$0.role==kAXSheetRole as String || $0.subrole=="AXDialog"}),
        let window=current.first(where:{$0.role==kAXWindowRole as String && $0.title?.contains("咚咚融合工作台")==true}),
        let expectedFrame=window.frame,
        let raw=CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]],
        let top=raw.first(where:{($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value==pid && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue==0}),
        let bounds=top[kCGWindowBounds as String] as? [String:Any],
        let actual=CGRect(dictionaryRepresentation:bounds as CFDictionary) else {return false}
      return jdReceptionWindowMatches(expected:expectedFrame,frontmost:actual)
    }
    let error=jdPrepareOpenReception(allowActivation:allowActivation,deadline:deadline,
      running:{self.allowsAutomation(automationEpoch) && self.runningPID()==pid},
      identityMatches:{
        guard ProcessInfo.processInfo.systemUptime<deadline else {return false}
        current=self.freshSendNodes(current,deadline:deadline) ?? self.receptionNodes(pid:pid,deadline:deadline) ?? []
        return self.activeCustomerMatches(expected,nodes:current)
      },focused:{self.receptionHasFocus(pid:pid,nodes:current)},activationIsSafe:sameReceptionIsTop,
      activate:{
        DispatchQueue.main.sync {
          if self.allowsAutomation(automationEpoch),ProcessInfo.processInfo.systemUptime<deadline,self.runningPID()==pid {
            activated=true
            _ = NSRunningApplication(processIdentifier:pid)?.activate(options:[.activateIgnoringOtherApps])
          }
        }
      })
    var result:[String:Any]=["activationPerformed":activated,"focusRequired":allowActivation,
      "focusVerified":allowActivation && error==nil,"focusElapsedMs":Int((ProcessInfo.processInfo.systemUptime-began)*1000)]
    if let error {
      result["opened"]=false;result["error"]=error
      result["message"]="The exact customer reception did not acquire safe focus; no message was sent."
    }
    return result
  }

  /// Returns the AX split that owns the active conversation and composer.
  /// Its horizontal bounds exclude both the customer sidebar and details
  /// panel, allowing OCR to reject text that belongs to another row.
  /// One AX traversal supplies the mutually consistent identity and geometry.
  func viewportContext() -> (customer: String, frame: CGRect, bottom: CGFloat)? {
    guard AXIsProcessTrusted(), let pid = runningPID(), let nodes = receptionNodes(pid: pid),
          let customer = activeCustomerIdentity(nodes: nodes),
          let composer = nodes.first(where: { $0.role == kAXTextAreaRole as String }),
          let composerFrame = composer.frame,
          let split = nodes.filter({ $0.role == kAXSplitGroupRole as String &&
            composer.path.hasPrefix($0.path + "/") && $0.frame != nil })
            .max(by: { $0.path.count < $1.path.count }), let chat = split.frame else { return nil }
    let transcript = nodes.filter { node in
      guard node.path.hasPrefix(split.path + "/"), node.role == kAXScrollAreaRole as String,
            let frame = node.frame, frame.width >= chat.width * 0.55,
            frame.minX >= chat.minX, frame.maxX <= chat.maxX,
            frame.maxY <= composerFrame.minY + 12 else { return false }
      return true
    }.max(by: { ($0.frame?.height ?? 0) < ($1.frame?.height ?? 0) })
    let top = transcript?.frame?.minY ?? min(chat.maxY, chat.minY + 70)
    let geometry=nodes.compactMap { node->JDTranscriptAXGeometry? in
      guard node.path.hasPrefix(split.path+"/"),let frame=node.frame else {return nil}
      return JDTranscriptAXGeometry(path:node.path,role:node.role,frame:frame,
        labels:[node.title,node.description,node.value,node.help].compactMap{$0})
    }
    let editorTop=jdTranscriptEditorChromeTop(chat:chat,transcriptPath:transcript?.path,
      transcriptFrame:transcript?.frame,composerPath:composer.path,composerFrame:composerFrame,nodes:geometry)
    let bottom=jdTranscriptContentBottom(composerTop:composerFrame.minY,
      scrollBottom:transcript?.frame?.maxY,toolbarTops:[],editorChromeTop:editorTop)
    let viewport = CGRect(x:chat.minX, y:top, width:chat.width, height:max(0,bottom-top))
    return (customer, viewport, bottom)
  }

  func activeChatFrame() -> CGRect? {
    guard AXIsProcessTrusted(), let pid = runningPID(),
          let scoped = receptionNodes(pid: pid) else { return nil }
    guard let composer = scoped.first(where: { $0.role == kAXTextAreaRole as String }) else {
      return nil
    }
    return scoped
      .filter({
        $0.role == kAXSplitGroupRole as String &&
          composer.path.hasPrefix($0.path + "/") && $0.frame != nil
      })
      .max(by: { $0.path.count < $1.path.count })?.frame
  }

  /// Bound OCR to the transcript, excluding the emoji toolbar and composer.
  /// Prefer the accessibility scroll area; its size follows JD's layout.
  func activeMessageBottom() -> CGFloat? {
    guard AXIsProcessTrusted(), let pid = runningPID(),
          let nodes = receptionNodes(pid: pid),
          let composer = nodes.first(where: {
      $0.role == kAXTextAreaRole as String && $0.frame != nil
    }), let composerFrame = composer.frame,
      let split = nodes.filter({
        $0.role == kAXSplitGroupRole as String &&
        composer.path.hasPrefix($0.path + "/") && $0.frame != nil
      }).max(by: { $0.path.count < $1.path.count }),
      let chatFrame = split.frame else { return nil }
    let transcripts = nodes.compactMap { node -> CGRect? in
      guard node.path.hasPrefix(split.path + "/"),
            node.role == kAXScrollAreaRole as String,
            let frame = node.frame,
            frame.width >= chatFrame.width * 0.55,
            frame.minX >= chatFrame.minX,
            frame.maxX <= chatFrame.maxX,
            frame.maxY <= composerFrame.minY + 12 else { return nil }
      return frame
    }
    return transcripts.max(by: { $0.height < $1.height })?.maxY ?? composerFrame.minY
  }

  /// Resolves the complete active JD identity from the AX header toolbar only.
  /// List groups and screenshots are locators, never identity authority.
  func activeCustomerIdentity() -> String? {
    guard AXIsProcessTrusted(), let pid = runningPID(),
          let scoped = receptionNodes(pid: pid) else { return nil }
    return activeCustomerIdentity(nodes: scoped)
  }

  /// A single AX-only identity resolver is shared by capture, opening and send.
  /// The observed JD header places its full name directly above the transfer
  /// toolbar (raw AX fixture: name x408/y132, transfer x408/y156). Sidebar,
  /// transcript, shop labels and truncated text cannot establish identity.
  private func activeCustomerIdentity(nodes scoped: [AXNode], freshValues: Bool = false) -> String? {
    let composers = scoped.filter { $0.role == kAXTextAreaRole as String }
    guard composers.count == 1, let composer = composers.first,
      let split = scoped.filter({ $0.role == kAXSplitGroupRole as String &&
        composer.path.hasPrefix($0.path + "/") && $0.frame != nil })
        .max(by: { $0.path.count < $1.path.count }), let chat = split.frame else { return nil }
    let controls = scoped.filter { node in
      guard node.role == kAXButtonRole as String, node.path.hasPrefix(split.path + "/"),
        let f = node.frame else { return false }
      return f.minX >= chat.minX && f.maxX <= chat.maxX &&
        f.minY >= chat.minY - 100 && f.maxY <= chat.minY + 70
    }
    func hasLabel(_ node: AXNode, _ label: String) -> Bool {
      [node.title,node.value,node.description].compactMap { $0 }.contains(label)
    }
    let transfer = controls.filter { hasLabel($0,"⌃R快捷转接") }
    let anchors = transfer.isEmpty ? controls.filter { hasLabel($0,"拨打电话") } : transfer
    guard anchors.count == 1, let anchor = anchors.first, let toolbar = anchor.frame else { return nil }
    let ignored: Set<String> = ["咨询中","接待中","在线","离线","客户信息","客户详情","客户ID","客户昵称","京东账号","SDK最近联系人入口"]
    var candidates = [String]()
    for node in scoped {
      guard node.role == kAXStaticTextRole as String,
        node.path.hasPrefix(split.path + "/"), let f = node.frame,
        f.minX >= chat.minX && f.maxX <= chat.maxX,
        f.minY >= max(chat.minY - 100,toolbar.minY - 45), f.maxY <= toolbar.minY + 1,
        (transfer.isEmpty ? (f.minX >= toolbar.minX - 36 && f.minX <= toolbar.minX + 2)
          : abs(f.minX - toolbar.minX) <= 2),
        let text = (freshValues ? [stringAttribute(node.element,kAXValueAttribute),stringAttribute(node.element,kAXDescriptionAttribute),stringAttribute(node.element,kAXTitleAttribute)] : [node.value,node.description,node.title]).compactMap { $0?.trimmingCharacters(in:.whitespacesAndNewlines) }.first(where: { !$0.isEmpty }),
        !ignored.contains(text), !text.contains("\n"), !text.contains("\r"),
        !text.contains("…"), !text.contains("..."),
        let identity = cleanedRowCustomerIdentity(text), identity == text else { continue }
      candidates.append(identity)
    }
    let unique = Set(candidates.map { Data($0.utf8) })
    return unique.count == 1 ? candidates.first : nil
  }

  func conversationIdentities() -> [String] {
    conversationRows().compactMap { $0["customer"] as? String }
  }

  /// Launches Qianniu when needed and opens its verified Accessibility button
  /// for the customer-service reception center. This never selects a customer,
  /// changes the composer, or sends a message.
  func ensureReceptionWindow(allowActivation: Bool = true,
                              completion: @escaping FlutterResult) {
    queue.async { [weak self] in
      guard let self else { return }
      func finish(_ payload: [String: Any]) {
        DispatchQueue.main.async { completion(payload) }
      }
      func launchOrReopen(at url: URL) {
        DispatchQueue.main.async {
          let configuration = NSWorkspace.OpenConfiguration()
          configuration.activates = true
          NSWorkspace.shared.openApplication(
            at: url, configuration: configuration
          ) { [weak self] app, error in
            guard let self else { return }
            self.queue.async {
              if let error {
                finish(["error": "jingmai_launch_failed",
                        "message": error.localizedDescription])
                return
              }
              guard let app else {
                finish(["error": "jingmai_launch_failed",
                        "message": "JingMai did not launch."])
                return
              }
              // Reopening the already-running bundle can take noticeably
              // longer than a normal AX button press on recent Jingmai builds.
              let deadline = ProcessInfo.processInfo.systemUptime + 10
              for _ in 0..<12 {
                guard ProcessInfo.processInfo.systemUptime < deadline else { break }
                let response = self.openReceptionWindow(app: app)
                if response["ready"] as? Bool == true {
                  finish(response)
                  return
                }
                usleep(250_000)
              }
              finish(["error": "reception_window_missing",
                      "message": "JingMai launched, but its reception center did not become available."])
            }
          }
        }
      }
      guard AXIsProcessTrusted() else {
        if allowActivation {
          DispatchQueue.main.async {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            finish(["error": "accessibility_not_allowed",
                    "message": "请在系统弹窗中允许 JD Automation 的辅助功能访问，然后再次开始。"])
          }
        } else {
          finish(["error": "accessibility_not_allowed",
                  "message": "JD Automation needs Accessibility permission."])
        }
        return
      }
      if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        .first(where: { !$0.isTerminated }) {
        if !allowActivation {
          let root = AXUIElementCreateApplication(app.processIdentifier)
          var nodes: [AXNode] = []
          self.walk(root, path: "app", depth: 0, maxDepth: 22, maxNodes: 5_000) {
            node, _ in nodes.append(node)
          }
          guard let reception = nodes.first(where: {
            $0.role == kAXWindowRole as String && ($0.title?.contains("咚咚融合工作台") == true)
          }) else {
            finish(["error": "reception_window_missing",
                    "message": "JingMai is running, but the reception window is not open. Passive monitoring will not activate it."])
            return
          }
          var minimizedValue: CFTypeRef?
          let minimized = AXUIElementCopyAttributeValue(
            reception.element, kAXMinimizedAttribute as CFString, &minimizedValue) == .success &&
            (minimizedValue as? NSNumber)?.boolValue == true
          guard !minimized, !app.isHidden else {
            finish(["error": "reception_window_hidden",
                    "message": "JingMai's reception window is hidden or minimized. Passive monitoring will not restore it."])
            return
          }
          finish(["ready": true, "opened": false, "method": "passive_existing_window"])
          return
        }
        let response = self.openReceptionWindow(app: app)
        if response["ready"] as? Bool == true {
          finish(response)
          return
        }
        guard let url = app.bundleURL ??
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        else {
          finish(response)
          return
        }
        // The Dingdong helper can stay running after its last window closes.
        // Opening its bundle again is the reliable way to recreate that
        // window; activation alone does not invoke the application's reopen
        // handler.
        launchOrReopen(at: url)
        return
      }
      guard allowActivation else {
        finish(["error": "jingmai_not_running",
                "message": "JingMai is not running. Passive monitoring will not launch it."])
        return
      }
      guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
        finish(["error": "jingmai_not_installed",
                "message": "The installed JingMai application could not be located."])
        return
      }
      launchOrReopen(at: url)
    }
  }

  private func openReceptionWindow(app: NSRunningApplication) -> [String: Any] {
    let root = AXUIElementCreateApplication(app.processIdentifier)
    func snapshot() -> [AXNode] {
      var nodes: [AXNode] = []
      walk(root, path: "app", depth: 0, maxDepth: 22, maxNodes: 5_000) {
        node, _ in nodes.append(node)
      }
      return nodes
    }
    var nodes = snapshot()
    if let reception = nodes.first(where: {
      $0.role == kAXWindowRole as String && ($0.title?.contains("咚咚融合工作台") == true)
    }) {
      var minimizedValue: CFTypeRef?
      let minimized = AXUIElementCopyAttributeValue(
        reception.element, kAXMinimizedAttribute as CFString, &minimizedValue) == .success &&
        (minimizedValue as? NSNumber)?.boolValue == true
      if minimized {
        _ = app.unhide()
        _ = app.activate(options: [.activateIgnoringOtherApps])
        _ = AXUIElementSetAttributeValue(
          reception.element, kAXMinimizedAttribute as CFString, false as CFTypeRef)
        usleep(250_000)
        return ["ready": true, "opened": true, "method": "restored_minimized_window"]
      }
      return ["ready": true, "opened": false, "method": "already_open"]
    }
    // A minimized/hidden main workbench may omit all of its child buttons from
    // the AX snapshot. Restore it once, then resolve the exact named control.
    _ = app.unhide()
    _ = app.activate(options: [.activateIgnoringOtherApps])
    usleep(300_000)
    nodes = snapshot()
    guard let button = nodes.first(where: {
      $0.role == kAXButtonRole as String && $0.title == "接待中心" &&
        $0.actions.contains(kAXPressAction as String)
    }) else {
      return ["error": "reception_button_missing",
              "message": "JingMai is running, but its verified 接待中心 button is unavailable."]
    }
    _ = AXUIElementPerformAction(button.element, kAXPressAction as CFString)
    for _ in 0..<12 {
      usleep(125_000)
      nodes = snapshot()
      if nodes.contains(where: {
        $0.role == kAXWindowRole as String && ($0.title?.contains("咚咚融合工作台") == true)
      }) {
        return ["ready": true, "opened": true, "method": "verified_ax_press"]
      }
    }
    return ["error": "reception_open_failed",
            "message": "JingMai did not expose a reception window after the verified 接待中心 button was pressed."]
  }

  /// Tmall-style identity extraction: use one unambiguous row label or a
  /// first-line AXStaticText descendant. No OCR result is a customer identity.
  private func rowCustomerIdentity(_ row: AXNode, nodes: [AXNode]) -> String? {
    guard let frame = row.frame else { return nil }
    let descendants = nodes.filter {
      $0.path.hasPrefix(row.path + "/") && $0.role == kAXStaticTextRole as String &&
      $0.frame.map { frame.intersects($0) && $0.midY <= frame.midY + 2 &&
        $0.minX < frame.minX + frame.width * 0.75 } == true
    }
    func labels(_ node: AXNode) -> [String] {
      let raw = [node.value,node.description,node.title].compactMap { $0?.trimmingCharacters(in:.whitespacesAndNewlines) }.first(where: { !$0.isEmpty })
      return raw.flatMap(cleanedRowCustomerIdentity).map { [$0] } ?? []
    }
    let childNames = Set(descendants.flatMap(labels))
    if childNames.count == 1 { return childNames.first }
    if childNames.count > 1 { return nil }
    let rowNames = Set(labels(row))
    if rowNames.count == 1 { return rowNames.first }
    if rowNames.count > 1 { return nil }
    return nil
  }

  /// Returns AX-first identities plus screenshot-derived unread evidence.
  /// The red-pixel detector is only a priority hint; Flutter still performs a
  /// fallback scan of every visible row to avoid losing messages.
  private func sidebarRows(_ nodes:[AXNode],window:AXNode) -> [AXNode] {
    guard let bounds=window.frame else { return [] }
    let headerBottom=nodes.filter { node in
      guard let frame=node.frame,frame.height<50,frame.minX<bounds.minX+bounds.width*0.35 else { return false }
      return (node.text ?? "").range(of:#"^在线咨询\s*\[?\d*\]?$"#,options:.regularExpression) != nil
    }.compactMap { $0.frame?.maxY }.max() ?? (bounds.minY+180)
    return nodes.filter { node in
      guard node.path.hasPrefix(window.path+"/"),node.role==kAXGroupRole as String,
        node.actions.contains(kAXPressAction as String),let frame=node.frame else { return false }
      return frame.minX>=bounds.minX && frame.maxX<=bounds.minX+bounds.width*0.35 &&
        frame.minY>=max(bounds.minY+180,headerBottom) && frame.maxY<=bounds.maxY-30 &&
        frame.width>=140 && frame.width<=360 && frame.height>=35 && frame.height<=100
    }.sorted { $0.frame!.minY<$1.frame!.minY }
  }

  private func selectedRow(_ rows:[AXNode],pixels:UnreadScreenshot?) -> Int? {
    let selected=rows.indices.filter { index in
      var value:CFTypeRef?
      return AXUIElementCopyAttributeValue(rows[index].element,kAXSelectedAttribute as CFString,&value) == .success &&
        (value as? NSNumber)?.boolValue==true
    }
    if selected.count==1 { return selected.first }
    if selected.count>1 { return nil }
    guard let pixels else { return nil }
    let colors=rows.map { row in row.frame.flatMap { jdRowBackground($0,pixels) } }
    var neutral:[Double]?
    if rows.count<3,let frame=rows.first?.frame {
      // With one/two customers, use the blank chat-side gutter as the neutral
      // light-theme reference instead of assuming that the sole row is active.
      let gutter=CGRect(x:frame.maxX+4,y:frame.minY,width:8,height:frame.height)
      neutral=jdRowBackground(gutter,pixels,rightInset:3)
    }
    return jdSelectedRowFromBackgrounds(colors,gutter:neutral)
  }

  private func rememberRow(_ row:AXNode,window:AXNode,pid:pid_t,fingerprint:String,
                           shape:[UInt8],canonical:String?) -> JDRowAnchor {
    rowAnchorLock.lock(); defer { rowAnchorLock.unlock() }
    let now=ProcessInfo.processInfo.systemUptime
    rowAnchors=rowAnchors.filter { now-$0.value.seenAt<30 }
    let matches=rowAnchors.values.filter { prior in
      prior.pid==pid && CFEqual(prior.window,window.element) &&
      jdRowLocatorMatches(sameElement:CFEqual(prior.element,row.element),oldFingerprint:prior.fingerprint,
        oldShape:prior.shape,newFingerprint:fingerprint,newShape:shape)
    }
    // Unique visual continuity keeps the same observation key even when JD
    // recreates AX elements. This key is never a canonical customer identity.
    let exact=matches.filter { $0.fingerprint==fingerprint }
    let prior=exact.count==1 ? exact.first:(exact.isEmpty && matches.count==1 ? matches.first:nil)
    let conflicts = canonical.map { actual in canonicalRowKeys.contains {
      $0.value == prior?.key && $0.key != customerIdentityKey(actual)
    }} ?? false
    let key = conflicts ? UUID().uuidString : (prior?.key ?? UUID().uuidString)
    let token = conflicts ? UUID().uuidString : (prior?.token ?? UUID().uuidString)
    let anchor=JDRowAnchor(token:token,key:key,pid:pid,window:window.element,element:row.element,
      fingerprint:fingerprint,shape:shape,seenAt:now)
    rowAnchors[token]=anchor;rowTokensByKey[key]=token
    if let canonical { canonicalRowKeys[customerIdentityKey(canonical)]=key }
    if rowTokensByKey.count>200 { rowTokensByKey=rowTokensByKey.filter { rowAnchors[$0.value] != nil } }
    return anchor
  }

  private func knownRowToken(_ customer:String) -> String? {
    rowAnchorLock.lock();defer { rowAnchorLock.unlock() }
    guard let key=canonicalRowKeys[customerIdentityKey(customer)],
      let token=rowTokensByKey[key],let anchor=rowAnchors[token],
      ProcessInfo.processInfo.systemUptime-anchor.seenAt<30 else { return nil }
    return token
  }

  /// No Vision/OCR: the active AX identity and selected row bind the red pill.
  private func activeCustomerHasRedClock(expectedCustomer:String, pid:pid_t,nodes supplied:[AXNode]?=nil,deadline:TimeInterval?=nil) -> Bool? {
    guard deadline.map({ProcessInfo.processInfo.systemUptime<$0}) ?? true,
      let nodes=supplied ?? receptionNodes(pid:pid,deadline:deadline),
      let active=activeCustomerIdentity(nodes:nodes),
      exactCustomerIdentityMatches(active,expectedCustomer),
      let window=nodes.first(where: { $0.role==kAXWindowRole as String && ($0.title?.contains("咚咚融合工作台")==true) }),
      let bounds=window.frame,let pixels=unreadScreenshot(pid:pid,matching:bounds) else { return nil }
    let rows=sidebarRows(nodes,window:window)
    guard let selected=selectedRow(rows,pixels:pixels),rows.indices.contains(selected),
      let frame=rows[selected].frame else { return nil }
    return jdRedClockPill(unreadBadgeEvidence(frame:frame,windowBounds:pixels.bounds,image:pixels.image).bounds)
  }

  /// Timer values come exclusively from AX nodes inside this row's red pill.
  /// Qt may expose no such node: presence still starts Flutter's local clock.
  private func axRedClockReading(row:AXNode,nodes:[AXNode],pixels:UnreadScreenshot)
    -> (present:Bool,age:Int?,text:String?,confidence:Float) {
    guard let frame=row.frame,
      let badge=unreadBadgeEvidence(frame:frame,windowBounds:pixels.bounds,image:pixels.image).bounds,
      jdRedClockPill(badge) else { return (false,nil,nil,0) }
    let sx=pixels.bounds.width/CGFloat(pixels.image.width)
    let sy=pixels.bounds.height/CGFloat(pixels.image.height)
    let screen=CGRect(x:pixels.bounds.minX+badge.minX*sx,y:pixels.bounds.minY+badge.minY*sy,
      width:badge.width*sx,height:badge.height*sy)
    var readings=[(Int,String)]()
    for node in nodes where node.path.hasPrefix(row.path+"/") {
      guard let f=node.frame,screen.contains(CGPoint(x:f.midX,y:f.midY)),
        f.width<=screen.width*1.8,f.height<=screen.height*1.8 else { continue }
      for value in [node.value,node.title,node.description].compactMap({$0}) {
        if let age=jdParseRedClockAXText(value) { readings.append((age,value)) }
      }
    }
    let ages=Set(readings.map {$0.0})
    guard ages.count==1,let value=readings.first else { return (true,nil,nil,0) }
    return (true,value.0,value.1,1)
  }

  func conversationRows() -> [[String:Any]] {
    guard AXIsProcessTrusted(),let pid=runningPID(),let nodes=receptionNodes(pid:pid),
      let window=nodes.first(where: { $0.role==kAXWindowRole as String && ($0.title?.contains("咚咚融合工作台")==true) }),
      let bounds=window.frame else { return [] }
    let rows=sidebarRows(nodes,window:window)
    let pixels=unreadScreenshot(pid:pid,matching:bounds)
    // All rows were sampled from these same sidebar pixels, even if logging,
    // fingerprinting or delivery of the shared result completes much later.
    let signalObservedAtMs=Int64(Date().timeIntervalSince1970*1000)
    let active=activeCustomerIdentity(nodes:nodes)
    let selected=selectedRow(rows,pixels:pixels)
    let shapes=rows.map { row in pixels.flatMap { pixels in row.frame.flatMap { jdRowShape($0,pixels) } } }
    let fingerprints=shapes.map { $0.map(jdShapeFingerprint) }
    let counts=Dictionary(grouping:fingerprints.compactMap { $0 },by: { $0 })
    if rows.isEmpty {
      return active.map { [["customer":$0,"unread":false,"unreadEvidence":0,
        "evidenceAvailable":false,"identitySource":"active_ax",
        "signalObservedAtMs":signalObservedAtMs]] } ?? []
    }
    return rows.enumerated().map { index,row in
      let axName=rowCustomerIdentity(row,nodes:nodes)
      let directMatch=axName.flatMap { name in active.map { exactCustomerIdentityMatches(name,$0) } }==true
      var previouslyBound=false
      if fingerprints[index] != nil,let active {
        self.rowAnchorLock.lock()
        if let key=self.canonicalRowKeys[customerIdentityKey(active)],
          let token=self.rowTokensByKey[key],let prior=self.rowAnchors[token] {
          previouslyBound=CFEqual(prior.element,row.element) && shapes[index].map { jdSameRowShape(prior.shape,$0) }==true
        }
        self.rowAnchorLock.unlock()
      }
      let canonical=(index==selected && (directMatch || previouslyBound)) ? active : nil
      var result:[String:Any]=["customer":canonical ?? axName ?? "",
        "identitySource":canonical != nil ? "active_ax":"row_anchor",
        "rowIndex":index,"candidateLabel":axName ?? "",
        "signalObservedAtMs":signalObservedAtMs]
      if let fingerprint=fingerprints[index],counts[fingerprint]?.count==1 {
        let anchor=rememberRow(row,window:window,pid:pid,fingerprint:fingerprint,shape:shapes[index]!,canonical:canonical)
        result["rowKey"]=anchor.key;result["rowToken"]=anchor.token
      }
      let red=pixels.map { unreadRedPixels(frame:row.frame!,windowBounds:$0.bounds,image:$0.image) } ?? 0
      result["unread"]=red>=8;result["unreadEvidence"]=red;result["evidenceAvailable"]=pixels != nil
      let clock=pixels.map { axRedClockReading(row:row,nodes:nodes,pixels:$0) }
      result["redClockPresent"]=clock.map { $0.present as Any } ?? NSNull()
      result["unreadAgeSeconds"]=clock?.age.map { $0 as Any } ?? NSNull()
      result["unreadBadgeText"]=clock?.text.map { $0 as Any } ?? NSNull()
      result["unreadBadgeConfidence"]=clock.map { Double($0.confidence) as Any } ?? NSNull()
      return result
    }
  }

  /// Resolve a captured row reference without comparing an OCR name to the
  /// chat header. Every action revalidates row content and actual selection.
  func openConversationRow(token:String,expectedCustomer:String?,allowActivation:Bool,
                           timeout:TimeInterval=2.5,automationEpoch:Int? = nil,completion:@escaping FlutterResult) {
    let queuedAt=ProcessInfo.processInfo.systemUptime
    queue.async { [weak self] in
      guard let self else { return }
      let expires=queuedAt+timeout;var finished=false;var stage="row_reference"
      var rowDiagnostics:[String:Any]=[:];var proofDiagnostics:[String:Any]=[:]
      var snapshots=0;var clicked=false
      let queueWaitMs=Int((ProcessInfo.processInfo.systemUptime-queuedAt)*1000)
      func finish(_ value:[String:Any]) {
        guard !finished else { return };finished=true
        var result=value;result["openStage"]=stage;result["rowEvidence"]=rowDiagnostics
        result["selectionEvidence"]=proofDiagnostics;result["snapshots"]=snapshots
        result["clickDispatched"]=clicked;result["queueWaitMs"]=queueWaitMs
        result["elapsedMs"]=Int((ProcessInfo.processInfo.systemUptime-queuedAt)*1000)
        DispatchQueue.main.async { completion(result) }
      }
      func expired()->Bool {
        if finished { return true }
        if !self.allowsAutomation(automationEpoch) { finish(["error":"automation_stopped","message":"Old automation run cannot open a row."]); return true }
        guard ProcessInfo.processInfo.systemUptime<expires else {
          finish(["error":"row_open_timeout","message":"本次行操作预算已到，保留最后确认阶段和证据，未发送。"]);return true
        }
        return false
      }
      self.rowAnchorLock.lock();let saved=self.rowAnchors[token];self.rowAnchorLock.unlock()
      guard let anchor=saved,ProcessInfo.processInfo.systemUptime-anchor.seenAt<30,
        AXIsProcessTrusted(),self.runningPID()==anchor.pid else {
        finish(["error":"row_reference_expired","message":"请先刷新当前客户列表。"]);return
      }
      func finishOpened(_ payload:[String:Any],nodes:[AXNode]) {
        let focus=self.openedReceptionFocus(pid:anchor.pid,expected:payload["customer"] as? String ?? expectedCustomer ?? "",
          nodes:nodes,allowActivation:allowActivation,deadline:expires,automationEpoch:automationEpoch)
        finish(payload.merging(focus){_,new in new})
      }
      if expired() { return }
      if let expected=expectedCustomer,let nodes=self.receptionNodes(pid:anchor.pid),
        let active=self.activeCustomerIdentity(nodes:nodes),exactCustomerIdentityMatches(active,expected) {
        if !expired() { finishOpened(["opened":true,"customer":active,"rowKey":anchor.key,
          "identityProof":"exact_active_ax","method":"canonical_already_active"],nodes:nodes) };return
      }
      guard allowActivation || NSWorkspace.shared.frontmostApplication?.processIdentifier==anchor.pid else {
        finish(["error":"qianniu_not_frontmost","message":"京麦不在前台，未抢占焦点。"]);return
      }
      if NSWorkspace.shared.frontmostApplication?.processIdentifier != anchor.pid {
        _ = NSRunningApplication(processIdentifier:anchor.pid)?.activate(options:[.activateIgnoringOtherApps])
        usleep(125_000)
      }
      func moveOutside() {
        guard let frame=frameAttribute(anchor.window),NSWorkspace.shared.frontmostApplication?.processIdentifier==anchor.pid else { return }
        CGEvent(mouseEventSource:nil,mouseType:.mouseMoved,
          mouseCursorPosition:CGPoint(x:frame.minX+frame.width*0.60,y:frame.minY+100),
          mouseButton:.left)?.post(tap:.cghidEventTap)
      }
      func snapshot()->([AXNode],AXNode,[AXNode],UnreadScreenshot,Int)? {
        guard !expired(),let nodes=self.receptionNodes(pid:anchor.pid),
          let window=nodes.first(where: { CFEqual($0.element,anchor.window) }),let bounds=window.frame,
          let pixels=unreadScreenshot(pid:anchor.pid,matching:bounds) else { return nil }
        snapshots+=1
        let rows=self.sidebarRows(nodes,window:window)
        let shapes=rows.map { $0.frame.flatMap { jdRowShape($0,pixels) } }
        let index=jdUniqueRowShapeIndex(anchor.shape,shapes)
        let layoutDiagnostics:[String:Any]=["rowKey":anchor.key,"locator":"current_target_ax_frame",
          "targetIndex":index as Any? ?? NSNull(),"rowCount":rows.count,
          "targetFrame":index.flatMap { rows[$0].frame }.map {
            ["x":$0.minX,"y":$0.minY,"width":$0.width,"height":$0.height]
          } as Any? ?? NSNull(),
          "targetFingerprint":anchor.fingerprint,
          "visibleFingerprints":shapes.map { $0.map(jdShapeFingerprint) as Any? ?? NSNull() }]
        rowDiagnostics.merge(layoutDiagnostics) { _,new in new }
        guard let index else { return nil }
        return (nodes,window,rows,pixels,index)
      }
      // Remove hover before the ONE pre-click snapshot; do not spend the
      // operation trying AXPress or repeatedly re-reading the entire list.
      moveOutside();usleep(50_000)
      stage="row_layout"
      guard let before=snapshot() else {
        if !expired() { finish(["error":"row_changed","message":"当前行引用不唯一，保留观察，未点击。"])};return
      }
      let headerBefore=self.activeCustomerIdentity(nodes:before.0)
      let selectedBefore=self.selectedRow(before.2,pixels:before.3)
      guard let point=jdRowClickPoint(before.2[before.4].frame,in:before.1.frame) else {
        finish(["error":"row_layout_changed","message":"目标行当前 AX 矩形无效或已越出窗口，未点击。"]);return
      }
      _ = self.recoverOwnUnsentReply(nodes:before.0,pid:anchor.pid)
      if let composer=before.0.first(where: { $0.role==kAXTextAreaRole as String }),
        !(stringAttribute(composer.element,kAXValueAttribute)?.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ?? true) {
        finish(["error":"composer_not_empty","message":"输入框有草稿，未切换客户。"]);return
      }
      if expired() { return }
      guard NSWorkspace.shared.frontmostApplication?.processIdentifier==anchor.pid,
        let down=CGEvent(mouseEventSource:nil,mouseType:.leftMouseDown,mouseCursorPosition:point,mouseButton:.left),
        let up=CGEvent(mouseEventSource:nil,mouseType:.leftMouseUp,mouseCursorPosition:point,mouseButton:.left) else {
        finish(["error":"row_click_unavailable","message":"当前前台或点击条件已变化。"]);return
      }
      self.pendingRowConfirmations=self.pendingRowConfirmations.filter { ProcessInfo.processInfo.systemUptime-$0.value.seenAt<30 }
      let pending=self.pendingRowConfirmations[token]
      let resumable=pending.map { ProcessInfo.processInfo.systemUptime-$0.seenAt<30 && $0.epoch==automationEpoch }==true && selectedBefore==before.4
      var confirmation=JDRowConfirmationGate()
      if resumable {
        confirmation.requiredChangeFrom=pending?.old
        _ = confirmation.observe(selected:true,header:headerBefore,expected:expectedCustomer)
        rowDiagnostics["resumedIdentityConfirmation"]=true
      } else {
        stage="row_click";clicked=true
        rowDiagnostics["clickPoint"]=["x":point.x,"y":point.y]
        rowDiagnostics["clickAfterMs"]=Int((ProcessInfo.processInfo.systemUptime-queuedAt)*1000)
        down.post(tap:.cghidEventTap);usleep(40_000);up.post(tap:.cghidEventTap)
        if selectedBefore != before.4 { confirmation.requiredChangeFrom=headerBefore }
        self.pendingRowConfirmations[token]=(old:confirmation.requiredChangeFrom,
          seenAt:ProcessInfo.processInfo.systemUptime,epoch:automationEpoch)
        // Let JD consume the click before moving the pointer away.
        usleep(140_000);moveOutside()
      }
      stage="row_selection_confirmation"
      var baseline=before
      var refreshHeaderScope=false
      // Two fresh AX header/selection reads, without two full reception-tree
      // traversals. Row shapes, every row frame and the window are revalidated;
      // insertions/reordering invalidate this proof instead of guessing a row.
      func lightSnapshot()->([AXNode],AXNode,[AXNode],UnreadScreenshot,Int)? {
        guard !expired(),frameAttribute(anchor.window)==baseline.1.frame,
          baseline.2.allSatisfy({ frameAttribute($0.element)==$0.frame }),
          let bounds=baseline.1.frame,
          let pixels=unreadScreenshot(pid:anchor.pid,matching:bounds) else { return nil }
        let shapes=baseline.2.map { $0.frame.flatMap { jdRowShape($0,pixels) } }
        guard let index=jdUniqueRowShapeIndex(anchor.shape,shapes),index==baseline.4 else { return nil }
        return (baseline.0,baseline.1,baseline.2,pixels,index)
      }
      for _ in 0..<3 {
        usleep(75_000)
        guard let state=refreshHeaderScope ? snapshot() : (lightSnapshot() ?? snapshot()) else {
          if !expired() { finish(["error":"row_changed","message":"点击后目标行已改变，未绑定客户。"])};return
        }
        baseline=state
        let selected=self.selectedRow(state.2,pixels:state.3)
        let header=self.activeCustomerIdentity(nodes:state.0,freshValues:true)
        refreshHeaderScope=header==nil || confirmation.requiredChangeFrom.map { old in
          header.map { exactCustomerIdentityMatches($0,old) }==true
        }==true
        let target=state.2[state.4].frame!
        proofDiagnostics=["targetIndex":state.4,"selectedIndex":selected as Any? ?? NSNull(),
          "targetFrame":["x":target.minX,"y":target.minY,"width":target.width,"height":target.height],
          "headerBefore":headerBefore as Any? ?? NSNull(),"header":header as Any? ?? NSNull(),
          "previousHeader":confirmation.previous as Any? ?? NSNull(),
          "requiredHeaderChangeFrom":confirmation.requiredChangeFrom as Any? ?? NSNull(),
          "backgrounds":state.2.map { $0.frame.flatMap { jdRowBackground($0,state.3) } as Any? ?? NSNull() }]
        if expired() { return }
        if let actual=confirmation.observe(selected:selected==state.4,header:header,expected:expectedCustomer),
          let frame=state.2[state.4].frame,let shape=jdRowShape(frame,state.3) {
          _ = self.rememberRow(state.2[state.4],window:state.1,pid:anchor.pid,
            fingerprint:jdShapeFingerprint(shape),shape:shape,canonical:actual)
          self.pendingRowConfirmations.removeValue(forKey:token)
          finishOpened(["opened":true,"customer":actual,"rowKey":anchor.key,
            "method":resumable ? "resumed_selected_row_ax_confirmation":"ax_frame_click","identityProof":"selected_row_and_stable_ax_header"],nodes:state.0);return
        }
      }
      finish(["error":"row_activation_unconfirmed","message":"点击后未取得稳定客户 AX 身份，保留证据，未发送。"])
    }
  }

  /// Walk candidate handles in short, synchronous slices. Every AX message
  /// has a small timeout; returning a slice never leaves a background AX job
  /// which could later click over a reply. Header/frames are refreshed below.
  private func advanceTransferOpenScan(_ scan:JDTransferOpenScan,available:()->Bool)->Bool {
    while let next=scan.pending.last {
      guard available(),scan.nodes.count<5_000,next.depth<=22 else {return false}
      let readAllowed = {
        guard available() else {return false}
        AXUIElementSetMessagingTimeout(next.element,0.035);return true
      }
      guard let node=makeNode(next.element,path:next.path,readAllowed:readAllowed),
        node.role != "AXUnknown",available() else {return false}
      scan.pending.removeLast();scan.nodes.append(node)
      if next.depth<22 {
        for (index,child) in node.children.enumerated().reversed() {
          scan.pending.append((child,"\(next.path)/child[\(index)]",next.depth+1))
        }
      }
    }
    scan.complete=true;return available()
  }

  private func transferOpenProjectionCandidates(_ baseline:[AXNode])->[AXNode] {
    guard let window=baseline.first(where:{$0.role==kAXWindowRole as String}),
      baseline.filter({$0.role==kAXTextAreaRole as String}).count==1,
      let composer=baseline.first(where:{$0.role==kAXTextAreaRole as String}),
      let split=baseline.filter({$0.role==kAXSplitGroupRole as String && composer.path.hasPrefix($0.path+"/")})
        .max(by:{$0.path.count<$1.path.count}),let chat=split.frame else {return []}
    var paths=Set(sidebarRows(baseline,window:window).map(\.path))
    for node in baseline {
      let structural=node.path==window.path || node.path==composer.path || node.path==split.path ||
        node.role==kAXSheetRole as String || node.subrole=="AXDialog"
      let header=(node.role==kAXStaticTextRole as String || node.role==kAXButtonRole as String) &&
        node.path.hasPrefix(split.path+"/") && node.frame.map {
          $0.minX>=chat.minX && $0.maxX<=chat.maxX && $0.minY>=chat.minY-100 && $0.maxY<=chat.minY+70
        }==true
      if structural || header {paths.insert(node.path)}
    }
    for candidate in Array(paths) {
      var path=candidate
      while path != window.path,let slash=path.lastIndex(of:"/") {
        path=String(path[..<slash]);paths.insert(path)
      }
    }
    return baseline.filter {paths.contains($0.path)}
  }

  private func advanceTransferOpenProjection(_ scan:JDTransferOpenScan,available:()->Bool)->JDCooperativeRefreshResult {
    if scan.projection != nil {return .complete}
    let candidates=transferOpenProjectionCandidates(scan.nodes)
    guard !candidates.isEmpty else {return .invalidated}
    let progress=scan.refreshCursor.advance(items:candidates,available:available) { node in
      self.makeNode(node.element,path:node.path,readAllowed:{
        guard available() else {return false}
        AXUIElementSetMessagingTimeout(node.element,0.035);return true
      })
    }
    if case .complete=progress {scan.projection=scan.refreshCursor.values}
    return progress
  }

  /// Refresh only the required reception/chat/header/composer and optional
  /// row nodes. As in reply delivery, validate each node's direct parent;
  /// unrelated ancestors and sidebar branches are not extra opening gates.
  private func freshTransferOpenNodes(_ baseline:[AXNode],includeRows:Bool=true,available:()->Bool)->[AXNode]? {
    guard let window=baseline.first(where:{$0.role==kAXWindowRole as String}),
      let composer=baseline.first(where:{$0.role==kAXTextAreaRole as String}),
      baseline.filter({$0.role==kAXTextAreaRole as String}).count==1,
      let split=baseline.filter({$0.role==kAXSplitGroupRole as String && composer.path.hasPrefix($0.path+"/")})
        .max(by:{$0.path.count<$1.path.count}),let chat=split.frame else {return nil}
    let rowPaths=Set((includeRows ? sidebarRows(baseline,window:window):[]).map(\.path))
    let byPath=Dictionary(uniqueKeysWithValues:baseline.map{($0.path,$0)})
    let selected=baseline.filter { node in
      let structural=node.path==window.path || node.path==split.path || node.path==composer.path ||
        node.role==kAXSheetRole as String || node.subrole=="AXDialog"
      let header=(node.role==kAXStaticTextRole as String || node.role==kAXButtonRole as String) &&
        node.path.hasPrefix(split.path+"/") && node.frame.map {
          $0.minX>=chat.minX && $0.maxX<=chat.maxX && $0.minY>=chat.minY-100 && $0.maxY<=chat.minY+70
        }==true
      return structural || header || rowPaths.contains(node.path)
    }
    let references=selected.map { node->JDReplyStyleNodeReference<AXUIElement> in
      let parent=node.path.lastIndex(of:"/").flatMap{byPath[String(node.path[..<$0])]}
      return JDReplyStyleNodeReference(element:node.element,role:node.role,frame:node.frame,
        structural:node.path==window.path || node.path==split.path || node.path==composer.path ||
          node.role==kAXSheetRole as String,
        parent:parent?.element,parentChildren:parent?.children)
    }
    func prepare(_ element:AXUIElement)->Bool {
      guard available() else {return false};AXUIElementSetMessagingTimeout(element,0.035);return true
    }
    guard let values=jdRefreshReplyStyleNodes(references,available:available,
      readString:{ element,attribute in
        guard prepare(element) else {return nil};return stringAttribute(element,attribute)
      },readFrame:{ element in frameAttribute(element,readAllowed:{prepare(element)}) },
      readChildren:{ element in
        guard prepare(element) else {return nil};return elementArrayAttribute(element,kAXChildrenAttribute)
      },equal:{CFEqual($0,$1)}) else {return nil}
    var refreshedByPath=[String:AXNode]()
    for (node,value) in zip(selected,values) {
      if rowPaths.contains(node.path) && value.frame==nil {return nil}
      refreshedByPath[node.path]=AXNode(element:node.element,path:node.path,role:node.role,subrole:value.subrole,
        identifier:node.identifier,title:value.title,description:value.description,value:value.value,help:node.help,
        frame:value.frame,actions:node.actions,children:node.children)
    }
    // Keep unrefreshed locator/parent context just as freshSendNodes does.
    // Required live values above are replaced; retained parents are candidates
    // whose child membership will be checked again on the next refresh.
    return available() ? baseline.map{refreshedByPath[$0.path] ?? $0}:nil
  }

  /// Transfer recovery has no total customer-open deadline. A slice may stop
  /// for queue time, slow AX or a reply; the caller releases its UI lease and
  /// resumes later. Ordinary delivery continues to use its existing opener.
  private func openTransferConversation(expectedCustomer:String,allowActivation:Bool,
      automationEpoch:Int?,completion:@escaping FlutterResult) {
    let queuedAt=ProcessInfo.processInfo.systemUptime
    let control=beginTransferWork(automationEpoch)
    queue.async { [weak self] in
      guard let self else {return}
      defer {self.endTransferWork(control)}
      // Queue contention is not work performed by this slice. The control is
      // already registered, so a queued old request still honors Stop/yield.
      let deadline=ProcessInfo.processInfo.systemUptime+1.6
      let expected=expectedCustomer.trimmingCharacters(in:.whitespacesAndNewlines)
      let sessionKey="\(automationEpoch.map(String.init) ?? "manual")|\(customerIdentityKey(expected))"
      let now=ProcessInfo.processInfo.systemUptime
      self.transferOpenSessions=self.transferOpenSessions.filter {
        now-$0.value.lastUsed<30
      }
      let session=self.transferOpenSessions[sessionKey] ?? JDTransferOpenSession(epoch:automationEpoch)
      self.transferOpenSessions[sessionKey]=session;session.lastUsed=now
      var stage="row_reference",finished=false,clickedThisStep=false,hadClickCheckpoint=false
      var rowKey=session.rowKey,lastObservedCustomer:String?
      var rowEvidence=[String:Any](),selectionEvidence=[String:Any]()
      func available()->Bool {
        self.allowsAutomation(automationEpoch) && !control.isInterrupted && ProcessInfo.processInfo.systemUptime<deadline
      }
      func finish(_ payload:[String:Any]) {
        guard !finished else {return};finished=true
        var result=payload
        let pending=session.rowToken.flatMap {self.pendingRowConfirmations[$0]}
        result["expectedCustomer"]=expected;result["activeCustomerId"]=lastObservedCustomer as Any? ?? NSNull()
        result["rowToken"]=session.rowToken as Any? ?? NSNull();result["rowKey"]=rowKey as Any? ?? NSNull()
        result["openStage"]=stage;result["rowEvidence"]=rowEvidence;result["selectionEvidence"]=selectionEvidence
        result["clickDispatched"]=clickedThisStep || hadClickCheckpoint || pending?.epoch==automationEpoch && pending != nil
        result["clickDispatchedThisStep"]=clickedThisStep;result["transferClicked"]=false
        result["identitySource"]="ax_header_toolbar"
        result["queueWaitMs"]=Int((now-queuedAt)*1000)
        result["elapsedMs"]=Int((ProcessInfo.processInfo.systemUptime-queuedAt)*1000)
        DispatchQueue.main.async {completion(result)}
      }
      func pending(_ reason:String) {
        finish(["opened":false,"openState":"pending","error":"conversation_open_pending","pendingReason":reason])
      }
      func boundary()->Bool {
        guard let error=jdTransferOpenBoundary(epochValid:self.allowsAutomation(automationEpoch),
          interrupted:control.isInterrupted,budgetExpired:ProcessInfo.processInfo.systemUptime>=deadline) else {return false}
        if error=="conversation_open_pending" {pending(stage+"_step_budget")}
        else {
          // A reply can serve another customer before this lease resumes.
          // Keep the row click checkpoint, discard all candidate AX handles.
          session.scan=nil;session.proof=nil;session.activeNodes=nil
          finish(["opened":false,"error":error,"pendingReason":"reply_priority_or_epoch_changed"])
        }
        return true
      }
      if boundary() {return}
      guard !expected.isEmpty else {finish(["opened":false,"error":"conversation_customer_missing"]);return}
      guard AXIsProcessTrusted() else {finish(["opened":false,"error":"accessibility_not_trusted"]);return}
      guard let pid=self.runningPID() else {finish(["opened":false,"error":"jd_not_running"]);return}
      func sameReceptionIsTop(_ nodes:[AXNode])->Bool {
        guard !nodes.contains(where:{$0.role==kAXSheetRole as String || $0.subrole=="AXDialog"}),
          let raw=CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]],
          let top=raw.first(where:{($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value==pid && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue==0}),
          let bounds=top[kCGWindowBounds as String] as? [String:Any],let frame=CGRect(dictionaryRepresentation:bounds as CFDictionary),
          let expectedFrame=nodes.first(where:{$0.role==kAXWindowRole as String})?.frame else {return false}
        return jdReceptionWindowMatches(expected:expectedFrame,frontmost:frame)
      }
      func requestSafeFocus(_ nodes:[AXNode]) {
        guard allowActivation else {finish(["opened":false,"error":"qianniu_not_frontmost"]);return}
        guard sameReceptionIsTop(nodes) else {pending("reception_focus_blocked");return}
        guard available(),self.runningPID()==pid else {
          if !boundary() {pending("reception_process_changed")};return
        }
        _=NSRunningApplication(processIdentifier:pid)?.activate(options:[.activateIgnoringOtherApps])
        pending("reception_focus_settling")
      }
      self.rowAnchorLock.lock()
      let knownKey=self.canonicalRowKeys[customerIdentityKey(expected)]
      let knownToken=knownKey.flatMap {self.rowTokensByKey[$0]}
      let anchor=knownToken.flatMap {self.rowAnchors[$0]}
      self.rowAnchorLock.unlock()
      // Requested text never binds an unconfirmed row. Only the native exact
      // header/row mapping can supply this locator, even after a deferred call.
      if session.rowToken != knownToken {session.proof=nil}
      session.rowToken=knownToken;session.rowKey=knownKey;rowKey=knownKey
      hadClickCheckpoint=knownToken.flatMap {self.pendingRowConfirmations[$0]}.map {$0.epoch==automationEpoch}==true
      if let scan=session.scan,scan.pid != pid || now-scan.createdAt>=30 {session.scan=nil}
      func prepare(_ element:AXUIElement)->Bool {
        guard available() else {return false};AXUIElementSetMessagingTimeout(element,0.035);return true
      }
      // Match ordinary reply opening: an already-active exact AX customer
      // does not need a sidebar locator, pixels, or a row-selection operation.
      // A real transfer-owned row click retains its existing selection proof.
      if !hadClickCheckpoint && !session.selectionWasRequired {
        stage="active_identity"
        var current:[AXNode]?
        if let baseline=session.activeNodes ?? session.scan?.projection {
          current=self.freshTransferOpenNodes(baseline,includeRows:false,available:available)
          if current==nil && available() {current=self.receptionNodes(pid:pid,deadline:deadline)}
        } else if session.scan==nil {
          current=self.receptionNodes(pid:pid,deadline:deadline)
        }
        if let current {
          lastObservedCustomer=self.activeCustomerIdentity(nodes:current)
          if let active=lastObservedCustomer,exactCustomerIdentityMatches(active,expected) {
            // A focus/budget yield retains candidate handles only. The next
            // lease must freshly read them before any successful admission.
            session.activeNodes=current
            stage="active_focus_verification"
            let focused=available() && self.runningPID()==pid && self.receptionHasFocus(pid:pid,nodes:current)
            let first=jdTransferActiveOpenCheck(expected:expected,customer:active,
              composerValue:current.first(where:{$0.role==kAXTextAreaRole as String})?.value,
              focused:focused,modalBlocked:current.contains(where:{$0.role==kAXSheetRole as String || $0.subrole=="AXDialog"}),
              available:available())
            guard !boundary() else {return}
            switch first {
            case .blocked(let error):finish(["opened":false,"error":error]);return
            case .pending(let reason):
              if reason=="reception_focus_required" {requestSafeFocus(current)} else {pending(reason)}
              return
            case .differentCustomer:
              session.activeNodes=nil;pending("active_customer_changed");return
            case .ready:break
            }
            // This scope was just freshly read and focus was checked above.
            // Reply admission does not require a second full AX pass here;
            // native account inspection rechecks identity/composer before its
            // own guarded button press. Never depend on sidebar pixels merely
            // to acknowledge the already-active exact AX customer.
            if case .ready(let actual)=first {
              if let token=session.rowToken {self.pendingRowConfirmations.removeValue(forKey:token)}
              finish(["opened":true,"openState":"opened","customer":actual,"focusVerified":true,
                "identityProof":"exact_active_ax","method":"transfer_exact_already_active"])
              self.transferOpenSessions.removeValue(forKey:sessionKey);return
            }
          }
          guard lastObservedCustomer != nil else {pending("active_identity_unavailable");return}
          session.activeNodes=nil
          // Reuse the just-acquired fresh tree as row candidates when a real
          // switch is needed. All row actions still refresh current geometry.
          if session.scan==nil,let window=current.first(where:{$0.role==kAXWindowRole as String}),let frame=window.frame {
            let scan=JDTransferOpenScan(pid:pid,window:window.element,frame:frame)
            scan.nodes=current;scan.pending.removeAll();scan.complete=true;session.scan=scan
          }
        } else if !available() {_=boundary();return}
        else if session.activeNodes != nil {pending("active_identity_unavailable");return}
      }
      guard CGPreflightScreenCaptureAccess() else {finish(["opened":false,"error":"screen_recording_not_authorized"]);return}
      if session.scan==nil {
        stage="reception_scope"
        let app=AXUIElementCreateApplication(pid)
        guard prepare(app) else {_=boundary();return}
        let windows=elementArrayAttribute(app,kAXWindowsAttribute)
        var target:AXUIElement?
        for window in windows {
          guard prepare(window) else {_=boundary();return}
          if stringAttribute(window,kAXTitleAttribute)?.contains("咚咚融合工作台")==true {
            if target != nil {pending("reception_scope_ambiguous");return};target=window
          }
        }
        // Some Qt versions omit AXWindows. A prior native-bound reception is
        // still only a candidate and must pass current title/PID/frame checks.
        if target==nil,windows.isEmpty,let anchor,anchor.pid==pid {target=anchor.window}
        guard let target,prepare(target) else {
          if !boundary() {pending("reception_scope_unavailable")};return
        }
        var targetPID:pid_t=0
        guard AXUIElementGetPid(target,&targetPID) == .success,targetPID==pid,
          stringAttribute(target,kAXRoleAttribute)==kAXWindowRole as String,prepare(target),
          stringAttribute(target,kAXTitleAttribute)?.contains("咚咚融合工作台")==true,
          let frame=frameAttribute(target,readAllowed:{prepare(target)}) else {
          if !boundary() {pending("reception_scope_unavailable")};return
        }
        session.scan=JDTransferOpenScan(pid:pid,window:target,frame:frame)
      }
      guard let scan=session.scan,prepare(scan.window),
        frameAttribute(scan.window,readAllowed:{prepare(scan.window)})==scan.windowFrame else {
        if available() {session.scan=nil;session.proof=nil}
        if !boundary() {pending("reception_layout_changed")};return
      }
      stage="reception_scan"
      if !scan.complete && !self.advanceTransferOpenScan(scan,available:available) {
        if scan.nodes.count>=5_000 || (scan.pending.last?.depth ?? 0)>22 {session.scan=nil}
        if !boundary() {pending("reception_ax_scan_incomplete")};return
      }
      stage="reception_candidate_refresh"
      switch self.advanceTransferOpenProjection(scan,available:available) {
      case .pending:
        if !boundary() {pending("reception_candidate_refresh_incomplete")};return
      case .invalidated:
        session.scan=nil;session.proof=nil;pending("reception_candidate_refresh_invalidated");return
      case .complete:break
      }
      guard let projection=scan.projection else {pending("reception_candidate_refresh_incomplete");return}
      typealias Snapshot=(nodes:[AXNode],window:AXNode,rows:[AXNode],pixels:UnreadScreenshot,index:Int?)
      func snapshot()->Snapshot? {
        guard available(),self.runningPID()==pid,
          let current=self.freshTransferOpenNodes(projection,available:available),
          let window=current.first(where:{$0.role==kAXWindowRole as String}),
          CFEqual(window.element,scan.window),window.title?.contains("咚咚融合工作台")==true,let bounds=window.frame,
          let pixels=unreadScreenshot(pid:pid,matching:bounds),available() else {return nil}
        let rows=self.sidebarRows(current,window:window)
        let shapes=rows.map {$0.frame.flatMap{jdRowShape($0,pixels)}}
        let index=anchor.flatMap {
          $0.pid==pid && CFEqual($0.window,window.element) ? jdUniqueRowShapeIndex($0.shape,shapes):nil
        }
        rowEvidence=["locator":"current_target_ax_frame","rowCount":rows.count,
          "targetIndex":index as Any? ?? NSNull(),"targetFrame":index.flatMap{rows[$0].frame}.map {
            ["x":$0.minX,"y":$0.minY,"width":$0.width,"height":$0.height]
          } as Any? ?? NSNull()]
        return (current,window,rows,pixels,index)
      }
      // The full layout/selection refresh and final header/focus proof run in
      // different leases. Slow but successful AX reads therefore make progress
      // instead of repeating three refreshes inside the same short budget.
      if var proof=session.proof,proof.confirmedCustomer != nil {
        stage="final_focus_verification"
        guard let final=self.freshTransferOpenNodes(projection,includeRows:session.selectionWasRequired,available:available),
          let window=final.first(where:{$0.role==kAXWindowRole as String}),
          CFEqual(window.element,scan.window),window.title?.contains("咚咚融合工作台")==true else {
          if available() {session.proof=nil;session.scan=nil}
          if !boundary() {pending("final_focus_ax_unavailable")};return
        }
        lastObservedCustomer=self.activeCustomerIdentity(nodes:final)
        guard !final.contains(where:{$0.role==kAXSheetRole as String || $0.subrole=="AXDialog"}) else {
          session.proof=nil;pending("reception_focus_blocked");return
        }
        selectionEvidence=["finalHeader":lastObservedCustomer as Any? ?? NSNull(),
          "stableHeaderPreviouslyConfirmed":true,"resumedIdentityConfirmation":session.resumedSelection]
        guard let active=lastObservedCustomer else {
          session.proof=nil;pending("final_header_unavailable");return
        }
        guard exactCustomerIdentityMatches(active,expected) else {
          session.proof=nil;session.scan=nil;pending("final_header_relocalizing");return
        }
        if session.selectionWasRequired {
          guard let anchor,anchor.pid==pid,CFEqual(anchor.window,window.element),let bounds=window.frame,
            let pixels=unreadScreenshot(pid:pid,matching:bounds),available() else {
            session.proof=nil;if !boundary() {pending("final_row_selection_unavailable")};return
          }
          let rows=self.sidebarRows(final,window:window)
          let shapes=rows.map {$0.frame.flatMap{jdRowShape($0,pixels)}}
          let index=jdUniqueRowShapeIndex(anchor.shape,shapes)
          let selected=self.selectedRow(rows,pixels:pixels)
          selectionEvidence["targetIndex"]=index as Any? ?? NSNull()
          selectionEvidence["selectedIndex"]=selected as Any? ?? NSNull()
          guard let index,selected==index else {
            session.proof=nil;session.scan=nil;pending("final_row_selection_relocalizing");return
          }
        }
        guard let value=final.first(where:{$0.role==kAXTextAreaRole as String})?.value else {
          session.proof=nil;pending("final_composer_ax_unavailable");return
        }
        guard value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {
          session.proof=nil;finish(["opened":false,"error":"composer_not_empty"]);return
        }
        guard !boundary(),self.runningPID()==pid else {
          if !finished {pending("reception_process_changed")};return
        }
        let focused=self.receptionHasFocus(pid:pid,nodes:final)
        guard !boundary() else {return}
        if !focused {requestSafeFocus(final);return}
        guard proof.complete(finalHeader:active,expected:expected,focused:focused,composerEmpty:true) else {
          session.proof=nil;pending("final_identity_or_focus_unconfirmed");return
        }
        // No cached frame/header is authority here. Exact current AX identity,
        // current selected target pixels and reception focus precede clearing.
        if let token=session.rowToken {self.pendingRowConfirmations.removeValue(forKey:token)}
        finish(["opened":true,"openState":"opened","customer":active,"focusVerified":true,
          "identityProof":session.selectionWasRequired ? "selected_row_and_stable_ax_header":"exact_active_ax",
          "method":session.resumedSelection ? "resumed_selected_row_ax_confirmation":"transfer_cooperative_exact_ax"])
        self.transferOpenSessions.removeValue(forKey:sessionKey);return
      }
      stage="row_layout"
      guard let state=snapshot() else {
        if available() {session.proof=nil;session.scan=nil}
        if !boundary() {pending("fresh_ax_layout_unavailable")};return
      }
      lastObservedCustomer=self.activeCustomerIdentity(nodes:state.nodes)
      guard !state.nodes.contains(where:{$0.role==kAXSheetRole as String || $0.subrole=="AXDialog"}) else {
        session.proof=nil;pending("reception_focus_blocked");return
      }
      let activeAlready=lastObservedCustomer.map {exactCustomerIdentityMatches($0,expected)}==true
      let selected=self.selectedRow(state.rows,pixels:state.pixels)
      let targetSelected=state.index.map {selected==$0}==true
      let checkpoint=session.rowToken.flatMap {self.pendingRowConfirmations[$0]}
      let resumable=checkpoint.map {$0.epoch==automationEpoch && now-$0.seenAt<30}==true && targetSelected
      selectionEvidence=["targetIndex":state.index as Any? ?? NSNull(),"selectedIndex":selected as Any? ?? NSNull(),
        "header":lastObservedCustomer as Any? ?? NSNull(),"resumedIdentityConfirmation":resumable]
      let locatorCurrent=anchor.map {$0.pid==pid && ProcessInfo.processInfo.systemUptime-$0.seenAt<30}==true && state.index != nil
      guard let composer=state.nodes.first(where:{$0.role==kAXTextAreaRole as String}),let value=composer.value else {
        session.proof=nil;pending("composer_ax_unavailable");return
      }
      guard value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {
        session.proof=nil;finish(["opened":false,"error":"composer_not_empty"]);return
      }
      if !activeAlready {
        guard lastObservedCustomer != nil else {session.proof=nil;pending("fresh_header_unavailable");return}
        guard locatorCurrent else {session.proof=nil;pending("row_locator_refresh_required");return}
        if jdTransferOpenShouldClick(locatorCurrent:locatorCurrent,targetSelected:targetSelected,
          active:lastObservedCustomer,expected:expected) {
          session.proof=nil
          guard NSWorkspace.shared.frontmostApplication?.processIdentifier==pid else {
            if !boundary() {requestSafeFocus(state.nodes)};return
          }
          guard self.receptionHasFocus(pid:pid,nodes:state.nodes) else {
            if !boundary() {pending("reception_focus_blocked")};return
          }
          guard let index=state.index,let point=jdRowClickPoint(state.rows[index].frame,in:state.window.frame),
            available(),self.runningPID()==pid,
            let down=CGEvent(mouseEventSource:nil,mouseType:.leftMouseDown,mouseCursorPosition:point,mouseButton:.left),
            let up=CGEvent(mouseEventSource:nil,mouseType:.leftMouseUp,mouseCursorPosition:point,mouseButton:.left) else {
            if !boundary() {pending("current_row_click_unavailable")};return
          }
          stage="row_click"
          session.selectionWasRequired=true
          if let token=session.rowToken {
            self.pendingRowConfirmations[token]=(old:lastObservedCustomer,seenAt:ProcessInfo.processInfo.systemUptime,epoch:automationEpoch)
          }
          clickedThisStep=true
          rowEvidence["clickPoint"]=["x":point.x,"y":point.y]
          down.post(tap:.cghidEventTap);usleep(20_000);up.post(tap:.cghidEventTap)
          if !boundary() {pending("row_selection_settling")};return
        }
        if !resumable {
          session.proof=nil;session.scan=nil;pending("selected_row_header_relocalizing");return
        }
      }
      stage="row_selection_confirmation"
      guard !boundary() else {return}
      let requireSelection=hadClickCheckpoint || session.selectionWasRequired || !activeAlready
      if session.selectionWasRequired != requireSelection {session.proof=nil}
      session.selectionWasRequired=requireSelection
      session.resumedSelection=resumable
      var proof=session.proof ?? JDTransferOpenProof(requiredChangeFrom:resumable ? checkpoint?.old:nil)
      switch proof.observe(selected:!requireSelection || targetSelected,header:lastObservedCustomer,expected:expected) {
      case .differentCustomer:
        session.proof=nil;session.scan=nil;pending("active_header_relocalizing")
      case .pending:
        session.proof=proof;pending("stable_header_confirmation_required")
      case .confirmed:
        session.proof=proof;pending("final_focus_verification_required")
      }

    }
  }

  func openConversation(expectedCustomer: String, allowActivation: Bool = true,
                        timeout: TimeInterval = 6.5,
                        useRowReference: Bool = true, automationEpoch: Int? = nil,
                        purpose:String="delivery",
                        completion: @escaping FlutterResult) {
    if purpose=="transfer" {
      openTransferConversation(expectedCustomer:expectedCustomer,allowActivation:allowActivation,
        automationEpoch:automationEpoch,completion:completion)
      return
    }
    // Include time spent waiting in the native queue. A timed-out Dart caller
    // must not leave an old operation that switches chats minutes later.
    if useRowReference,let token=knownRowToken(expectedCustomer) {
      let began=ProcessInfo.processInfo.systemUptime
      openConversationRow(token:token,expectedCustomer:expectedCustomer,
        allowActivation:allowActivation,timeout:min(timeout,2.5),automationEpoch:automationEpoch) { result in
          if let value=result as? [String:Any],let error=value["error"] as? String,
            ["row_changed","row_reference_expired","row_activation_unconfirmed","row_open_timeout","row_layout_changed"].contains(error),
            timeout-(ProcessInfo.processInfo.systemUptime-began)>0.2 {
            // A stale locator does not invalidate a KNOWN customer. Re-resolve
            // independently within the original budget; never relax identity.
            self.openConversation(expectedCustomer:expectedCustomer,allowActivation:allowActivation,
              timeout:timeout-(ProcessInfo.processInfo.systemUptime-began),useRowReference:false,automationEpoch:automationEpoch) { fallback in
                if var output=fallback as? [String:Any] { output["rowReferenceFallback"]=error;completion(output) }
                else { completion(fallback) }
              }
          } else { completion(result) }
        }
      return
    }
    let queuedAt = ProcessInfo.processInfo.systemUptime
    let expiresAt = queuedAt + timeout
    queue.async { [weak self] in
      guard let self else { return }
      let queueWaitMs = Int((ProcessInfo.processInfo.systemUptime - queuedAt) * 1000)
      var stage = "initial_identity"
      var lastObservedCustomer: String?
      var phaseStarted = ProcessInfo.processInfo.systemUptime
      var phaseMs: [String:Int] = [:]
      func enter(_ next: String) {
        let now = ProcessInfo.processInfo.systemUptime
        phaseMs[stage,default:0] += Int((now-phaseStarted)*1000)
        stage = next; phaseStarted = now
      }
      func finish(_ payload: [String: Any]) {
        var result = payload
        result["expectedCustomer"]=expectedCustomer
        result["activeCustomerId"]=lastObservedCustomer as Any? ?? NSNull()
        result["identitySource"]="ax_header_toolbar"
        if payload["opened"] as? Bool == true {
          result["identityProof"] = "exact_active_ax"
          result["identitySource"] = "ax_header_toolbar"
        }
        var timings=phaseMs
        timings[stage,default:0] += Int((ProcessInfo.processInfo.systemUptime-phaseStarted)*1000)
        result["openPhaseMs"] = timings
        result["openStage"] = stage
        result["queueWaitMs"] = queueWaitMs
        DispatchQueue.main.async { completion(result) }
      }
      func expired() -> Bool {
        if !self.allowsAutomation(automationEpoch) { finish(["error":"automation_stopped","message":"Old automation run cannot open a conversation."]); return true }
        guard ProcessInfo.processInfo.systemUptime >= expiresAt else { return false }
        finish(["error": "conversation_open_timeout",
                "message": "切换客户会话超过时限，已取消过期操作；不会继续点击或发送。"])
        return true
      }
      if expired() { return }
      let expected = expectedCustomer.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !expected.isEmpty, AXIsProcessTrusted(), let pid = runningPID() else {
        finish(["error": "conversation_unavailable", "message": "JingMai, Accessibility, or customer ID is unavailable."])
        return
      }
      guard let nodes = receptionNodes(pid: pid) else {
        finish(["error": "conversation_window_missing",
                "message": "JingMai's reception window is not available."])
        return
      }
      guard let window = nodes.first(where: {
        $0.role == kAXWindowRole as String && ($0.title?.contains("咚咚融合工作台") == true)
      }) else {
        finish(["error": "conversation_window_missing",
                "message": "JingMai's reception window is not available."])
        return
      }
      func finishOpened(_ payload:[String:Any],nodes current:[AXNode]?=nil) {
        let focus=self.openedReceptionFocus(pid:pid,expected:expected,nodes:current ?? nodes,
          allowActivation:allowActivation,deadline:expiresAt,automationEpoch:automationEpoch)
        finish(payload.merging(focus){_,new in new})
      }
      let scoped = nodes.filter {
        $0.path == window.path || $0.path.hasPrefix(window.path + "/")
      }
      if expired() { return }
      lastObservedCustomer = activeCustomerIdentity(nodes: scoped)
      if activeCustomerMatches(expected, nodes: scoped) {
        finishOpened(["opened": true, "customer": expected, "method": "already_active"],nodes:scoped)
        return
      }
      enter("row_resolution")
      let rowCandidates = scoped.compactMap { node -> (AXNode, String)? in
        guard ProcessInfo.processInfo.systemUptime < expiresAt,
              node.role == kAXGroupRole as String,
              node.actions.contains(kAXPressAction as String),
              let frame = node.frame,
              let windowFrame = window.frame,
              frame.minX >= windowFrame.minX,
              frame.maxX <= windowFrame.minX + windowFrame.width * 0.35,
              frame.minY >= windowFrame.minY + 180,
              frame.maxY <= windowFrame.maxY - 30,
              frame.width >= 140, frame.width <= 360,
              frame.height >= 35, frame.height <= 100,
              let customer = self.rowCustomerIdentity(node, nodes: scoped)
        else { return nil }
        return (node, customer)
      }
      if expired() { return }
      let exact = rowCandidates.filter { exactCustomerIdentityMatches($0.1, expected) }
      let candidates = exact.map(\.0)
      guard candidates.count == 1, let target = candidates.first else {
        finish(["error": "conversation_not_found", "message": "Exact conversation \(expected) was not found."])
        return
      }

      func verifiedIdentity(in supplied: [AXNode]? = nil) -> String? {
        guard let current = supplied ?? receptionNodes(pid: pid) else { return nil }
        lastObservedCustomer=activeCustomerIdentity(nodes: current)
        guard let actual=lastObservedCustomer,exactCustomerIdentityMatches(actual, expected) else { return nil }
        return actual
      }

      if expired() { return }
      if let verified = verifiedIdentity(in: scoped) {
        finishOpened(["opened": true, "customer": verified, "method": "already_active"],nodes:scoped)
        return
      }

      // Switching an embedded Qianniu chat ultimately requires keyboard/mouse
      // focus on builds that ignore AXPress. A background monitor must defer
      // instead of interrupting typing in VS Code or another application.
      guard allowActivation ||
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
        finish(["error": "qianniu_not_frontmost",
                "message": "Unread conversation is queued until JingMai is frontmost; focus was not stolen."])
        return
      }

      // Try the verified AX action in the background first. Qianniu may accept
      // it without stealing focus. Only the guarded coordinate fallback below
      // activates Qianniu when its embedded web view ignores AXPress.
      _ = self.recoverOwnUnsentReply(nodes:scoped,pid:pid)
      if let composer = scoped.first(where: { $0.role == kAXTextAreaRole as String }),
         !(stringAttribute(composer.element, kAXValueAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
        finish(["error": "composer_not_empty",
                "message": "Automatic switching paused because the current composer contains text."])
        return
      }

      if expired() { return }
      enter("ax_press")
      _ = AXUIElementPerformAction(target.element, kAXPressAction as CFString)
      // JD advertises AXPress on rows but often ignores it. Do not spend a
      // full second polling an ineffective action before the verified click.
      for _ in 0..<1 {
        if expired() { return }
        usleep(125_000)
        if let verified = verifiedIdentity() {
          finishOpened(["opened": true, "customer": verified, "method": "ax_press"])
          return
        }
      }

      // Qianniu's embedded web view sometimes advertises AXPress but ignores it.
      // Fall back to one click on the already identity-matched sidebar row, then
      // verify the complete active AX customer again before proceeding.
      // Reaching this point proves either activation was explicitly allowed or
      // Qianniu was already frontmost. Passive monitoring may click a verified
      // row only in the latter case; it still never steals focus.
      if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
        _ = NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateIgnoringOtherApps])
        usleep(150_000)
      }
      if expired() { return }
      // A new message can reorder the sidebar while AXPress is settling.
      // Re-resolve the row from fresh AX geometry and complete AX row labels.
      enter("row_revalidation")
      guard let latest = receptionNodes(pid: pid),
            let currentWindow = latest.first(where: { $0.role == kAXWindowRole as String }),
            let windowFrame = currentWindow.frame else {
        finish(["error": "conversation_changed", "message": "点击前无法重新核实客户列表。"])
        return
      }
      if let verified = verifiedIdentity(in: latest) {
        finishOpened(["opened": true, "customer": verified, "method": "settled_ax_press"],nodes:latest)
        return
      }
      let freshMatches = latest.filter { node in
        guard node.role == kAXGroupRole as String,
              node.actions.contains(kAXPressAction as String),
              let bounds = node.frame,
              bounds.minX >= windowFrame.minX,
              bounds.maxX <= windowFrame.minX + windowFrame.width * 0.35,
              bounds.minY >= windowFrame.minY + 180,
              bounds.maxY <= windowFrame.maxY - 30,
              bounds.width >= 140, bounds.width <= 360,
              bounds.height >= 35, bounds.height <= 100,
              let name = self.rowCustomerIdentity(node, nodes: latest)
        else { return false }
        return exactCustomerIdentityMatches(name, expected)
      }
      guard freshMatches.count == 1, let frame = freshMatches.first?.frame else {
        finish(["error": "conversation_changed", "message": "客户行已变化或身份有歧义，未点击。"])
        return
      }
      _ = self.recoverOwnUnsentReply(nodes:latest,pid:pid)
      if let composer = latest.first(where: { $0.role == kAXTextAreaRole as String }),
         !(stringAttribute(composer.element, kAXValueAttribute)?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
        finish(["error": "composer_not_empty", "message": "输入框中有草稿，未切换客户。"])
        return
      }
      if expired() { return }
      let point = CGPoint(x: frame.midX, y: frame.midY)
      guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                               mouseCursorPosition: point, mouseButton: .left),
            let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                             mouseCursorPosition: point, mouseButton: .left) else {
        finish(["error": "conversation_click_failed",
                "message": "Could not create a guarded click for \(expected)."])
        return
      }
      enter("click_confirmation")
      down.post(tap: .cghidEventTap)
      up.post(tap: .cghidEventTap)
      for _ in 0..<12 {
        if expired() { return }
        usleep(125_000)
        if let verified = verifiedIdentity() {
          finishOpened(["opened": true, "customer": verified, "method": "guarded_click"])
          return
        }
      }
      finish(["error": "conversation_verification_failed",
              "message": "JingMai did not activate the expected customer \(expected) after AXPress and a guarded row click."])
    }
  }

  /// Opens the verified active customer's transfer dialog and returns only
  /// visible service accounts with a green online badge. JD's account rows are
  /// canvas-rendered and absent from AX, so names come from Vision OCR while
  /// status comes from an independent pixel-color check beside each name.
  func listActiveTransferAccounts(expectedCustomer: String, automationEpoch: Int? = nil,
                                  completion: @escaping FlutterResult) {
    let control=beginTransferWork(automationEpoch)
    queue.async { [weak self] in
      guard let self else { return }
      defer {self.endTransferWork(control)}
      var ownedDialogID:CGWindowID?
      var openingPID:pid_t?
      var dialogIDsBeforeOpen=Set<CGWindowID>()
      var openingAttempted=false
      var completed = false
      var lastRecognitionDiagnostics:[String:Any]=[:]
      let started=Date()
      var inspectionStage="identity"
      var stageStarted=Date()
      var stageElapsedMs:[String:Int]=[:]
      var ocrRecognitionCount=0,axProbeCount=0,groupLabelReuseCount=0,statusSampleCount=0
      func enterInspectionStage(_ name:String) {
        guard inspectionStage != name else {return}
        stageElapsedMs[inspectionStage,default:0] += Int(Date().timeIntervalSince(stageStarted)*1000)
        inspectionStage=name;stageStarted=Date()
      }
      func finish(_ payload: [String: Any]) {
        guard !completed else { return }; completed = true
        var output=payload
        stageElapsedMs[inspectionStage,default:0] += Int(Date().timeIntervalSince(stageStarted)*1000)
        output["stageElapsedMs"]=stageElapsedMs
        output["ocrRecognitionCount"]=ocrRecognitionCount
        output["axProbeCount"]=axProbeCount
        output["groupLabelReuseCount"]=groupLabelReuseCount
        output["statusSampleCount"]=statusSampleCount
        output["axDiagnostics"]=output["axDiagnostics"] ?? lastRecognitionDiagnostics
        output["identitySource"]=output["identitySource"] ?? lastRecognitionDiagnostics["identitySource"] ?? "not_read"
        DispatchQueue.main.async { completion(output) }
      }
      let deadline:Date?=nil
      var expiredStage=false
      func expired()->Bool {
        if expiredStage {return true}
        let stopped = !self.allowsAutomation(automationEpoch)
        guard stopped || control.isInterrupted else {return false}
        expiredStage=true
        if openingAttempted,ownedDialogID==nil,let pid=openingPID {
          // AXPress can already have created the modal while its first frame
          // is not captured yet. Adopt only one newly-created owned window.
          for _ in 0..<5 {
            if let id=jdNewTransferModalID(before:dialogIDsBeforeOpen,after:jdTransferDialogWindowIDs(pid:pid)) {
              ownedDialogID=id;self.pendingTransferDialogID=id;break
            }
            usleep(50_000)
          }
        }
        if let pid=openingPID {_ = self.closeTransferSelection(pid:pid,windowID:ownedDialogID)}
        self.pendingTransferCustomer=nil
        finish(["error":stopped ? "automation_stopped":"handoff_yielded_for_reply",
          "message":"Transfer inspection yielded before any transfer click.","inspectionStage":inspectionStage,
          "inspectionElapsedMs":Int(Date().timeIntervalSince(started)*1000),"transferClicked":false])
        return true
      }
      if expired() { return }
      let expected = expectedCustomer.trimmingCharacters(in: .whitespacesAndNewlines)
      self.pendingTransferCustomer = nil
      guard !expected.isEmpty, AXIsProcessTrusted(), CGPreflightScreenCaptureAccess(),
            let pid = self.runningPID() else {
        finish(["error": "transfer_precondition_failed",
                "message": "JingMai, Accessibility, Screen Recording, or the customer ID is unavailable."])
        return
      }

      guard let nodes=self.receptionNodes(pid:pid) else {
        finish(["error":"transfer_window_missing","message":"The verified reception scope is unavailable."]);return
      }
      guard let reception = nodes.first(where: {
        $0.role == kAXWindowRole as String && ($0.title?.contains("咚咚融合工作台") == true)
      }) else {
        finish(["error": "transfer_window_missing",
                "message": "The JD Dingdong reception window is not available."])
        return
      }
      let scoped = nodes.filter {
        $0.path == reception.path || $0.path.hasPrefix(reception.path + "/")
      }
      guard self.activeCustomerMatches(expected, nodes: scoped) else {
        finish(["error": "transfer_customer_mismatch",
                "message": "The exact customer \(expected) is not the active JD conversation."])
        return
      }
      let sourceAccount = self.currentServiceAccount(
        in: reception, nodes: scoped, excluding: expected)
      guard let composer = scoped.first(where: { $0.role == kAXTextAreaRole as String }),
            (stringAttribute(composer.element, kAXValueAttribute)?
              .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) else {
        finish(["error": "transfer_composer_not_empty",
                "message": "Clear the current JD composer before transferring this chat."])
        return
      }
      guard let transferButton = scoped.first(where: {
        $0.role == kAXButtonRole as String &&
          ($0.description?.contains("快捷转接") == true) &&
          $0.actions.contains(kAXPressAction as String)
      }) else {
        finish(["error": "transfer_button_missing",
                "message": "JD's verified 快捷转接 button is unavailable for this conversation."])
        return
      }

      if expired() { return }
      _ = NSRunningApplication(processIdentifier: pid)?
        .activate(options: [.activateIgnoringOtherApps])
      usleep(150_000)
      if expired() {return}
      openingPID=pid
      dialogIDsBeforeOpen=jdTransferDialogWindowIDs(pid:pid)
      openingAttempted=true
      let pressed = AXUIElementPerformAction(
        transferButton.element, kAXPressAction as CFString) == .success
      if !pressed, let frame = transferButton.frame {
        _ = postClick(at: CGPoint(x: frame.midX, y: frame.midY))
      }

      enterInspectionStage("dialog_opening")
      var snapshot: TransferDialogSnapshot?
      // The modal title is painted before the canvas body. Do not treat that
      // first title-only frame as a ready dialog: it can make Vision miss the
      // group label and force coordinate fallback while the body is blank.
      for _ in 0..<24 {
        if expired() { return }
        usleep(125_000)
        guard let newlyOpened=jdNewTransferModalID(before:dialogIDsBeforeOpen,after:jdTransferDialogWindowIDs(pid:pid)),
          let observed = captureTransferDialog(pid: pid, deadline: deadline, recognize:false,control:control,windowID:newlyOpened) else { continue }
        snapshot = observed
        ownedDialogID=observed.windowID
        self.pendingTransferDialogID=observed.windowID
        // The verified CG modal title suffices to open the harmless group.
        // Do not run Vision repeatedly on a collapsed/title-only window.
        usleep(125_000)
        break
      }
      if expired() { return }
      guard var dialog = snapshot else {
        finish(["error": "transfer_dialog_missing",
                "message": "JD did not open the verified transfer dialog."])
        return
      }

      self.pendingTransferDialogID = dialog.windowID
      ownedDialogID=dialog.windowID
      enterInspectionStage("initial_recognition")
      axProbeCount += 1
      let initialAX=transferAXLabels(pid:pid,bounds:dialog.bounds,image:dialog.image,deadline:deadline)
      // Read the actual group label/disclosure even when its body is empty.
      // A blank painted-row heuristic must never authorize a guessed click.
      let initial=resolveTransferDialogLabels(ax:initialAX) {
        ocrRecognitionCount += 1
        return recognizeTransferText(in:dialog.image,deadline:deadline,control:control)
      }
      dialog=TransferDialogSnapshot(windowID:dialog.windowID,bounds:dialog.bounds,image:dialog.image,
        lines:initial.labels,diagnostics:initial.diagnostics)
      lastRecognitionDiagnostics=initial.diagnostics
      var candidates = transferAccountCandidates(in: dialog)
      enterInspectionStage("prepare_group")
      func recognizeFresh(_ raw:TransferDialogSnapshot)->TransferDialogSnapshot {
        axProbeCount += 1
        let ax=transferAXLabels(pid:pid,bounds:raw.bounds,image:raw.image,deadline:deadline)
        let labels=resolveTransferDialogLabels(ax:ax) {
          ocrRecognitionCount += 1
          return recognizeTransferText(in:raw.image,deadline:deadline,control:control)
        }
        return TransferDialogSnapshot(windowID:raw.windowID,bounds:raw.bounds,image:raw.image,
          lines:labels.labels,diagnostics:labels.diagnostics)
      }
      func retainRecognizedNames(_ observed:TransferDialogSnapshot,_ rows:[TransferAccountCandidate]) {
        guard self.allowsAutomation(automationEpoch),!rows.isEmpty,
          !observed.lines.contains(where:{$0.source=="accessibility"}) else { return }
        self.transferNameCache=JDTransferNameCache(customer:expected,pid:pid,epoch:automationEpoch,
          seenAt:ProcessInfo.processInfo.systemUptime,snapshot:observed)
      }
      retainRecognizedNames(dialog,candidates)
      func waitForStableExpandedAccounts() {
        let confirmationStarted=Date()
        var previousInactiveKey:String?
        var inactiveFrames=0
        var bestDialog = dialog
        var bestCandidates = candidates
        var latestDialog = dialog
        var previousActiveKey: String?
        var consecutiveActiveFrames = 0
        var collapsedFrames=0

        for _ in 0..<16 {
          if expired() { return }
        usleep(125_000)
          guard let raw = captureTransferDialog(pid: pid, deadline: deadline, recognize:false,control:control,windowID:ownedDialogID) else { continue }
          let expanded:TransferDialogSnapshot
          // A current AX identity always wins. Only the modal's OCR-only
          // fallback can reuse a name after exact fresh glyph verification.
          axProbeCount += 1
          let ax=transferAXLabels(pid:pid,bounds:raw.bounds,image:raw.image,deadline:deadline)
          if !ax.labels.isEmpty {
            expanded=TransferDialogSnapshot(windowID:raw.windowID,bounds:raw.bounds,image:raw.image,
              lines:ax.labels,diagnostics:ax.diagnostics)
            lastRecognitionDiagnostics=ax.diagnostics
          } else if let reused=transferDialogReusingNames(raw,latestDialog) ??
              self.transferNameCache?.reusing(raw,customer:expected,pid:pid,
                epoch:automationEpoch,now:ProcessInfo.processInfo.systemUptime) {
            expanded=reused
          } else {
            enterInspectionStage("recognize_expanded_accounts")
            let recognized=resolveTransferDialogLabels(ax:ax) {
              ocrRecognitionCount += 1
              return recognizeTransferText(in:raw.image,deadline:deadline,control:control)
            }
            lastRecognitionDiagnostics=recognized.diagnostics
            expanded=TransferDialogSnapshot(windowID:raw.windowID,bounds:raw.bounds,image:raw.image,lines:recognized.labels,diagnostics:recognized.diagnostics)
          }
          enterInspectionStage("confirm_green_badges")
          latestDialog = expanded
          statusSampleCount += 1
          let observed = transferAccountCandidates(in: expanded)
          if observed.isEmpty && jdTransferGroupDisclosure(expanded).state == .collapsed {
            collapsedFrames+=1
            if collapsedFrames>=3 {dialog=expanded;candidates=[];return}
          } else {collapsedFrames=0}
          retainRecognizedNames(expanded,observed)
          let observedActive = observed.filter(\.isActive)
          let bestActive = bestCandidates.filter(\.isActive)
          if observedActive.count > bestActive.count ||
              (observedActive.count == bestActive.count &&
                observed.count > bestCandidates.count) {
            bestDialog = expanded
            bestCandidates = observed
          }

          let activeKey = observedActive
            .map { customerIdentityKey($0.name) }
            .sorted()
            .joined(separator: "|")
          if !activeKey.isEmpty && activeKey == previousActiveKey {
            consecutiveActiveFrames += 1
          } else {
            previousActiveKey = activeKey.isEmpty ? nil : activeKey
            consecutiveActiveFrames = activeKey.isEmpty ? 0 : 1
          }
          let inactiveKey=observed.map { $0.name }.sorted().joined(separator:"\u{1f}")
          if observedActive.isEmpty && !observed.isEmpty {
            inactiveFrames=inactiveKey==previousInactiveKey ? inactiveFrames+1:1
            previousInactiveKey=inactiveKey
            // Never infer "online" from a readable name. Stable non-green
            // rows finish as no confirmed active account, not an OCR timeout.
            if inactiveFrames>=3 && Date().timeIntervalSince(confirmationStarted)>=0.5 {
              dialog=expanded;candidates=observed;return
            }
          } else {inactiveFrames=0;previousInactiveKey=nil}
          // JD renders the account text before its status badges during the
          // expansion animation. Require the same non-empty green set twice
          // so a transient name-only frame cannot become an agents-busy result.
          if consecutiveActiveFrames >= 2 {
            dialog = expanded
            candidates = observed
            return
          }
        }
        // When no row is recognized, retain the latest frame for diagnostics
        // instead of reporting the title-only frame captured during opening.
        dialog = bestCandidates.isEmpty ? latestDialog : bestDialog
        candidates = bestCandidates
      }

      var expansionClickPoint: CGPoint?
      var disclosure=jdTransferGroupDisclosure(dialog)
      if candidates.isEmpty && disclosure.state == .unknown {
        // A newly opened modal may have painted only its title. Obtain fresh
        // process evidence; never infer collapse from age or an empty list.
        for _ in 0..<3 {
          if expired() {return}
          guard let raw=captureTransferDialog(pid:pid,deadline:deadline,recognize:false,control:control,windowID:ownedDialogID) else {continue}
          let fresh=recognizeFresh(raw)
          dialog=fresh;candidates=transferAccountCandidates(in:fresh)
          lastRecognitionDiagnostics=fresh.diagnostics
          disclosure=jdTransferGroupDisclosure(fresh)
          if !candidates.isEmpty || disclosure.state != .unknown {break}
        }
      }
      if candidates.isEmpty && disclosure.state == .collapsed {
        // Retry a missed group click only after another fresh frame proves
        // that the same owned group's arrow still points right. Expanded or
        // unreadable states never receive a toggle.
        for _ in 0..<2 {
          if expired() {return}
          guard let raw=captureTransferDialog(pid:pid,deadline:deadline,recognize:false,control:control,windowID:ownedDialogID) else {break}
          let fresh:TransferDialogSnapshot
          if let reused=transferDialogReusingGroupLabel(raw,dialog) {
            groupLabelReuseCount += 1;fresh=reused
          } else {fresh=recognizeFresh(raw)}
          dialog=fresh;candidates=transferAccountCandidates(in:fresh)
          let current=jdTransferGroupDisclosure(fresh)
          guard candidates.isEmpty,current.state == .collapsed,let point=current.point,
            jdTransferDialogWindowIDs(pid:pid).contains(fresh.windowID),
            NSWorkspace.shared.frontmostApplication?.processIdentifier==pid else {break}
          let global=fresh.globalPoint(for:point)
          if expired() {return}
          expansionClickPoint=global
          _=postHover(at:global)
          guard postClick(at:global) else {break}
          enterInspectionStage("expanded_accounts")
          waitForStableExpandedAccounts()
          if expired() {return}
          disclosure=jdTransferGroupDisclosure(dialog)
          if !candidates.isEmpty || disclosure.state != .collapsed {break}
        }
      } else if !candidates.isEmpty || disclosure.state == .expanded {
        enterInspectionStage("confirm_existing_expanded_accounts")
        waitForStableExpandedAccounts()
        if expired() {return}
      }

      if expired() { return }
      guard !candidates.isEmpty else {
        let recognized = dialog.lines
          .map { compactTransferText($0.text) }
          .filter { !$0.isEmpty }
          .joined(separator: " | ")
        let boundsSummary = String(
          format: "bounds=(%.0f,%.0f %.0fx%.0f), image=%.0fx%.0f",
          dialog.bounds.minX, dialog.bounds.minY,
          dialog.bounds.width, dialog.bounds.height,
          dialog.imageWidth, dialog.imageHeight)
        let clickSummary = expansionClickPoint.map {
          String(format: "click=(%.0f,%.0f), local=(%.0f,%.0f)",
                 $0.x, $0.y,
                 $0.x - dialog.bounds.minX, $0.y - dialog.bounds.minY)
        } ?? "click=not-required"
        _ = self.closeTransferSelection(pid:pid,windowID:ownedDialogID)
        finish(["error": "transfer_group_not_expanded",
                "message": "JD's 默认咨询组 did not expose recognizable account rows after fresh disclosure verification. Only a proven collapsed group can be clicked. \(boundsSummary), \(clickSummary). OCR: \(recognized.prefix(500))"])
        return
      }

      let active = candidates.filter(\.isActive)
      var seen = Set<String>()
      if expired() { return }
      let accounts = active.map(\.name).filter {
        seen.insert(customerIdentityKey($0)).inserted
      }
      guard !accounts.isEmpty else {
        let evidence = candidates.map {
          "\($0.name)[green=\($0.greenPixelEvidence),red=\($0.redPixelEvidence)]"
        }.joined(separator: ", ")
        _ = self.closeTransferSelection(pid:pid,windowID:ownedDialogID)
        finish(["error": "no_active_transfer_accounts",
                "message": evidence.isEmpty
                  ? "No JD sub-account rows were recognized after expanding the consultation group."
                  : "No visible JD sub-account had a confirmed green active badge. Observed: \(evidence)"])
        return
      }
      if expired() { return }
      self.pendingTransferCustomer = expected
      self.pendingTransferSnapshot = dialog
      var diagnostics=dialog.diagnostics
      diagnostics["staffRows"]=transferRowDiagnostics(candidates)
      finish(["accounts": accounts, "customer": expected,
              "sourceAccount": sourceAccount,"inspectionStage":"accounts_confirmed",
              "identitySource":dialog.diagnostics["identitySource"] ?? "ocr",
              "axDiagnostics":diagnostics,
              "inspectionElapsedMs":Int(Date().timeIntervalSince(started)*1000),"transferClicked":false])
    }
  }

  /// Revalidates the selected account's green badge, selects its row to reveal
  /// actions, and clicks only that row's explicit blue 转接 control. The
  /// adjacent 备注原因 control is never used.
  func transferConversation(expectedCustomer: String, targetAccount: String, attemptId:String?=nil,receiptPath:String?=nil,automationEpoch: Int? = nil,
                            completion: @escaping FlutterResult) {
    let control=beginTransferWork(automationEpoch)
    queue.async { [weak self] in
      guard let self else { return }
      defer {self.endTransferWork(control)}
      var ownedDialogID:CGWindowID?
      let started=Date()
      let expected=expectedCustomer.trimmingCharacters(in:.whitespacesAndNewlines)
      let target=targetAccount.trimmingCharacters(in:.whitespacesAndNewlines)
      if self.allowsAutomation(automationEpoch),
          self.pendingTransferCustomer.map({exactCustomerIdentityMatches($0,expected)})==true {
        ownedDialogID=self.pendingTransferDialogID
      }
      var clicked=false
      var clickIntent=false
      var stage="revalidate_names_and_badges"
      var finished=false
      var latestDiagnostics:[String:Any]=[:]
      func finish(_ payload: [String: Any]) {
        guard !finished else { return };finished=true
        let receiptState=payload["transferred"] as? Bool == true ? "confirmed":((clicked || clickIntent) ? "unknown":"not_clicked")
        let persisted=self.writeTransferReceipt(receiptPath,attemptId:attemptId,customer:expected,target:target,
          state:receiptState,clicked:clicked || clickIntent,error:payload["error"] as? String)
        var result=payload;result["receiptState"]=receiptState;result["receiptPersisted"]=persisted
        if let attemptId {result["attemptId"]=attemptId}
        result["transferClicked"]=clicked || clickIntent;result["stage"]=stage;result["axDiagnostics"]=latestDiagnostics
        result["elapsedMs"]=Int(Date().timeIntervalSince(started)*1000)
        DispatchQueue.main.async { completion(result) }
      }
      let deadline:Date?=nil
      func expired()->Bool {
        let stopped = !self.allowsAutomation(automationEpoch)
        guard stopped || control.isInterrupted else {return false}
        // A pre-click modal may yield safely. Once intent is journaled,
        // leave the UI as evidence and preserve an unknown physical outcome.
        if !(clicked || clickIntent),let pid=self.runningPID() {
          _ = self.closeTransferSelection(pid:pid,windowID:ownedDialogID)
        }
        finish(["error":(clicked || clickIntent) ? "transfer_unconfirmed":
          (stopped ? "automation_stopped":"handoff_yielded_for_reply"),
          "message":"Transfer yielded to a reply; any click intent still requires reconciliation."])
        return true
      }
      guard self.writeTransferReceipt(receiptPath,attemptId:attemptId,customer:expected,target:target,state:"prepared",clicked:false) else {
        finish(["error":"transfer_receipt_unavailable","message":"The transfer journal could not be prepared; no transfer was clicked."]);return
      }
      if expired() { return }
      guard !expected.isEmpty, !target.isEmpty, AXIsProcessTrusted(),
            CGPreflightScreenCaptureAccess(), let pid = self.runningPID(),
            self.pendingTransferCustomer.map({
              exactCustomerIdentityMatches($0, expected)
            }) == true else {
        finish(["error": "transfer_selection_expired",
                "message": "The verified JD transfer selection expired. Inspect active accounts again."])
        return
      }
      let fresh=captureTransferDialog(pid:pid,deadline:deadline,recognize:false,control:control,windowID:ownedDialogID)
      if let fresh,self.pendingTransferDialogID==fresh.windowID {ownedDialogID=fresh.windowID}
      let reused=fresh.flatMap { image in self.pendingTransferSnapshot.flatMap { transferDialogReusingNames(image,$0) } }
      guard var dialog = reused ?? captureTransferDialog(pid: pid, deadline: deadline,control:control,windowID:ownedDialogID),
            let candidate = transferAccountCandidates(in: dialog).first(where: {
              $0.isActive && exactCustomerIdentityMatches($0.name, target)
            }) else {
        if expired() {return}
        self.pendingTransferCustomer = nil
        finish(["error": "transfer_target_not_active",
                "message": "The selected account \(target) no longer has a confirmed green badge."])
        return
      }

      jdDryRunSnapshot(dialog,"before-hover")
      jdDryRunRecord(["event":"selected_target","target":target,"frame":[candidate.frame.minX,candidate.frame.minY,candidate.frame.width,candidate.frame.height],"active":candidate.isActive])
      _ = NSRunningApplication(processIdentifier: pid)?
        .activate(options: [.activateIgnoringOtherApps])
      usleep(150_000)
      // Click inside the account-name portion of the row. This reveals the
      // row-specific 转接 and 备注原因 actions; neither exists while collapsed.
      // Keep the click well left of the action area observed in JD 10.4.5 so
      // selecting the account can never accidentally invoke 转接 itself.
      let rowSelectionX = min(
        max(candidate.frame.midX, dialog.imageWidth * 0.24),
        dialog.imageWidth * 0.50)
      ownedDialogID=dialog.windowID
      if expired() {return}
      stage="hover_target_row"
      let rowPoint=dialog.globalPoint(for:CGPoint(x:rowSelectionX,y:candidate.frame.midY))
      jdDryRunRecord(["event":"hover_point","global":[rowPoint.x,rowPoint.y],"pixel":[rowSelectionX,candidate.frame.midY]])
      guard postHover(at:rowPoint) else {
        finish(["error":"transfer_row_hover_failed","message":"Could not move the pointer onto the selected staff row; no transfer was clicked."]);return
      }
      if expired() {return}
      guard postClick(at:rowPoint) else {
        finish(["error":"transfer_row_selection_failed","message":"Could not select the staff row; no transfer was clicked."]);return
      }

      stage="verify_target_action"
      var actionPoint: CGPoint?
      var actionElement:AXUIElement?
      var targetIdentitySource=candidate.identitySource
      for iteration in 0..<12 {
        if expired() { return }
        usleep(125_000)
        guard let selected = captureTransferDialog(pid: pid, deadline: deadline,requireAction:true,control:control,windowID:ownedDialogID) else { break }
        jdDryRunSnapshot(selected,"after-hover-\(iteration)")
        dialog = selected
        latestDiagnostics=selected.diagnostics
        guard let selectedCandidate = transferAccountCandidates(in: selected).first(where: {
          $0.isActive && exactCustomerIdentityMatches($0.name, target)
        }) else { continue }
        jdDryRunRecord(["event":"button_conditions","iteration":iteration,"target":target,
          "selectedCandidateActive":selectedCandidate.isActive,
          "lines":selected.lines.map {line in ["text":line.text,"exactText":compactTransferText(line.text)=="转接",
            "x":Double(line.frame.midX),"y":Double(line.frame.midY),
            "xLowerPass":line.frame.midX>selected.imageWidth*0.55,
            "xUpperPass":line.frame.midX<selected.imageWidth*0.85,
            "rowPass":jdTransferActionBelongsToRow(action:line.frame,candidate:selectedCandidate)]}])
        // Re-anchor to the freshly captured row. Selecting an account can
        // slightly change row geometry when JD reveals 转接 / 备注原因.
        if let action = selected.lines
          .filter({
            compactTransferText($0.text) == "转接" &&
              $0.frame.midX > selected.imageWidth * 0.55 &&
              $0.frame.midX < selected.imageWidth * 0.85 &&
              jdTransferActionBelongsToRow(action:$0.frame,candidate:selectedCandidate)
          })
          .min(by: {
            abs($0.frame.midY - selectedCandidate.frame.midY) <
              abs($1.frame.midY - selectedCandidate.frame.midY)
          }) {
          latestDiagnostics["staffRows"]=transferRowDiagnostics(transferAccountCandidates(in:selected))
          latestDiagnostics["selectedActionCenterY"]=Double(action.frame.midY)
          latestDiagnostics["selectedActionRowBounded"]=true
          actionElement=action.axElement
          targetIdentitySource=selectedCandidate.identitySource
          actionPoint = selected.globalPoint(for: CGPoint(
            x: action.frame.midX, y: action.frame.midY))
          break
        }
      }
      guard let actionPoint else {
        if expired() {return}
        self.pendingTransferCustomer = nil
        finish(["error": "transfer_action_missing",
                "message": "JD did not reveal the selected row's explicit 转接 action. Nothing was transferred."])
        return
      }

      // The caller showed an explicit confirmation before invoking this
      // method. Clear the one-shot token before the external transfer click so
      // an unconfirmed outcome can never be retried automatically.
      self.pendingTransferCustomer = nil
      self.pendingTransferSnapshot = nil
      stage="verify_customer_before_click"
      guard let actual=self.activeCustomerIdentity(),exactCustomerIdentityMatches(actual,expected),
        NSWorkspace.shared.frontmostApplication?.processIdentifier==pid else {
        finish(["error":"transfer_customer_mismatch","message":"Exact active AX customer changed before the transfer click."]);return
      }
      if expired() { return }
      if let actionElement {
        guard stringAttribute(actionElement,kAXRoleAttribute)==kAXButtonRole as String,
          [stringAttribute(actionElement,kAXTitleAttribute),stringAttribute(actionElement,kAXDescriptionAttribute),stringAttribute(actionElement,kAXValueAttribute)].compactMap({$0}).contains("转接"),
          boolAttribute(actionElement,kAXEnabledAttribute) != false else {
          finish(["error":"transfer_action_missing","message":"The exact row's AX transfer action changed or became disabled; no transfer was clicked."]);return
        }
      }
      if expired() {return}
      jdDryRunRecord(["event":"dry_run_stopped_before_click","wouldClick":[actionPoint.x,actionPoint.y]])
      finish(["dryRun":true,"transferClicked":false,"wouldClick":[actionPoint.x,actionPoint.y]])
      return
      stage="persist_click_intent"
      guard self.writeTransferReceipt(receiptPath,attemptId:attemptId,customer:expected,target:target,state:"click_intent",clicked:true) else {
        finish(["error":"transfer_receipt_unavailable","message":"Click intent could not be journaled; no transfer was clicked."]);return
      }
      clickIntent=true
      if expired() {return}
      stage="click_and_confirm"
      clicked = true
      let dispatched=false // HARD DISABLED: NO TRANSFER CLICK IN THIS HARNESS
      guard dispatched else {
        finish(["error": "transfer_click_failed",
                "message": "Could not click JD's explicit 转接 action."])
        return
      }
      _ = self.writeTransferReceipt(receiptPath,attemptId:attemptId,customer:expected,target:target,state:"clicked",clicked:true)
      for _ in 0..<20 {
        if expired() { return }
        usleep(150_000)
        if !jdWindowVisible(pid: pid, windowID: dialog.windowID) {
          finish(["transferred": true, "customer": expected,
                  "targetAccount": target, "verification": "dialog_closed",
                  "targetIdentitySource":targetIdentitySource,"actionSource":actionElement == nil ? "ocr":"accessibility"])
          return
        }
      }
      finish(["error": "transfer_unconfirmed",
              "message": "JD's 转接 action was clicked once, but the dialog did not close. Do not retry automatically; verify in JD."])
    }
  }

  func cancelTransferSelection(completion: @escaping FlutterResult) {
    queue.async { [weak self] in
      guard let self else { return }
      func finish(_ value: [String: Any]) { DispatchQueue.main.async { completion(value) } }
      self.pendingTransferCustomer = nil
      guard let pid = self.runningPID() else { finish(["closed": true]); return }
      guard let id=self.pendingTransferDialogID else {finish(["closed":true]);return}
      if !jdWindowVisible(pid:pid,windowID:id) {self.pendingTransferDialogID=nil;finish(["closed":true]);return}
      guard self.closeTransferSelection(pid:pid,windowID:id) else {
        finish(["error":"transfer_dialog_close_failed","message":"The owned transfer modal is not frontmost; no unrelated window was touched."]);return
      }
      let deadline = Date().addingTimeInterval(0.8)
      repeat {
        usleep(80_000)
        let remains=jdWindowVisible(pid:pid,windowID:id)
        if !remains { self.pendingTransferDialogID = nil; finish(["closed": true]); return }
      } while Date() < deadline
      finish(["error": "transfer_dialog_close_failed", "message": "The verified transfer modal did not close."])
    }
  }

  /// Sample the verified transcript, excluding chrome and the composer.
  /// The small comparison raster tolerates minor paint noise while still
  /// distinguishing a scroll from an unchanged chat at its boundary.
  private func historyViewportSampler(pid: pid_t, transcript: CGRect) -> (() -> [UInt8]?)? {
    guard CGPreflightScreenCaptureAccess(),
          let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],
              kCGNullWindowID) as? [[String:Any]] else { return nil }
    let owners = windows.compactMap { info -> CGWindowID? in
      guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
            (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
            (info[kCGWindowName as String] as? String)?.contains("咚咚融合工作台") == true,
            let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
            let bounds = windowBounds(id),bounds.contains(transcript) else { return nil }
      return id
    }
    guard owners.count == 1, let id = owners.first else { return nil }
    let area = CGRect(x: transcript.minX + transcript.width * 0.035,
      y: transcript.minY + transcript.height * 0.12, width: transcript.width * 0.68,
      height: transcript.height * 0.76).integral
    guard area.width >= 80, area.height >= 80 else { return nil }
    return {
      guard let image = CGWindowListCreateImage(area,.optionIncludingWindow,id,
             [.boundsIgnoreFraming,.nominalResolution]) else { return nil }
      let width = 96, height = 64
      var pixels = [UInt8](repeating:0,count:width*height)
      let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(data:buffer.baseAddress,width:width,height:height,
          bitsPerComponent:8,bytesPerRow:width,space:CGColorSpaceCreateDeviceGray(),
          bitmapInfo:CGImageAlphaInfo.none.rawValue) else { return false }
        context.interpolationQuality = .low
        context.draw(image,in:CGRect(x:0,y:0,width:width,height:height))
        return true
      }
      return drawn ? pixels : nil
    }
  }

  private func historyViewportChanged(_ before: [UInt8], _ after: [UInt8]) -> Bool {
    guard before.count == after.count else { return true }
    var changed = 0
    for i in before.indices where abs(Int(before[i])-Int(after[i])) >= 9 {
      changed += 1
      if changed >= 12 { return true }
    }
    return false
  }

  /// Scrolls only the verified active chat viewport. Positive values reveal
  /// older/upper content; negative values return toward the newest message.
  func scrollConversation(expectedCustomer: String, deltaY: Int32,
                          waitForViewport: Bool = false, viewportSteps: Int? = nil,
                          completion: @escaping FlutterResult) {
    queue.async { [weak self] in
      guard let self else { return }
      func finish(_ payload: [String: Any]) {
        DispatchQueue.main.async { completion(payload) }
      }
      let expected = expectedCustomer.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !expected.isEmpty, deltaY != 0, AXIsProcessTrusted(),
            let pid = runningPID() else {
        finish(["error": "scroll_precondition_failed",
                "message": "Customer, scroll amount, or Accessibility is unavailable."])
        return
      }
      guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
        finish(["error": "qianniu_not_frontmost",
                "message": "JingMai is not active. Chat scrolling was deferred without stealing focus."])
        return
      }
      let root = AXUIElementCreateApplication(pid)
      var nodes: [AXNode] = []
      walk(root, path: "app", depth: 0, maxDepth: 22, maxNodes: 5_000) {
        node, _ in nodes.append(node)
      }
      guard activeCustomerMatches(expected, nodes: nodes),
            let composer = nodes.first(where: { $0.role == kAXTextAreaRole as String }),
            let composerFrame = composer.frame,
            (stringAttribute(composer.element, kAXValueAttribute)?
              .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
            let split = nodes
              .filter({ $0.role == kAXSplitGroupRole as String && composer.path.hasPrefix($0.path + "/") })
              .max(by: { $0.path.count < $1.path.count }),
            let splitFrame = split.frame else {
        finish(["error": "scroll_verification_failed",
                "message": "The exact active chat viewport or empty composer could not be verified."])
        return
      }
      let messageBottom = min(composerFrame.minY, splitFrame.maxY)
      let transcript = CGRect(x:splitFrame.minX,y:splitFrame.minY,width:splitFrame.width,
                              height: max(0,messageBottom-splitFrame.minY))
      let amount = viewportSteps.flatMap { steps -> Int32? in
        guard steps > 0, deltaY > 0, transcript.height.isFinite else { return nil }
        let step = max(60, min(700, Int((transcript.height * 0.30).rounded())))
        return Int32(clamping: step * min(steps, 100))
      } ?? deltaY
      let point = CGPoint(x: splitFrame.midX,
                          y: splitFrame.minY + (messageBottom - splitFrame.minY) * 0.55)
      guard let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                               mouseCursorPosition: point, mouseButton: .left),
            let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                 wheelCount: 1, wheel1: amount,
                                 wheel2: 0, wheel3: 0) else {
        finish(["error": "scroll_event_failed",
                "message": "Could not create a guarded chat scroll event."])
        return
      }
      move.post(tap: .cghidEventTap)
      let sample = waitForViewport ? historyViewportSampler(pid:pid,transcript:transcript) : nil
      let reference = sample?()
      let began = ProcessInfo.processInfo.systemUptime
      scroll.post(tap: .cghidEventTap)
      var settle = "fixed_fallback"
      if let sample, let reference {
        var last = reference, moved = false, stable = 0
        while ProcessInfo.processInfo.systemUptime - began < 0.450 {
          usleep(40_000)
          guard let current = sample() else { continue }
          moved = moved || historyViewportChanged(reference,current)
          stable = moved && !historyViewportChanged(last,current) ? stable+1 : 0
          last = current
          if stable >= 2 {
            settle = "moved_and_stable"
            break
          }
        }
        if settle != "moved_and_stable" {
          settle = moved ? "not_stable_by_fallback" : "no_visible_change"
        }
      } else {
        usleep(450_000)
      }
      let settleElapsedMs = Int((ProcessInfo.processInfo.systemUptime-began)*1000)
      var after: [AXNode] = []
      walk(root, path: "app", depth: 0, maxDepth: 22, maxNodes: 5_000) {
        node, _ in after.append(node)
      }
      guard activeCustomerMatches(expected, nodes: after) else {
        finish(["error": "scroll_customer_changed",
                "message": "The active customer changed during scrolling."])
        return
      }
      finish(["scrolled": true, "customer": expected, "deltaY": Int(amount),
              "viewportSettle": settle, "settleElapsedMs": settleElapsedMs])
    }
  }

  private func poll() {
    guard AXIsProcessTrusted(), let pid = runningPID() else { return }
    let root = AXUIElementCreateApplication(pid)
    var nodes: [AXNode] = []
    walk(root, path: "app", depth: 0, maxDepth: 22, maxNodes: 5_000) { node, _ in nodes.append(node) }

    // Validated against Qianniu macOS 9.95.01. Scope all matching to the reception
    // window so similarly named controls in the workbench window cannot be selected.
    guard let receptionWindow = nodes.first(where: {
      $0.role == kAXWindowRole as String && ($0.title?.contains("咚咚融合工作台") == true)
    }) else {
      onDiagnostic?(["event": "reception_window_missing",
                     "hint": "Open JingMai's customer-service reception center."])
      return
    }
    let scopedNodes = nodes.filter {
      $0.path == receptionWindow.path || $0.path.hasPrefix(receptionWindow.path + "/")
    }
    guard let composer = scopedNodes.first(where: { $0.role == kAXTextAreaRole as String }),
          let splitGroup = scopedNodes
            .filter({ $0.role == kAXSplitGroupRole as String && composer.path.hasPrefix($0.path + "/") })
            .max(by: { $0.path.count < $1.path.count }) else {
      onDiagnostic?(["event": "composer_missing",
                     "hint": "Keep an active conversation open and inspect the AX tree again."])
      return
    }

    guard let splitFrame = splitGroup.frame,
          let customerNode = scopedNodes
            .filter({ node in
              guard node.role == "AXStaticText", let frame = node.frame,
                    let text = node.text, !text.isEmpty else { return false }
              return frame.minX >= splitFrame.minX && frame.maxX <= splitFrame.maxX &&
                frame.maxY <= splitFrame.minY && frame.minY >= splitFrame.minY - 100
            })
            .max(by: { ($0.frame?.minY ?? 0) < ($1.frame?.minY ?? 0) }),
          let customerName = customerNode.text else {
      onDiagnostic?(["event": "customer_identity_missing",
                     "splitFrame": normalizedFrame(splitGroup.frame)])
      return
    }
    let conversationKey = stableConversationKey(customerNode, customerName: customerName)
    lastActiveConversation = conversationKey

    // The live dump exposes message history as AXSplitGroup/AXGroup/AXList and the
    // composer as AXTextArea. Restricting the list to this split group excludes the
    // sidebar and the customer/product panels.
    guard let composerFrame = composer.frame,
          let messageArea = scopedNodes
            .filter({ node in
              guard node.role == "AXList", let frame = node.frame else { return false }
              return node.path.hasPrefix(splitGroup.path + "/") && frame.maxY <= composerFrame.minY
            })
            .max(by: { ($0.frame?.width ?? 0) < ($1.frame?.width ?? 0) }) else {
      onDiagnostic?(["event": "message_list_missing", "customer": customerName])
      return
    }
    let messageNodes = scopedNodes.filter {
      $0.path.hasPrefix(messageArea.path + "/") && $0.role == "AXStaticText" && $0.text != nil
    }
    let captures: [[String: Any]] = messageNodes.compactMap { node in
      guard let body = node.text, body != customerName, body.count <= 20_000 else { return nil }
      let fingerprint = sha256([conversationKey, node.identifier ?? "", body, normalizedFrame(node.frame), node.path].joined(separator: "\u{1f}"))
      guard seenFingerprints.insert(fingerprint).inserted else { return nil }
      return [
        "stableId": node.identifier.flatMap { $0.isEmpty ? nil : "ax:\($0)" } ?? "fp:\(fingerprint)",
        "direction": inferDirection(node: node, container: messageArea),
        "body": body,
        "axPath": node.path,
      ]
    }
    guard !captures.isEmpty else {
      onDiagnostic?(["event": "capture_ready", "customer": customerName,
                     "messageList": messageArea.path, "visibleMessages": messageNodes.count,
                     "note": "No unseen accessible messages are currently visible."])
      return
    }
    onCapture?([
      "stableKey": conversationKey,
      "customerName": customerName,
      "messages": captures,
      "capturedAtMs": Int(Date().timeIntervalSince1970 * 1000),
    ])
  }

  private func inferDirection(node: AXNode, container: AXNode) -> String {
    guard let x = node.frame?.midX, let middle = container.frame?.midX else { return "unknown" }
    return x < middle ? "incoming" : "outgoing"
  }

  private func stableConversationKey(_ identity: AXNode, customerName: String) -> String {
    if let identifier = identity.identifier, !identifier.isEmpty { return "ax:\(identifier)" }
    return "customer:\(sha256(customerName))"
  }

  private func descendantTexts(of ancestor: AXNode, in nodes: [AXNode]) -> [String] {
    nodes.lazy.filter { $0.path.hasPrefix(ancestor.path + "/") }
      .compactMap(\.text).filter { !$0.isEmpty }
  }

  @discardableResult
  private func walk(_ element: AXUIElement, path: String, depth: Int, maxDepth: Int,
                    maxNodes: Int, timeBudget: TimeInterval? = nil,
                    now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                    nodeReader: ((AXUIElement,String,()->Bool)->AXNode?)? = nil,
                    roleReader: ((AXUIElement)->String?)? = nil,
                    visit: (AXNode, Int) -> Void) -> Bool {
    guard depth <= maxDepth else { return false }
    let deadline = timeBudget.map { now() + max(0,$0) }
    var complete=true;var visited=0
    func available()->Bool { deadline.map { now() < $0 } ?? true }
    func prepare(_ current:AXUIElement)->Bool {
      guard available() else { complete=false;return false }
      if nodeReader == nil || roleReader == nil {
        AXUIElementSetMessagingTimeout(current,Float(min(0.15,deadline.map { max(0.001,$0-now()) } ?? 0.15)))
      }
      return true
    }
    func recurse(_ current:AXUIElement,_ currentPath:String,_ currentDepth:Int) {
      guard currentDepth<=maxDepth else { return }
      guard visited<maxNodes,prepare(current) else {complete=false;return}
      visited+=1
      let readAllowed = { prepare(current) }
      guard let node=nodeReader?(current,currentPath,readAllowed) ??
        (nodeReader == nil ? makeNode(current,path:currentPath,readAllowed:readAllowed):nil),
        available() else {complete=false;return}
      visit(node,currentDepth)
      guard currentDepth<maxDepth else {return}
      var roleCounts=[String:Int]()
      for child in node.children {
        guard visited<maxNodes,prepare(child) else {complete=false;break}
        let role=(roleReader?(child) ?? (roleReader == nil ? stringAttribute(child,kAXRoleAttribute):nil)) ?? "AXUnknown"
        guard available() else {complete=false;break}
        let index=roleCounts[role,default:0];roleCounts[role]=index+1
        recurse(child,"\(currentPath)/\(role)[\(index)]",currentDepth+1)
        if !complete {break}
      }
    }
    recurse(element,path,depth)
    return complete && available()
  }

  private func makeNode(_ element: AXUIElement, path: String,readAllowed:()->Bool) -> AXNode? {
    guard readAllowed() else {return nil}
    var names:CFArray?
    AXUIElementCopyActionNames(element,&names)
    func text(_ attribute:String)->String? {
      guard readAllowed() else {return nil};return stringAttribute(element,attribute)
    }
    let role=text(kAXRoleAttribute) ?? "AXUnknown"
    let subrole=text(kAXSubroleAttribute),identifier=text(kAXIdentifierAttribute)
    let title=text(kAXTitleAttribute),description=text(kAXDescriptionAttribute)
    let value=text(kAXValueAttribute),help=text(kAXHelpAttribute)
    let frame=frameAttribute(element,readAllowed:readAllowed)
    guard readAllowed() else {return nil}
    let children=elementArrayAttribute(element,kAXChildrenAttribute)
    guard readAllowed() else {return nil}
    return AXNode(element:element,path:path,role:role,subrole:subrole,identifier:identifier,
      title:title,description:description,value:value,help:help,frame:frame,
      actions:names as? [String] ?? [],children:children)
  }

}

private func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
  var value: CFTypeRef?
  guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
  if let string = value as? String { return string }
  if let number = value as? NSNumber { return number.stringValue }
  return nil
}

private func boolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool? {
  var value: CFTypeRef?
  guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
  return (value as? NSNumber)?.boolValue
}

private func elementArrayAttribute(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
  var value: CFTypeRef?
  guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
  return value as? [AXUIElement] ?? []
}

private func frameAttribute(_ element: AXUIElement, readAllowed:()->Bool = {true}) -> CGRect? {
  var positionValue: CFTypeRef?
  var sizeValue: CFTypeRef?
  guard readAllowed(), AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
        readAllowed(), AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
        let positionAX = positionValue, let sizeAX = sizeValue,
        CFGetTypeID(positionAX) == AXValueGetTypeID(), CFGetTypeID(sizeAX) == AXValueGetTypeID() else { return nil }
  var point = CGPoint.zero
  var size = CGSize.zero
  guard AXValueGetValue(positionAX as! AXValue, .cgPoint, &point),
        AXValueGetValue(sizeAX as! AXValue, .cgSize, &size) else { return nil }
  return CGRect(origin: point, size: size)
}

private func normalizedFrame(_ frame: CGRect?) -> String {
  guard let frame else { return "-" }
  return "\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))"
}

private func sha256(_ value: String) -> String {
  SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}

private struct PasteboardSnapshot {
  private let items: [[NSPasteboard.PasteboardType: Data]]

  init(_ pasteboard: NSPasteboard) {
    items = (pasteboard.pasteboardItems ?? []).map { item in
      Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
        item.data(forType: type).map { (type, $0) }
      })
    }
  }

  func restore(to pasteboard: NSPasteboard) {
    pasteboard.clearContents()
    let restored = items.map { values -> NSPasteboardItem in
      let item = NSPasteboardItem()
      for (type, data) in values { item.setData(data, forType: type) }
      return item
    }
    if !restored.isEmpty { pasteboard.writeObjects(restored) }
  }
}

private func postCommandC() -> Bool {
  guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: true),
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: false) else { return false }
  down.flags = .maskCommand
  up.flags = .maskCommand
  down.post(tap: .cghidEventTap)
  up.post(tap: .cghidEventTap)
  return true
}

private func postCommandV() -> Bool {
  guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false) else { return false }
  down.flags = .maskCommand
  up.flags = .maskCommand
  down.post(tap: .cghidEventTap)
  up.post(tap: .cghidEventTap)
  return true
}

private func averageImageHash(_ image: CGImage) -> String {
  var pixels = [UInt8](repeating: 0, count: 64)
  let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
    guard let context = CGContext(data: buffer.baseAddress, width: 8, height: 8,
                                  bitsPerComponent: 8, bytesPerRow: 8,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
      return false
    }
    context.interpolationQuality = .medium
    context.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 8))
    return true
  }
  guard rendered else { return "" }
  let average = pixels.reduce(0) { $0 + Int($1) } / pixels.count
  var hash: UInt64 = 0
  for (index, pixel) in pixels.enumerated() where Int(pixel) >= average {
    hash |= UInt64(1) << UInt64(index)
  }
  return String(format: "%016llx", hash)
}

/// JD video thumbnails use a bright circular play ring near the media center.
/// OCR crops may include the sender avatar and surrounding whitespace, so scan
/// a small center area rather than assuming the ring is at the crop midpoint.
/// Requiring most angular sectors plus the center triangle avoids promoting
/// ordinary product photos merely because they contain one white control.
func looksLikeVideoThumbnail(_ image: CGImage) -> Bool {
  guard Double(max(image.width,image.height))/Double(max(1,min(image.width,image.height))) <= 3.2 else { return false }
  let scale = min(1.0, 320.0 / Double(max(image.width, image.height)))
  let width = max(1, Int(Double(image.width)*scale))
  let height = max(1, Int(Double(image.height)*scale))
  let shortest = Double(min(width, height))
  guard shortest >= 80 else { return false }
  var pixels = [UInt8](repeating: 0, count: width*height*4)
  let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
    guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
      bitsPerComponent: 8, bytesPerRow: width*4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return true
  }
  guard rendered else { return false }
  let imageCenterX = Double(width-1)/2
  let imageCenterY = Double(height-1)/2
  func brightness(x: Int, y: Int) -> Double {
    guard x >= 0, y >= 0, x < width, y < height else { return 0 }
    let offset = (y*width+x)*4
    return (0.2126*Double(pixels[offset])+0.7152*Double(pixels[offset+1])+0.0722*Double(pixels[offset+2]))/255
  }

  // JD also displays unloaded videos as a smooth neutral-gray card. Its
  // white play ring is only about 20 RGB levels brighter than the background,
  // so the ordinary photo/video contrast thresholds cannot see it. Enable a
  // separate, stricter shape check only for this UI surface; a blank card,
  // white disk or ring without a triangle still cannot become a video.
  let neutralGrayCard:Bool = {
    let step=max(1,min(width,height)/64)
    var neutral=0,smooth=0,total=0
    for y in stride(from:0,to:height,by:step) {
      let row=stride(from:0,to:width,by:step).map {brightness(x:$0,y:y)}.sorted()
      let median=row[row.count/2]
      for x in stride(from:0,to:width,by:step) {
        let offset=(y*width+x)*4
        let rgb=(0..<3).map {Double(pixels[offset+$0])/255}
        let level=brightness(x:x,y:y)
        total+=1
        if rgb.max()!-rgb.min()!<=0.035 && level>=0.65 && level<=0.985 {neutral+=1}
        if abs(level-median)<=0.035 {smooth+=1}
      }
    }
    return total>0 && Double(neutral)/Double(total)>=0.94 && Double(smooth)/Double(total)>=0.94
  }()

  func hasPlayControl(centerX: Double, centerY: Double,
                      nominalRadius: Double) -> Bool {
    // A real JD play overlay can sit over a LIGHT printer. Fixed "dark
    // interior" thresholds missed those videos. Verify triangle/background
    // contrast inside the ring instead; a white photo/disk has no contrast.
    // JD has two play glyph layouts: a centered triangle and a triangle whose
    // baseline sits at the ring center and whose top touches the upper ring.
    // The latter appears in actual 16:33:33 cards. Requiring a white triangle
    // below the ring center rejects that valid layout. Test both shapes with
    // their own dark negative-space samples; retain the ring contrast tests.
    let triangleProfiles: [([(Double, Double)], [(Double, Double)])] = [
      ([(-0.18,-0.25),(-0.18,0.25),(0.1,0),(0.3,0)],
       [(-0.58,0),(0,-0.65),(0,0.65),(0.6,0.3)]),
      ([(0.08,-0.75),(0.08,-0.25),(0.35,-0.5),(0.55,-0.5)],
       [(-0.5,-0.5),(-0.5,0),(0.2,0.4),(0.6,0.3)]),
      // CoreGraphics raster direction can mirror the glyph vertically.
      ([(0.08,0.75),(0.08,0.25),(0.35,0.5),(0.55,0.5)],
       [(-0.5,0.5),(-0.5,0),(0.2,-0.4),(0.6,-0.3)])
    ]
    let trianglePresent = triangleProfiles.contains { positive, negative in
      let triangle = positive.map { brightness(
        x: Int((centerX+$0.0*nominalRadius).rounded()),
        y: Int((centerY+$0.1*nominalRadius).rounded())) }
      let mean = triangle.reduce(0,+)/Double(triangle.count)
      return mean >= (neutralGrayCard ? 0.94:0.85) && negative.filter {
        brightness(x: Int((centerX+$0.0*nominalRadius).rounded()),
          y: Int((centerY+$0.1*nominalRadius).rounded())) <= mean-(neutralGrayCard ? 0.045:0.12)
      }.count >= 3
    }
    guard trianglePresent else { return false }
    var brightSectors = 0
    var edgeContrastSectors = 0
    for sector in 0..<24 {
      let angle = Double(sector) * 2 * Double.pi / 24
      var maximum = 0.0
      for offset in -4...4 {
        let radius = nominalRadius + Double(offset)
        let x = Int((centerX + cos(angle) * radius).rounded())
        let y = Int((centerY + sin(angle) * radius).rounded())
        maximum = max(maximum, brightness(x: x, y: y))
      }
      if maximum >= 0.82 { brightSectors += 1 }
      let inner = brightness(x:Int((centerX+cos(angle)*nominalRadius*0.7).rounded()),
                             y:Int((centerY+sin(angle)*nominalRadius*0.7).rounded()))
      let outer = brightness(x:Int((centerX+cos(angle)*nominalRadius*1.35).rounded()),
                             y:Int((centerY+sin(angle)*nominalRadius*1.35).rounded()))
      let contrast=neutralGrayCard ? 0.035:0.08
      if maximum-inner >= contrast && maximum-outer >= contrast { edgeContrastSectors += 1 }

    }
    // A few disconnected white strokes in printed Chinese text previously
    // supplied 19 bright sectors and only ten contrasted sectors. Playback
    // requires an almost complete ring, with independently contrasted edges
    // around at least three quarters of its circumference. Keep the separate
    // low-contrast gray-card profile; it still requires its full shape proof.
    guard brightSectors >= (neutralGrayCard ? 21:22),
      edgeContrastSectors >= 18 else { return false }


    var brightCenterSamples = 0
    for yOffset in stride(from: -0.035, through: 0.035, by: 0.0175) {
      for xOffset in stride(from: -0.015, through: 0.05, by: 0.01625) {
        let x = Int((centerX + shortest * xOffset).rounded())
        let y = Int((centerY + shortest * yOffset).rounded())
        if brightness(x: x, y: y) >= 0.82 { brightCenterSamples += 1 }
      }
    }
    return brightCenterSamples >= 5
  }

  for yOffset in stride(from: -0.38, through: 0.38, by: 0.02) {
    for xOffset in stride(from: -0.38, through: 0.38, by: 0.02) {
      let centerX = imageCenterX + Double(width) * xOffset
      let centerY = imageCenterY + Double(height) * yOffset
      for radiusRatio in stride(from: 0.065, through: 0.11, by: 0.01) {
        if hasPlayControl(centerX: centerX, centerY: centerY,
                          nominalRadius: shortest * radiusRatio) {
          return true
        }
      }
    }
  }
  return false
}

/// The AX-verified customer's timestamp anchors a search band, never a
/// replacement image rectangle. The next sender header caps that band.
func jdIncomingMediaBands(observations:[[String:Any]],customer:String,
  chatRegion:[String:Double])->[ClosedRange<Double>] {
  guard !customer.isEmpty,let left=chatRegion["left"],let right=chatRegion["right"],
    let top=chatRegion["top"],let bottom=chatRegion["bottom"] else {return []}
  func compact(_ text:String)->String {
    text.replacingOccurrences(of:"：",with:":")
      .components(separatedBy:.whitespacesAndNewlines).joined()
  }
  let name=compact(customer)
  let isClock:(String)->Bool = {
    $0.range(of:#"^\d{1,2}:\d{2}:\d{2}$"#,options:.regularExpression) != nil
  }
  let lines=observations.compactMap { row -> (text:String,x:Double,y:Double,h:Double)? in
    guard let text=row["text"] as? String,let x=(row["x"] as? NSNumber)?.doubleValue,
      let y=(row["y"] as? NSNumber)?.doubleValue,let h=(row["height"] as? NSNumber)?.doubleValue,
      (row["confidence"] as? NSNumber)?.doubleValue ?? 0 >= 0.45,
      row["isWatermark"] as? Bool != true,
      abs((row["rotationDegrees"] as? NSNumber)?.doubleValue ?? 0)<=10,
      x>=left,x<right,y>=top,y+h<bottom else {return nil}
    return (compact(text),x,y,h)
  }
  var headers=[(y:Double,h:Double,incoming:Bool)]()
  for line in lines {
    let onLeft=line.x<left+(right-left)*0.30
    let incoming=onLeft && line.text.hasPrefix(name) &&
      (isClock(String(line.text.dropFirst(name.count))) ||
        (line.text==name && lines.filter { clock in
          clock.x>line.x && clock.x<left+(right-left)*0.54 &&
          abs(clock.y+clock.h/2-line.y-line.h/2)<0.009 && isClock(clock.text)
        }.count==1))
    let rightHeader = !onLeft &&
      line.text.range(of:#"^\d{1,2}:\d{2}:\d{2}.+|^.+\d{1,2}:\d{2}:\d{2}$"#,
        options:.regularExpression) != nil
    if incoming || rightHeader {
      headers.append((line.y,line.h,incoming))
    }
  }
  headers.sort { $0.y<$1.y }
  var separated=[(y:Double,h:Double,incoming:Bool)]()
  for header in headers {
    if let last=separated.last,abs(header.y-last.y)<0.008 {continue}
    separated.append(header)
  }
  return separated.enumerated().compactMap { (index,header) in
    guard header.incoming else {return nil}
    let start=header.y+header.h
    let end=index+1<separated.count ? separated[index+1].y : bottom
    guard end-start>0.04 else {return nil}
    return start...end
  }
}

/// A partly clipped card can outlive its sender header. Find only bounded
/// foreground cards on the customer side of the AX-verified transcript and
/// require explicit playback pixels. These are acquisition proposals, never
/// an OCR customer identity, sender clock, or permission to mark a turn read.
func jdUnboundMediaRegions(image: CGImage, chatRegion: [String: Double],
  includeFullCards: Bool = false, messageBands: [ClosedRange<Double>] = [],
  onDiagnostic:([String:Any])->Void = { _ in }) -> [[String: Any]] {
  guard let left=chatRegion["left"],let right=chatRegion["right"],
    let top=chatRegion["top"],let bottom=chatRegion["bottom"],
    left>=0,right<=1,top>=0,bottom<=1,left<right,top<bottom else {return []}
  let scope=CGRect(x:left*Double(image.width),y:top*Double(image.height),
    width:(right-left)*Double(image.width)*0.46,height:(bottom-top)*Double(image.height)).integral
  guard scope.width>=80,scope.height>=80,let chat=image.cropping(to:scope) else {return []}
  let scale=min(1,480/Double(chat.width),720/Double(chat.height))
  let width=max(1,Int(Double(chat.width)*scale)),height=max(1,Int(Double(chat.height)*scale))
  var rgba=[UInt8](repeating:0,count:width*height*4)
  let rendered=rgba.withUnsafeMutableBytes { buffer -> Bool in
    guard let context=CGContext(data:buffer.baseAddress,width:width,height:height,
      bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),
      bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {return false}
    context.interpolationQuality = .medium
    context.draw(chat,in:CGRect(x:0,y:0,width:width,height:height));return true
  }
  guard rendered else {return []}
  // The transcript's narrow left gutter is separate from message bubbles.
  // Use its median, so avatars and an occasional watermark are outliers.
  let samples=stride(from:0,to:height,by:max(1,height/80)).map { ($0*width)*4 }
  let background=(0..<3).map { channel in samples.map {Int(rgba[$0+channel])}.sorted()[samples.count/2] }
  let backgroundOK=background.min()!>=220 && background.max()!-background.min()!<=12
  onDiagnostic(jdMediaCondition(stage:"media.region_detection",id:"region.neutral_background",
    expression:"min(backgroundRGB) >= 220 && max(backgroundRGB)-min(backgroundRGB) <= 12",
    actual:["backgroundRGB":background,"minimum":background.min()!,"spread":background.max()!-background.min()!],
    threshold:["minimum":220,"maximumSpread":12],passed:backgroundOK))
  guard backgroundOK else {return []}
  var ink=[Bool](repeating:false,count:width*height)
  for i in ink.indices {
    ink[i]=(0..<3).map {abs(Int(rgba[i*4+$0])-background[$0])}.max()!>=5
  }
  onDiagnostic(jdMediaCondition(stage:"media.region_detection",id:"region.foreground_rgb",
    expression:"anyPixel(max(abs(pixelRGB-backgroundRGB)) >= 5)",
    actual:["foregroundPixels":ink.filter{$0}.count,"samplePixels":ink.count,"backgroundRGB":background],
    threshold:["minimumChannelDelta":5,"edgeBackgroundDeltaExclusive":2],passed:ink.contains(true)))
  // Establish the outside boundary from the two vertical card edges.
  // Never shrink that rectangle according to ink inside the customer's image.
  var outerCards = [[String:Any]]()
  if includeFullCards {
    func backgroundPixel(_ x:Int,_ y:Int)->Bool {
      guard x>=0,x<width,y>=0,y<height else {return false}
      let i=(y*width+x)*4
      return (0..<3).allSatisfy {abs(Int(rgba[i+$0])-background[$0])<2}
    }
    func side(_ x:Int,_ y:Int,_ left:Bool)->Bool {
      let outside=left ? x-2:x+2,inside=left ? x+1:x-1
      return backgroundPixel(outside,y) && !backgroundPixel(inside,y)
    }
    typealias Edge = (x:Int,top:Int,bottom:Int)
    for band in messageBands {
      let lower=max(1,Int(ceil((band.lowerBound*Double(image.height)-scope.minY)*scale)))
      let upper=min(height-2,Int(floor((band.upperBound*Double(image.height)-scope.minY)*scale)))
      guard upper-lower>=Int(80*scale) else {continue}
      func edges(_ left:Bool)->[Edge] {
        var result=[Edge]()
        let xStart=left ? max(3,Int(scope.width*0.035*scale)):max(3,Int(scope.width*0.035*scale)+Int(80*scale))
        let xEnd=left ? min(width-3,Int(scope.width*0.30*scale)):width-3
        guard xStart<xEnd else {return []}
        for x in xStart..<xEnd {
          var first:Int?,last=0,miss=0,hits=0
          func flush() {
            if let first, last-first>=Int(80*scale), hits*100 >= (last-first+1)*85,
               first>lower+1,last<upper-2 {
              result.append((x,first,last))
            }
          }
          for y in lower..<upper {
            if side(x,y,left) {
              if first==nil {first=y}
              last=y;miss=0;hits+=1
            } else if first != nil {
              miss+=1
              if miss>12 {flush();first=nil;hits=0;miss=0}
            }
          }
          flush()
        }
        return result
      }
      let leftEdges=edges(true),rightEdges=edges(false)
      var rectangles=[CGRect]()
      for l in leftEdges {for r in rightEdges {
        let w=r.x-l.x
        guard w>=Int(80*scale),abs(l.top-r.top)<=3,abs(l.bottom-r.bottom)<=3 else {continue}
        let y=min(l.top,r.top),end=max(l.bottom,r.bottom),h=end-y+1
        guard Double(w)/Double(h)>=0.25,Double(w)/Double(h)<=3.2 else {continue}
        let rect=CGRect(x:scope.minX+Double(l.x)/scale,y:scope.minY+Double(y)/scale,
                        width:Double(w)/scale,height:Double(h)/scale).integral
        guard rect.width>=80,rect.height>=80 else {continue}
        // Adjacent scan columns describe one border, not additional messages.
        if !rectangles.contains(where:{abs($0.minX-rect.minX)<6 && abs($0.maxX-rect.maxX)<6 &&
            abs($0.minY-rect.minY)<6 && abs($0.maxY-rect.maxY)<6}) {
          rectangles.append(rect)
        }
      }}
      for rect in rectangles {
        outerCards.append(["x":Double(rect.minX)/Double(image.width),"y":Double(rect.minY)/Double(image.height),
          "width":Double(rect.width)/Double(image.width),"height":Double(rect.height)/Double(image.height),
          "confidence":1.0,"proof":"full_card_pixels"])
      }
    }
  }
  // A full-width viewport/product-bar separator is not part of the card.
  // Remove its narrow band before closing; otherwise a clipped photo touching
  // that rule becomes one component with the entire product header.
  let separators=(0..<height).filter { y in
    (0..<width).filter {ink[y*width+$0]}.count>=Int(Double(width)*0.94)
  }
  for y in separators {for yy in max(0,y-2)...min(height-1,y+2) {
    for x in 0..<width {ink[yy*width+x]=false}
  }}
  // A small binary close joins compression cracks within a photo/card. It
  // cannot join distinct turns separated by the sender/header whitespace.
  var dilated=[Bool](repeating:false,count:ink.count)
  for y in 0..<height {for x in 0..<width where ink[y*width+x] {
    for yy in max(0,y-1)...min(height-1,y+1) {for xx in max(0,x-1)...min(width-1,x+1) {dilated[yy*width+xx]=true}}
  }}
  var closed=[Bool](repeating:false,count:ink.count)
  for y in 0..<height {for x in 0..<width where dilated[y*width+x] {
    closed[y*width+x]=(max(0,y-1)...min(height-1,y+1)).allSatisfy { yy in
      (max(0,x-1)...min(width-1,x+1)).allSatisfy {dilated[yy*width+$0]}
    }
  }}
  var seen=[Bool](repeating:false,count:ink.count),regions=[[String:Any]]()
  for start in closed.indices where closed[start] && !seen[start] {
    var work=[start],head=0,minX=start%width,maxX=minX,minY=start/width,maxY=minY
    seen[start]=true
    while head<work.count {
      let at=work[head];head+=1;let x=at%width,y=at/width
      minX=min(minX,x);maxX=max(maxX,x);minY=min(minY,y);maxY=max(maxY,y)
      for yy in max(0,y-1)...min(height-1,y+1) {for xx in max(0,x-1)...min(width-1,x+1) {
        let next=yy*width+xx
        if closed[next] && !seen[next] {seen[next]=true;work.append(next)}
      }}
    }
    let local=CGRect(x:Double(minX)/scale,y:Double(minY)/scale,
      width:Double(maxX-minX+1)/scale,height:Double(maxY-minY+1)/scale).integral
    let density=Double(work.count)/Double((maxX-minX+1)*(maxY-minY+1))
    let aspect=local.width/local.height
    onDiagnostic(jdMediaCondition(stage:"media.region_detection",id:"region.component_geometry",
      expression:"width >= 80 && height >= 80 && width <= scopeWidth*0.95 && height <= scopeHeight && aspect >= 0.25 && aspect <= 3.2 && density >= 0.35",
      actual:["width":local.width,"height":local.height,"scopeWidth":scope.width,"scopeHeight":scope.height,
        "aspect":aspect,"density":density,"x":scope.minX+local.minX,"y":scope.minY+local.minY],
      threshold:["minimumWidth":80,"minimumHeight":80,"maximumScopeWidthRatio":0.95,
        "minimumAspect":0.25,"maximumAspect":3.2,"minimumDensity":0.35],
      passed:local.width>=80 && local.height>=80 && local.width<=scope.width*0.95 && local.height<=scope.height &&
        aspect>=0.25 && aspect<=3.2 && density>=0.35))
    guard local.width>=80,local.height>=80,local.width<=scope.width*0.95,
      local.height<=scope.height,local.width/local.height>=0.25,local.width/local.height<=3.2,
      Double(work.count)/Double((maxX-minX+1)*(maxY-minY+1))>=0.35 else {continue}
    let full=CGRect(x:scope.minX+local.minX,y:scope.minY+local.minY,width:local.width,height:local.height)
    guard let card=image.cropping(to:full) else {continue}
    let play=looksLikeVideoThumbnail(card)
    func append(_ proof:String) {
      regions.append(["x":Double(full.minX)/Double(image.width),"y":Double(full.minY)/Double(image.height),
        "width":Double(full.width)/Double(image.width),"height":Double(full.height)/Double(image.height),
        "confidence":1.0,"proof":proof])
    }
    if play { append("explicit_play_overlay") }
  }
  regions.append(contentsOf:outerCards)
  return regions
}

func failedSendRetryDelay(attempts: Int) -> TimeInterval {
  let delays: [TimeInterval] = [15, 30, 60, 120, 300]
  return delays[min(max(attempts, 0), delays.count - 1)]
}

struct FailedSendBubble {
  let point: CGPoint
  let frame: CGRect
  let image: CGImage
  let fingerprint: String
}

/// Locate JD's white-exclamation/red-circle next to a light-blue outgoing
/// bubble. No AX text layout, receipt, or network probe is needed.
func failedSendBubbles(image: CGImage, windowBounds: CGRect,
    chatFrame: CGRect, onlyLatestOutgoing: Bool = false) -> [FailedSendBubble] {
  let sx = CGFloat(image.width) / max(windowBounds.width, 1)
  let sy = CGFloat(image.height) / max(windowBounds.height, 1)
  let region = CGRect(x: (chatFrame.minX - windowBounds.minX) * sx,
      y: (chatFrame.minY - windowBounds.minY) * sy,
      width: chatFrame.width * sx, height: chatFrame.height * sy).integral
    .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
  guard region.width > 20, region.height > 20,
        let crop = image.cropping(to: region) else { return [] }
  let w = crop.width, h = crop.height
  var pixels = [UInt8](repeating: 0, count: w * h * 4)
  let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
    guard let context = CGContext(data: buffer.baseAddress, width: w, height: h,
        bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
          CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
    context.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
    return true
  }
  guard rendered else { return [] }
  func red(_ i: Int) -> Bool {
    let p = i * 4, r = Int(pixels[p]), g = Int(pixels[p + 1]), b = Int(pixels[p + 2])
    return r > 165 && r - g > 65 && r - b > 50
  }
  func white(_ x: Int, _ y: Int) -> Bool {
    let p = (y * w + x) * 4
    return pixels[p] > 235 && pixels[p + 1] > 235 && pixels[p + 2] > 235
  }
  func blue(_ x: Int, _ y: Int) -> Bool {
    let p = (y * w + x) * 4
    let r = Int(pixels[p]), g = Int(pixels[p + 1]), b = Int(pixels[p + 2])
    return r > 165 && r < 238 && g > 185 && b > 240 && b - r > 18 && g >= r
  }
  var visited = [Bool](repeating: false, count: w * h)
  var results: [FailedSendBubble] = []
  for seed in 0..<(w * h) where !visited[seed] && red(seed) {
    visited[seed] = true
    var pending = [seed], count = 0
    var left = seed % w, right = left, top = seed / w, bottom = top
    while let i = pending.popLast() {
      count += 1
      let x = i % w, y = i / w
      left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
      let neighbors = [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
      for (nx, ny) in neighbors where nx >= 0 && nx < w && ny >= 0 && ny < h {
        let n = ny * w + nx
        if !visited[n] && red(n) { visited[n] = true; pending.append(n) }
      }
    }
    let bw = right - left + 1, bh = bottom - top + 1
    let logicalW = CGFloat(bw) / sx, logicalH = CGFloat(bh) / sy
    let fill = Double(count) / Double(bw * bh)
    guard logicalW >= 8, logicalW <= 40, logicalH >= 8, logicalH <= 40,
          logicalW / logicalH > 0.8, logicalW / logicalH < 1.25,
          fill > 0.5, fill < 0.9 else { continue }
    // Require the white vertical stem and separate dot inside the red circle.
    // Avatars, red text, notification counts, and solid red shapes are rejected.
    let cx = (left + right) / 2, cy = (top + bottom) / 2
    func centerWhite(at fraction: Double) -> Bool {
      let y = top + Int(Double(bh - 1) * fraction)
      return ((cx - max(1, bw / 12))...(cx + max(1, bw / 12))).contains { white($0, y) }
    }
    guard centerWhite(at: 0.25), centerWhite(at: 0.45),
          centerWhite(at: 0.73), !centerWhite(at: 0.65) else { continue }
    let searchEnd = min(w - 1, right + Int(60 * sx))
    guard right + 1 < searchEnd,
          let bubbleLeft = ((right + 1)...searchEnd).first(where: { blue($0, cy) }) else { continue }
    // Inspect the left padding column, not message glyphs or AX line frames.
    let column = min(w - 1, bubbleLeft + max(2, Int(4 * sx)))
    func paddingBlue(_ y: Int) -> Bool {
      [3, 5, 7, 9].filter {
        blue(min(w - 1, bubbleLeft + max(1, Int(CGFloat($0) * sx))), y)
      }.count >= 2
    }
    // JD overlays a faint watermark on the bubble. A few non-blue pixels
    // must not truncate a multiline message in the middle of that watermark.
    func edge(_ direction: Int) -> Int {
      var y = cy, lastBlue = cy, gap = 0
      while y + direction >= 0 && y + direction < h {
        y += direction
        if paddingBlue(y) { lastBlue = y; gap = 0 } else { gap += 1 }
        if gap >= max(3, Int(6 * sy)) { break }
      }
      return lastBlue
    }
    let bubbleTop = edge(-1), bubbleBottom = edge(1)
    let paddingRow = min(bubbleBottom, bubbleTop + max(2, Int(3 * sy)))
    var bubbleRight = column
    while bubbleRight + 1 < w && blue(bubbleRight + 1, paddingRow) { bubbleRight += 1 }
    guard CGFloat(bubbleRight - bubbleLeft) / sx >= 45,
          CGFloat(bubbleBottom - bubbleTop) / sy >= 20,
          // Outgoing bubbles terminate in the right half of the transcript.
          bubbleRight > w / 2, bubbleTop > 0, bubbleBottom < h - 1 else { continue }
    if onlyLatestOutgoing {
      // An old red icon above a newer successful bubble is not a failure of
      // this send. Require it to belong to the last visible outgoing bubble.
      let start = bubbleBottom + max(3, Int(8 * sy))
      if start < h {
        let laterBlue = stride(from: start, to: h, by: max(1, Int(3 * sy))).contains { y in
          stride(from: w / 2, to: w, by: max(1, Int(3 * sx))).filter { x in blue(x, y) }.count >= 12
        }
        if laterBlue { continue }
      }
    }
    let rect = CGRect(x: region.minX + CGFloat(bubbleLeft),
        y: region.minY + CGFloat(bubbleTop),
        width: CGFloat(bubbleRight - bubbleLeft + 1),
        height: CGFloat(bubbleBottom - bubbleTop + 1))
    guard let message = image.cropping(to: rect),
          let data = NSBitmapImageRep(cgImage: message).representation(using: .png, properties: [:])
    else { continue }
    results.append(FailedSendBubble(
        point: CGPoint(x: windowBounds.minX + (region.minX + CGFloat(cx)) / sx,
                       y: windowBounds.minY + (region.minY + CGFloat(cy)) / sy),
        frame: CGRect(x: windowBounds.minX + rect.minX / sx,
                      y: windowBounds.minY + rect.minY / sy,
                      width: rect.width / sx, height: rect.height / sy),
        image: message,
        fingerprint: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
  }
  return results.sorted { $0.point.y > $1.point.y }
}


private func postClick(at point: CGPoint) -> Bool {
  guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                           mouseCursorPosition: point, mouseButton: .left),
        let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                         mouseCursorPosition: point, mouseButton: .left) else { return false }
  down.post(tap: .cghidEventTap)
  up.post(tap: .cghidEventTap)
  usleep(100_000)
  return true
}

private func postRightClick(at point:CGPoint)->Bool {
  guard let down=CGEvent(mouseEventSource:nil,mouseType:.rightMouseDown,
    mouseCursorPosition:point,mouseButton:.right),
    let up=CGEvent(mouseEventSource:nil,mouseType:.rightMouseUp,
      mouseCursorPosition:point,mouseButton:.right) else {return false}
  down.post(tap:.cghidEventTap);up.post(tap:.cghidEventTap)
  return true
}

private func postHover(at point: CGPoint) -> Bool {
  guard let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                           mouseCursorPosition: point, mouseButton: .left)
  else { return false }
  move.post(tap: .cghidEventTap)
  usleep(250_000)
  return true
}

private func postCommandShiftG() -> Bool {
  guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 5, keyDown: true),
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 5, keyDown: false)
  else { return false }
  down.flags = [.maskCommand, .maskShift]
  up.flags = [.maskCommand, .maskShift]
  down.post(tap: .cghidEventTap)
  up.post(tap: .cghidEventTap)
  return true
}

private func postDoubleClick(at point: CGPoint) -> Bool {
  guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                           mouseCursorPosition: point, mouseButton: .left),
        let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                         mouseCursorPosition: point, mouseButton: .left) else { return false }
  down.setIntegerValueField(.mouseEventClickState, value: 1)
  up.setIntegerValueField(.mouseEventClickState, value: 1)
  down.post(tap: .cghidEventTap)
  up.post(tap: .cghidEventTap)
  usleep(80_000)
  down.setIntegerValueField(.mouseEventClickState, value: 2)
  up.setIntegerValueField(.mouseEventClickState, value: 2)
  down.post(tap: .cghidEventTap)
  up.post(tap: .cghidEventTap)
  return true
}

private func postEscape() -> Bool {
  guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true),
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false)
  else { return false }
  down.post(tap: .cghidEventTap)
  up.post(tap: .cghidEventTap)
  return true
}

private func closeJDImageViewer(pid: pid_t, bounds: CGRect) -> Bool {
  let app = AXUIElementCreateApplication(pid)
  for window in elementArrayAttribute(app, kAXWindowsAttribute) {
    let title = stringAttribute(window, kAXTitleAttribute) ?? ""
    guard title.contains("图片浏览器") else { continue }
    var closeValue: CFTypeRef?
    if AXUIElementCopyAttributeValue(
      window, kAXCloseButtonAttribute as CFString, &closeValue) == .success,
       let closeValue,
       CFGetTypeID(closeValue) == AXUIElementGetTypeID() {
      _ = AXUIElementPerformAction(
        unsafeBitCast(closeValue, to: AXUIElement.self),
        kAXPressAction as CFString)
      usleep(100_000)
    }
  }
  if namedWindowBounds(pid: pid, containing: "图片浏览器") == nil { return true }

  // JD builds that do not expose AXCloseButton still use the standard macOS
  // close control at the top-left of this already verified viewer window.
  _ = postClick(at: CGPoint(x: bounds.minX + 20, y: bounds.minY + 20))
  usleep(100_000)
  if namedWindowBounds(pid: pid, containing: "图片浏览器") == nil { return true }

  _ = postEscape()
  usleep(100_000)
  return namedWindowBounds(pid: pid, containing: "图片浏览器") == nil
}

private func describe(_ node: AXNode) -> String {
  var fields = [node.role]
  if let subrole = node.subrole { fields.append("subrole=\(quoted(subrole))") }
  if let id = node.identifier { fields.append("id=\(quoted(id))") }
  if let title = node.title { fields.append("title=\(quoted(title))") }
  if let value = node.value { fields.append("value=\(quoted(value))") }
  if let description = node.description { fields.append("description=\(quoted(description))") }
  if let help = node.help { fields.append("help=\(quoted(help))") }
  if let frame = node.frame { fields.append("frame=\(normalizedFrame(frame))") }
  if !node.actions.isEmpty { fields.append("actions=\(node.actions)") }
  fields.append("path=\(node.path)")
  return fields.joined(separator: " ")
}

private func quoted(_ value: String) -> String {
  let clipped = value.count > 240 ? String(value.prefix(240)) + "…" : value
  return "\"\(clipped.replacingOccurrences(of: "\n", with: "\\n"))\""
}


/// No time-only pairing: companion names and parent chat directory must agree.
func verifiedCompanionVideo(thumbnail: URL) -> URL? {
  let parent = thumbnail.deletingLastPathComponent()
  guard parent.lastPathComponent == "images",
        parent.deletingLastPathComponent().lastPathComponent.hasPrefix("chat_") else { return nil }
  let directory = parent.deletingLastPathComponent().appendingPathComponent("videos")
  let stem = thumbnail.deletingPathExtension().lastPathComponent
  let candidates = ["mp4", "mov", "m4v", "webm"].map {
    directory.appendingPathComponent(stem).appendingPathExtension($0)
  }.filter {
    guard let values = try? $0.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else { return false }
    return values.isRegularFile == true && (values.fileSize ?? 0) > 0 && (values.fileSize ?? 0) <= 100*1024*1024
  }
  return candidates.count == 1 ? candidates[0] : nil
}

private func mediaPixels(_ image: CGImage) -> [UInt8]? {
  let count = 32 * 32 * 4
  var pixels = [UInt8](repeating: 0, count: count)
  let ok = pixels.withUnsafeMutableBytes { buffer -> Bool in
    guard let context = CGContext(data: buffer.baseAddress, width: 32, height: 32,
      bitsPerComponent: 8, bytesPerRow: 32 * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
    context.interpolationQuality = .medium
    context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
    return true
  }
  return ok ? pixels : nil
}

func normalizedMediaPixelDifference(_ a: CGImage, _ b: CGImage) -> Double {
  guard let left = mediaPixels(a), let right = mediaPixels(b) else { return 1 }
  var difference = 0.0
  for i in 0..<(32 * 32) {
    for channel in 0..<3 { difference += abs(Double(left[i*4+channel])-Double(right[i*4+channel])) }
  }
  return difference / Double(32*32*3*255)
}

/// Measures independent visual content relative to the dominant background.
/// A low score means UNVERIFIED, never proof the customer sent no image.
func mediaForegroundFraction(_ image: CGImage) -> Double {
  guard let pixels = mediaPixels(image) else { return 0 }
  var bins: [Int:Int] = [:]
  for i in 0..<(32*32) {
    let key = Int(pixels[i*4]/16)*256 + Int(pixels[i*4+1]/16)*16 + Int(pixels[i*4+2]/16)
    bins[key, default: 0] += 1
  }
  guard let dominant = bins.max(by: { $0.value < $1.value })?.key else { return 0 }
  let rgb = [(dominant/256)*16+8, ((dominant/16)%16)*16+8, (dominant%16)*16+8]
  var foreground = 0
  for i in 0..<(32*32) {
    if (0..<3).map({ abs(Int(pixels[i*4+$0])-rgb[$0]) }).max()! > 24 { foreground += 1 }
  }
  return Double(foreground)/Double(32*32)
}


/// Normalize only small near-white chat borders, never alter saved originals.
func mediaWithoutChatBorder(_ image: CGImage) -> CGImage {
  let bitmap = NSBitmapImageRep(cgImage: image)
  let width=bitmap.pixelsWide, height=bitmap.pixelsHigh
  func content(_ x:Int,_ y:Int) -> Bool {
    guard let c=bitmap.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB) else { return false }
    return min(c.redComponent,c.greenComponent,c.blueComponent) < 0.88
  }
  let ys=Array(stride(from:0,to:height,by:max(1,height/64)))
  let xs=Array(stride(from:0,to:width,by:max(1,width/64)))
  let columns=(0..<width).filter { x in ys.filter { content(x,$0) }.count > ys.count/2 }
  let rows=(0..<height).filter { y in xs.filter { content($0,y) }.count > xs.count/2 }
  guard let left=columns.first,let right=columns.last,let top=rows.first,let bottom=rows.last,
    left<width/6,right>width*5/6,top<height/6,bottom>height*5/6 else { return image }
  return image.cropping(to:CGRect(x:left,y:top,width:right-left+1,height:bottom-top+1)) ?? image
}

struct JDCachedImagePreviewMatch {
  let hashDistance:Int
  let ratioDelta:Double
  let borderNormalized:Bool
}

/// A rounded JD thumbnail can include a narrow near-white chat gutter. Remove
/// only that bounded gutter for comparison, never from the saved original.
/// This fallback requires stronger pixel, shape and structural agreement than
/// the original untrimmed match; it does not raise the average-hash threshold.
func jdMatchingCachedImagePreview(visible:CGImage,original:CGImage,
  onDiagnostic:([String:Any])->Void = { _ in })->JDCachedImagePreviewMatch? {
  guard let originalBits=UInt64(averageImageHash(original),radix:16) else {return nil}
  func metrics(_ image:CGImage)->(Int,Double)? {
    guard let bits=UInt64(averageImageHash(image),radix:16) else {return nil}
    let ratio=abs(log((Double(image.width)/Double(max(image.height,1))) /
      (Double(original.width)/Double(max(original.height,1)))))
    return ((bits ^ originalBits).nonzeroBitCount,ratio)
  }
  if let (distance,ratio)=metrics(visible) {
    let pixelDifference=normalizedMediaPixelDifference(visible,original)
    onDiagnostic(jdMediaCondition(stage:"media.cache_match",id:"cache.image_preview_pixels",
      expression:"hashDistance <= 12 && ratioDelta <= 0.40 && pixelDifference <= 0.16",
      actual:["hashDistance":distance,"ratioDelta":ratio,"pixelDifference":pixelDifference],
      threshold:["maximumHashDistance":12,"maximumRatioDelta":0.40,"maximumPixelDifference":0.16],
      passed:distance<=12 && ratio<=0.40 && pixelDifference<=0.16))
  }
  if let (distance,ratio)=metrics(visible),distance<=12,ratio<=0.40,
    normalizedMediaPixelDifference(visible,original)<=0.16 {
    return JDCachedImagePreviewMatch(hashDistance:distance,ratioDelta:ratio,borderNormalized:false)
  }
  let trimmed=mediaWithoutChatBorder(visible)
  if let (distance,ratio)=metrics(trimmed) {
    let difference=normalizedMediaPixelDifference(trimmed,original)
    let similarity=mediaStructuralSimilarity(trimmed,original)
    let widthRatio=Double(trimmed.width)/Double(visible.width)
    let heightRatio=Double(trimmed.height)/Double(visible.height)
    let foreground=mediaForegroundFraction(trimmed)
    let changed=trimmed.width != visible.width || trimmed.height != visible.height
    onDiagnostic(jdMediaCondition(stage:"media.cache_match",id:"cache.trimmed_preview_pixels",
      expression:"borderChanged && widthRatio >= 0.86 && heightRatio >= 0.86 && foreground >= 0.10 && hashDistance <= 8 && ratioDelta <= 0.08 && pixelDifference <= 0.04 && structuralSimilarity >= 0.93",
      actual:["borderChanged":changed,"widthRatio":widthRatio,"heightRatio":heightRatio,
        "foreground":foreground,"hashDistance":distance,"ratioDelta":ratio,
        "pixelDifference":difference,"structuralSimilarity":similarity],
      threshold:["minimumWidthRatio":0.86,"minimumHeightRatio":0.86,"minimumForeground":0.10,
        "maximumHashDistance":8,"maximumRatioDelta":0.08,"maximumPixelDifference":0.04,"minimumStructuralSimilarity":0.93],
      passed:changed && widthRatio>=0.86 && heightRatio>=0.86 && foreground>=0.10 &&
        distance<=8 && ratio<=0.08 && difference<=0.04 && similarity>=0.93))
  }
  guard trimmed.width != visible.width || trimmed.height != visible.height,
    Double(trimmed.width)/Double(visible.width)>=0.86,
    Double(trimmed.height)/Double(visible.height)>=0.86,
    mediaForegroundFraction(trimmed)>=0.10,
    let (distance,ratio)=metrics(trimmed),distance<=8,ratio<=0.08,
    normalizedMediaPixelDifference(trimmed,original)<=0.04,
    mediaStructuralSimilarity(trimmed,original)>=0.93 else {return nil}
  return JDCachedImagePreviewMatch(hashDistance:distance,ratioDelta:ratio,borderNormalized:true)
}

/// Some JD image-cache PNGs letterbox a portrait photo with wide white
/// columns. Compare the normalized content only; return the untouched file
/// and keep the strict same-content requirement for ambiguous candidates.
func jdMatchingCachedSidePaddedImage(visible:CGImage,original:CGImage)->JDCachedImagePreviewMatch? {
  guard original.width>=80,original.height>=80,
    visible.width>=60,visible.height>=60 else {return nil}
  let scale=min(1,1024/Double(max(original.width,original.height)))
  let normalized=jdImageOriginalComparisonContent(original)
  let contentWidth=Double(normalized.width)/(Double(original.width)*scale)
  let contentHeight=Double(normalized.height)/(Double(original.height)*scale)
  guard contentWidth>=0.50,contentWidth<=0.84,contentHeight>=0.96,
    mediaForegroundFraction(visible)>=0.12,
    let a=UInt64(averageImageHash(visible),radix:16),
    let b=UInt64(averageImageHash(normalized),radix:16) else {return nil}
  let shape=abs(log((Double(visible.width)/Double(visible.height)) /
    (Double(normalized.width)/Double(normalized.height))))
  let distance=(a ^ b).nonzeroBitCount
  guard shape<=0.045,distance<=8,
    normalizedMediaPixelDifference(visible,normalized)<=0.035,
    mediaStructuralSimilarity(visible,normalized)>=0.94 else {return nil}
  return JDCachedImagePreviewMatch(hashDistance:distance,ratioDelta:shape,borderNormalized:true)
}

func jdCachedImageOriginalsIdentical(_ urls:[URL])->Bool {
  guard let first=urls.first,let data=try? Data(contentsOf:first,options:.mappedIfSafe),
    jdCompleteOriginalImage(data) != nil else {return false}
  let digest=SHA256.hash(data:data)
  return urls.dropFirst().allSatisfy {url in
    guard let other=try? Data(contentsOf:url,options:.mappedIfSafe),
      jdCompleteOriginalImage(other) != nil else {return false}
    return SHA256.hash(data:other)==digest
  }
}

func mediaStructuralSimilarity(_ a: CGImage,_ b: CGImage) -> Double {
  guard let p=mediaPixels(a),let q=mediaPixels(b) else { return 0 }
  func luminance(_ bytes:[UInt8],_ i:Int)->Double {
    (0.2126*Double(bytes[i*4])+0.7152*Double(bytes[i*4+1])+0.0722*Double(bytes[i*4+2]))/255
  }
  let x=(0..<1024).map { luminance(p,$0) },y=(0..<1024).map { luminance(q,$0) }
  let mx=x.reduce(0,+)/1024,my=y.reduce(0,+)/1024
  var vx=0.0,vy=0.0,cov=0.0
  for i in 0..<1024 { vx += pow(x[i]-mx,2);vy += pow(y[i]-my,2);cov += (x[i]-mx)*(y[i]-my) }
  vx/=1024;vy/=1024;cov/=1024
  return (2*mx*my+0.0001)/(mx*mx+my*my+0.0001)*(2*cov+0.0009)/(vx+vy+0.0009)
}

/// Only used after chat geometry proved the old card ends here. Allow a
/// narrow tolerance for the sticky header and the detected lower card edge.
func jdMatchingClippedMediaBottom(visible:CGImage,original:CGImage)->Double? {
  guard visible.width>=60,visible.height>=32,
    original.width>=60,original.height>=60 else {return nil}
  func compact(_ image:CGImage)->CGImage {
    let ratio=min(1,192/Double(image.width))
    let width=max(1,Int(Double(image.width)*ratio))
    let height=max(1,Int(Double(image.height)*ratio))
    guard ratio<1,let context=CGContext(data:nil,width:width,height:height,
      bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),
      bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {return image}
    context.interpolationQuality = .medium
    context.draw(image,in:CGRect(x:0,y:0,width:width,height:height))
    return context.makeImage() ?? image
  }
  let visible=compact(visible),original=compact(original)
  var best:Double?
  let current=jdNativeWork.currentValidity()
  for inset in [0.0,0.018,0.036,0.05] {
    guard current() else {return nil}
    let x=Double(visible.width)*inset
    for top in [0.0,0.10,0.20,0.28,0.34,0.40] {
      for bottom in [0.0,0.06,0.12,0.18,0.22] {
        let h=Double(visible.height)*(1-top-bottom)
        let w=Double(visible.width)-2*x
        guard let part=visible.cropping(to:CGRect(x:x,y:Double(visible.height)*top,width:w,height:h).integral),
          mediaForegroundFraction(part)>=0.12 else {continue}
        let naturalHeight=h*Double(original.width)/w
        for scale in [0.92,0.98,1.04,1.10] {
          let height=naturalHeight*scale
          guard height>=Double(original.height)*0.11,
            height<=Double(original.height)*0.80 else {continue}
          for tail in [0.0,0.025,0.05] {
            let y=Double(original.height)*(1-tail)-height
            guard y>=0,let target=original.cropping(to:CGRect(x:0,y:y,width:Double(original.width),height:height).integral) else {continue}
            let difference=normalizedMediaPixelDifference(part,target)
            guard difference<=0.065 else {continue}
            let similarity=mediaStructuralSimilarity(part,target)
            guard similarity>=0.94 else {continue}
            let score=difference*100+(1-similarity)*100
            best=min(best ?? score,score)
          }
        }
      }
    }
  }
  return best
}

/// Accept only a high-information, contiguous top/bottom fragment of a cover.
/// The caller additionally requires explicit playback and a same-chat,
/// same-stem video original, and rejects visually tied different originals.
/// No clock, age, global newest file, or OCR identity proves this association.
func jdMatchingVideoCoverFragment(visible:CGImage,cover:CGImage)->CGImage? {
  guard mediaForegroundFraction(visible)>=0.12 else {return nil}
  var best:CGImage?,bestScore=0.96
  for fraction in stride(from:0.45,through:0.975,by:0.025) {
    let h=Double(cover.height)*fraction
    for y in [0.0,Double(cover.height)-h] {
      guard let crop=cover.cropping(to:CGRect(x:0,y:y,width:Double(cover.width),height:h).integral),
        normalizedMediaPixelDifference(visible,crop)<=0.04 else {continue}
      let score=mediaStructuralSimilarity(visible,crop)
      if score>bestScore {best=crop;bestScore=score}
    }
  }
  return best
}

/// Receives only AX text from the current composer notice area, not history.
func jdReceptionNoticeBlocksDelivery(_ notices: [String]) -> Bool {
  notices.contains {
    let text = $0.replacingOccurrences(of: " ", with: "")
    return (text.contains("正在咨询其他客服") && text.contains("无法回复")) ||
      text == "当前客户由其他客服接待，无法回复顾客消息"
  }
}

private func jdWindowVisible(pid: pid_t, windowID: CGWindowID) -> Bool {
  let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
  return windows.contains { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid &&
    ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID }
}

func jdRefreshSendSnapshot<T>(initial:T?,expected:String,canRefresh:()->Bool,
  identity:(T)->String?,ready:(T)->Bool,read:()->T?,now:()->TimeInterval,pause:()->Void)->T? {
  let deadline=now()+0.35
  var current=initial
  while canRefresh(),now()<deadline {
    if let value=current,let actual=identity(value) {
      if Array(actual.utf8) != Array(expected.utf8) { return current }
      if ready(value) { return current }
    }
    pause();current=read()
  }
  return current
}

/// Some JD versions use different names for the cover and original. This path
/// requires a video-card UI cue at the caller, a pixel-matched owned cover,
/// and a unique video-content match inside that exact chat cache directory.
/// Original and cover modification times may differ after a delayed download;
/// only their verified content and stable files establish this relationship.
/// It runs on the bounded native evidence queue, never in the send transaction or AX queue.
func verifiedVisualVideoCompanion(thumbnail:URL)->URL? {
  let parent=thumbnail.deletingLastPathComponent()
  guard parent.lastPathComponent=="images",parent.deletingLastPathComponent().lastPathComponent.hasPrefix("chat_"),
    let values=try? thumbnail.resourceValues(forKeys:[.contentModificationDateKey]),
    let thumbnailModified=values.contentModificationDate,
    let cover=NSImage(contentsOf:thumbnail)?.cgImage(forProposedRect:nil,context:nil,hints:nil),
    mediaForegroundFraction(cover)>0.10 else {return nil}
  let folder=parent.deletingLastPathComponent().appendingPathComponent("videos")
  let keys:Set<URLResourceKey>=[.isRegularFileKey,.contentModificationDateKey,.fileSizeKey]
  guard let urls=try? FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:Array(keys)) else {return nil}
  let candidates=urls.filter { url in
    guard ["mp4","mov","m4v","webm"].contains(url.pathExtension.lowercased()),
      let v=try? url.resourceValues(forKeys:keys),v.isRegularFile==true,
      let size=v.fileSize,size>0,size<=100*1024*1024 else {return false}
    return true
  }
  guard !candidates.isEmpty,candidates.count<=8 else {return nil}
  let deadline=ProcessInfo.processInfo.systemUptime+2
  var matches=[URL]()
  for url in candidates {
    if ProcessInfo.processInfo.systemUptime>=deadline {return nil} // Partial search proves nothing.
    let asset=AVURLAsset(url:url)
    let duration=CMTimeGetSeconds(asset.duration)
    let generator=AVAssetImageGenerator(asset:asset)
    guard let frameCancellation=jdNativeWork.registerResourceCancellation({generator.cancelAllCGImageGeneration()}) else {return nil}
    defer {jdNativeWork.unregisterResourceCancellation(frameCancellation)}
    generator.appliesPreferredTrackTransform=true
    generator.maximumSize=CGSize(width:320,height:320)
    generator.requestedTimeToleranceBefore=CMTime(seconds:0.1,preferredTimescale:600)
    generator.requestedTimeToleranceAfter=CMTime(seconds:0.1,preferredTimescale:600)
    // A small fixed sample covers common poster offsets. The search must
    // finish across every eligible candidate before claiming unique identity.
    for second in [0.0,0.5,1.0,2.0] {
      // Seeking beyond EOF can stall a decoder. It provides no additional proof.
      if duration.isFinite && duration>0 && second>=duration {continue}
      if ProcessInfo.processInfo.systemUptime>=deadline {return nil}
      guard (try? jdNativeWork.withCurrent({true}))==true else {return nil}
      guard let frame=try? generator.copyCGImage(at:CMTime(seconds:second,preferredTimescale:600),actualTime:nil) else {continue}
      guard (try? jdNativeWork.withCurrent({true}))==true else {return nil}
      let ratio=Double(frame.width)/Double(max(frame.height,1))
      let coverRatio=Double(cover.width)/Double(max(cover.height,1))
      if abs(log(ratio/coverRatio))<=0.045 && normalizedMediaPixelDifference(cover,frame)<=0.04 && mediaStructuralSimilarity(cover,frame)>=0.97 {
        matches.append(url);break
      }
    }
  }
  guard (try? thumbnail.resourceValues(forKeys:[.contentModificationDateKey]))?.contentModificationDate == thumbnailModified,
    let first=matches.first,let bytes=try? Data(contentsOf:first,options:.mappedIfSafe) else {return nil}
  let digest=SHA256.hash(data:bytes)
  for contender in matches.dropFirst() {
    guard let other=try? Data(contentsOf:contender,options:.mappedIfSafe),SHA256.hash(data:other)==digest else {return nil}
  }
  return first
}

func jdSendMediaContextCurrent(path:String?,customer:String,revision:Int?)->Bool {
  guard let revision else {return true} // Holding/text replies do not depend on media.
  guard let path,let data=try? Data(contentsOf:URL(fileURLWithPath:path)),
    let json=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
    let owner=json["customer"] as? String,Array(owner.utf8)==Array(customer.utf8),
    let current=json["revision"] as? Int else {return false}
  return current==revision
}


private let jdDryRunDirectory=URL(fileURLWithPath:"/Users/m1air/Desktop/JD Automation/work/transfer-v102-dryrun")
private func jdDryRunRecord(_ data:[String:Any]) {
  var payload=data;payload["time"]=ISO8601DateFormatter().string(from:Date())
  if let bytes=try? JSONSerialization.data(withJSONObject:payload,options:[.sortedKeys]),let text=String(data:bytes,encoding:.utf8) {
    print(text);fflush(stdout)
    let url=jdDryRunDirectory.appendingPathComponent("conditions.jsonl")
    if !FileManager.default.fileExists(atPath:url.path) {FileManager.default.createFile(atPath:url.path,contents:Data())}
    if let h=try? FileHandle(forWritingTo:url) {h.seekToEndOfFile();h.write(Data((text+"\n").utf8));try? h.close()}
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


if CommandLine.arguments.count>=4 && CommandLine.arguments[1]=="--offline" {
  let url=URL(fileURLWithPath:CommandLine.arguments[2]),stage=CommandLine.arguments[3]
  guard let data=try? Data(contentsOf:url),let image=NSBitmapImageRep(data:data)?.cgImage else {exit(4)}
  let recognized=transferDialogLabels(pid:56162,bounds:CGRect(x:0,y:0,width:image.width,height:image.height),image:image,deadline:nil,requireAction:true)
  let snapshot=TransferDialogSnapshot(windowID:0,bounds:CGRect(x:0,y:0,width:image.width,height:image.height),image:image,lines:recognized.labels,diagnostics:recognized.diagnostics)
  jdDryRunSnapshot(snapshot,stage)
  let candidates=transferAccountCandidates(in:snapshot)
  if let candidate=candidates.first(where:{$0.name.contains("文文")}) {
    let x=min(max(candidate.frame.midX,snapshot.imageWidth*0.24),snapshot.imageWidth*0.50)
    jdDryRunRecord(["event":"original_v102_name_click_point","stage":stage,"target":candidate.name,"pixel":[x,candidate.frame.midY],"active":candidate.isActive])
    jdDryRunRecord(["event":"original_v102_action_predicates","stage":stage,"selectedCandidateActive":candidate.isActive,
      "lines":snapshot.lines.map {line in ["text":line.text,"compact":compactTransferText(line.text),"exactText":compactTransferText(line.text)=="转接",
        "x":Double(line.frame.midX),"y":Double(line.frame.midY),"xFraction":Double(line.frame.midX/snapshot.imageWidth),
        "xLowerPass":line.frame.midX>snapshot.imageWidth*0.55,"xUpperPass":line.frame.midX<snapshot.imageWidth*0.85,
        "rowPass":jdTransferActionBelongsToRow(action:line.frame,candidate:candidate)]}])
  } else {jdDryRunRecord(["event":"target_candidate_missing","stage":stage])}
  exit(0)
}

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
