import 'package:flutter/material.dart';

import '../domain/message_record.dart';

class CustomerMessageTimeline extends StatelessWidget {
  const CustomerMessageTimeline({
    super.key,
    required this.customer,
    required this.records,
    this.loading = false,
    this.failed = false,
    this.recoveringCount = 0,
    this.onRetryAnswer,
  });

  final String? customer;
  final List<CustomerMessageRecord>? records;
  final bool loading;
  final bool failed;
  final int recoveringCount;
  final VoidCallback? onRetryAnswer;

  static String formatTime(DateTime value) {
    // Match the JD message header even when the Mac uses another time zone.
    final time = value.toUtc().add(const Duration(hours: 8));
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
  }

  static String statusLabel(String status) => switch (status) {
        'answered' => '已回复',
        'delegated' => '已转交',
        'analyzing' || 'generating' => '正在处理',
        'ready' => '等待发送',
        'sending' => '正在发送',
        'awaiting_review' => '待人工核查',
        'needs_answer' => '待补答',
        'awaiting_media' => '等待媒体解析',
        'skipped_image' => '已跳过，待重发',
        'skipped_media' => '已跳过，待重发',
        'resend_requested' => '已请求重发',
        'image_resend_pending' => '等待发送重发请求',
        _ => '待回复',
      };

  static String kindLabel(String kind) => switch (kind) {
        'video' => '视频消息',
        'image' => '图片消息',
        'text' => '文字消息',
        _ => '类型待确认',
      };

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(14, 8, 14, 6),
            child: Text('消息时间线', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
          if (customer != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              child: SelectableText(customer!,
                  key: const ValueKey('message-timeline-customer'),
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(14, 0, 14, 10),
            child: Text('按聊天消息时间排序；一条图片或视频只记一条。',
                style: TextStyle(fontSize: 12, color: Colors.black54)),
          ),
          if (records?.any((record) => record.status == 'needs_answer') == true)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('尚未生成正式答复，原问题仍保留为未答。',
                      style: TextStyle(fontSize: 12, color: Colors.deepOrange)),
                  TextButton.icon(
                    key: const ValueKey('retry-customer-answer'),
                    onPressed: onRetryAnswer,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('重新生成答复'),
                  ),
                ],
              ),
            ),
          if (recoveringCount > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
              child: Text('$recoveringCount 条消息正在恢复，尚未正式回复',
                  key: const ValueKey('timeline-admission-gaps'),
                  style: TextStyle(color: Colors.orange.shade900)),
            ),
          Expanded(child: _content(context)),
        ],
      );

  Widget _content(BuildContext context) {
    if (customer == null) {
      return const Center(
          child: Padding(
              padding: EdgeInsets.all(20),
              child: Text('在中间选择客户，查看消息接收时间和回复记录。',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.black54))));
    }
    if (failed) {
      return const Center(child: Text('消息记录暂时无法读取，请刷新。'));
    }
    if (records == null) {
      return Center(
          child: loading
              ? const CircularProgressIndicator()
              : const Text('该客户本轮暂无消息记录'));
    }
    if (records!.isEmpty) {
      return Center(
          child: Text(recoveringCount > 0 ? '正在恢复消息记录，尚未正式回复' : '该客户本轮暂无消息记录'));
    }
    return ListView.separated(
        key: const ValueKey('customer-message-timeline'),
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        itemCount: records!.length,
        separatorBuilder: (context, index) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final record = records![index];
          final answered = record.status == 'answered';
          final color = answered
              ? Colors.green.shade700
              : record.status == 'delegated'
                  ? Colors.blueGrey
                  : Colors.orange.shade900;
          final body = record.kind == 'text' ? record.body.trim() : '';
          return Container(
            key: ValueKey('message-record:${record.stableId}'),
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: color.withValues(alpha: .22)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(
                      child: Text('${index + 1} · ${kindLabel(record.kind)}',
                          style: const TextStyle(fontWeight: FontWeight.w600))),
                  Text(statusLabel(record.status),
                      key: ValueKey('message-status:${record.stableId}'),
                      style: TextStyle(color: color, fontSize: 12)),
                ]),
                if (body.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(body, maxLines: 3, overflow: TextOverflow.ellipsis),
                ],
                const SizedBox(height: 8),
                Text(
                    record.messageAt == null
                        ? '消息时间待识别'
                        : '消息 ${formatTime(record.messageAt!)}',
                    key: ValueKey('message-received:${record.stableId}'),
                    style: const TextStyle(fontSize: 12)),
                const SizedBox(height: 3),
                Text(
                    '${record.status == 'resend_requested' ? '请求重发' : !answered && record.repliedAt != null ? '上次回复' : '回复'} '
                    '${record.repliedAt == null ? '—' : formatTime(record.repliedAt!)}',
                    key: ValueKey('message-replied:${record.stableId}'),
                    style: const TextStyle(fontSize: 12)),
                if (answered &&
                    record.replyAttemptId != null &&
                    (record.coveredMessageCount ?? 0) > 1) ...[
                  const SizedBox(height: 5),
                  Text('合并回复 · 同次覆盖${record.coveredMessageCount}条消息',
                      key: ValueKey('message-merged-reply:${record.stableId}'),
                      style: TextStyle(
                          fontSize: 11, color: Colors.green.shade700)),
                ],
                if (record.holdingAt != null &&
                    !answered &&
                    !const {
                      'skipped_image',
                      'skipped_media',
                      'resend_requested'
                    }.contains(record.status)) ...[
                  const SizedBox(height: 5),
                  Text('已兜底 ${formatTime(record.holdingAt!)}，仍待正式回复',
                      style: TextStyle(
                          fontSize: 11, color: Colors.orange.shade900)),
                ],
              ],
            ),
          );
        });
  }
}
