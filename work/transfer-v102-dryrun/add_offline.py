from pathlib import Path
p=Path('work/transfer-v102-dryrun/main.swift');s=p.read_text();needle='let dryApp=NSApplication.shared'
block='''
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
'''
assert needle in s;s=s.replace(needle,block+'\n'+needle);p.write_text(s)
