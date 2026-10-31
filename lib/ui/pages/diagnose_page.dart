import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/diagnose_service.dart';
import '../../services/device_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

/// 一键诊断
///
/// 快速检查设备与环境状态，找出常见问题
class DiagnosePage extends StatefulWidget {
  const DiagnosePage({super.key});

  @override
  State<DiagnosePage> createState() => _DiagnosePageState();
}

class _DiagnosePageState extends State<DiagnosePage> {
  List<DiagGroup> _groups = [];
  bool _running = false;
  final List<String> _log = [];

  @override
  void initState() {
    super.initState();
    // 测试用：GAOJI_AUTO=1 自动开始诊断
    if (Platform.environment['GAOJI_AUTO'] == '1') {
      // 延迟 2 秒，等 DeviceProvider 加载完设备列表
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) _run();
      });
    }
  }

  Future<void> _run() async {
    var device = context.read<DeviceProvider>().selectedDevice;

    // 设备列表可能还没加载完，等最多 5 秒
    if (device == null) {
      for (var i = 0; i < 10; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        if (!mounted) return;
        device = context.read<DeviceProvider>().selectedDevice;
        if (device != null) break;
      }
    }

    setState(() {
      _running = true;
      _groups = [];
      _log.clear();
    });

    final groups = await DiagnoseService.instance.runAll(
      serial: device?.serial,
      onLine: (s) {
        if (!mounted) return;
        setState(() => _log.add(s));
      },
    );

    if (!mounted) return;
    setState(() {
      _groups = groups;
      _running = false;
    });
  }

  Color _levelColor(DiagLevel l) {
    switch (l) {
      case DiagLevel.ok:
        return AppTheme.success;
      case DiagLevel.warn:
        return AppTheme.warning;
      case DiagLevel.error:
        return AppTheme.danger;
      case DiagLevel.info:
        return AppTheme.textMuted;
    }
  }

  IconData _levelIcon(DiagLevel l) {
    switch (l) {
      case DiagLevel.ok:
        return Icons.check_circle;
      case DiagLevel.warn:
        return Icons.warning_amber;
      case DiagLevel.error:
        return Icons.error;
      case DiagLevel.info:
        return Icons.info_outline;
    }
  }

  @override
  Widget build(BuildContext context) {
    final device = context.watch<DeviceProvider>().selectedDevice;

    // 汇总
    final allItems = _groups.expand((g) => g.items).toList();
    final errors =
        allItems.where((i) => i.level == DiagLevel.error).length;
    final warns = allItems.where((i) => i.level == DiagLevel.warn).length;

    return Column(
      children: [
        // 顶部
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: AppTheme.border)),
          ),
          child: Row(
            children: [
              SizedBox(
                height: 34,
                child: ElevatedButton.icon(
                  onPressed: _running ? null : _run,
                  icon: Icon(
                      _running ? Icons.hourglass_top : Icons.play_arrow,
                      size: 16),
                  label: Text(_running ? '诊断中…' : '开始诊断',
                      style: const TextStyle(fontSize: 12)),
                ),
              ),
              const SizedBox(width: 14),
              if (device != null)
                Text(
                  '设备: ${device.displayName}',
                  style: const TextStyle(
                      fontSize: 11.5, color: AppTheme.textSecondary),
                )
              else
                const Text(
                  '未选中设备（仅检查工具环境）',
                  style: TextStyle(
                      fontSize: 11.5, color: AppTheme.warning),
                ),
              const Spacer(),
              if (allItems.isNotEmpty) ...[
                if (errors > 0)
                  _summaryChip('$errors 个错误', AppTheme.danger),
                if (warns > 0) ...[
                  const SizedBox(width: 6),
                  _summaryChip('$warns 个警告', AppTheme.warning),
                ],
                if (errors == 0 && warns == 0) ...[
                  _summaryChip('全部正常', AppTheme.success),
                ],
              ],
            ],
          ),
        ),

        // 结果
        Expanded(
          child: _groups.isEmpty
              ? EmptyState(
                  icon: _running
                      ? Icons.hourglass_top
                      : Icons.health_and_safety,
                  title: _running ? '诊断中…' : '点击「开始诊断」',
                  subtitle: '检查工具环境、设备连接、系统状态、刷机能力\n'
                      '快速定位常见问题',
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    for (final g in _groups) ...[
                      _GroupCard(
                        group: g,
                        levelColor: _levelColor,
                        levelIcon: _levelIcon,
                      ),
                      const SizedBox(height: 12),
                    ],
                  ],
                ),
        ),

        // 日志条
        if (_log.isNotEmpty)
          Container(
            height: 90,
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: const BoxDecoration(
              color: Color(0xFF0A0C10),
              border: Border(top: BorderSide(color: AppTheme.border)),
            ),
            child: ListView.builder(
              itemCount: _log.length,
              itemBuilder: (context, i) => Text(
                _log[i],
                style: const TextStyle(
                    fontSize: 10.5,
                    fontFamily: 'monospace',
                    color: AppTheme.textMuted,
                    height: 1.4),
              ),
            ),
          ),
      ],
    );
  }

  Widget _summaryChip(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(text,
          style: TextStyle(fontSize: 11, color: color)),
    );
  }
}

class _GroupCard extends StatelessWidget {
  final DiagGroup group;
  final Color Function(DiagLevel) levelColor;
  final IconData Function(DiagLevel) levelIcon;

  const _GroupCard({
    required this.group,
    required this.levelColor,
    required this.levelIcon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.bgSurface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: group.hasIssue
              ? AppTheme.warning.withValues(alpha: 0.3)
              : AppTheme.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 标题
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              border: Border(
                  bottom: BorderSide(color: AppTheme.border)),
            ),
            child: Row(
              children: [
                Icon(
                  group.hasIssue
                      ? Icons.warning_amber_rounded
                      : Icons.check_circle_outline,
                  size: 15,
                  color: group.hasIssue
                      ? AppTheme.warning
                      : AppTheme.success,
                ),
                const SizedBox(width: 8),
                Text(
                  group.title,
                  style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textPrimary),
                ),
                const Spacer(),
                Text(
                  '${group.items.length} 项',
                  style: const TextStyle(
                      fontSize: 10.5, color: AppTheme.textMuted),
                ),
              ],
            ),
          ),
          // 项目
          for (var i = 0; i < group.items.length; i++)
            _DiagRow(
              item: group.items[i],
              color: levelColor(group.items[i].level),
              icon: levelIcon(group.items[i].level),
              isLast: i == group.items.length - 1,
            ),
        ],
      ),
    );
  }
}

class _DiagRow extends StatelessWidget {
  final DiagItem item;
  final Color color;
  final IconData icon;
  final bool isLast;

  const _DiagRow({
    required this.item,
    required this.color,
    required this.icon,
    required this.isLast,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        border: isLast
            ? null
            : Border(
                bottom: BorderSide(
                    color: AppTheme.border.withValues(alpha: 0.5))),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 10),
          SizedBox(
            width: 110,
            child: Text(
              item.name,
              style: const TextStyle(
                  fontSize: 12, color: AppTheme.textSecondary),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.value,
                  style: TextStyle(
                      fontSize: 12,
                      color: color,
                      fontFamily: 'monospace'),
                ),
                if (item.hint != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      item.hint!,
                      style: const TextStyle(
                          fontSize: 10.5,
                          color: AppTheme.textMuted,
                          height: 1.4),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
