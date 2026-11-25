import 'customer_language.dart';
import '../domain/capture_models.dart';

/// Invoice collection uses the customer's original text, never extracted media
/// text or a model's guess. The active episode begins at its explicit request.
class InvoiceCollection {
  const InvoiceCollection({
    required this.requestMessageId,
    required this.inputMessageIds,
    required this.facts,
    required this.missingSlots,
    required this.currentTurnInvoiceOnly,
  });

  final String requestMessageId;
  final List<String> inputMessageIds;
  final Map<String, String> facts;
  final List<String> missingSlots;
  final bool currentTurnInvoiceOnly;
  bool get complete => missingSlots.isEmpty;

  Map<String, Object?> context() => {
        'request_message_id': requestMessageId,
        'customer_provided_details': facts,
        'missing_slots': missingSlots,
        'details_complete': complete,
        'authority': 'collect_details_then_customer_service_handoff',
      };

  String clarification(CustomerLanguage language) {
    final names = missingSlots.map((slot) => InvoiceRequestPolicy
        .slotNames[slot]![language == CustomerLanguage.english ? 1 : 0]);
    return language == CustomerLanguage.english
        ? 'Please provide ${names.join(', ')} for the invoice. Once the details are complete, I can connect you with a customer service colleague to handle it.'
        : '麻烦您补充${names.join('、')}。开票资料齐全后，我为您转接客服同事核实办理。';
  }

  AiDraft draft(CustomerLanguage language, {String? sessionId}) =>
      AiDraft.fromJson({
        'reply': complete
            ? language == CustomerLanguage.english
                ? 'I have your invoice details. I will connect you with a customer service colleague to verify and handle the request.'
                : '开票资料已收到，我为您转接客服同事核实办理。'
            : clarification(language),
        'decision': complete ? 'human_review_required' : 'ask_clarification',
        'reply_purpose': 'substantive',
        'confidence': 1,
        'risk_level': complete ? 'medium' : 'low',
        'human_review_required': complete,
        'risk_triggers': complete ? ['order_service_handoff'] : <String>[],
        'required_slots': missingSlots,
        'actions': <Object?>[],
        'attachments': <Object?>[],
        'auto_send_allowed': false,
        'used_record_ids': ['jd_order_page_invoice_types'],
        'human_transfer_request_message_ids': <String>[],
        'invoice_collection': context(),
        'invoice_collection_phase': complete ? 'handoff' : 'collecting',
        if (sessionId != null) 'service_session_id': sessionId,
        'model': InvoiceRequestPolicy.model,
      }, mediaBaseUrl: Uri());
}

class InvoiceRequestPolicy {
  static const model = 'jd-invoice-collection-v1';
  static const slotNames = <String, List<String>>{
    'invoice_order': [
      '订单号或明确的本笔订单',
      'the order number or the specific current order'
    ],
    'invoice_type': [
      '所需发票类型（普票或专票）',
      'the invoice type (ordinary or special VAT invoice)'
    ],
    'invoice_title_type': [
      '抬头类型（个人或单位）',
      'whether the invoice is personal or for a company'
    ],
    'invoice_title': ['发票抬头', 'the invoice title/name'],
    'invoice_tax_id': ['税号', 'the tax ID'],
    'invoice_general_taxpayer': [
      '一般纳税人资格情况',
      'the general VAT taxpayer qualification status'
    ],
    'invoice_bank_name': ['开户行', 'the company bank name'],
    'invoice_bank_account': ['银行账号', 'the company bank account number'],
    'invoice_company_address': ['公司地址', 'the company address'],
    'invoice_contact_phone': ['联系电话', 'the contact telephone number'],
  };

  static bool isRequest(String text) {
    var requested = false;
    for (final clause in text.split(RegExp(r'[。;；，,\n]'))) {
      if (_negativeClause(clause)) {
        requested = false;
      } else if (_requestClause(clause)) {
        requested = true;
      }
    }
    return requested;
  }

  static bool _requestClause(String text) {
    if (RegExp(
            r'发票打印|打印发票|票据打印|invoice\s+print|print(?:ing)?\s+(?:an?\s+)?invoice',
            caseSensitive: false)
        .hasMatch(text)) {
      return false;
    }
    if (RegExp(r'怎么|如何|哪里|在哪|流程|步骤|\bhow\s+(?:do|can|to)\b|\bwhere\b',
                caseSensitive: false)
            .hasMatch(text) &&
        !RegExp(r'帮我|请帮|麻烦.{0,6}(?:开|补开|重开)|\b(?:please\s+(?:issue|send)|issue\s+me)\b',
                caseSensitive: false)
            .hasMatch(text)) {
      return false;
    }
    if (RegExp(r'了解|咨询|询问|问一下|\b(?:information|know about)\b',
            caseSensitive: false)
        .hasMatch(text)) {
      return false;
    }
    if (RegExp(
            r'(?:我要|我需要|需要)(?:一(?:张|份)|个|张)?(?:电子|普通|增值税专用|公司|单位|个人)?发票|(?:请|帮我|麻烦).{0,8}开(?:一张|个|张|一下)?发票|(?:我要|我想|我需要|需要|请|帮我|麻烦).{0,8}(?:开|补开|重开)?(?:专票|普票)|开票资料(?:如下|[:：])|\b(?:can|could|would)\s+you\s+(?:please\s+)?(?:issue|send|provide)\b.{0,30}\b(?:an?|my)\s+invoice\b|^(?:an?\s+)?invoice\s+please[?!.\s]*$',
            caseSensitive: false)
        .hasMatch(text)) {
      return true;
    }
    return RegExp(
            r'(?:我要|我想|我需要|需要|帮我|请帮|麻烦|请).{0,14}(?:开票|开发票|开具.{0,4}发票|补开.{0,4}发票|重开.{0,4}发票)|(?:申请|要求)(?:开票|开具发票|发票)|^(?:开票|开(?:个|张)?发票|补开发票|重开发票)[。！!\s]*$|\b(?:i\s+(?:need|want|would like)|please\s+(?:issue|send|provide)|(?:issue|send|provide)\s+me|request(?:ing)?)\b.{0,35}\binvoice\b',
            caseSensitive: false)
        .hasMatch(text);
  }

  static bool isCancellation(String text) {
    var cancelled = false;
    for (final clause in text.split(RegExp(r'[。;；，,\n]'))) {
      if (_negativeClause(clause)) {
        cancelled = true;
      } else if (_requestClause(clause)) {
        cancelled = false;
      }
    }
    return cancelled;
  }

  static bool _negativeClause(String text) => RegExp(
          r'(?:不要|不用|不需要|无需|取消).{0,8}(?:开票|发票|专票|普票)|(?:开票|发票|专票|普票).{0,8}(?:不要|不用|取消)|\b(?:do\s+not|don[’\x27]?t|no\s+longer)\s+(?:need|want)\b.{0,15}\binvoice\b|\bcancel\b.{0,15}\binvoice\b',
          caseSensitive: false)
      .hasMatch(text);

  static bool _original(Map<String, dynamic> message, String? customer) =>
      message['direction'] == 'incoming' &&
      message['id'] is String &&
      message['text_origin'] != 'media' &&
      message['media_receipt_id'] == null &&
      (message['media'] as List? ?? const []).isEmpty &&
      (customer == null ||
          message['sender'] == null ||
          message['sender'] == customer) &&
      !RegExp(r'^\[(?:Customer|Video|Image|Media)', caseSensitive: false)
          .hasMatch(message['body']?.toString() ?? '');

  static DateTime? _time(Map message) => DateTime.tryParse(
      (message['sent_at'] ?? message['captured_at'])?.toString() ?? '');

  static InvoiceCollection? resolve({
    required List<Map<String, dynamic>> history,
    required List<Map<String, dynamic>> currentInputs,
    String? customer,
    String? sessionId,
  }) {
    final current = currentInputs.where((m) => _original(m, customer)).toList();
    if (current.isEmpty) return null;
    final currentIds = current.map((m) => m['id']).toSet();
    final cutoff = current.map(_time).whereType<DateTime>().toList()..sort();
    final messages = history
        .where((m) =>
            _original(m, customer) &&
            (cutoff.isEmpty ||
                _time(m) == null ||
                !_time(m)!.isAfter(cutoff.last)))
        .toList();
    for (final message in current) {
      if (!messages.any((m) => m['id'] == message['id'])) messages.add(message);
    }
    messages.sort((a, b) {
      final first = _time(a), second = _time(b);
      return first == null || second == null ? 0 : first.compareTo(second);
    });
    var start = -1;
    for (var i = 0; i < messages.length; i++) {
      final text = messages[i]['body']?.toString() ?? '';
      if (isCancellation(text)) {
        start = -1;
      } else if (isRequest(text)) {
        start = i;
      }
    }
    if (start < 0) return null;
    final request = messages[start];
    final requestId = request['id']! as String;
    final currentHasRequest = currentIds.contains(requestId);
    Map? previousRaw;
    if (!currentHasRequest) {
      final firstCurrent = current.map(_time).whereType<DateTime>().toList()
        ..sort();
      final previous = history
          .where((m) =>
              m['direction'] == 'outgoing' &&
              m['source'] == 'generated_reply' &&
              const {'sent', 'submitted', 'accepted'}
                  .contains(m['delivery_status']) &&
              _time(m) != null &&
              (firstCurrent.isEmpty || _time(m)!.isBefore(firstCurrent.first)))
          .toList()
        ..sort((a, b) => _time(a)!.compareTo(_time(b)!));
      if (previous.isEmpty) return null;
      previousRaw =
          (previous.last['reply_metadata'] as Map?)?['raw_response'] as Map?;
      final linked = previousRaw?['invoice_collection'] as Map?;
      if (previousRaw?['model'] != model ||
          previousRaw?['invoice_collection_phase'] != 'collecting' ||
          linked?['request_message_id'] != requestId ||
          (sessionId != null &&
              previousRaw?['service_session_id'] != sessionId)) {
        return null;
      }
    }
    final facts = <String, String>{};
    for (final message in messages.skip(start)) {
      final extracted = _facts(message['body']?.toString() ?? '');
      final newOrder = extracted['invoice_order'];
      if (newOrder != null &&
          facts['invoice_order'] != null &&
          newOrder != facts['invoice_order']) {
        facts.clear();
      }
      facts.addAll(extracted);
    }
    var acceptedBareValue = false;
    if (!currentHasRequest && current.length == 1) {
      final priorSlots = (previousRaw?['required_slots'] as List? ?? const [])
          .whereType<String>()
          .toList();
      if (priorSlots.length == 1 && !facts.containsKey(priorSlots.single)) {
        final value = _bareValue(
            priorSlots.single, current.single['body']?.toString() ?? '');
        if (value != null) {
          facts[priorSlots.single] = value;
          acceptedBareValue = true;
        }
      }
    }
    final currentRelevant = current
        .map((m) => _relevant(m['body']?.toString() ?? '') || acceptedBareValue)
        .toList();
    if (!currentHasRequest &&
        !currentRelevant.any((v) => v) &&
        !acceptedBareValue) {
      return null;
    }
    final slots = <String>['invoice_order', 'invoice_type', 'invoice_title'];
    final special = facts['invoice_type'] == 'special_vat';
    if (!special && facts['invoice_title_type'] == null) {
      slots.add('invoice_title_type');
    }
    if (special || facts['invoice_title_type'] == 'company') {
      slots.add('invoice_tax_id');
    }
    if (special) {
      slots.addAll([
        'invoice_general_taxpayer',
        'invoice_bank_name',
        'invoice_bank_account',
        'invoice_company_address',
        'invoice_contact_phone'
      ]);
    }
    return InvoiceCollection(
        requestMessageId: requestId,
        inputMessageIds: current.map((m) => m['id']! as String).toList(),
        facts: Map.unmodifiable(facts),
        missingSlots: slots.where((s) => !facts.containsKey(s)).toList(),
        currentTurnInvoiceOnly: current.length == currentInputs.length &&
            currentRelevant.every((v) => v) &&
            current.every(
                (m) => !_hasIndependentQuestion(m['body']?.toString() ?? '')));
  }

  static bool _relevant(String text) =>
      isRequest(text) ||
      _facts(text).isNotEmpty ||
      RegExp(r'开票|发票|抬头|税号|纳税|开户行|银行账号|公司地址|联系电话|订单号|\binvoice\b|\btax\s+id\b|\bbank\s+(?:name|account)\b|\bcompany\s+(?:name|address)\b|\border\s*(?:id|number|#)',
              caseSensitive: false)
          .hasMatch(text);

  static bool _hasIndependentQuestion(String text) => RegExp(
          r'(?:怎么|如何|为什么|怎样|无法|不能|不会|不行|失败).{0,20}(?:打印|连接|安装|驱动|色带|蓝牙|卡纸|电源)|(?:打印|连接|安装|驱动|色带|蓝牙|卡纸|电源).{0,15}(?:怎么|如何|为什么|不行|失败)|\b(?:how|why|what|can|does|do)\b.{0,50}\b(?:printer|print|driver|ribbon|bluetooth|paper|power|install|connect)\b',
          caseSensitive: false)
      .hasMatch(text);

  static Map<String, String> _facts(String text) {
    final facts = <String, String>{};
    for (final line in text.split(RegExp(r'[\n;；，,]'))) {
      void take(String slot, String pattern, {bool numeric = false}) {
        final matches = RegExp('(?:$pattern)\\s*[:：=]\\s*([^\\n;；，,]+)',
                caseSensitive: false)
            .allMatches(line);
        for (final match in matches) {
          var value =
              match.group(1)!.trim().replaceAll(RegExp(r'[。.!！]+$'), '');
          if (value.isEmpty ||
              RegExp(r'^(?:不知道|不清楚|没有|待提供|unknown|not sure|n/?a)$',
                      caseSensitive: false)
                  .hasMatch(value)) {
            continue;
          }
          if (numeric &&
              !RegExp(r'^[A-Za-z0-9 +()\-]{5,40}$').hasMatch(value)) {
            continue;
          }
          facts[slot] = value;
        }
      }

      take('invoice_order', r'订单(?:号|编号)|order\s*(?:number|id|#)',
          numeric: true);
      take('invoice_title',
          r'发票抬头|抬头|公司名称|单位名称|个人姓名|invoice\s*(?:title|name)|company\s*name|name\s*on\s*(?:the\s*)?invoice');
      take('invoice_tax_id',
          r'税号|纳税人识别号|统一社会信用代码|tax\s*(?:id|number)|VAT\s*(?:id|number)',
          numeric: true);
      take('invoice_bank_name', r'开户行|开户银行|bank\s*name');
      take('invoice_bank_account', r'银行账号|开户账号|账号|bank\s*account(?:\s*number)?',
          numeric: true);
      take('invoice_company_address',
          r'公司地址|注册地址|company\s*address|registered\s*address');
      take('invoice_contact_phone',
          r'联系电话|公司电话|contact\s*(?:phone|telephone)|phone(?:\s*number)?',
          numeric: true);
      take('invoice_general_taxpayer',
          r'一般纳税人资格(?:情况)?|一般纳税人|general\s*(?:VAT\s*)?taxpayer(?:\s*(?:qualification|status))?');
      if (RegExp(
              r'公司名称|单位名称|单位(?:发票|抬头)|企业(?:发票|抬头)|抬头类型\s*[:：=]\s*(?:单位|公司|企业)|company\s*(?:name|invoice)|business\s*invoice|^(?:单位|公司|企业|company|business)$',
              caseSensitive: false)
          .hasMatch(line)) {
        facts['invoice_title_type'] = 'company';
      }
      if (RegExp(
              r'个人(?:发票|抬头|姓名|普票|电子|普通)|抬头(?:类型)?\s*[:：=]\s*个人|personal\s*(?:ordinary\s*)?invoice|invoice\s*(?:for|type\s*[:=])\s*(?:an?\s*)?individual|^(?:个人|personal|individual)$',
              caseSensitive: false)
          .hasMatch(line)) {
        facts['invoice_title_type'] = 'personal';
      }
      if (RegExp(r'一般纳税人', caseSensitive: false).hasMatch(line) &&
          !RegExp(r'资格|[:：=]|\?|？').hasMatch(line)) {
        facts['invoice_general_taxpayer'] = line.trim();
      }
      if (RegExp(r'专票|增值税专用发票|special\s*(?:VAT\s*)?invoice',
              caseSensitive: false)
          .hasMatch(line)) {
        facts['invoice_type'] = 'special_vat';
      } else if (RegExp(
              r'普票|普通发票|电子发票|ordinary\s*(?:electronic\s*)?invoice|standard\s*invoice',
              caseSensitive: false)
          .hasMatch(line)) {
        facts['invoice_type'] = 'ordinary';
      }
      if (RegExp(r'这笔订单|本笔订单|当前这笔订单|本订单|\bthis order\b|\bthe current order\b',
              caseSensitive: false)
          .hasMatch(line)) {
        facts.putIfAbsent('invoice_order', () => line.trim());
      }
    }
    final title = facts['invoice_title'];
    if (title != null &&
        RegExp(r'公司|企业|商行|合作社|\b(?:ltd|limited|llc|inc|corp|corporation|gmbh)\b',
                caseSensitive: false)
            .hasMatch(title)) {
      facts['invoice_title_type'] = 'company';
    }
    return facts;
  }

  static String? _bareValue(String slot, String body) {
    final value = body.trim().replaceAll(RegExp(r'[。.!！]+$'), '');
    if (slot == 'invoice_general_taxpayer' &&
        RegExp(r'^(?:是|否|不是|是的|yes|no)$', caseSensitive: false)
            .hasMatch(value)) {
      return value;
    }
    if (slot == 'invoice_type') {
      if (RegExp(r'^(?:普票|普通发票|电子发票|ordinary|standard)$', caseSensitive: false)
          .hasMatch(value)) {
        return 'ordinary';
      }
      if (RegExp(r'^(?:专票|增值税专用发票|special(?: VAT)?)$', caseSensitive: false)
          .hasMatch(value)) {
        return 'special_vat';
      }
    }
    if (value.isEmpty ||
        value.length > 100 ||
        RegExp(r'^(?:ok|okay|yes|no|thanks|thank you|好的|好|是|是的|不知道|不清楚|谢谢)$',
                caseSensitive: false)
            .hasMatch(value) ||
        RegExp(r'[?？\n]|怎么|如何|取消|不要|不需要|\bhow\b|\bcancel\b',
                caseSensitive: false)
            .hasMatch(value)) {
      return null;
    }
    if (slot == 'invoice_title' &&
        !RegExp(r'^[0-9]+$|坏了|故障|错误|问题|打印机|色带|驱动|\b(?:printer|ribbon|driver|broken|problem|issue)\b',
                caseSensitive: false)
            .hasMatch(value)) {
      return value;
    }
    if (slot == 'invoice_order' &&
        RegExp(r'^[A-Za-z0-9-]{8,30}$').hasMatch(value)) {
      return value;
    }
    if (slot == 'invoice_tax_id' &&
        RegExp(r'^[A-Za-z0-9]{15,20}$').hasMatch(value)) {
      return value;
    }
    if (const {'invoice_bank_account', 'invoice_contact_phone'}
            .contains(slot) &&
        RegExp(r'^[0-9+() \-]{7,35}$').hasMatch(value)) {
      return value;
    }
    return null;
  }
}
