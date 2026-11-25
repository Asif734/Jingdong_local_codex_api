import 'customer_message_time.dart';

/// The caller supplies only current-session, genuinely incoming messages.
/// Screenshot rereads, media parsing updates and seller replies are not new
/// customer input. Durable once-only handling belongs to the message ledger.
enum IncompleteImageAction { wait, requestResend, skip }

class IncompleteImagePolicy {
  static const timeout = Duration(minutes: 3);

  /// [waitingSince] is the caller's stable deadline anchor. [imageSentAt]
  /// separately identifies later customer input, including input sent before a
  /// delayed first screenshot of the original image.
  static IncompleteImageAction decide({
    required DateTime now,
    required DateTime waitingSince,
    required DateTime imageSentAt,
    DateTime? latestIncomingAt,
  }) {
    if (now.isBefore(waitingSince.add(timeout))) {
      return IncompleteImageAction.wait;
    }
    return latestIncomingAt != null &&
            CustomerMessageTime.second(latestIncomingAt)
                .isAfter(CustomerMessageTime.second(imageSentAt))
        ? IncompleteImageAction.skip
        : IncompleteImageAction.requestResend;
  }

  /// Use only when the customer has a durable skipped/incomplete image. This
  /// recognizes an explicit reference to that earlier upload; a request for
  /// product photos or a tutorial must stay on its ordinary answer path.
  static bool referencesPreviousImage(String body) {
    final text = body.trim();
    if (text.isEmpty || _placeholder.hasMatch(text) || !_image.hasMatch(text)) {
      return false;
    }
    if (_newUpload.hasMatch(text) || _futureUpload.hasMatch(text)) return false;
    final sentByCustomer = _customerUpload.hasMatch(text);
    if (!sentByCustomer && _sellerPhotoRequest.hasMatch(text)) {
      return false;
    }
    return sentByCustomer ||
        _priorImage.hasMatch(text) ||
        _receiptOrReview.hasMatch(text) ||
        _imageContent.hasMatch(text);
  }

  /// Only a reference/check request may be replaced by the fixed resend
  /// clarification. Any independent question or unfamiliar wording stays on
  /// the normal answer path, with the old-image resend context attached.
  static bool isSimpleReference(String body) {
    if (!referencesPreviousImage(body) ||
        RegExp(r'\b(?:and|also|besides|additionally)\b|另外|还有|以及|并且|顺便|同时|此外|再问',
                caseSensitive: false)
            .hasMatch(body)) {
      return false;
    }
    final words = RegExp(r"[a-z]+(?:['’][a-z]+)?", caseSensitive: false);
    if (words.allMatches(body).any(
        (word) => !_referenceWords.contains(word.group(0)!.toLowerCase()))) {
      return false;
    }
    var remainder = body.replaceAll(words, '');
    remainder = remainder.replaceAll(_referenceChinese, '');
    return remainder
        .replaceAll(RegExp(r'[\s0-9\p{P}\p{S}]', unicode: true), '')
        .isEmpty;
  }

  static final _referenceWords = ('did have has can could would do does you i '
          'we it they the a an that this those these my our your me us sent send '
          'sending upload uploaded share shared attach attached previous '
          'earlier old original last latest image images photo photos picture '
          'pictures screenshot screenshots see seen saw receive received '
          'receiving got get check checked checking view viewed look looked '
          'looking read reading load loaded loading fully complete completely '
          'clear clearly wrong issue problem need needs help tell what how '
          'about in on from at to for of is are was were been not yet already '
          'just now before ago again please kindly hi hello thanks thank '
          'really actually still here there with let take whether confirm '
          'review reviewed inspect inspected understand understood')
      .split(' ')
      .toSet();
  static final _referenceChinese = RegExp(
      r'请问|您好|你好|麻烦|谢谢|刚才|刚刚|之前|先前|前面|前边|上次|最新|最后|这张|那张|这个|那个|这些|那些|上一张|前一张|第[一二三四五六七八九十0-9]+|图片|照片|截图|相片|图像|发过去|发给|发送|上传|发来|发过|发的|发了|收到了|收到|看到了|看到|看见|看过|看得清|看不清|看清|清楚|看下|看看|检查|查看|确认|分析|解析|读取|加载|一下|是否|能否|有没有|没有|还没|已经|到底|怎么样|怎么了|什么情况|能不能|可以|能够|是不是|不是|你们|我们|我|你|您|亲|请|帮|给|到|在|这|那|的|了|吗|嘛|么|啊|呀|呢|没|是|不|收|看|能|有|已|还|几|两|一|个|段|张|条|份|对吧|吧|图|发');

  static final _placeholder =
      RegExp(r'^\[(?:Customer sent|image|video|图片|视频)', caseSensitive: false);
  static final _image = RegExp(
      r'图片|照片|截图|相片|图像|(?:那|这|上|前)张图|\b(?:image|photo|picture|screenshot)s?\b',
      caseSensitive: false);
  static final _customerUpload = RegExp(
      r'(?:我|我们)(?:刚才|之前|先前|刚刚|已经|刚|已)?(?:发|发送|传|上传|贴|分享)(?:给你们?|给您|给你看的|过|来|去|的|了|一下|那张|这张|[0-9:：\s]){0,8}(?:图片|照片|截图|相片|图)|(?:图片|照片|截图|相片|图).{0,20}(?:我|我们)(?:刚才|之前|先前|刚刚|已经|刚|已)?(?:发|传|上传)|\b(?:image|photo|picture|screenshot)s?\b.{0,35}\b(?:i|we)\s+(?:(?:have|had|just|already|previously)\s+)*(?:sent|uploaded|shared|attached)\b|\b(?:i|we)\s+(?:(?:have|had|just|already|previously)\s+)*(?:sent|uploaded|shared|attached)\b.{0,35}\b(?:image|photo|picture|screenshot)s?\b',
      caseSensitive: false);
  static final _priorImage = RegExp(
      r'(?:刚才|之前|先前|前面|前边|上次|上一张|前一张|那张|这张|那个|这个|那幅|这幅|上面|前面的).{0,12}(?:图片|照片|截图|相片|图像|图)|\b(?:that|those|this|these|previous|earlier|last|above|old|original)\s+(?:(?:uploaded|sent|attached|shared)\s+)?(?:image|photo|picture|screenshot)s?\b|\b(?:what|how)\s+about\s+(?:the|my)\s+(?:image|photo|picture|screenshot)s?\b',
      caseSensitive: false);
  static final _receiptOrReview = RegExp(
      r'(?:图片|照片|截图|相片|图像).{0,15}(?:看到了|看过|收到|看得|能看|加载|看一下|帮我看)|(?:看到了|看过|收到|看得|能看|加载|看一下|帮我看).{0,15}(?:图片|照片|截图|相片|图像)|\b(?:did|have|can|could|do|has|was)\b.{0,30}\b(?:see|receive|received|check|checked|view|read|load|loaded|look at)\b.{0,20}\b(?:image|photo|picture|screenshot)s?\b',
      caseSensitive: false);
  static final _imageContent = RegExp(
      r'(?:图片|照片|截图|相片|图像)(?:里面|上面|里|上|中的|里的|上的)|\b(?:in|on|from)\s+(?:the|my|that|this|previous|earlier|last|above)\s+(?:image|photo|picture|screenshot)s?\b',
      caseSensitive: false);
  static final _sellerPhotoRequest = RegExp(
      r'(?:给我|给我们|给您|给你|请|麻烦|有没有|是否有|我需要|我想要|我要).{0,18}(?:发(?!的|过|了)|提供|找|给|要|有).{0,15}(?:产品|商品|打印机|安装|教程|型号|色带)?(?:图片|照片|截图|相片|图)|(?:有没有|是否有|有没).{0,15}(?:产品|商品|打印机|安装|教程|型号|色带).{0,12}(?:图片|照片|截图|相片|图)|(?:发|发送|提供|找).{0,6}(?:给我|给我们).{0,20}(?:图片|照片|截图|相片|图)|\b(?:send|show|give|provide|find)\b.{0,15}\b(?:me|us)\b.{0,25}\b(?:image|photo|picture|screenshot)s?\b|\b(?:send|show|give|provide)\b.{0,30}\b(?:image|photo|picture|screenshot)s?\b.{0,15}\b(?:to|for)\s+(?:me|us)\b|\b(?:do you have|can you provide|i (?:want|need))\b.{0,25}\b(?:image|photo|picture|screenshot)s?\b',
      caseSensitive: false);
  static final _futureUpload = RegExp(
      r'(?:我|我们)(?:等下|稍后|一会儿|现在|马上|会|准备|打算).{0,8}(?:发|上传).{0,12}(?:图片|照片|截图|相片|图)|\b(?:i|we)(?:[’\x27]ll|\s+will|\s+am going to|\s+are going to)\s+(?:send|resend|upload|share|attach)\b',
      caseSensitive: false);
  static final _newUpload = RegExp(
      r'(?:我|我们).{0,8}(?:又|重新|再).{0,5}(?:发|传|上传).{0,12}(?:图片|照片|截图|相片|图)|(?:我|我们).{0,8}(?:发|传|上传).{0,8}(?:新|另一).{0,5}(?:图片|照片|截图|相片|图)|\b(?:i|we)\s+(?:(?:have|had|just|already)\s+)*(?:sent|uploaded|shared|attached)\b.{0,15}\b(?:new|another|different|fresh)\b.{0,10}\b(?:image|photo|picture|screenshot)s?\b',
      caseSensitive: false);
}
