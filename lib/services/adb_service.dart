import 'dart:async';
import 'dart:io';

import '../core/config.dart';
import '../core/process_runner.dart';
import '../models/android_device.dart';

/// ADB 服务
///
/// 封装所有 adb 命令，提供类型安全的接口。
class AdbService {
  AdbService._();
  static final AdbService instance = AdbService._();

  String? _adbPathCache;

  /// 获取 adb 路径（首次调用时解析，之后缓存）
  Future<String> _getAdb() async {
    _adbPathCache ??= await AppConfig.adbPath();
    return _adbPathCache!;
  }

  // ═══════════════════════════════════════════════════════
  // 设备管理
  // ═══════════════════════════════════════════════════════

  /// 检查 adb 是否可用
  Future<bool> isAvailable() async {
    final r = await ProcessRunner.run(await _getAdb(), ['version'],
        timeout: AppConfig.shortTimeout);
    return r.ok && r.output.contains('Android Debug Bridge');
  }

  /// 诊断 adb 为什么不可用
  Future<String> diagnose(String path) async {
    final buf = StringBuffer();

    final f = File(path);
    if (!f.existsSync()) {
      buf.writeln('✗ 文件不存在');
      return buf.toString();
    }

    // 直接执行看真实错误
    final r = await ProcessRunner.run(path, ['version'],
        timeout: AppConfig.shortTimeout);
    buf.writeln('退出码: ${r.exitCode}');
    if (r.stderr.isNotEmpty) {
      buf.writeln('stderr: ${r.stderr.trim()}');
    }
    if (r.stdout.isNotEmpty) {
      buf.writeln('stdout: ${r.stdout.trim()}');
    }
    if (r.exitCode == -2) {
      buf.writeln('提示: Windows 上 adb 需要 AdbWinApi.dll 和 AdbWinUsbApi.dll');
      final dir = File(path).parent;
      for (final dll in ['AdbWinApi.dll', 'AdbWinUsbApi.dll']) {
        final dllFile = File('${dir.path}${Platform.pathSeparator}$dll');
        buf.writeln('  $dll: ${dllFile.existsSync() ? "✓" : "✗ 缺失"}');
      }
    }
    return buf.toString();
  }

  /// adb 版本号
  Future<String?> version() async {
    final r = await ProcessRunner.run(await _getAdb(), ['version'],
        timeout: AppConfig.shortTimeout);
    if (!r.ok) return null;
    final m = RegExp(r'Version\s+([\d.]+)').firstMatch(r.output);
    return m?.group(1);
  }

  /// 启动 adb server
  Future<bool> startServer() async {
    final r = await ProcessRunner.run(await _getAdb(), ['start-server'],
        timeout: AppConfig.normalTimeout);
    return r.ok;
  }

  /// 结束 adb server
  Future<bool> killServer() async {
    final r = await ProcessRunner.run(await _getAdb(), ['kill-server'],
        timeout: AppConfig.shortTimeout);
    return r.ok;
  }

  /// 列出所有设备
  ///
  /// 解析 `adb devices -l` 输出：
  /// ```
  /// List of devices attached
  /// emulator-5554          device product:sdk_gphone64_x86_64 model:sdk_gphone64_x86_64 device:emu64xa transport_id:1
  /// ABCD1234               unauthorized usb:1-1 transport_id:2
  /// ```
  Future<List<AndroidDevice>> listDevices() async {
    final r = await ProcessRunner.run(await _getAdb(), ['devices', '-l'],
        timeout: AppConfig.shortTimeout);
    if (!r.ok) return [];

    final devices = <AndroidDevice>[];
    final lines = r.stdout.split('\n');

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (trimmed.startsWith('List of devices')) continue;
      if (trimmed.startsWith('*')) continue; // daemon 提示行

      final parts = trimmed.split(RegExp(r'\s+'));
      if (parts.length < 2) continue;

      final serial = parts[0];
      final state = parts[1];

      // 判断连接方式
      String connType = 'usb';
      if (serial.startsWith('emulator-')) {
        connType = 'emulator';
      } else if (serial.contains(':')) {
        connType = 'tcp';
      }

      devices.add(AndroidDevice(
        serial: serial,
        state: state,
        connectionType: connType,
      ));
    }

    return devices;
  }

  /// 填充设备详细信息（getprop + 屏幕信息）
  Future<AndroidDevice> fillDeviceInfo(AndroidDevice device) async {
    if (!device.isReady) return device;

    // 一次批量取所有属性，减少 adb 调用次数
    final props = await _getProps(device.serial);
    if (props.isNotEmpty) {
      device.model = props['ro.product.model'];
      device.brand = props['ro.product.brand'];
      device.manufacturer = props['ro.product.manufacturer'];
      device.androidVersion = props['ro.build.version.release'];
      device.sdkVersion = props['ro.build.version.sdk'];
      device.abi = props['ro.product.cpu.abi'];
      device.productName = props['ro.product.name'];
      device.buildId = props['ro.build.id'];
      device.securityPatch = props['ro.build.version.security_patch'];
    }

    // 屏幕信息
    final wm = await shell(device.serial, ['wm', 'size']);
    if (wm.ok) {
      final m = RegExp(r'(\d+x\d+)').firstMatch(wm.output);
      device.screenResolution = m?.group(1);
    }
    final wmd = await shell(device.serial, ['wm', 'density']);
    if (wmd.ok) {
      final m = RegExp(r'(\d+)').firstMatch(wmd.output);
      device.screenDensity = m?.group(1);
    }

    return device;
  }

  /// 批量读取系统属性
  Future<Map<String, String>> _getProps(String serial) async {
    final keys = [
      'ro.product.model',
      'ro.product.brand',
      'ro.product.manufacturer',
      'ro.build.version.release',
      'ro.build.version.sdk',
      'ro.product.cpu.abi',
      'ro.product.name',
      'ro.build.id',
      'ro.build.version.security_patch',
    ];

    final r = await ProcessRunner.run(await _getAdb(),
      ['-s', serial, 'shell', 'getprop'],
      timeout: AppConfig.normalTimeout,
    );

    // getprop 多个 key 时输出格式：[key]: [value]
    final all = <String, String>{};
    final regex = RegExp(r'\[([^\]]+)\]:\s*\[([^\]]*)\]');
    for (final m in regex.allMatches(r.output)) {
      all[m.group(1)!] = m.group(2)!;
    }
    final result = <String, String>{};
    for (final k in keys) {
      final v = all[k];
      if (v != null && v.isNotEmpty) result[k] = v;
    }
    return result;
  }

  /// 读取单个属性
  Future<String?> getProp(String serial, String key) async {
    final r = await shell(serial, ['getprop', key]);
    return r.ok ? r.output.trim() : null;
  }

  // ═══════════════════════════════════════════════════════
  // Shell 命令
  // ═══════════════════════════════════════════════════════

  /// 执行 shell 命令
  Future<ExecResult> shell(
    String serial,
    List<String> command, {
    Duration timeout = AppConfig.normalTimeout,
  }) async {
    return ProcessRunner.run(await _getAdb(),
      ['-s', serial, 'shell', ...command],
      timeout: timeout,
    );
  }

  /// 流式执行 shell（长任务）
  Future<int> shellStream(
    String serial,
    List<String> command, {
    required void Function(String line) onLine,
    Duration timeout = AppConfig.longTimeout,
  }) async {
    return ProcessRunner.stream(await _getAdb(),
      ['-s', serial, 'shell', ...command],
      onLine: onLine,
      timeout: timeout,
    );
  }

  // ═══════════════════════════════════════════════════════
  // 设备控制
  // ═══════════════════════════════════════════════════════

  /// 重启
  Future<bool> reboot(String serial, {String? mode}) async {
    // mode: null(正常) / recovery / bootloader / fastboot / edl
    final args = ['-s', serial, 'reboot'];
    if (mode != null && mode.isNotEmpty) args.add(mode);
    final r = await ProcessRunner.run(await _getAdb(), args, timeout: AppConfig.shortTimeout);
    return r.ok;
  }

  /// 关机
  Future<bool> shutdown(String serial) async {
    final r = await shell(serial, ['reboot', '-p']);
    return r.ok;
  }

  /// 连接网络设备
  Future<ExecResult> connect(String address) async {
    return ProcessRunner.run(await _getAdb(), ['connect', address],
        timeout: AppConfig.normalTimeout);
  }

  /// 断开网络设备
  Future<ExecResult> disconnect([String? address]) async {
    final args = ['disconnect'];
    if (address != null) args.add(address);
    return ProcessRunner.run(await _getAdb(), args, timeout: AppConfig.shortTimeout);
  }

  /// 授权设备（需要用户手机上点确认）
  Future<bool> waitForDevice(String serial,
      {Duration timeout = AppConfig.longTimeout}) async {
    final r = await ProcessRunner.run(await _getAdb(),
      ['-s', serial, 'wait-for-device'],
      timeout: timeout,
    );
    return r.ok;
  }

  // ═══════════════════════════════════════════════════════
  // 应用管理
  // ═══════════════════════════════════════════════════════

  /// 列出已安装包名
  ///
  /// [includeSystem] 是否包含系统应用
  Future<List<String>> listPackages(
    String serial, {
    bool includeSystem = true,
    bool onlyEnabled = false,
  }) async {
    final args = ['pm', 'list', 'packages'];
    if (!includeSystem) args.add('-3');
    if (onlyEnabled) args.add('-e');

    final r = await shell(serial, args, timeout: AppConfig.normalTimeout);
    if (!r.ok) return [];

    return r.output
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.startsWith('package:'))
        .map((l) => l.substring(8).trim())
        .where((l) => l.isNotEmpty)
        .toList();
  }

  /// 获取包详情（dumpsys package）
  Future<Map<String, String>> packageInfo(
      String serial, String packageName) async {
    final r = await shell(
      serial,
      ['dumpsys', 'package', packageName],
      timeout: AppConfig.normalTimeout,
    );
    final info = <String, String>{};
    if (!r.ok) return info;

    // versionName=1.2.3
    final vn = RegExp(r'versionName=(\S+)').firstMatch(r.output);
    if (vn != null) info['versionName'] = vn.group(1)!;

    // versionCode=123 minSdk=21 targetSdk=33
    final vc = RegExp(r'versionCode=(\d+)').firstMatch(r.output);
    if (vc != null) info['versionCode'] = vc.group(1)!;

    final ms = RegExp(r'minSdk=(\d+)').firstMatch(r.output);
    if (ms != null) info['minSdk'] = ms.group(1)!;

    final ts = RegExp(r'targetSdk=(\d+)').firstMatch(r.output);
    if (ts != null) info['targetSdk'] = ts.group(1)!;

    final uid = RegExp(r'userId=(\d+)').firstMatch(r.output);
    if (uid != null) info['uid'] = uid.group(1)!;

    // 是否系统应用
    if (r.output.contains('systemPrivApp') || r.output.contains('systemApp')) {
      info['isSystem'] = 'true';
    }

    return info;
  }

  /// 安装 APK
  Future<int> install(
    String serial,
    String apkPath, {
    bool replace = true,
    bool grantAll = false,
    bool downgrade = false,
    void Function(String line)? onLine,
  }) async {
    final args = ['-s', serial, 'install'];
    if (replace) args.add('-r');
    if (grantAll) args.add('-g');
    if (downgrade) args.add('-d');
    args.add(apkPath);

    return ProcessRunner.stream(await _getAdb(),
      args,
      onLine: onLine ?? (_) {},
      timeout: AppConfig.longTimeout,
    );
  }

  /// 卸载应用
  Future<ExecResult> uninstall(
    String serial,
    String packageName, {
    bool keepData = false,
  }) async {
    final args = ['-s', serial, 'uninstall'];
    if (keepData) args.add('-k');
    args.add(packageName);
    return ProcessRunner.run(await _getAdb(), args, timeout: AppConfig.normalTimeout);
  }

  /// 启用应用
  Future<ExecResult> enableApp(String serial, String packageName) async {
    return shell(serial, ['pm', 'enable', packageName]);
  }

  /// 禁用应用
  Future<ExecResult> disableApp(String serial, String packageName,
      {bool asUser0 = true}) async {
    final args = ['pm', 'disable-user', '--user', '0', packageName];
    return shell(serial, args);
  }

  /// 强制停止
  Future<ExecResult> forceStop(String serial, String packageName) async {
    return shell(serial, ['am', 'force-stop', packageName]);
  }

  /// 清除数据
  Future<ExecResult> clearData(String serial, String packageName) async {
    return shell(serial, ['pm', 'clear', packageName]);
  }

  /// 启动应用
  Future<ExecResult> launchApp(String serial, String packageName) async {
    return shell(
        serial, ['monkey', '-p', packageName, '-c', 'android.intent.category.LAUNCHER', '1']);
  }

  /// 获取 APK 路径
  Future<String?> apkPath(String serial, String packageName) async {
    final r = await shell(serial, ['pm', 'path', packageName]);
    if (!r.ok) return null;
    final line = r.output
        .split('\n')
        .map((l) => l.trim())
        .firstWhere((l) => l.startsWith('package:'), orElse: () => '');
    return line.isEmpty ? null : line.substring(8);
  }

  /// 拉取文件
  Future<ExecResult> pull(
    String serial,
    String remotePath,
    String localPath, {
    void Function(String line)? onLine,
  }) async {
    return ProcessRunner.run(await _getAdb(),
      ['-s', serial, 'pull', remotePath, localPath],
      timeout: AppConfig.longTimeout,
    );
  }

  /// 推送文件
  Future<ExecResult> push(
    String serial,
    String localPath,
    String remotePath,
  ) async {
    return ProcessRunner.run(await _getAdb(),
      ['-s', serial, 'push', localPath, remotePath],
      timeout: AppConfig.longTimeout,
    );
  }

  // ═══════════════════════════════════════════════════════
  // 屏幕
  // ═══════════════════════════════════════════════════════

  /// 截图（返回 PNG 字节）
  Future<List<int>?> screenshot(String serial) async {
    try {
      final result = await Process.run(
        await _getAdb(),
        ['-s', serial, 'exec-out', 'screencap', '-p'],
        stdoutEncoding: null,
      ).timeout(AppConfig.normalTimeout);

      if (result.exitCode != 0) return null;
      final bytes = result.stdout as List<int>;
      // 简单校验 PNG 头
      if (bytes.length > 8 &&
          bytes[0] == 0x89 &&
          bytes[1] == 0x50 &&
          bytes[2] == 0x4E &&
          bytes[3] == 0x47) {
        return bytes;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 熄灭/点亮屏幕
  Future<ExecResult> screenPower(String serial, bool on) async {
    return shell(serial, ['input', 'keyevent', on ? '224' : '223']);
  }

  /// 点击
  Future<ExecResult> tap(String serial, int x, int y) async {
    return shell(serial, ['input', 'tap', '$x', '$y']);
  }

  /// 滑动
  Future<ExecResult> swipe(
      String serial, int x1, int y1, int x2, int y2, {int ms = 300}) async {
    return shell(
        serial, ['input', 'swipe', '$x1', '$y1', '$x2', '$y2', '$ms']);
  }

  /// 输入文本
  Future<ExecResult> inputText(String serial, String text) async {
    // 空格要转义
    final escaped = text.replaceAll(' ', '%s');
    return shell(serial, ['input', 'text', escaped]);
  }

  /// 按键
  Future<ExecResult> keyevent(String serial, String keycode) async {
    return shell(serial, ['input', 'keyevent', keycode]);
  }

  // ═══════════════════════════════════════════════════════
  // 系统信息
  // ═══════════════════════════════════════════════════════

  /// 电池信息
  Future<Map<String, String>> batteryInfo(String serial) async {
    final r = await shell(serial, ['dumpsys', 'battery']);
    final info = <String, String>{};
    if (!r.ok) return info;
    for (final line in r.output.split('\n')) {
      final idx = line.indexOf(':');
      if (idx > 0) {
        final k = line.substring(0, idx).trim();
        final v = line.substring(idx + 1).trim();
        if (k.isNotEmpty) info[k] = v;
      }
    }
    return info;
  }

  /// 内存信息
  Future<Map<String, String>> memInfo(String serial) async {
    final r = await shell(serial, ['cat', '/proc/meminfo']);
    final info = <String, String>{};
    if (!r.ok) return info;
    for (final line in r.output.split('\n')) {
      final idx = line.indexOf(':');
      if (idx > 0) {
        final k = line.substring(0, idx).trim();
        final v = line.substring(idx + 1).trim();
        if (k.isNotEmpty) info[k] = v;
      }
    }
    return info;
  }

  /// 存储信息
  Future<List<Map<String, String>>> storageInfo(String serial) async {
    final r = await shell(serial, ['df', '-h']);
    final result = <Map<String, String>>[];
    if (!r.ok) return result;

    final lines = r.output.split('\n');
    if (lines.isEmpty) return result;

    for (var i = 1; i < lines.length; i++) {
      final parts = lines[i].split(RegExp(r'\s+'));
      if (parts.length < 6) continue;
      result.add({
        'filesystem': parts[0],
        'size': parts[1],
        'used': parts[2],
        'avail': parts[3],
        'usePercent': parts[4],
        'mounted': parts[5],
      });
    }
    return result;
  }

  /// CPU 信息
  Future<Map<String, String>> cpuInfo(String serial) async {
    final r = await shell(serial, ['cat', '/proc/cpuinfo']);
    final info = <String, String>{};
    if (!r.ok) return info;
    for (final line in r.output.split('\n')) {
      final idx = line.indexOf(':');
      if (idx > 0) {
        final k = line.substring(0, idx).trim();
        final v = line.substring(idx + 1).trim();
        if (k.isNotEmpty && !info.containsKey(k)) info[k] = v;
      }
    }
    return info;
  }

  /// 是否已 root
  Future<bool> checkRoot(String serial) async {
    final r = await shell(serial, ['which', 'su']);
    return r.ok && r.output.contains('su');
  }

  /// 获取当前前台应用
  Future<String?> currentForegroundApp(String serial) async {
    final r = await shell(
      serial,
      ['dumpsys', 'activity', 'activities'],
      timeout: AppConfig.normalTimeout,
    );
    if (!r.ok) return null;
    final m = RegExp(r'mResumedActivity.*?([a-zA-Z0-9_.]+)/')
        .firstMatch(r.output);
    return m?.group(1);
  }

  /// 获取 logcat
  Future<String> logcat(
    String serial, {
    int lines = 100,
    String? filter,
  }) async {
    final args = ['logcat', '-d', '-t', '$lines'];
    if (filter != null) args.addAll(['-s', filter]);
    final r = await shell(serial, args, timeout: AppConfig.normalTimeout);
    return r.output;
  }

  /// 清空 logcat
  Future<bool> clearLogcat(String serial) async {
    final r = await shell(serial, ['logcat', '-c']);
    return r.ok;
  }
}
