import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/app_theme.dart';

/// 高级功能协议确认门
///
/// 首次进入高级功能区时弹出，用户必须完整输入确认短语才能进入。
/// 确认后记录到 SharedPreferences，之后不再重复询问。
class DisclaimerGate extends StatefulWidget {
  /// 确认后回调
  final VoidCallback onAccepted;

  /// 已接受时是否跳过（默认 true）
  final bool skipIfAccepted;

  const DisclaimerGate({
    super.key,
    required this.onAccepted,
    this.skipIfAccepted = true,
  });

  /// 必须完整输入的确认短语
  static const confirmPhrase = '我已阅读并同意以上全部条款，自愿承担变砖与数据丢失的全部风险';

  /// SharedPreferences 键名
  static const _prefKey = 'disclaimer_accepted_v1';

  /// 检查是否已接受
  static Future<bool> isAccepted() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_prefKey) ?? false;
  }

  /// 清除接受状态（测试用）
  static Future<void> reset() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefKey);
  }

  @override
  State<DisclaimerGate> createState() => _DisclaimerGateState();
}

class _DisclaimerGateState extends State<DisclaimerGate> {
  bool? _accepted;
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();
  bool _scrolledToBottom = false;
  String _agreementText = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _check();
    _loadAgreement();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    final ok = await DisclaimerGate.isAccepted();
    if (!mounted) return;
    if (ok && widget.skipIfAccepted) {
      // 已接受，直接放行
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.onAccepted();
      });
      return;
    }
    setState(() => _accepted = false);
  }

  Future<void> _loadAgreement() async {
    try {
      final text = await rootBundle.loadString('assets/data/disclaimer.md');
      if (!mounted) return;
      setState(() {
        _agreementText = text;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _agreementText = '（协议文件加载失败）';
        _loading = false;
      });
    }
  }

  void _onScroll() {
    if (_scrolledToBottom) return;
    final pos = _scrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 40) {
      setState(() => _scrolledToBottom = true);
    }
  }

  bool get _canAccept =>
      _scrolledToBottom &&
      _inputController.text.trim() == DisclaimerGate.confirmPhrase;

  Future<void> _accept() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(DisclaimerGate._prefKey, true);
    if (!mounted) return;
    widget.onAccepted();
  }

  @override
  Widget build(BuildContext context) {
    // 检查中
    if (_accepted == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return Container(
      color: AppTheme.bgDeep,
      child: Center(
        child: Container(
          width: 760,
          height: 700,
          decoration: BoxDecoration(
            color: AppTheme.bgSurface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.border),
          ),
          child: Column(
            children: [
              // 标题栏
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppTheme.danger.withValues(alpha: 0.1),
                  borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(12)),
                  border: Border(
                    bottom: BorderSide(
                        color: AppTheme.danger.withValues(alpha: 0.3)),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded,
                        size: 22, color: AppTheme.danger),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '高级功能 · 风险告知与免责声明',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.textPrimary,
                            ),
                          ),
                          SizedBox(height: 3),
                          Text(
                            '此区域包含 Bootloader 解锁、底层分区改写等操作，可能导致设备变砖、数据永久丢失',
                            style: TextStyle(
                                fontSize: 11.5, color: AppTheme.textSecondary),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              // 协议正文
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : Container(
                        color: AppTheme.bgDeep,
                        child: SingleChildScrollView(
                          controller: _scrollController,
                          padding: const EdgeInsets.all(20),
                          child: _renderAgreement(_agreementText),
                        ),
                      ),
              ),

              // 底部确认区
              Container(
                padding: const EdgeInsets.all(16),
                decoration: const BoxDecoration(
                  border: Border(top: BorderSide(color: AppTheme.border)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 滚动提示
                    if (!_scrolledToBottom)
                      Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: AppTheme.warning.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Row(
                          children: [
                            Icon(Icons.arrow_downward,
                                size: 14, color: AppTheme.warning),
                            SizedBox(width: 8),
                            Text(
                              '请滚动阅读完整协议后，才能进行确认',
                              style: TextStyle(
                                  fontSize: 11.5, color: AppTheme.warning),
                            ),
                          ],
                        ),
                      ),

                    // 确认短语
                    const Text(
                      '请完整输入以下文字以确认：',
                      style: TextStyle(
                          fontSize: 12, color: AppTheme.textSecondary),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: AppTheme.bgElevated,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: AppTheme.border),
                      ),
                      child: SelectableText(
                        DisclaimerGate.confirmPhrase,
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppTheme.warning,
                          height: 1.6,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _inputController,
                      enabled: _scrolledToBottom,
                      maxLines: 2,
                      style: const TextStyle(fontSize: 12.5),
                      decoration: InputDecoration(
                        hintText: _scrolledToBottom
                            ? '在此完整输入上面这句话'
                            : '请先滚动阅读协议',
                        isDense: true,
                        filled: true,
                        fillColor: AppTheme.bgElevated,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: 14),

                    // 按钮
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => widget.onAccepted(),
                            style: OutlinedButton.styleFrom(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 14),
                            ),
                            child: const Text('返回普通功能'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 2,
                          child: ElevatedButton(
                            onPressed: _canAccept ? _accept : null,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppTheme.danger,
                              foregroundColor: Colors.white,
                              padding:
                                  const EdgeInsets.symmetric(vertical: 14),
                            ),
                            child: Text(
                              _canAccept
                                  ? '我已知晓风险，进入高级功能'
                                  : '输入正确后才能继续',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 渲染协议 Markdown（简化版）
  Widget _renderAgreement(String md) {
    final widgets = <Widget>[];
    for (final raw in md.split('\n')) {
      final line = raw.trimRight();
      if (line.trim().isEmpty) {
        widgets.add(const SizedBox(height: 6));
        continue;
      }
      if (line.startsWith('# ')) {
        widgets.add(Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            line.substring(2).trim(),
            style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: AppTheme.textPrimary),
          ),
        ));
        continue;
      }
      if (line.startsWith('## ')) {
        widgets.add(Padding(
          padding: const EdgeInsets.only(top: 16, bottom: 8),
          child: Text(
            line.substring(3).trim(),
            style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppTheme.primary),
          ),
        ));
        continue;
      }
      if (line.startsWith('---')) {
        widgets.add(const Padding(
          padding: EdgeInsets.symmetric(vertical: 10),
          child: Divider(),
        ));
        continue;
      }
      // 有序列表
      if (RegExp(r'^\d+\.\s').hasMatch(line)) {
        widgets.add(Padding(
          padding: const EdgeInsets.only(left: 4, top: 4, bottom: 4),
          child: Text(
            _cleanInline(line),
            style: const TextStyle(
                fontSize: 12.5,
                color: AppTheme.textSecondary,
                height: 1.75),
          ),
        ));
        continue;
      }
      // 无序列表
      if (RegExp(r'^-\s').hasMatch(line)) {
        widgets.add(Padding(
          padding: const EdgeInsets.only(left: 12, top: 3, bottom: 3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Icon(Icons.circle, size: 4, color: AppTheme.textMuted),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _cleanInline(line.substring(2).trim()),
                  style: const TextStyle(
                      fontSize: 12.5,
                      color: AppTheme.textSecondary,
                      height: 1.7),
                ),
              ),
            ],
          ),
        ));
        continue;
      }
      // 普通段落
      widgets.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Text(
          _cleanInline(line),
          style: const TextStyle(
              fontSize: 12.5,
              color: AppTheme.textSecondary,
              height: 1.75),
        ),
      ));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: widgets,
    );
  }

  String _cleanInline(String s) {
    var t = s;
    // **bold** → bold（保留加粗语义用【】标记）
    t = t.replaceAllMapped(
        RegExp(r'\*\*([^*]+)\*\*'), (m) => '【${m.group(1)}】');
    // `code` → code
    t = t.replaceAllMapped(RegExp(r'`([^`]+)`'), (m) => m.group(1)!);
    return t;
  }
}
