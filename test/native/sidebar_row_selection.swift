// Appended to AccessibilityBridge.swift to exercise the production sampling
// and identity checks on synthetic window pixels. No AX queries or events.
func testSelection(_ selected: Set<Int>, scale: Int, layoutInset: Bool, origin: CGPoint) -> Int? {
  let bounds = CGRect(x: origin.x, y: origin.y, width: 400, height: 420)
  let width = 400 * scale
  let height = 420 * scale
  let ctx = CGContext(data: nil, width: width, height: height,
     bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  let frames = (0..<5).map { CGRect(x: bounds.minX + 65, y: bounds.minY + 198 + CGFloat($0 * 40),
                                    width: layoutInset ? 278 : 274, height: 40) }
  let pixels = ctx.data!.assumingMemoryBound(to: UInt8.self)
  for y in 0..<height {
    for x in 0..<width {
      let i = (y * width + x) * 4
      let row = (y / scale - 198) / 40
      let inRows = y / scale >= 198 && row < frames.count
      let stripe = layoutInset && x / scale >= 339 && x / scale < 343
      let color: [UInt8] = inRows && stripe
          ? (row < 2 ? [226, 226, 226] : [255, 255, 255])
          : (inRows && selected.contains(row) ? [231, 232, 234] : [253, 253, 253])
      for c in 0..<3 { pixels[i+c] = color[c] }
      pixels[i+3] = 255
    }
  }
  let snapshot = UnreadScreenshot(bounds: bounds, image: ctx.makeImage()!)
  return jdSelectedRowFromBackgrounds(frames.map { jdRowBackground($0, snapshot) })
}
func verifySidebarSelection() {
  let gutter = [247.0, 247.0, 247.0]
  let compactSelected = [225.0, 226.0, 229.0]
  precondition(jdSelectedRowFromBackgrounds([compactSelected], gutter: gutter) == 0)
  precondition(jdSelectedRowFromBackgrounds([gutter, compactSelected], gutter: gutter) == 1)
  precondition(jdSelectedRowFromBackgrounds([gutter], gutter: gutter) == nil)
  precondition(jdSelectedRowFromBackgrounds([compactSelected, compactSelected], gutter: gutter) == nil)
  precondition(jdSelectedRowFromBackgrounds([[242,242,242]], gutter: gutter) == nil)
  precondition(jdSelectedRowFromBackgrounds([compactSelected, gutter, gutter], gutter: gutter) == nil)
  let builtIn = CGPoint(x: 0, y: 30)
  precondition(testSelection([0], scale: 2, layoutInset: false, origin: builtIn) == 0, "original layout")
  precondition(testSelection([0], scale: 2, layoutInset: true, origin: builtIn) == 0,
    "278-point row: right edge scrollbar must not invalidate the selected row")
  precondition(testSelection([3], scale: 2, layoutInset: true, origin: builtIn) == 3, "another selected row")
  let external = CGPoint(x: -1200, y: 82)
  precondition(testSelection([1], scale: 1, layoutInset: true, origin: external) == 1, "1x plus translated origin")
  precondition(testSelection([0, 1], scale: 2, layoutInset: true, origin: builtIn) == nil, "ambiguous grey rows")
  precondition(testSelection([], scale: 2, layoutInset: true, origin: builtIn) == nil, "no selected row")
  var gate = JDRowConfirmationGate()
  gate.requiredChangeFrom = "jd_previous"
  precondition(gate.observe(selected: true, header: "jd_other", expected: "jd_target") == nil)
  precondition(gate.observe(selected: true, header: "jd_target", expected: "jd_target") == nil)
  precondition(gate.observe(selected: true, header: "jd_target", expected: "jd_target") == "jd_target")
  print("PASS: sidebar geometry, unambiguous selection and exact stable AX identity")
}
