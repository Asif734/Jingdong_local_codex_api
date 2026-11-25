import Cocoa
import FlutterMacOS
import XCTest
@testable import JD_Automation

class RunnerTests: XCTestCase {
  func testRegionDiagnosticsRecordMeasuredBackgroundAndRGBThreshold() {
    func image(_ gray:CGFloat) -> CGImage {
      let context=CGContext(data:nil,width:240,height:240,bitsPerComponent:8,bytesPerRow:0,
        space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
      context.setFillColor(red:gray,green:gray,blue:gray,alpha:1)
      context.fill(CGRect(x:0,y:0,width:240,height:240))
      return context.makeImage()!
    }
    let chat:[String:Double] = ["left":0,"right":1,"top":0,"bottom":1]
    var conditions=[[String:Any]]()
    XCTAssertTrue(jdUnboundMediaRegions(image:image(219.0/255),chatRegion:chat,
      onDiagnostic:{conditions.append($0)}).isEmpty)
    let blocked=conditions.first{$0["conditionId"] as? String == "region.neutral_background"}!
    XCTAssertEqual(blocked["passed"] as? Bool,false)
    XCTAssertEqual((blocked["actual"] as? [String:Any])?["backgroundRGB"] as? [Int],[219,219,219])
    XCTAssertEqual((blocked["threshold"] as? [String:Any])?["minimum"] as? Int,220)
    conditions=[]
    _=jdUnboundMediaRegions(image:image(247.0/255),chatRegion:chat,onDiagnostic:{conditions.append($0)})
    let rgb=conditions.first{$0["conditionId"] as? String == "region.foreground_rgb"}!
    XCTAssertEqual((rgb["threshold"] as? [String:Any])?["minimumChannelDelta"] as? Int,5)
    XCTAssertEqual((rgb["threshold"] as? [String:Any])?["edgeBackgroundDeltaExclusive"] as? Int,2)
    XCTAssertEqual((rgb["actual"] as? [String:Any])?["foregroundPixels"] as? Int,0)
  }

  func testSellerTextIsNotAVideoPlayOverlay() {
    let context=CGContext(data:nil,width:540,height:180,bitsPerComponent:8,bytesPerRow:0,
      space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(NSColor(deviceRed:0.82,green:0.88,blue:1,alpha:1).cgColor)
    context.fill(CGRect(x:0,y:0,width:540,height:180))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current=NSGraphicsContext(cgContext:context,flipped:false)
    for (index,text) in ["Install the USB printer driver.","Use Wi-Fi or Bluetooth printing.","Download the app for your phone."].enumerated() {
      (text as NSString).draw(at:CGPoint(x:10,y:130-index*45),withAttributes:
        [.font:NSFont.systemFont(ofSize:28),.foregroundColor:NSColor.black])
    }
    NSGraphicsContext.restoreGraphicsState()
    XCTAssertFalse(looksLikeVideoThumbnail(context.makeImage()!))
  }

  func testMediaClassifierRejectsWhitePhotosAndPreservesPlayControl() {

func mediaFixture(_ mode: Int) -> CGImage {
  let width = 400
  let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width,
    pixelsHigh: width, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  for y in 0..<width { for x in 0..<width {
    let dx = Double(x) - 199.5, dy = Double(y) - (mode == 3 ? 85.5 : 199.5)
    let radius = hypot(dx, dy)
    let ring = abs(radius - 36) <= 2.5
    let triangle = dx >= -10 && dx <= 18 && abs(dy) <= 15 * (18 - dx) / 28
    let bright = mode == 0 || ((mode == 1 || mode == 3) && (ring || triangle)) || (mode == 2 && radius <= 45)
    let grey: CGFloat = bright ? 1 : (mode == 3 ? 0.72 : 0.2)
    bitmap.setColor(NSColor(deviceRed: grey, green: grey, blue: grey, alpha: 1), atX: x, y: y)
  }}
  return bitmap.cgImage!
}
    XCTAssertFalse(looksLikeVideoThumbnail(mediaFixture(0)))
    XCTAssertTrue(looksLikeVideoThumbnail(mediaFixture(1)))
    XCTAssertFalse(looksLikeVideoThumbnail(mediaFixture(2)))
    XCTAssertTrue(looksLikeVideoThumbnail(mediaFixture(3)))
    XCTAssertLessThan(mediaForegroundFraction(mediaFixture(0)), 0.025)
    XCTAssertGreaterThanOrEqual(mediaForegroundFraction(mediaFixture(1)), 0.025)
  }

  func testUnreadBadgeIgnoresMirroredRowsAvatarsAndGreyClocks() {
    func fixture(_ red: CGRect?, scale: Int = 1) -> CGImage {
      let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 400 * scale,
          pixelsHigh: 400 * scale, bitsPerSample: 8, samplesPerPixel: 4,
          hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
          bytesPerRow: 0, bitsPerPixel: 0)!
      memset(bitmap.bitmapData!, 255, bitmap.bytesPerRow * bitmap.pixelsHigh)
      if let red {
        for y in Int(red.minY) * scale..<Int(red.maxY) * scale {
          for x in Int(red.minX) * scale..<Int(red.maxX) * scale {
            bitmap.setColor(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1), atX: x, y: y)
          }
        }
      }
      return bitmap.cgImage!
    }
    let row = CGRect(x: 0, y: 60, width: 200, height: 60)
    let window = CGRect(x: 0, y: 0, width: 400, height: 400)
    let badge = CGRect(x: 160, y: 80, width: 30, height: 18)
    XCTAssertGreaterThanOrEqual(unreadRedPixels(frame: row, windowBounds: window, image: fixture(badge)), 8)
    XCTAssertGreaterThanOrEqual(unreadRedPixels(frame: row, windowBounds: window, image: fixture(badge, scale: 2)), 8)
    XCTAssertEqual(unreadRedPixels(frame: row, windowBounds: window,
        image: fixture(CGRect(x: 160, y: 290, width: 30, height: 18))), 0)
    XCTAssertEqual(unreadRedPixels(frame: row, windowBounds: window,
        image: fixture(CGRect(x: 10, y: 80, width: 30, height: 18))), 0)
    XCTAssertNil(unreadElapsedSeconds(frame: row, windowBounds: window, image: fixture(nil)))
  }

  func testRowOCRPrefixConfusionRequiresOtherwiseExactJDIdentity() {
    XCTAssertTrue(rowOCRIdentityCandidateMatches("ja_6c67c99371fa4", "jd_6c67c99371fa4"))
    XCTAssertTrue(rowOCRIdentityCandidateMatches("jd_4laeec7741d05", "jd_41aeec7741d05"))
    XCTAssertFalse(rowOCRIdentityCandidateMatches("ja_6c67c99371fa5", "jd_6c67c99371fa4"))
    XCTAssertFalse(rowOCRIdentityCandidateMatches("alice", "a1ice"))
    XCTAssertFalse(rowOCRIdentityCandidateMatches("jd_41aeec7741d05", "jd_41aeec7741d05"))
  }

  func testRetryPixelInspectionReturnsBeforeDeliveringSeparateEvent() {
    let inspector = QianniuOCRInspector()
    let snapshot = image(badges: [badge], bubbles: [bubble], scale: 2)
    let event = expectation(description: "background retry candidates")
    event.assertForOverFulfill = true
    let capturedAt = Date(timeIntervalSince1970: 1791354310)
    var returned = false
    inspector.onFailedSendInspection = { payload in
      XCTAssertTrue(returned, "Incoming OCR must not wait for the retry scan")
      XCTAssertTrue(Thread.isMainThread)
      XCTAssertEqual(payload["customer"] as? String, "jd_customer")
      XCTAssertEqual(payload["capturedAtMs"] as? Int, 1791354310000)
      let candidates = payload["candidates"] as? [[String: Any]]
      XCTAssertEqual(candidates?.count, 1)
      XCTAssertEqual(candidates?.first?["windowId"] as? Int, 42)
      event.fulfill()
    }
    inspector.inspectFailedSends(image: snapshot, windowBounds: window,
        windowID: 42, transcript: window, customer: "jd_customer", capturedAt: capturedAt)
    returned = true
    // The same snapshot must not create a growing queue or change identity.
    inspector.inspectFailedSends(image: snapshot, windowBounds: window,
        windowID: 42, transcript: window, customer: "other_customer", capturedAt: capturedAt)
    wait(for: [event], timeout: 3)
  }

  func testNormalChatBackgroundInspectionEmitsNoRetryEvent() {
    let inspector = QianniuOCRInspector()
    let noRetry = expectation(description: "no failed message")
    noRetry.isInverted = true
    inspector.onFailedSendInspection = { _ in noRetry.fulfill() }
    inspector.inspectFailedSends(image: image(badges: [], bubbles: [bubble]),
        windowBounds: window, windowID: 42, transcript: window,
        customer: "jd_customer", capturedAt: Date())
    wait(for: [noRetry], timeout: 0.3)
  }

  private let window = CGRect(x: 100, y: 100, width: 400, height: 300)
  private let badge = CGRect(x: 164, y: 120, width: 32, height: 32)
  private let bubble = CGRect(x: 204, y: 100, width: 160, height: 100)

  private func image(badges: [CGRect], bubbles: [CGRect], scale: Int = 1,
      marks: [CGRect] = [], exclamation: Bool = true) -> CGImage {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 400 * scale,
        pixelsHigh: 300 * scale, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    let white = NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1)
    let red = NSColor(deviceRed: 1, green: 0.35, blue: 0.35, alpha: 1)
    let blue = NSColor(deviceRed: 0.85, green: 0.90, blue: 1, alpha: 1)
    for y in 0..<bitmap.pixelsHigh {
      for x in 0..<bitmap.pixelsWide {
        let point = CGPoint(x: CGFloat(x) / CGFloat(scale), y: CGFloat(y) / CGFloat(scale))
        var color = bubbles.contains(where: { $0.contains(point) }) ? blue : white
        for rect in badges {
          let nx = (point.x - rect.minX) / rect.width
          let ny = (point.y - rect.minY) / rect.height
          if pow(nx - 0.5, 2) + pow(ny - 0.5, 2) <= 0.25 {
            color = red
            if exclamation && nx >= 0.42 && nx <= 0.58 &&
                ((ny >= 0.21 && ny <= 0.59) || (ny >= 0.70 && ny <= 0.82)) {
              color = white
            }
          }
        }
        if marks.contains(where: { $0.contains(point) }) {
          color = NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 1)
        }
        bitmap.setColor(color, atX: x, y: y)
      }
    }
    return bitmap.cgImage!
  }

  private func detect(_ image: CGImage, chat: CGRect? = nil) -> [FailedSendBubble] {
    failedSendBubbles(image: image, windowBounds: window, chatFrame: chat ?? window)
  }

  func testScreenshotSized32PixelFailedIcon() throws {
    let result = try XCTUnwrap(detect(image(badges: [badge], bubbles: [bubble])).first)
    XCTAssertEqual(result.point.x, 280, accuracy: 1)
    XCTAssertEqual(result.point.y, 236, accuracy: 1)
    XCTAssertEqual(result.frame.height, 100, accuracy: 1)
  }

  func testRetinaCoordinates() throws {
    let result = try XCTUnwrap(detect(image(badges: [badge], bubbles: [bubble], scale: 2)).first)
    XCTAssertEqual(result.point.x, 280, accuracy: 1)
    XCTAssertEqual(result.point.y, 236, accuracy: 1)
  }

  func test16PointFailedIcon() {
    let small = CGRect(x: 180, y: 130, width: 16, height: 16)
    XCTAssertEqual(detect(image(badges: [small], bubbles: [bubble], scale: 2)).count, 1)
  }

  func testMultilineReplyAndWatermarkDoNotTruncateBubble() throws {
    let long = CGRect(x: 204, y: 50, width: 160, height: 200)
    let marks = [CGRect(x: 225, y: 133, width: 100, height: 5),
                 CGRect(x: 207, y: 170, width: 10, height: 2)]
    let result = try XCTUnwrap(detect(image(badges: [badge], bubbles: [long], marks: marks)).first)
    XCTAssertEqual(result.frame.height, 200, accuracy: 1)
  }

  func testRedShapesWithoutExclamationAreRejected() {
    XCTAssertTrue(detect(image(badges: [badge], bubbles: [bubble], exclamation: false)).isEmpty)
  }

  func testIconWithoutOutgoingBlueBubbleIsRejected() {
    XCTAssertTrue(detect(image(badges: [badge], bubbles: [])).isEmpty)
  }

  func testOtherChatAndEmojiToolbarAreExcluded() {
    let chat = CGRect(x: 100, y: 100, width: 400, height: 100)
    XCTAssertTrue(detect(image(badges: [badge], bubbles: [bubble]), chat: chat).isEmpty)
  }

  func testClippedMessageIsNotClicked() {
    let clipped = CGRect(x: 204, y: 0, width: 160, height: 200)
    XCTAssertTrue(detect(image(badges: [badge], bubbles: [clipped])).isEmpty)
  }

  func testBubbleFingerprintIgnoresFailedIcon() throws {
    let first = try XCTUnwrap(detect(image(badges: [badge], bubbles: [bubble])).first)
    let shifted = CGRect(x: 164, y: 140, width: 32, height: 32)
    let second = try XCTUnwrap(detect(image(badges: [shifted], bubbles: [bubble])).first)
    XCTAssertEqual(first.fingerprint, second.fingerprint)
  }

  func testBoundedRetryCooldown() {
    XCTAssertEqual((0..<7).map { failedSendRetryDelay(attempts: $0) }, [15, 30, 60, 120, 300, 300, 300])
  }

  func testCroppedChatCoordinatesExcludeSidebar() throws {
    let chat = CGRect(x: 240, y: 150, width: 250, height: 200)
    let result = try XCTUnwrap(detect(image(badges: [badge], bubbles: [bubble]), chat: chat).first)
    XCTAssertEqual(result.point.x, 280, accuracy: 1)
    XCTAssertEqual(result.point.y, 236, accuracy: 1)
  }

  func testNormalSentBubbleProducesNoRetryWork() {
    XCTAssertTrue(detect(image(badges: [], bubbles: [bubble])).isEmpty)
  }

  func testCandidateOnlyRevalidationRetainsFingerprint() throws {
    let screenshot = image(badges: [badge], bubbles: [bubble], scale: 2)
    let original = try XCTUnwrap(detect(screenshot).first)
    let region = original.frame.union(CGRect(x: original.point.x - 24,
        y: original.point.y - 24, width: 48, height: 48))
      .insetBy(dx: -8, dy: -8).intersection(window)
    let verified = try XCTUnwrap(detect(screenshot, chat: region).first)
    XCTAssertEqual(verified.fingerprint, original.fingerprint)
    XCTAssertEqual(verified.point, original.point)
  }
  func testCurrentFailedBubbleCannotConfirmDelivery() {
    XCTAssertEqual(failedSendBubbles(image: image(badges: [badge], bubbles: [bubble]),
      windowBounds: window, chatFrame: window, onlyLatestOutgoing: true).count, 1)
  }
  func testHistoricalFailureAboveNewSuccessfulBubbleDoesNotRejectNewSend() {
    let screenshot = image(badges: [badge], bubbles: [bubble, CGRect(x: 204,y: 230,width: 160,height: 50)])
    XCTAssertEqual(detect(screenshot).count, 1)
    XCTAssertTrue(failedSendBubbles(image: screenshot, windowBounds: window,
      chatFrame: window, onlyLatestOutgoing: true).isEmpty)
  }
  func testCurrentReceptionNoticeIsExplicitAndConservative() {
    XCTAssertTrue(jdReceptionNoticeBlocksDelivery(["该顾客正在咨询其他客服，无法回复顾客消息"]))
    XCTAssertFalse(jdReceptionNoticeBlocksDelivery(["您的同事将客户转接给您！"]))
    XCTAssertFalse(jdReceptionNoticeBlocksDelivery(["发送", "旧转接记录"]))
  }

}
