// Compile alongside AccessibilityBridge.swift so the test can run the real
// cache matcher against an isolated local cache.
func verifyMessageAnchoredCacheSearch(fixtures: URL) throws {
  let fm = FileManager.default
  let root = fm.temporaryDirectory.appendingPathComponent("jd_timed_index_\(UUID())")
  defer { try? fm.removeItem(at: root) }
  let source = fixtures.appendingPathComponent("v35_media/paper-image-1.png")
  let bitmap = NSBitmapImageRep(data: try Data(contentsOf: source))!.cgImage!
  let sent = Date(timeIntervalSince1970: 1794820000)
  let reception = "客服测试甲-咚咚融合工作台"
  func put(_ account: String, _ folder: String, _ name: String, _ delay: Double) throws -> URL {
    let dir=root.appendingPathComponent(account).appendingPathComponent("chat/chat_4").appendingPathComponent(folder)
    try fm.createDirectory(at:dir,withIntermediateDirectories:true)
    let path=dir.appendingPathComponent(name)
    try fm.copyItem(at:source,to:path)
    try fm.setAttributes([.modificationDate:sent.addingTimeInterval(delay)],ofItemAtPath:path.path)
    return path
  }
  precondition(jdCacheMessageTimeTier(secondsAfterMessage: -1) == 2)
  precondition(jdCacheMessageTimeTier(secondsAfterMessage: 16) == 0)
  precondition(jdCacheMessageTimeTier(secondsAfterMessage: 16.01) == 1)
  precondition(jdCacheMessageTimeTier(secondsAfterMessage: 60) == 1)
  precondition(jdCacheMessageTimeTier(secondsAfterMessage: 60.01) == 2)
  _ = try put("客服测试乙","images","other.png",2)
  let later = try put("客服测试甲","images","later.png",31)
  _ = try put("客服测试甲","thumbnails","later.png",5)
  var search=[String:Any]()
  func match(_ time: Double) -> URL? {
    matchingRecentJDCachedImage(visibleImage:bitmap,expectedAt:sent,
      now:sent.addingTimeInterval(time),cacheRoot:root,receptionTitle:reception,
      onSearch:{search=$0})?.url.standardizedFileURL
  }
  precondition(match(10)==nil,"Do not borrow the other account or future file.")
  precondition(match(40)==later.standardizedFileURL)
  precondition(search["tier"] as? Int == 1 && search["sameStemThumbnail"] as? Bool == true)
  let immediate=try put("客服测试甲","images","immediate.png",8)
  precondition(match(40)==immediate.standardizedFileURL)
  precondition(search["tier"] as? Int == 0)
  try fm.removeItem(at:immediate)
  try fm.removeItem(at:later)
  let older=try put("客服测试甲","images","older.png",-22)
  precondition(match(40)==older.standardizedFileURL)
  precondition(search["tier"] as? Int == 2)
  print("Timed media cache index checks passed")
}
