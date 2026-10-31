import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../services/plugin_service.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

/// 插件管理
class PluginsPage extends StatefulWidget {
  const PluginsPage({super.key});

  @override
  State<PluginsPage> createState() => _PluginsPageState();
}

class _PluginsPageState extends State<PluginsPage> {
  List<InstalledPlugin> _plugins = [];
  InstalledPlugin? _selected;
  bool _busy = false;
  final Map<String, String> _inputs = {};

  final List<String> _log = [];
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scan();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final plugins = await PluginService.instance.scan();
    if (!mounted) return;
    setState(() {
      _plugins = plugins;
      if (plugins.isNotEmpty && _selected == null) {
        _selected = plugins.first;
      } else if (_selected != null) {
        // 刷新选中项
        final found = plugins.where((p) => p.manifest.id == _selected!.manifest.id);
        _selected = found.isNotEmpty ? found.first : null;
      }
    });

    // 测试钩子：GAOJI_PLUGIN_AUTO=索引 自动执行第 N 个 action
    final auto = Platform.environment['GAOJI_PLUGIN_AUTO'];
    if (auto != null && _selected != null && !_autoRan) {
      _autoRan = true;
      final idx = int.tryParse(auto) ?? 0;
      final allActions = <PluginAction>[];
      for (final card in _selected!.manifest.ui.cards) {
        allActions.addAll(card.actions);
      }
      if (idx < allActions.length) {
        await Future.delayed(const Duration(seconds: 1));
        if (mounted) _runAction(_selected!, allActions[idx]);
      }
    }
  }

  bool _autoRan = false;

  void _addLog(String s) {
    if (!mounted) return;
    setState(() => _log.add(s));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  Future<void> _import() async {
    final r = await FilePicker.platform.pickFiles(
      dialogTitle: '选择插件包（.zip）',
      type: FileType.any,
    );
    if (r == null || r.files.single.path == null) return;

    setState(() {
      _busy = true;
      _log.clear();
    });

    final result = await PluginService.instance.importFromZip(
      zipPath: r.files.single.path!,
      onLine: _addLog,
    );

    if (!mounted) return;
    setState(() => _busy = false);
    _addLog(result.ok ? '✅ ${result.message}' : '❌ ${result.message}');

    if (result.ok) await _scan();
  }

  Future<void> _uninstall(InstalledPlugin plugin) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('卸载插件'),
        content: Text('确定卸载「${plugin.manifest.name}」？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
            child: const Text('卸载'),
          ),
        ],
      ),
    );

    if (ok != true) return;

    final r = await PluginService.instance.uninstall(plugin.manifest.id);
    if (!mounted) return;
    _addLog(r.ok ? '✅ ${r.message}' : '❌ ${r.message}');
    await _scan();
  }

  Future<void> _runAction(InstalledPlugin plugin, PluginAction action) async {
    if (action.confirm != null) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(action.label),
          content: Text(action.confirm!,
              style: const TextStyle(fontSize: 12, height: 1.6)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: action.danger
                  ? ElevatedButton.styleFrom(backgroundColor: AppTheme.danger)
                  : null,
              child: const Text('确认'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }

    setState(() {
      _busy = true;
      _log.clear();
    });

    final r = await PluginService.instance.runAction(
      plugin: plugin,
      action: action,
      inputs: _inputs,
      onLine: _addLog,
    );

    if (!mounted) return;
    setState(() => _busy = false);
    _addLog(r.ok ? '✅ ${r.message}' : '❌ ${r.message}');
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        // 左侧：插件列表
        Container(
          width: 240,
          decoration: const BoxDecoration(
            border: Border(right: BorderSide(color: AppTheme.border)),
          ),
          child: Column(
            children: [
              // 工具栏
              Container(
                padding: const EdgeInsets.all(10),
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: AppTheme.border)),
                ),
                child: Row(
                  children: [
                    const Text('插件',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.textSecondary)),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: AppTheme.primary.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: Text('${_plugins.length}',
                          style: const TextStyle(
                              fontSize: 9, color: AppTheme.primary)),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.add, size: 16),
                      color: AppTheme.primary,
                      visualDensity: VisualDensity.compact,
                      tooltip: '导入插件',
                      onPressed: _busy ? null : _import,
                    ),
                    IconButton(
                      icon: const Icon(Icons.refresh, size: 15),
                      color: AppTheme.textMuted,
                      visualDensity: VisualDensity.compact,
                      tooltip: '刷新',
                      onPressed: _busy ? null : _scan,
                    ),
                  ],
                ),
              ),

              // 列表
              Expanded(
                child: _plugins.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.extension,
                                  size: 40, color: AppTheme.textMuted),
                              const SizedBox(height: 14),
                              const Text('还没有插件',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: AppTheme.textMuted)),
                              const SizedBox(height: 8),
                              const Text(
                                '插件可以给软件增加新功能\n而不增加主程序体积',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    fontSize: 10.5,
                                    color: AppTheme.textMuted,
                                    height: 1.6),
                              ),
                              const SizedBox(height: 16),
                              OutlinedButton.icon(
                                onPressed: _busy ? null : _import,
                                icon: const Icon(Icons.add, size: 14),
                                label: const Text('导入插件',
                                    style: TextStyle(fontSize: 11)),
                              ),
                            ],
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        itemCount: _plugins.length,
                        itemBuilder: (context, i) {
                          final plugin = _plugins[i];
                          final sel =
                              _selected?.manifest.id == plugin.manifest.id;
                          return InkWell(
                            onTap: () => setState(() {
                              _selected = plugin;
                              _inputs.clear();
                              // 初始化默认值
                              for (final inp in plugin.manifest.ui.inputs) {
                                if (inp.defaultValue != null) {
                                  _inputs[inp.id] = inp.defaultValue!;
                                }
                              }
                            }),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 9),
                              color: sel
                                  ? AppTheme.primary.withValues(alpha: 0.1)
                                  : null,
                              child: Row(
                                children: [
                                  Icon(
                                    _iconOf(plugin.manifest.icon),
                                    size: 15,
                                    color: plugin.valid
                                        ? (sel
                                            ? AppTheme.primary
                                            : AppTheme.textSecondary)
                                        : AppTheme.danger,
                                  ),
                                  const SizedBox(width: 9),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          plugin.manifest.name,
                                          style: TextStyle(
                                            fontSize: 11.5,
                                            color: sel
                                                ? AppTheme.primary
                                                : AppTheme.textPrimary,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        Text(
                                          'v${plugin.manifest.version}',
                                          style: const TextStyle(
                                              fontSize: 9.5,
                                              color: AppTheme.textMuted),
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (!plugin.valid)
                                    const Icon(Icons.error,
                                        size: 12, color: AppTheme.danger),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),

        // 中间：插件详情
        Expanded(
          flex: 3,
          child: _selected == null
              ? const EmptyState(
                  icon: Icons.extension,
                  title: '选择一个插件',
                  subtitle: '或点击左上角「+」导入插件',
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(18),
                  child: _buildPluginDetail(_selected!),
                ),
        ),

        // 右侧：日志
        Container(
          width: 340,
          decoration: const BoxDecoration(
            border: Border(left: BorderSide(color: AppTheme.border)),
          ),
          child: Column(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: AppTheme.border)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.terminal,
                        size: 14, color: AppTheme.accent),
                    const SizedBox(width: 7),
                    const Text('输出',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.textSecondary)),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.delete_sweep, size: 14),
                      color: AppTheme.textMuted,
                      visualDensity: VisualDensity.compact,
                      onPressed: () => setState(() => _log.clear()),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Container(
                  color: const Color(0xFF0A0C10),
                  child: _log.isEmpty
                      ? const Center(
                          child: Text('等待操作…',
                              style: TextStyle(
                                  fontSize: 11.5,
                                  color: AppTheme.textMuted)))
                      : ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.all(9),
                          itemCount: _log.length,
                          itemBuilder: (context, i) {
                            final line = _log[i];
                            Color c = AppTheme.textSecondary;
                            if (line.contains('✅')) c = AppTheme.success;
                            if (line.contains('❌') || line.contains('⚠️')) {
                              c = AppTheme.danger;
                            }
                            if (line.startsWith('══')) c = AppTheme.accent;
                            return SelectableText(line,
                                style: TextStyle(
                                    fontSize: 10.5,
                                    fontFamily: 'monospace',
                                    color: c,
                                    height: 1.4));
                          },
                        ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPluginDetail(InstalledPlugin plugin) {
    final m = plugin.manifest;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 头部
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppTheme.primary.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
            border:
                Border.all(color: AppTheme.primary.withValues(alpha: 0.25)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(_iconOf(m.icon), size: 20, color: AppTheme.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(m.name,
                            style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: AppTheme.textPrimary)),
                        Text('v${m.version} · ${m.author}',
                            style: const TextStyle(
                                fontSize: 10.5, color: AppTheme.textMuted)),
                      ],
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : () => _uninstall(plugin),
                    icon: const Icon(Icons.delete_outline, size: 13),
                    label: const Text('卸载',
                        style: TextStyle(fontSize: 10.5)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.danger,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 9, vertical: 4),
                      minimumSize: Size.zero,
                    ),
                  ),
                ],
              ),
              if (m.description.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(m.description,
                    style: const TextStyle(
                        fontSize: 11.5,
                        color: AppTheme.textSecondary,
                        height: 1.6)),
              ],
              if (m.license != null || m.homepage != null) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    if (m.license != null)
                      Text('许可: ${m.license}',
                          style: const TextStyle(
                              fontSize: 10, color: AppTheme.textMuted)),
                    if (m.license != null && m.homepage != null)
                      const SizedBox(width: 14),
                    if (m.homepage != null)
                      Text(m.homepage!,
                          style: const TextStyle(
                              fontSize: 10, color: AppTheme.accent)),
                  ],
                ),
              ],
            ],
          ),
        ),

        // 无效提示
        if (!plugin.valid) ...[
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppTheme.danger.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              children: [
                const Icon(Icons.error, size: 14, color: AppTheme.danger),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('插件无效: ${plugin.error}',
                      style: const TextStyle(
                          fontSize: 11, color: AppTheme.danger)),
                ),
              ],
            ),
          ),
        ],

        // 输入项
        if (m.ui.inputs.isNotEmpty) ...[
          const SizedBox(height: 14),
          AppCard(
            title: '参数',
            child: Column(
              children: [
                for (final inp in m.ui.inputs)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _buildInput(inp),
                  ),
              ],
            ),
          ),
        ],

        // 操作卡片
        for (final card in m.ui.cards) ...[
          const SizedBox(height: 14),
          AppCard(
            title: card.title,
            child: Column(
              children: [
                for (var i = 0; i < card.actions.length; i++) ...[
                  if (i > 0) const Divider(height: 14),
                  _buildActionRow(plugin, card.actions[i]),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildInput(PluginInput inp) {
    final value = _inputs[inp.id] ?? '';

    switch (inp.type) {
      case 'file':
        return Row(
          children: [
            SizedBox(
              width: 90,
              child: Text(inp.label,
                  style: const TextStyle(
                      fontSize: 11.5, color: AppTheme.textSecondary)),
            ),
            Expanded(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                decoration: BoxDecoration(
                  color: AppTheme.bgElevated,
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  value.isEmpty ? (inp.hint ?? '未选择') : p.basename(value),
                  style: TextStyle(
                    fontSize: 10.5,
                    fontFamily: 'monospace',
                    color: value.isEmpty
                        ? AppTheme.textMuted
                        : AppTheme.textPrimary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            const SizedBox(width: 6),
            OutlinedButton(
              onPressed: _busy
                  ? null
                  : () async {
                      final r = await FilePicker.platform.pickFiles(
                        dialogTitle: inp.label,
                        type: FileType.any,
                      );
                      if (r != null && r.files.single.path != null) {
                        setState(() => _inputs[inp.id] = r.files.single.path!);
                      }
                    },
              style: OutlinedButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                minimumSize: Size.zero,
              ),
              child: const Text('选择', style: TextStyle(fontSize: 10.5)),
            ),
          ],
        );

      case 'dir':
        return Row(
          children: [
            SizedBox(
              width: 90,
              child: Text(inp.label,
                  style: const TextStyle(
                      fontSize: 11.5, color: AppTheme.textSecondary)),
            ),
            Expanded(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                decoration: BoxDecoration(
                  color: AppTheme.bgElevated,
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  value.isEmpty ? (inp.hint ?? '未选择') : value,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontFamily: 'monospace',
                    color: value.isEmpty
                        ? AppTheme.textMuted
                        : AppTheme.textPrimary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            const SizedBox(width: 6),
            OutlinedButton(
              onPressed: _busy
                  ? null
                  : () async {
                      final d = await FilePicker.platform
                          .getDirectoryPath(dialogTitle: inp.label);
                      if (d != null) {
                        setState(() => _inputs[inp.id] = d);
                      }
                    },
              style: OutlinedButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                minimumSize: Size.zero,
              ),
              child: const Text('选择', style: TextStyle(fontSize: 10.5)),
            ),
          ],
        );

      case 'select':
        return Row(
          children: [
            SizedBox(
              width: 90,
              child: Text(inp.label,
                  style: const TextStyle(
                      fontSize: 11.5, color: AppTheme.textSecondary)),
            ),
            Expanded(
              child: DropdownButton<String>(
                value: value.isEmpty ? null : value,
                isDense: true,
                isExpanded: true,
                hint: Text(inp.hint ?? '请选择',
                    style: const TextStyle(
                        fontSize: 11, color: AppTheme.textMuted)),
                underline: const SizedBox(),
                style: const TextStyle(
                    fontSize: 11.5, color: AppTheme.textPrimary),
                items: [
                  for (final o in inp.options)
                    DropdownMenuItem(
                        value: o['value'], child: Text(o['label'] ?? '')),
                ],
                onChanged: _busy
                    ? null
                    : (v) => setState(() => _inputs[inp.id] = v ?? ''),
              ),
            ),
          ],
        );

      case 'bool':
        return Row(
          children: [
            SizedBox(
              width: 90,
              child: Text(inp.label,
                  style: const TextStyle(
                      fontSize: 11.5, color: AppTheme.textSecondary)),
            ),
            Switch(
              value: value == 'true',
              onChanged: _busy
                  ? null
                  : (v) => setState(
                      () => _inputs[inp.id] = v ? 'true' : 'false'),
            ),
          ],
        );

      default: // text
        return Row(
          children: [
            SizedBox(
              width: 90,
              child: Text(inp.label,
                  style: const TextStyle(
                      fontSize: 11.5, color: AppTheme.textSecondary)),
            ),
            Expanded(
              child: TextField(
                controller: TextEditingController(text: value),
                onChanged: (v) => _inputs[inp.id] = v,
                decoration: InputDecoration(
                  hintText: inp.hint,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 8),
                ),
                style: const TextStyle(
                    fontSize: 11, fontFamily: 'monospace'),
              ),
            ),
          ],
        );
    }
  }

  Widget _buildActionRow(InstalledPlugin plugin, PluginAction action) {
    final enabled = !_busy;
    return InkWell(
      onTap: enabled ? () => _runAction(plugin, action) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            Icon(
              _iconOf(action.icon ?? 'play_arrow'),
              size: 15,
              color: enabled
                  ? (action.danger ? AppTheme.danger : AppTheme.primary)
                  : AppTheme.textMuted,
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    action.label,
                    style: TextStyle(
                        fontSize: 12,
                        color: enabled
                            ? (action.danger
                                ? AppTheme.danger
                                : AppTheme.textPrimary)
                            : AppTheme.textMuted),
                  ),
                  if (action.description != null)
                    Text(action.description!,
                        style: const TextStyle(
                            fontSize: 10, color: AppTheme.textMuted)),
                ],
              ),
            ),
            if (enabled)
              const Icon(Icons.chevron_right,
                  size: 15, color: AppTheme.textMuted),
          ],
        ),
      ),
    );
  }

  IconData _iconOf(String name) {
    const map = {
      'extension': Icons.extension,
      'build': Icons.build,
      'flash_on': Icons.flash_on,
      'memory': Icons.memory,
      'usb': Icons.usb,
      'cable': Icons.cable,
      'phone_iphone': Icons.phone_iphone,
      'developer_board': Icons.developer_board,
      'watch': Icons.watch,
      'play_arrow': Icons.play_arrow,
      'download': Icons.download,
      'upload': Icons.upload,
      'delete': Icons.delete,
      'settings': Icons.settings,
      'info': Icons.info,
      'error': Icons.error,
      'lock_open': Icons.lock_open,
      'security': Icons.security,
      'storage': Icons.storage,
      'folder': Icons.folder,
    };
    return map[name] ?? Icons.extension;
  }
}
