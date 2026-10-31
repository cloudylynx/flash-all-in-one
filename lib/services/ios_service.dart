import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/config.dart';
import '../core/process_runner.dart';
import '../core/tool_extractor.dart';

/// iOS 设备信息
class IosDevice {
  final String udid;
  final String name;
  final String model;
  final String iosVersion;
  final String? ecid;
  final String mode; // normal / recovery / dfu

  IosDevice({
    required this.udid,
    required this.name,
    required this.model,
    required this.iosVersion,
    this.ecid,
    this.mode = 'normal',
  });
}

/// iOS 操作结果
class IosResult {
  final bool ok;
  final String message;
  final List<String> log;
  IosResult(this.ok, this.message, [this.log = const []]);
}

/// iOS 设备服务
///
/// 工具：libimobiledevice 1.4.0 + idevicerestore 1.0.1
///   libimobiledevice（8300★，LGPL-2.1）
///   idevicerestore（2001★，LGPL-3.0）
///
/// 能力：
///   · 设备信息读取（型号 / iOS 版本 / UDID / ECID）
///   · IPSW 固件刷写（update / erase 两种模式）
///   · 进入恢复模式 / DFU 模式
///   · 完整备份 / 恢复（idevicebackup2）
///   · 系统日志实时查看（idevicesyslog）
///   · 截图 / 改名 / 诊断
///
/// ⚠️ 重要：iOS 越狱本身（palera1n / checkra1n）需要特定漏洞利用，
///    本项目不集成越狱工具，只做设备管理和官方固件刷写。
class IosService {
  IosService._();
  static final IosService instance = IosService._();

  String? _dir;
  bool _available = false;

  bool get isAvailable => _available;

  /// 初始化
  Future<bool> init() async {
    if (_available) return true;

    // 只支持 Linux（Windows 需要单独编译）
    if (Platform.isWindows) return false;

    const tools = [
      'idevicerestore',
      'ideviceinfo',
      'idevicebackup2',
      'idevicesyslog',
      'idevicediagnostics',
      'ideviceenterrecovery',
      'idevicescreenshot',
      'idevicename',
      'idevicepair',
    ];

    for (final t in tools) {
      final path = await ToolExtractor.extractFile(
        assetPath: 'assets/tools/linux/ios/$t',
        subDir: 'ios',
        fileName: t,
        executable: true,
      );
      if (path != null && _dir == null) {
        _dir = File(path).parent.path;
      }
    }

    // 依赖库
    const libs = [
      'libirecovery-1.0.so.5',
      'libimobiledevice-1.0.so.6',
      'libusbmuxd-2.0.so.7',
      'libimobiledevice-glue-1.0.so.0',
      'libtatsu.so.0',
      'libplist-2.0.so.4',
    ];
    for (final lib in libs) {
      await ToolExtractor.extractFile(
        assetPath: 'assets/tools/linux/ios/lib/$lib',
        subDir: 'ios/lib',
        fileName: lib,
      );
    }

    _available = _dir != null;
    return _available;
  }

  String? _exe(String name) {
    if (_dir == null) return null;
    final path = p.join(_dir!, name);
    return File(path).existsSync() ? path : null;
  }

  /// 环境变量（库路径）
  Map<String, String>? _env() {
    if (_dir == null) return null;
    return {'LD_LIBRARY_PATH': p.join(_dir!, 'lib')};
  }

  /// idevicerestore 版本
  Future<String?> version() async {
    if (!await init()) return null;
    final exe = _exe('idevicerestore');
    if (exe == null) return null;
    final r = await ProcessRunner.run(
      exe,
      ['--version'],
      timeout: AppConfig.shortTimeout,
      workingDirectory: _dir,
      environment: _env(),
    );
    final m = RegExp(r'idevicerestore\s+([\d.]+)').firstMatch(r.output);
    return m?.group(1);
  }

  /// 列出已连接的 iOS 设备
  Future<List<IosDevice>> listDevices() async {
    final devices = <IosDevice>[];
    if (!await init()) return devices;

    final exe = _exe('ideviceinfo');
    if (exe == null) return devices;

    // 先看普通模式的设备
    final idExe = _exe('ideviceinfo');
    if (idExe != null) {
      final udids = await ProcessRunner.run(
        idExe,
        ['-l'],
        timeout: const Duration(seconds: 5),
        workingDirectory: _dir,
        environment: _env(),
      );
      // ideviceinfo -l 输出 UDID 列表
      for (final line in udids.stdout.split('\n')) {
        final udid = line.trim();
        if (udid.length >= 24 && !udid.contains(' ')) {
          final info = await _getDeviceInfo(udid);
          if (info != null) devices.add(info);
        }
      }
    }

    // 再查恢复模式设备（irecovery）
    // 注意：irecovery 需要 root 权限访问 USB，这里只做提示
    return devices;
  }

  Future<IosDevice?> _getDeviceInfo(String udid) async {
    final exe = _exe('ideviceinfo');
    if (exe == null) return null;

    final r = await ProcessRunner.run(
      exe,
      ['-u', udid, '-k', 'DeviceName'],
      timeout: const Duration(seconds: 5),
      workingDirectory: _dir,
      environment: _env(),
    );
    if (!r.ok) return null;

    final name = r.stdout.trim();
    final modelR = await ProcessRunner.run(
      exe,
      ['-u', udid, '-k', 'ProductType'],
      timeout: const Duration(seconds: 5),
      workingDirectory: _dir,
      environment: _env(),
    );
    final verR = await ProcessRunner.run(
      exe,
      ['-u', udid, '-k', 'ProductVersion'],
      timeout: const Duration(seconds: 5),
      workingDirectory: _dir,
      environment: _env(),
    );

    return IosDevice(
      udid: udid,
      name: name,
      model: modelR.stdout.trim(),
      iosVersion: verR.stdout.trim(),
    );
  }

  /// 读取设备详细信息
  Future<IosResult> readInfo({
    String? udid,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) return IosResult(false, 'iOS 工具未就绪', log);
    final exe = _exe('ideviceinfo');
    if (exe == null) return IosResult(false, 'ideviceinfo 未找到', log);

    add('══ iOS 设备信息');
    if (udid != null) add('  UDID: $udid');
    add('');

    final args = <String>[];
    if (udid != null) args.addAll(['-u', udid]);

    final code = await ProcessRunner.stream(
      exe,
      args,
      onLine: add,
      timeout: const Duration(seconds: 15),
      workingDirectory: _dir,
      environment: _env(),
    );

    return IosResult(code == 0, code == 0 ? '已读取' : '读取失败（设备未连接或未信任）', log);
  }

  /// 刷写 IPSW 固件
  ///
  /// [erase] true = 全新刷机（清空数据），false = 升级（保留数据）
  Future<IosResult> flashIpsw({
    required String ipswPath,
    String? udid,
    bool erase = false,
    bool confirmed = false,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!confirmed) {
      return IosResult(false, '需要确认（confirmed=false）', log);
    }

    if (!await init()) return IosResult(false, 'iOS 工具未就绪', log);
    final exe = _exe('idevicerestore');
    if (exe == null) return IosResult(false, 'idevicerestore 未找到', log);

    if (!File(ipswPath).existsSync()) {
      return IosResult(false, 'IPSW 文件不存在', log);
    }

    final size = File(ipswPath).lengthSync();
    add('══ iOS 固件刷写');
    add('  文件: ${p.basename(ipswPath)}');
    add('  大小: ${(size / 1024 / 1024 / 1024).toStringAsFixed(2)} GB');
    add('  模式: ${erase ? "全新刷机（清空数据）" : "升级（保留数据）"}');
    if (udid != null) add('  目标: $udid');
    add('');
    add('⚠️ 刷机过程约 10-30 分钟，期间不要断开 USB');
    add('⚠️ 设备会多次重启，属正常现象');

    final args = <String>[];
    if (udid != null) args.addAll(['-u', udid]);
    if (erase) args.add('-e');
    args.add(ipswPath);

    final code = await ProcessRunner.stream(
      exe,
      args,
      onLine: add,
      timeout: const Duration(minutes: 60),
      workingDirectory: _dir,
      environment: _env(),
    );

    if (code == 0) {
      add('');
      add('✅ 刷机完成');
      return IosResult(true, '固件已刷入', log);
    }
    return IosResult(false, '刷机失败（退出码 $code）', log);
  }

  /// 进入恢复模式
  Future<IosResult> enterRecovery({
    String? udid,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) return IosResult(false, 'iOS 工具未就绪', log);
    final exe = _exe('ideviceenterrecovery');
    if (exe == null) {
      return IosResult(false, 'ideviceenterrecovery 未找到', log);
    }

    add('══ 进入恢复模式');
    if (udid != null) add('  目标: $udid');
    add('');
    add('ℹ️ 设备会重启进入恢复模式（屏幕显示 iTunes 图标）');

    final args = <String>[];
    if (udid != null) args.add(udid);

    final code = await ProcessRunner.stream(
      exe,
      args,
      onLine: add,
      timeout: const Duration(seconds: 30),
      workingDirectory: _dir,
      environment: _env(),
    );

    if (code == 0) {
      add('');
      add('✅ 已进入恢复模式');
      return IosResult(true, '已进入恢复模式', log);
    }
    return IosResult(false, '进入失败', log);
  }

  /// 备份设备
  Future<IosResult> backup({
    required String outputDir,
    String? udid,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) return IosResult(false, 'iOS 工具未就绪', log);
    final exe = _exe('idevicebackup2');
    if (exe == null) return IosResult(false, 'idevicebackup2 未找到', log);

    Directory(outputDir).createSync(recursive: true);

    add('══ 备份 iOS 设备');
    add('  输出: $outputDir');
    add('');
    add('ℹ️ 首次备份可能需要较长时间（取决于数据量）');

    final args = <String>[];
    if (udid != null) args.addAll(['-u', udid]);
    args.addAll(['backup', outputDir]);

    final code = await ProcessRunner.stream(
      exe,
      args,
      onLine: add,
      timeout: const Duration(hours: 2),
      workingDirectory: _dir,
      environment: _env(),
    );

    if (code == 0) {
      add('');
      add('✅ 备份完成');
      return IosResult(true, '备份完成', log);
    }
    return IosResult(false, '备份失败', log);
  }

  /// 实时查看系统日志
  Future<IosResult> syslog({
    String? udid,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) return IosResult(false, 'iOS 工具未就绪', log);
    final exe = _exe('idevicesyslog');
    if (exe == null) return IosResult(false, 'idevicesyslog 未找到', log);

    add('══ iOS 系统日志');
    add('  （点「停止」结束）');
    add('');

    final args = <String>[];
    if (udid != null) args.addAll(['-u', udid]);

    final code = await ProcessRunner.stream(
      exe,
      args,
      onLine: add,
      timeout: const Duration(minutes: 30),
      workingDirectory: _dir,
      environment: _env(),
    );

    return IosResult(code == 0, '日志已结束', log);
  }

  /// 诊断（读设备诊断信息）
  Future<IosResult> diagnostics({
    String? udid,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) return IosResult(false, 'iOS 工具未就绪', log);
    final exe = _exe('idevicediagnostics');
    if (exe == null) {
      return IosResult(false, 'idevicediagnostics 未找到', log);
    }

    add('══ iOS 诊断');
    add('');

    final args = <String>[];
    if (udid != null) args.addAll(['-u', udid]);
    args.add('info');

    final code = await ProcessRunner.stream(
      exe,
      args,
      onLine: add,
      timeout: const Duration(seconds: 30),
      workingDirectory: _dir,
      environment: _env(),
    );

    return IosResult(code == 0, code == 0 ? '已读取' : '读取失败', log);
  }

  /// 截图
  Future<IosResult> screenshot({
    required String outputPath,
    String? udid,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) return IosResult(false, 'iOS 工具未就绪', log);
    final exe = _exe('idevicescreenshot');
    if (exe == null) return IosResult(false, 'idevicescreenshot 未找到', log);

    add('══ 截图');
    add('  输出: ${p.basename(outputPath)}');

    final args = <String>[];
    if (udid != null) args.addAll(['-u', udid]);
    args.add(outputPath);

    final code = await ProcessRunner.stream(
      exe,
      args,
      onLine: add,
      timeout: const Duration(seconds: 30),
      workingDirectory: _dir,
      environment: _env(),
    );

    if (code == 0 && File(outputPath).existsSync()) {
      final size = File(outputPath).lengthSync();
      add('');
      add('✅ 已保存 ${(size / 1024).toStringAsFixed(1)} KB');
      return IosResult(true, '截图已保存', log);
    }
    return IosResult(false, '截图失败', log);
  }

  /// 已知的 iOS 越狱工具（只做说明，不集成）
  static const List<Map<String, String>> jailbreakTools = [
    {
      'name': 'palera1n',
      'desc': 'checkm8 漏洞，A11 及以下（iPhone X 及更早）',
      'url': 'https://github.com/palera1n/palera1n',
    },
    {
      'name': 'checkra1n',
      'desc': 'checkm8 漏洞，已停止维护',
      'url': 'https://checkra.in',
    },
    {
      'name': 'Dopamine',
      'desc': 'iOS 15-16.6.1，A12-A16',
      'url': 'https://github.com/opa334/Dopamine',
    },
    {
      'name': 'unc0ver',
      'desc': 'iOS 11-14.8，已停止维护',
      'url': 'https://unc0ver.dev',
    },
  ];
}
