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
/// 越狱基于 checkm8 漏洞（A5~A11 / iPhone 5s ~ iPhone X），
/// 相关工具全部开源：palera1n(MIT) / gaster(MIT) /
/// libirecovery(LGPL-2.1) / PongoOS(MIT)。
/// A12 及以上机型不受 checkm8 影响，无法越狱。
class IosService {
  IosService._();
  static final IosService instance = IosService._();

  String? _dir;
  bool _available = false;

  bool get isAvailable => _available;

  /// 初始化
  Future<bool> init() async {
    if (_available) return true;

      // Windows：gaster + openra1n（原生 checkm8）+ libimobiledevice 工具链
      if (Platform.isWindows) {
        // ① 越狱工具
        for (final t in ['gaster.exe', 'openra1n.exe']) {
          final path = await ToolExtractor.extractFile(
            assetPath: 'assets/tools/windows/ios/$t',
            subDir: 'ios',
            fileName: t,
            executable: true,
          );
          if (path != null && _dir == null) {
            _dir = File(path).parent.path;
          }
        }

        // ② libimobiledevice 工具链（设备管理 / 备份 / 刷 IPSW）
        const winTools = [
          'idevicerestore.exe',
          'ideviceinfo.exe',
          'idevicebackup2.exe',
          'idevicediagnostics.exe',
          'ideviceenterrecovery.exe',
          'idevicename.exe',
          'idevicescreenshot.exe',
          'idevicesyslog.exe',
          'idevicepair.exe',
          'ideviceinstaller.exe',
        ];
        for (final t in winTools) {
          final path = await ToolExtractor.extractFile(
            assetPath: 'assets/tools/windows/ios/$t',
            subDir: 'ios',
            fileName: t,
            executable: true,
          );
          if (path != null && _dir == null) {
            _dir = File(path).parent.path;
          }
        }

        // ③ 依赖 DLL
        const dlls = [
          'libusb-1.0.dll',
          'libusbK.dll',
          // libimobiledevice 运行时依赖（旧版命名）
          'imobiledevice.dll',
          'plist.dll',
          'usbmuxd.dll',
          'getopt.dll',
          'libcrypto-1_1-x64.dll',
          'libssl-1_1-x64.dll',
          'libcharset.dll',
          'libiconv.dll',
        ];
        for (final dll in dlls) {
          await ToolExtractor.extractFile(
            assetPath: 'assets/tools/windows/ios/$dll',
            subDir: 'ios',
            fileName: dll,
          );
        }
        _available = _dir != null;
        return _available;
      }

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

    // palera1n（越狱）
    await ToolExtractor.extractFile(
      assetPath: 'assets/tools/linux/ios/palera1n',
      subDir: 'ios',
      fileName: 'palera1n',
      executable: true,
    );

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
    // Windows 上工具带 .exe 后缀，Linux 上不带
    final candidates = Platform.isWindows
        ? ['$name.exe', name]
        : [name, '$name.exe'];
    for (final c in candidates) {
      final path = p.join(_dir!, c);
      if (File(path).existsSync()) return path;
    }
    return null;
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

  // ═══════════════════════════════════════════════
  // 越狱（palera1n）
  // ═══════════════════════════════════════════════

  /// palera1n 版本
  Future<String?> palera1nVersion() async {
    if (!await init()) return null;
    final exe = _exe('palera1n');
    if (exe == null) return null;
    final r = await ProcessRunner.run(
      exe,
      ['--version'],
      timeout: AppConfig.shortTimeout,
      workingDirectory: _dir,
    );
    final m = RegExp(r'v([\d.]+)').firstMatch(r.output);
    return m?.group(1);
  }

  /// 检查 usbmuxd 是否运行（palera1n 需要）
  Future<bool> isUsbmuxdRunning() async {
    if (Platform.isWindows) return false;
    try {
      final r = await ProcessRunner.run(
        'systemctl',
        ['is-active', 'usbmuxd'],
        timeout: const Duration(seconds: 5),
      );
      if (r.stdout.trim() == 'active') return true;
      // 备用：检查 socket
      return File('/var/run/usbmuxd').existsSync();
    } catch (_) {
      return false;
    }
  }

  /// 启动 usbmuxd
  Future<bool> startUsbmuxd() async {
    // Windows：用自带的 usbmuxd.exe 后台启动
    if (Platform.isWindows) {
      final exe = _exe('usbmuxd');
      if (exe == null) return false;
      // 已经在跑就不重复启动
      final check = await ProcessRunner.run(
        'tasklist',
        ['/FI', 'IMAGENAME eq usbmuxd.exe'],
        timeout: const Duration(seconds: 5),
      );
      if (check.output.toLowerCase().contains('usbmuxd.exe')) return true;
      try {
        await Process.start(
          exe,
          [],
          mode: ProcessStartMode.detached,
        );
        await Future.delayed(const Duration(milliseconds: 800));
        return true;
      } catch (_) {
        return false;
      }
    }

    try {
      // 先试 systemctl
      var r = await ProcessRunner.run(
        'systemctl',
        ['start', 'usbmuxd'],
        timeout: const Duration(seconds: 10),
      );
      if (r.ok) return true;

      // 备用：直接跑（需要权限）
      r = await ProcessRunner.run(
        'usbmuxd',
        ['-v'],
        timeout: const Duration(seconds: 3),
      );
      return File('/var/run/usbmuxd').existsSync();
    } catch (_) {
      return false;
    }
  }

  /// 读取设备信息（palera1n 的 -I）
  ///
  /// 这个在恢复模式/DFU 模式下也能用
  Future<IosResult> deviceInfoJailbreak({
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) return IosResult(false, 'palera1n 未就绪', log);
    final exe = _exe('palera1n');
    if (exe == null) return IosResult(false, 'palera1n 未找到', log);

    add('══ 设备信息（含 DFU/恢复模式）');
    add('');

    final code = await ProcessRunner.stream(
      exe,
      ['-I'],
      onLine: add,
      timeout: const Duration(seconds: 20),
      workingDirectory: _dir,
    );

    return IosResult(code == 0, code == 0 ? '已读取' : '未检测到设备', log);
  }

  /// 进入 DFU 模式
  Future<IosResult> enterDfu({
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) return IosResult(false, 'palera1n 未就绪', log);
    final exe = _exe('palera1n');
    if (exe == null) return IosResult(false, 'palera1n 未找到', log);

    add('══ 进入 DFU 模式');
    add('');
    add('ℹ️ 会引导设备进入 DFU，然后退出');
    add('  请按屏幕提示操作');

    final code = await ProcessRunner.stream(
      exe,
      ['-D'],
      onLine: add,
      timeout: const Duration(minutes: 3),
      workingDirectory: _dir,
    );

    if (code == 0) {
      add('');
      add('✅ 设备已进入 DFU 模式');
      return IosResult(true, '已进入 DFU', log);
    }
    return IosResult(false, '进入失败', log);
  }

  /// 执行越狱（rootless 模式）
  ///
  /// rootless 是 palera1n 的默认模式，兼容性最好
  Future<IosResult> jailbreak({
    bool rootless = true,
    bool safeMode = false,
    bool verbose = false,
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

    if (!await init()) return IosResult(false, 'palera1n 未就绪', log);
    final exe = _exe('palera1n');
    if (exe == null) return IosResult(false, 'palera1n 未找到', log);

    // 检查 usbmuxd
    final muxdOk = await isUsbmuxdRunning();
    if (!muxdOk) {
      add('⚠️ usbmuxd 未运行，尝试启动…');
      final started = await startUsbmuxd();
      if (!started) {
        add('❌ usbmuxd 启动失败');
        add('');
        add('请手动运行：');
        add('  sudo systemctl start usbmuxd');
        add('  或 sudo usbmuxd');
        return IosResult(false, 'usbmuxd 未运行', log);
      }
      add('✅ usbmuxd 已启动');
    }

    add('══ 越狱（palera1n）');
    add('  模式: ${rootless ? "rootless（默认，兼容性好）" : "rootful（需要 fakefs）"}');
    if (safeMode) add('  安全模式: 开');
    add('');
    add('⚠️ 支持的设备：A8-A11（iPhone 6s ~ iPhone X）');
    add('⚠️ 支持的系统：iOS/iPadOS/tvOS 15.0+');
    add('⚠️ 越狱过程设备会多次重启，不要断开 USB');
    add('⚠️ 越狱后部分银行 App 可能无法使用');
    add('');

    final args = <String>[];
    if (rootless) args.add('-l');
    if (safeMode) args.add('-s');
    if (verbose) args.add('-v');

    final code = await ProcessRunner.stream(
      exe,
      args,
      onLine: add,
      timeout: const Duration(minutes: 15),
      workingDirectory: _dir,
    );

    if (code == 0) {
      add('');
      add('✅ 越狱完成');
      add('');
      add('📌 设备上会出现 palera1n loader 应用');
      add('  打开它安装 Sileo / Zebra 包管理器');
      return IosResult(true, '越狱完成', log);
    }
    return IosResult(false, '越狱失败（退出码 $code）', log);
  }

  /// 移除越狱
  Future<IosResult> removeJailbreak({
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

    if (!await init()) return IosResult(false, 'palera1n 未就绪', log);
    final exe = _exe('palera1n');
    if (exe == null) return IosResult(false, 'palera1n 未找到', log);

    add('══ 移除越狱');
    add('');
    add('ℹ️ 会清除 fakefs 和越狱环境，恢复原状');

    final code = await ProcessRunner.stream(
      exe,
      ['--force-revert'],
      onLine: add,
      timeout: const Duration(minutes: 10),
      workingDirectory: _dir,
    );

    if (code == 0) {
      add('');
      add('✅ 越狱已移除');
      return IosResult(true, '越狱已移除', log);
    }
    return IosResult(false, '移除失败', log);
  }

  /// 退出恢复模式
  Future<IosResult> exitRecovery({
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) return IosResult(false, 'palera1n 未就绪', log);
    final exe = _exe('palera1n');
    if (exe == null) return IosResult(false, 'palera1n 未找到', log);

    add('══ 退出恢复模式');

    final code = await ProcessRunner.stream(
      exe,
      ['-n'],
      onLine: add,
      timeout: const Duration(seconds: 30),
      workingDirectory: _dir,
    );

    if (code == 0) {
      add('');
      add('✅ 已退出恢复模式');
      return IosResult(true, '已退出', log);
    }
    return IosResult(false, '退出失败', log);
  }

  /// 设备支持情况
  static const List<Map<String, String>> supportedDevices = [
    {'chip': 'A11', 'models': 'iPhone 8 / 8 Plus / X', 'support': '✅ 完全支持'},
    {'chip': 'A10', 'models': 'iPhone 7 / 7 Plus', 'support': '✅ 完全支持'},
    {'chip': 'A9', 'models': 'iPhone 6s / 6s Plus / SE 1', 'support': '✅ 完全支持'},
    {'chip': 'A8', 'models': 'iPhone 6 / 6 Plus', 'support': '✅ 完全支持'},
    {'chip': 'A12+', 'models': 'iPhone XS 及以后', 'support': '❌ 不支持（checkm8 漏洞已修复）'},
  ];


  // ═══════════════════════════════════════════════
  // Dopamine（iOS 15-26，A12-A16）
  // ═══════════════════════════════════════════════

  /// Dopamine 支持的版本范围
  static const String dopamineRange = 'iOS 15.0 - 26.0.1';

  /// Dopamine 支持的芯片
  static const List<String> dopamineChips = [
    'A12', 'A13', 'A14', 'A15', 'A16',
  ];

  /// 安装 Dopamine 到设备
  ///
  /// Dopamine 是 semi-untethered 越狱，需要先安装到设备上运行。
  /// 安装方式：用 ideviceinstaller 或者 Sideloadly/AltStore 侧载。
  Future<IosResult> installDopamine({
    required String udid,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (Platform.isWindows) {
      return IosResult(false, 'Dopamine 安装需要 ideviceinstaller（仅 Linux）', log);
    }

    if (!await init()) return IosResult(false, 'iOS 工具未就绪', log);

    add('══ 安装 Dopamine');
    add('  UDID: $udid');
    add('');
    add('ℹ️ Dopamine 是 semi-untethered 越狱：');
    add('  · 需要先安装到设备上');
    add('  · 然后在设备上打开 App 执行越狱');
    add('  · 重启后需要重新运行 App');
    add('');
    add('⚠️ 侧载需要签名（免费 Apple ID 7 天有效）');
    add('');

    // 提取 IPA
    final ipaPath = await ToolExtractor.extractFile(
      assetPath: 'assets/ipa/Dopamine.ipa',
      subDir: 'ipa',
      fileName: 'Dopamine.ipa',
    );

    if (ipaPath == null) {
      add('❌ IPA 提取失败');
      return IosResult(false, 'IPA 提取失败', log);
    }

    add('  IPA: ${p.basename(ipaPath)}');
    add('  大小: ${(File(ipaPath).lengthSync() / 1024 / 1024).toStringAsFixed(1)} MB');
    add('');

    // 尝试用 ideviceinstaller（如果存在）
    final installer = File('/usr/bin/ideviceinstaller');
    if (!installer.existsSync()) {
      add('⚠️ ideviceinstaller 未安装');
      add('');
      add('请手动安装：');
      add('  sudo apt install ideviceinstaller');
      add('');
      add('或使用侧载工具：');
      add('  · Sideloadly（Windows/macOS）');
      add('  · AltStore（需要 AltServer）');
      add('  · TrollStore（iOS 14-17.0，无需签名）');
      return IosResult(false, 'ideviceinstaller 未安装', log);
    }

    add('── 安装中…');
    final code = await ProcessRunner.stream(
      'ideviceinstaller',
      ['-u', udid, '-i', ipaPath],
      onLine: add,
      timeout: const Duration(minutes: 5),
      environment: _env(),
    );

    if (code == 0) {
      add('');
      add('✅ Dopamine 已安装');
      add('');
      add('📌 下一步：');
      add('  1. 在设备上找到「Dopamine」App');
      add('  2. 打开它，点「Jailbreak」');
      add('  3. 等待完成（设备会重启）');
      return IosResult(true, 'Dopamine 已安装', log);
    }
    return IosResult(false, '安装失败', log);
  }

  // ═══════════════════════════════════════════════
  // Windows 越狱（gaster + openra1n）
  // ═══════════════════════════════════════════════

  /// Windows 下把设备置入 pwned DFU 模式（gaster checkm8）
  Future<IosResult> windowsPwnDfu({
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!Platform.isWindows) {
      return IosResult(false, '此功能仅 Windows 可用', log);
    }

    if (!await init()) return IosResult(false, 'iOS 工具未就绪', log);
    final exe = _exe('gaster.exe');
    if (exe == null) return IosResult(false, 'gaster.exe 未找到', log);

    add('══ Windows checkm8 利用（gaster）');
    add('');
    add('ℹ️ 会把设备置入 pwned DFU 模式');
    add('  这是 palera1n 的第一步');
    add('');
    add('⚠️ 需要设备已进入 DFU 模式');
    add('⚠️ 需要先装 libusb 驱动（用 zadig）');
    add('');

    final code = await ProcessRunner.stream(
      exe,
      ['pwn'],
      onLine: add,
      timeout: const Duration(minutes: 2),
      workingDirectory: _dir,
    );

    if (code == 0) {
      add('');
      add('✅ 设备已 pwned（pwned DFU 模式）');
      add('');
      add('📌 下一步：');
      add('  用 WSL 里的 palera1n 继续（-i fake-checkra1n.sh）');
      add('  或运行 openra1n.exe 加载 PongoOS');
      return IosResult(true, '已 pwned', log);
    }
    return IosResult(false, 'pwn 失败', log);
  }

  /// Windows 下加载 PongoOS（openra1n）
  Future<IosResult> windowsLoadPongo({
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!Platform.isWindows) {
      return IosResult(false, '此功能仅 Windows 可用', log);
    }

    if (!await init()) return IosResult(false, 'iOS 工具未就绪', log);
    final exe = _exe('openra1n.exe');
    if (exe == null) return IosResult(false, 'openra1n.exe 未找到', log);

    add('══ 加载 PongoOS（openra1n）');
    add('');
    add('ℹ️ 会向 pwned DFU 设备上传 PongoOS');
    add('  这是越狱的核心步骤');

    final code = await ProcessRunner.stream(
      exe,
      [],
      onLine: add,
      timeout: const Duration(minutes: 3),
      workingDirectory: _dir,
    );

    if (code == 0) {
      add('');
      add('✅ PongoOS 已加载');
      return IosResult(true, 'PongoOS 已加载', log);
    }
    return IosResult(false, '加载失败', log);
  }

  /// Windows 是否可用
  bool get windowsJailbreakAvailable => Platform.isWindows;

}
