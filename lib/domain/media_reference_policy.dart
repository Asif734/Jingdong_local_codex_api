import 'reply_progress.dart';

bool isVideoGuideRequest(String text) {
  final normalized = text.toLowerCase().trim();
  final mentionsVideo =
      RegExp(r'\b(?:videos?|clips?)\b|视频').hasMatch(normalized);
  if (!mentionsVideo) return false;
  // Asking the buyer to send media and offering to upload it are incoming
  // attachment turns, including when they mention setup or instructions.
  if (RegExp(
          r'\b(?:can|could|may|should)\s+(?:i|we)\b.{0,30}\b(?:send|share|upload|provide)\b|\b(?:i|we)\s+(?:(?:will|can|have|already|just|am|are)\s+)*(?:send|sent|sending|share|shared|upload|uploaded)\b|(?:我|我们).{0,8}(?:发|上传|传).{0,8}(?:你|您)|(?:可以|能否|能).{0,8}(?:发|传).{0,8}(?:给你|给您)|(?:可以|能否|能).{0,6}(?:给你|给您).{0,4}(?:发|传|分享)')
      .hasMatch(normalized)) {
    return false;
  }
  if (isExplicitMediaReceiptQuestion(normalized) ||
      RegExp(r'\b(?:check|watch|review|analy[sz]e|look at)\b.{0,25}\b(?:my|our|this|that|attached)\b.{0,25}\b(?:videos?|clips?)\b|\b(?:my|our|attached|uploaded)\s+(?:setup\s+)?(?:videos?|clips?)\b|(?:看|检查|分析).{0,8}(?:我|刚发|上传).{0,8}视频')
          .hasMatch(normalized)) {
    return false;
  }
  final outgoing = RegExp(
      r'\b(?:can|could|would|will)\s+you\s+(?:please\s+)?(?:share|send|provide|give|show)\b.{0,35}\b(?:videos?|clips?)\b|^(?:please\s+)?(?:share|send|provide|give|show)\s+(?:me|us)\b.{0,35}\b(?:videos?|clips?)\b|(?:发|分享|提供)(?:给)?(?:我|我们).{0,10}视频|(?:给我|给我们).{0,8}(?:发|分享|提供).{0,8}视频');
  if (outgoing.hasMatch(normalized)) return true;
  final asksForGuidance = RegExp(
          r'\b(guide|guidance|guideline|guidelines|tutorial|instructions?|how[- ]?to|setup|set up|operate|operation)\b|教程|指导|指南|操作|设置|怎么')
      .hasMatch(normalized);
  return asksForGuidance;
}
