import Cocoa

/// Synthetic geometry only: no collector, AX reads, saved customer traces,
/// windows or input events are used by this executable.
@main
struct EditorChromeNativeTests {
  static func node(_ path:String,_ role:String,_ frame:CGRect,_ labels:[String]=[])->JDTranscriptAXGeometry {
    JDTranscriptAXGeometry(path:path,role:role,frame:frame,labels:labels)
  }
  static func main() {
    let chat=CGRect(x:100,y:100,width:600,height:800)
    let composer=CGRect(x:112,y:755,width:576,height:140)
    let transcript=CGRect(x:100,y:200,width:600,height:540)
    let tools=["选择表情","发送图片","发送视频"].enumerated().map {
      node("chat/editor/tool\($0.offset)","AXButton",CGRect(x:112+$0.offset*32,y:720,width:20,height:20),[$0.element])
    }
    let ownEditor=node("chat/editor","AXGroup",CGRect(x:100,y:650,width:600,height:250))
    let shared=node("chat","AXSplitGroup",chat)
    let top=jdTranscriptEditorChromeTop(chat:chat,transcriptPath:"chat/transcript",transcriptFrame:transcript,
      composerPath:"chat/editor/composer",composerFrame:composer,nodes:[shared,ownEditor]+tools)
    precondition(top==650)
    precondition(jdTranscriptContentBottom(composerTop:755,scrollBottom:740,toolbarTops:[720],editorChromeTop:top)==650)
    // The shared whole-chat ancestor must never clip away customer messages.
    precondition(jdTranscriptEditorChromeTop(chat:chat,transcriptPath:"chat/transcript",transcriptFrame:transcript,
      composerPath:"chat/composer",composerFrame:composer,nodes:[shared]+tools)==720)
    let screenshot=node("chat/transcript/image/tools","AXToolbar",CGRect(x:120,y:400,width:300,height:30))
    let imageButton=node("chat/transcript/image/button","AXButton",CGRect(x:120,y:450,width:20,height:20),["发送图片"])
    precondition(jdTranscriptEditorChromeTop(chat:chat,transcriptPath:"chat/transcript",transcriptFrame:transcript,
      composerPath:"chat/composer",composerFrame:composer,nodes:[shared,screenshot,imageButton])==nil)

    // Flat Qt variant: the parent owns the whole chat and is not a boundary.
    // Only the repeated square lane + divider + labeled editor controls prove
    // the shortcut row. Text labels on those squares are deliberately opaque.
    let flatChat=CGRect(x:346,y:126,width:495,height:715)
    let flatComposer=CGRect(x:358,y:582,width:471,height:215)
    let names=["选择表情","发送图片","发送视频","发送文件","屏幕截图","字体设置"]
    let flatTools=names.enumerated().map {
      node("flat/tool\($0.offset)","AXButton",CGRect(x:358+$0.offset*32,y:551,width:20,height:20),[$0.element])
    }
    let divider=node("flat/divider","AXGrowArea",CGRect(x:346,y:535,width:495,height:4))
    let tiles=(0..<15).map {
      node("flat/tile\($0)","AXStaticText",CGRect(x:358+$0*28,y:504,width:24,height:24),["opaque synthetic label"])
    }
    func boundary(_ nodes:[JDTranscriptAXGeometry])->CGFloat? {
      jdTranscriptEditorChromeTop(chat:flatChat,transcriptPath:nil,transcriptFrame:nil,
        composerPath:"flat/composer",composerFrame:flatComposer,nodes:nodes)
    }
    precondition(boundary(flatTools+[divider]+tiles)==504)
    precondition(boundary(flatTools+tiles)==551) // no divider proof
    precondition(boundary(flatTools+[divider]+Array(tiles.prefix(7)))==551)
    precondition(boundary([divider]+tiles)==nil) // emoji-like geometry alone
    let nested=tiles.map {node("flat/customer/\($0.path)",$0.role,$0.frame,$0.labels)}
    precondition(boundary(flatTools+[divider]+nested)==551)
    let irregular=tiles.enumerated().map { index,tile in
      node(tile.path,tile.role,tile.frame.offsetBy(dx:index==7 ? 8:0,dy:0),tile.labels)
    }
    precondition(boundary(flatTools+[divider]+irregular)==551)
    let high=tiles.map {node($0.path,$0.role,$0.frame.offsetBy(dx:0,dy:-100),$0.labels)}
    precondition(boundary(flatTools+[divider]+high)==551)
    let all=flatTools+[divider]+tiles
    let scaled=all.map {
      node($0.path,$0.role,CGRect(x:$0.frame.minX*1.5+30,y:$0.frame.minY*1.5+20,
        width:$0.frame.width*1.5,height:$0.frame.height*1.5),$0.labels)
    }
    precondition(jdTranscriptEditorChromeTop(chat:CGRect(x:549,y:209,width:742.5,height:1072.5),
      transcriptPath:nil,transcriptFrame:nil,composerPath:"flat/composer",
      composerFrame:CGRect(x:567,y:893,width:706.5,height:322.5),nodes:scaled)==776)
    precondition(jdTranscriptContentBottom(composerTop:582,scrollBottom:nil,toolbarTops:[],editorChromeTop:boundary(all))==504)
    print("v56 editor-chrome synthetic geometry checks passed")
  }
}
