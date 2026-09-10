import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:tronclass/auth/web_login_credential.dart';
import 'package:tronclass/common/toast.dart';

/// 浮在认证页上的账号密码卡片：可以拖到任意位置，账号和密码各能一键复制，
/// 也能收起来免得挡住网页上的输入框。
class CredentialCard extends StatefulWidget {
  const CredentialCard({
    super.key,
    required this.credential,
    required this.viewSize,
    this.onAutofill,
  });

  final WebLoginCredential credential;

  /// 手动再试一次自动填充。
  final VoidCallback? onAutofill;

  /// 可摆放的区域，用来把卡片限制在屏幕里。
  final Size viewSize;

  @override
  State<CredentialCard> createState() => _CredentialCardState();
}

class _CredentialCardState extends State<CredentialCard> {
  static const _margin = 12.0;
  static const _cardWidth = 260.0;

  Offset? _position;
  bool _collapsed = false;
  bool _passwordVisible = false;

  Offset get _initialPosition => Offset(
    widget.viewSize.width - _cardWidth - _margin,
    _margin,
  );

  void _drag(DragUpdateDetails details) {
    final current = _position ?? _initialPosition;
    // 卡片高度按内容估个上限就够，别让它被拖出屏幕。
    final maxY = (widget.viewSize.height - 80).clamp(0.0, double.infinity);
    setState(() {
      _position = Offset(
        (current.dx + details.delta.dx)
            .clamp(0.0, (widget.viewSize.width - _cardWidth).clamp(0.0, double.infinity)),
        (current.dy + details.delta.dy).clamp(0.0, maxY),
      );
    });
  }

  Future<void> _copy(String label, String value) async {
    if (value.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: value));
    toastSuccess0('$label已复制');
  }

  @override
  Widget build(BuildContext context) {
    final position = _position ?? _initialPosition;
    final scheme = Theme.of(context).colorScheme;

    return Positioned(
      left: position.dx,
      top: position.dy,
      child: GestureDetector(
        onPanUpdate: _drag,
        child: Material(
          elevation: 6,
          borderRadius: BorderRadius.circular(12),
          color: scheme.surface,
          child: Container(
            width: _cardWidth,
            padding: const EdgeInsets.fromLTRB(12, 6, 6, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.drag_indicator, size: 18, color: scheme.outline),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        '账号密码',
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: _collapsed ? '展开' : '收起',
                      icon: Icon(
                        _collapsed ? Icons.expand_more : Icons.expand_less,
                        size: 20,
                      ),
                      onPressed: () =>
                          setState(() => _collapsed = !_collapsed),
                    ),
                  ],
                ),
                if (!_collapsed) ...[
                  _CredentialRow(
                    label: '账号',
                    value: widget.credential.username,
                    onCopy: () => _copy('账号', widget.credential.username),
                  ),
                  const SizedBox(height: 6),
                  _CredentialRow(
                    label: '密码',
                    value: widget.credential.password,
                    obscured: !_passwordVisible,
                    onToggleVisibility: () =>
                        setState(() => _passwordVisible = !_passwordVisible),
                    onCopy: () => _copy('密码', widget.credential.password),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '没自动填上就点右边，或复制后粘贴',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: scheme.outline),
                        ),
                      ),
                      if (widget.onAutofill != null)
                        TextButton(
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                          ),
                          onPressed: widget.onAutofill,
                          child: const Text('自动填充'),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CredentialRow extends StatelessWidget {
  const _CredentialRow({
    required this.label,
    required this.value,
    required this.onCopy,
    this.obscured = false,
    this.onToggleVisibility,
  });

  final String label;
  final String value;
  final VoidCallback onCopy;
  final bool obscured;
  final VoidCallback? onToggleVisibility;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shown = value.isEmpty
        ? '（未填写）'
        : (obscured ? '•' * value.length.clamp(1, 12) : value);

    return Row(
      children: [
        SizedBox(
          width: 32,
          child: Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.outline),
          ),
        ),
        Expanded(
          child: Text(
            shown,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
        if (onToggleVisibility != null)
          IconButton(
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(),
            padding: const EdgeInsets.all(4),
            tooltip: obscured ? '显示' : '隐藏',
            icon: Icon(
              obscured ? Icons.visibility_off : Icons.visibility,
              size: 18,
            ),
            onPressed: onToggleVisibility,
          ),
        IconButton(
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(),
          padding: const EdgeInsets.all(4),
          tooltip: '复制',
          icon: const Icon(Icons.copy, size: 18),
          onPressed: value.isEmpty ? null : onCopy,
        ),
      ],
    );
  }
}
