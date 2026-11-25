@main
struct ServiceAccountProofAcceptance {
  static func main() {
    func proof(_ header: String?, _ title: String?) -> String? {
      jdServiceAccountFromAXHeader(header, windowTitle: title)
    }
    precondition(proof("格志打印机小耿", "格志打印机小耿-咚咚融合工作台") == "格志打印机小耿")
    precondition(proof("其他店铺小林", "其他店铺小林 — 咚咚融合工作台") == "其他店铺小林")
    precondition(proof("Team-agent_I1", "Team-agent_I1 - 咚咚融合工作台") == "Team-agent_I1")
    precondition(proof("Team agent_I1", "Team agent_I1-咚咚融合工作台") == "Team agent_I1")
    precondition(proof("Team agent_Il", "Team agent_I1-咚咚融合工作台") == nil)
    precondition(proof("格志打印机小耿", "格志打印机小华-咚咚融合工作台") == nil)
    precondition(proof(nil, "格志打印机小耿-咚咚融合工作台") == nil)
    precondition(proof("格志打印机小耿", nil) == nil)
    precondition(proof("当前客服账号", "当前客服账号-咚咚融合工作台") == nil)
    precondition(proof("格志打印机小耿", "咚咚融合工作台") == nil)
    precondition(proof("格志打印机小耿", "格志打印机小耿-咚咚融合工作台-extra") == nil)
    print("PASS: literal AX service account proof, without native UI or OCR")
  }
}
