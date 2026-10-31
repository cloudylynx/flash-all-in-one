import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/config.dart';
import '../core/process_runner.dart';

/// LK 补丁选项
class LkPatchOptions {
  /// 补丁分类
  final Set<String> categories;

  /// 是否重签名绕过证书
  final bool certBypass;

  /// 是否修补安全策略
  final bool patchPolicies;

  /// 只分析不写入
  final bool dryRun;

  const LkPatchOptions({
    this.categories = const {'fastboot', 'dm_verity', 'orange_state', 'red_state'},
    this.certBypass = false,
    this.patchPolicies = false,
    this.dryRun = false,
  });
}

/// LK 补丁服务
///
/// 基于 lkpatcher（R0rt1z2/lkpatcher，406★，GPL-3.0）
///
/// LK（Little Kernel）是 MTK 设备的 bootloader 镜像，
/// 修补它可以：
///   · fastboot      —— 解锁 fastboot 命令限制
///   · dm_verity     —— 关闭 dm-verity 校验
///   · orange_state  —— 消除橙灯警告
///   · red_state     —— 消除红灯警告
///
/// 补丁原理：把特定字节序列替换为 `00207047`（ARM 的 `bx lr`，直接返回）
class LkpatcherService {
  LkpatcherService._();
  static final LkpatcherService instance = LkpatcherService._();

  String? _python;
  String? _lkpatcherDir;
  bool _available = false;

  bool get isAvailable => _available;

  /// 初始化：找 Python 和 lkpatcher
  Future<bool> init() async {
    // 1. 找 Python
    for (final cmd in ['python', 'python3', 'py']) {
      try {
        final r = await ProcessRunner.run(cmd, ['--version'],
            timeout: const Duration(seconds: 5));
        if (r.output.contains('Python 3')) {
          _python = cmd;
          break;
        }
      } catch (_) {}
    }
    if (_python == null) {
      _available = false;
      return false;
    }

    // 2. 找 lkpatcher 目录
    for (final sub in ['tools/lkpatcher', 'tools']) {
      final dir = p.join(AppConfig.exeDir, sub);
      final initFile = File(p.join(dir, 'lkpatcher', '__init__.py'));
      if (initFile.existsSync()) {
        _lkpatcherDir = dir;
        _available = true;
        return true;
      }
    }

    // 3. 检查是否已 pip 安装
    try {
      final r = await ProcessRunner.run(
        _python!,
        ['-c', 'import lkpatcher; print("ok")'],
        timeout: const Duration(seconds: 10),
      );
      if (r.output.contains('ok')) {
        _lkpatcherDir = null;
        _available = true;
        return true;
      }
    } catch (_) {}

    _available = false;
    return false;
  }

  /// 版本
  Future<String?> version() async {
    if (!await init()) return null;
    final args = _lkpatcherDir != null
        ? ['-m', 'lkpatcher', '--version']
        : ['-m', 'lkpatcher', '--version'];
    final r = await ProcessRunner.run(_python!, args,
        timeout: const Duration(seconds: 15),
        workingDirectory: _lkpatcherDir);
    final m = RegExp(r'(\d+\.\d+\.\d+)').firstMatch(r.output);
    return m?.group(1) ?? (r.ok ? '已安装' : null);
  }

  /// 列出镜像里的分区
  Future<List<String>> listPartitions(String imagePath) async {
    if (!await init()) return [];
    final r = await ProcessRunner.run(
      _python!,
      ['-m', 'lkpatcher', imagePath, '--list-partitions'],
      timeout: const Duration(seconds: 60),
      workingDirectory: _lkpatcherDir,
    );
    final parts = <String>[];
    for (final line in r.output.split('\n')) {
      final t = line.trim();
      if (t.isEmpty) continue;
      // 形如 "- lk" 或 "  lk"
      final m = RegExp(r'^[-*\s]*([a-z_][a-z0-9_]*)\s*$').firstMatch(t);
      if (m != null) parts.add(m.group(1)!);
    }
    return parts;
  }

  /// 分析安全策略（只读）
  Future<String> analyzePolicies(String imagePath) async {
    if (!await init()) return 'lkpatcher 未就绪';
    final r = await ProcessRunner.run(
      _python!,
      ['-m', 'lkpatcher', imagePath, '--analyze-policies'],
      timeout: const Duration(seconds: 60),
      workingDirectory: _lkpatcherDir,
    );
    return r.output;
  }

  /// 打补丁
  Future<int> patch({
    required String imagePath,
    required String outputPath,
    LkPatchOptions options = const LkPatchOptions(),
    void Function(String line)? onLine,
  }) async {
    if (!await init()) {
      onLine?.call('❌ lkpatcher 未就绪');
      return -1;
    }

    final args = <String>['-m', 'lkpatcher', imagePath, '-o', outputPath];

    for (final c in options.categories) {
      args.addAll(['--category', c]);
    }
    if (options.certBypass) args.add('--cert-bypass');
    if (options.patchPolicies) args.add('--patch-policies');
    if (options.dryRun) args.add('--dry-run');
    args.add('--backup');

    onLine?.call('══ lkpatcher ${args.join(" ")}');

    return ProcessRunner.stream(
      _python!,
      args,
      onLine: onLine ?? (_) {},
      workingDirectory: _lkpatcherDir,
      timeout: const Duration(minutes: 5),
    );
  }
}
