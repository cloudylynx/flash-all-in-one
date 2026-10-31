import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/config.dart';
import '../core/process_runner.dart';

/// 包的风险等级（UAD 定义）
enum UadRemoval {
  recommended('Recommended', '推荐移除'),
  advanced('Advanced', '高级'),
  expert('Expert', '专家'),
  unsafe('Unsafe', '危险'),
  unlisted('Unlisted', '未列出');

  final String id;
  final String label;
  const UadRemoval(this.id, this.label);
}

/// UAD 包信息
class UadPackage {
  final String name;
  final UadRemoval removal;
  final bool enabled;
  final String? description;

  UadPackage({
    required this.name,
    required this.removal,
    required this.enabled,
    this.description,
  });
}

/// UAD 操作结果
class UadResult {
  final bool ok;
  final String message;
  final List<String> log;
  UadResult(this.ok, this.message, [this.log = const []]);
}

/// 系统精简服务（UAD-ng）
///
/// 技术来源：Universal-Debloater-Alliance/universal-android-debloater-next-generation
/// （9660★，GPL-3.0）
///
/// 优势：
///   · 内置 1500+ 包的风险分级数据库（编译时嵌入二进制）
///   · 每个包都有详细说明（移除会破坏什么）
///   · 支持 --dry-run 预演
///   · 自动状态校验 + 回退
///
/// CLI（v1.2.0，实测）：
///   uad devices                              列出设备
///   uad list --device S                      列出包
///   uad info --device S pkg                  查看包详情
///   uad disable --device S pkg               禁用
///   uad uninstall --device S pkg             卸载
///   uad enable --device S pkg                恢复
class UadService {
  UadService._();
  static final UadService instance = UadService._();

  String? _exePath;
  bool _available = false;

  bool get isAvailable => _available;

  /// 初始化
  Future<bool> init() async {
    if (_available) return true;

    // 1. 应用目录
    for (final sub in ['tools/uad', 'tools']) {
      final dir = p.join(AppConfig.exeDir, sub);
      final exe = p.join(dir, Platform.isWindows ? 'uad.exe' : 'uad');
      if (File(exe).existsSync()) {
        _exePath = exe;
        _available = true;
        return true;
      }
    }

    // 2. 从 assets 提取
    try {
      final dataDir = await getApplicationSupportDirectory();
      final dir = Directory(p.join(dataDir.path, 'tools', 'uad'));
      if (!dir.existsSync()) dir.createSync(recursive: true);

      final isWin = Platform.isWindows;
      final fname = isWin ? 'uad.exe' : 'uad';
      final assetBase = isWin ? 'windows' : 'linux';
      final target = File(p.join(dir.path, fname));

      if (!target.existsSync()) {
        final data =
            await rootBundle.load('assets/tools/$assetBase/uad/$fname');
        await target.writeAsBytes(data.buffer.asUint8List(), flush: true);
      }

      if (!isWin) {
        await Process.run('chmod', ['+x', target.path]);
      }

      if (target.existsSync()) {
        _exePath = target.path;
        _available = true;
        return true;
      }
    } catch (_) {}

    // 3. PATH
    try {
      final r = await ProcessRunner.run('uad', ['--version'],
          timeout: AppConfig.shortTimeout);
      if (r.output.contains('uad')) {
        _exePath = 'uad';
        _available = true;
        return true;
      }
    } catch (_) {}

    _available = false;
    return false;
  }

  Future<String> _bin() async {
    if (_exePath == null) await init();
    return _exePath ?? 'uad';
  }

  /// 构造带 adb 目录的 PATH（uad 内部会调 adb）
  Future<Map<String, String>?> _env() async {
    try {
      final adb = await AppConfig.adbPath();
      final adbDir = File(adb).parent.path;
      final env = Map<String, String>.from(Platform.environment);
      final sep = Platform.isWindows ? ';' : ':';
      env['PATH'] = '$adbDir$sep${env['PATH'] ?? ''}';
      return env;
    } catch (_) {
      return null;
    }
  }

  /// 版本
  Future<String?> version() async {
    if (!await init()) return null;
    final r = await ProcessRunner.run(await _bin(), ['--version'],
        timeout: AppConfig.shortTimeout, environment: await _env());
    final m = RegExp(r'uad\s+([\d.]+)').firstMatch(r.output);
    return m?.group(1);
  }

  /// 列出包
  Future<List<UadPackage>> listPackages({
    required String serial,
    UadRemoval? filterRemoval,
    String? query,
    void Function(String line)? onLine,
  }) async {
    if (!await init()) return [];

    final args = ['list', '--device', serial];
    if (filterRemoval != null) {
      args.addAll(['--removal', filterRemoval.id.toLowerCase()]);
    }

    final r = await ProcessRunner.run(
      await _bin(),
      args,
      timeout: AppConfig.longTimeout,
      environment: await _env(),
    );

    if (!r.ok) return [];

    final packages = <UadPackage>[];
    // 两种输出格式：
    //   [Unsafe - Enabled] pkg - desc   （不带 --removal）
    //   [Enabled] pkg - desc            （带 --removal，风险等级已过滤掉）
    final regexFull = RegExp(
        r'\[(\w+)\s*-\s*(\w+)\]\s+([\w.]+)\s*(?:-\s*(.*))?');
    final regexShort = RegExp(
        r'\[(\w+)\]\s+([\w.]+)\s*(?:-\s*(.*))?');

    for (final line in r.output.split('\n')) {
      final t = line.trim();

      String? removalStr;
      String? state;
      String? name;
      String? desc;

      final mFull = regexFull.firstMatch(t);
      if (mFull != null) {
        removalStr = mFull.group(1);
        state = mFull.group(2);
        name = mFull.group(3);
        desc = mFull.group(4);
      } else {
        final mShort = regexShort.firstMatch(t);
        if (mShort != null) {
          state = mShort.group(1);
          name = mShort.group(2);
          desc = mShort.group(3);
          // 短格式没有风险等级，用过滤条件反推
          removalStr = filterRemoval?.id;
        }
      }

      if (name == null || state == null) continue;

      final removal = UadRemoval.values.firstWhere(
        (e) => e.id.toLowerCase() == (removalStr ?? '').toLowerCase(),
        orElse: () => UadRemoval.unlisted,
      );

      // 过滤搜索词
      if (query != null && query.isNotEmpty) {
        final q = query.toLowerCase();
        if (!name.toLowerCase().contains(q) &&
            !(desc?.toLowerCase().contains(q) ?? false)) {
          continue;
        }
      }

      packages.add(UadPackage(
        name: name,
        removal: removal,
        enabled: state.toLowerCase() == 'enabled',
        description: desc,
      ));
    }

    return packages;
  }

  /// 查看包详情
  Future<String> packageInfo(String serial, String packageName) async {
    if (!await init()) return '';
    final r = await ProcessRunner.run(
      await _bin(),
      ['info', '--device', serial, packageName],
      timeout: AppConfig.normalTimeout,
      environment: await _env(),
    );
    return r.output;
  }

  /// 禁用包
  Future<UadResult> disable({
    required String serial,
    required List<String> packages,
    bool dryRun = false,
    void Function(String line)? onLine,
  }) async {
    return _runAction(
      action: 'disable',
      serial: serial,
      packages: packages,
      dryRun: dryRun,
      onLine: onLine,
    );
  }

  /// 卸载包
  Future<UadResult> uninstall({
    required String serial,
    required List<String> packages,
    bool dryRun = false,
    void Function(String line)? onLine,
  }) async {
    return _runAction(
      action: 'uninstall',
      serial: serial,
      packages: packages,
      dryRun: dryRun,
      onLine: onLine,
    );
  }

  /// 恢复包
  Future<UadResult> enable({
    required String serial,
    required List<String> packages,
    bool dryRun = false,
    void Function(String line)? onLine,
  }) async {
    return _runAction(
      action: 'enable',
      serial: serial,
      packages: packages,
      dryRun: dryRun,
      onLine: onLine,
    );
  }

  Future<UadResult> _runAction({
    required String action,
    required String serial,
    required List<String> packages,
    required bool dryRun,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) {
      return UadResult(false, 'uad 未找到', log);
    }
    if (packages.isEmpty) {
      return UadResult(false, '没有选中任何包', log);
    }

    final actionLabel = {
      'disable': '禁用',
      'uninstall': '卸载',
      'enable': '恢复',
    }[action] ?? action;

    add('══ UAD $actionLabel${dryRun ? "（预演）" : ""}');
    add('  设备: $serial');
    add('  包数: ${packages.length}');
    for (final pkg in packages.take(20)) {
      add('    · $pkg');
    }
    if (packages.length > 20) {
      add('    …还有 ${packages.length - 20} 个');
    }
    add('');

    final args = [action, '--device', serial];
    if (dryRun) args.add('--dry-run');
    args.addAll(packages);

    final code = await ProcessRunner.stream(
      await _bin(),
      args,
      onLine: add,
      timeout: const Duration(minutes: 10),
      environment: await _env(),
    );

    if (code == 0) {
      add('');
      add('✅ $actionLabel完成');
      return UadResult(true, '$actionLabel完成（${packages.length} 个包）', log);
    }
    return UadResult(false, '$actionLabel失败（退出码 $code）', log);
  }

  /// 更新包名数据库（从远程拉最新）
  Future<UadResult> updateLists({
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) {
      return UadResult(false, 'uad 未找到', log);
    }

    add('══ 更新 UAD 包名数据库');

    final code = await ProcessRunner.stream(
      await _bin(),
      ['update'],
      onLine: add,
      timeout: AppConfig.longTimeout,
      environment: await _env(),
    );

    if (code == 0) {
      add('✅ 更新完成');
      return UadResult(true, '数据库已更新', log);
    }
    return UadResult(false, '更新失败', log);
  }
}
