import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../runtime/automation_settings.dart';

/// Edits apply to the next run. The parent owns the immutable running settings.
class AutomationControls extends StatefulWidget {
  const AutomationControls(
      {super.key,
      required this.settings,
      required this.locked,
      required this.onChanged,
      required this.onValidityChanged});
  final AutomationSettings settings;
  final bool locked;
  final ValueChanged<AutomationSettings> onChanged;
  final ValueChanged<bool> onValidityChanged;

  @override
  State<AutomationControls> createState() => _AutomationControlsState();
}

class _AutomationControlsState extends State<AutomationControls> {
  late final TextEditingController _holding;
  bool _valid = true;

  @override
  void initState() {
    super.initState();
    _holding = TextEditingController(
        text: '${widget.settings.holdingResponseSeconds}');
  }

  @override
  void didUpdateWidget(AutomationControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.settings != widget.settings &&
        _holding.text != '${widget.settings.holdingResponseSeconds}') {
      _holding.text = '${widget.settings.holdingResponseSeconds}';
      _valid = true;
    }
  }

  void _changed(String _) {
    final holding = int.tryParse(_holding.text);
    final valid = holding != null && holding >= 20 && holding <= 500;
    setState(() => _valid = valid);
    widget.onValidityChanged(valid);
    if (valid) {
      widget.onChanged(AutomationSettings(holdingResponseSeconds: holding));
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _field('兜底等待（秒）', '20–500', _holding, 'holding-seconds'),
          const SizedBox(height: 5),
          Text(widget.locked ? '运行期间参数已锁定' : '仅红标计时；正式答复就绪后立即发送',
              style: Theme.of(context).textTheme.bodySmall),
          if (!_valid)
            const Text('请输入范围内的整数',
                style: TextStyle(color: Colors.red, fontSize: 12)),
        ]),
      );

  Widget _field(String label, String hint, TextEditingController controller,
          String key) =>
      TextField(
        key: ValueKey(key),
        controller: controller,
        enabled: !widget.locked,
        keyboardType: TextInputType.number,
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(3)
        ],
        onChanged: _changed,
        decoration: InputDecoration(
            labelText: label,
            helperText: hint,
            isDense: true,
            border: const OutlineInputBorder()),
      );

  @override
  void dispose() {
    _holding.dispose();
    super.dispose();
  }
}
