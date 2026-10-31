import 'dart:io';

import '../core/config.dart';
import '../core/process_runner.dart';

/// 诊断项严重程度
enum DiagLevel { ok, warn, error, info }

/// 单项诊断结果
class DiagItem {
  final String name;
  final String value;
  final DiagLevel level;
  final String? hint;

  DiagItem({
    required this.name,
    required this.value,
    required this.level,
    this.hint,
  });
}

/// 诊断分组
class DiagGroup {
  final String title;
  final List<DiagItem> items;
  DiagGroup({required this.title, required this.items});

  /// 该组是否有问题
  bool get hasIssue =>
      items.any((i) => i.level == DiagLevel.error || i.level == DiagLevel.warn);
}

/// 一键诊断服务
///
/// 快速检查设备和环境的常见问题：
///   · adb / fastboot 可用性
///   · 设备连接状态
///   · USB 调试授权
///   · Root 状态
///   · 存储空间
///   · 电池健康
///   · 系统完整性（SELinux / dm-verity）
///   · 驱动问题排查
class DiagnoseService {
  DiagnoseService._();
  static final DiagnoseService instance = DiagnoseService._();

  /// 运行完整诊断
  Future<List<DiagGroup>> runAll({
    String? serial,
    void Function(String line)? onLine,
  }) async {
    final groups = <DiagGroup>[];
    void log(String s) => onLine?.call(s);

    // ═══ 1. 环境检查 ═══
    log('══ 检查工具环境');
    final envItems = <DiagItem>[];

    // adb
    final adbPath = await AppConfig.adbPath();
    final adbExists = File(adbPath).existsSync() || adbPath == 'adb';
    if (adbExists) {
      final r = await ProcessRunner.run(adbPath, ['version'],
          timeout: AppConfig.shortTimeout);
      if (r.ok) {
        final m = RegExp(r'Android Debug Bridge version ([\d.]+)')
            .firstMatch(r.stdout);
        envItems.add(DiagItem(
          name: 'adb',
          value: m?.group(1) ?? '可用',
          level: DiagLevel.ok,
        ));
      } else {
        envItems.add(DiagItem(
          name: 'adb',
          value: '无法执行',
          level: DiagLevel.error,
          hint: '检查 ${File(adbPath).parent.path} 下的 DLL 是否完整',
        ));
      }
    } else {
      envItems.add(DiagItem(
        name: 'adb',
        value: '未找到',
        level: DiagLevel.error,
        hint: '工具应自动提取，若失败请手动放到 tools/ 下',
      ));
    }

    // fastboot
    final fbPath = await AppConfig.fastbootPath();
    final fbExists = File(fbPath).existsSync() || fbPath == 'fastboot';
    envItems.add(DiagItem(
      name: 'fastboot',
      value: fbExists ? '可用' : '未找到',
      level: fbExists ? DiagLevel.ok : DiagLevel.warn,
      hint: fbExists ? null : '刷机功能受限，可从 platform-tools 获取',
    ));

    // 平台
    envItems.add(DiagItem(
      name: '平台',
      value: '${Platform.operatingSystem} ${Platform.version.split(" ").first}',
      level: DiagLevel.info,
    ));

    groups.add(DiagGroup(title: '工具环境', items: envItems));

    // ═══ 2. 设备连接 ═══
    if (serial == null) {
      log('══ 无设备，跳过设备检查');
      return groups;
    }

    log('══ 检查设备连接');
    final connItems = <DiagItem>[];

    // 连接状态
    final devList = await ProcessRunner.run(adbPath, ['devices'],
        timeout: AppConfig.shortTimeout);
    final devLine = devList.stdout
        .split('\n')
        .where((l) => l.contains(serial))
        .firstOrNull;

    if (devLine == null) {
      connItems.add(DiagItem(
        name: '连接',
        value: '设备已断开',
        level: DiagLevel.error,
        hint: '重新插拔 USB 线，检查是否被其他程序占用',
      ));
      groups.add(DiagGroup(title: '设备连接', items: connItems));
      return groups;
    }

    final state = devLine.contains('device')
        ? '已连接'
        : devLine.contains('unauthorized')
            ? '未授权'
            : '异常';
    connItems.add(DiagItem(
      name: '连接',
      value: state,
      level: state == '已连接' ? DiagLevel.ok : DiagLevel.error,
      hint: state == '未授权' ? '请在手机上点击「允许 USB 调试」' : null,
    ));

    // USB 调试
    final adbEnabled = await ProcessRunner.run(
        adbPath, ['-s', serial, 'shell', 'settings', 'get', 'global', 'adb_enabled'],
        timeout: AppConfig.shortTimeout);
    connItems.add(DiagItem(
      name: 'USB 调试',
      value: adbEnabled.stdout.trim() == '1' ? '已开启' : '已关闭',
      level: adbEnabled.stdout.trim() == '1'
          ? DiagLevel.ok
          : DiagLevel.warn,
    ));

    groups.add(DiagGroup(title: '设备连接', items: connItems));

    // ═══ 3. 系统状态 ═══
    log('══ 检查系统状态');
    final sysItems = <DiagItem>[];

    // Root
    final rootCheck = await ProcessRunner.run(
        adbPath, ['-s', serial, 'shell', 'su -c "id"'],
        timeout: AppConfig.normalTimeout);
    final hasRoot = rootCheck.stdout.contains('uid=0');
    sysItems.add(DiagItem(
      name: 'Root',
      value: hasRoot ? '已获取' : '未获取',
      level: DiagLevel.info,
      hint: hasRoot ? null : '需要 Root 的功能将不可用',
    ));

    // SELinux
    final se = await ProcessRunner.run(
        adbPath, ['-s', serial, 'shell', 'getenforce'],
        timeout: AppConfig.shortTimeout);
    final seStr = se.stdout.trim();
    sysItems.add(DiagItem(
      name: 'SELinux',
      value: seStr.isEmpty ? '未知' : seStr,
      level: seStr.toLowerCase() == 'enforcing'
          ? DiagLevel.ok
          : DiagLevel.warn,
      hint: seStr.toLowerCase() == 'permissive'
          ? 'Permissive 模式降低安全性，但某些操作需要'
          : null,
    ));

    // 存储空间
    final df = await ProcessRunner.run(
        adbPath, ['-s', serial, 'shell', 'df', '-h', '/data'],
        timeout: AppConfig.shortTimeout);
    final dfMatch = RegExp(r'(\d+)%\s+/data').firstMatch(df.stdout);
    final usedPct = int.tryParse(dfMatch?.group(1) ?? '') ?? 0;
    sysItems.add(DiagItem(
      name: '/data 空间',
      value: usedPct > 0 ? '已用 $usedPct%' : '未知',
      level: usedPct > 90
          ? DiagLevel.error
          : usedPct > 75
              ? DiagLevel.warn
              : DiagLevel.ok,
      hint: usedPct > 90 ? '空间不足，可能导致系统异常' : null,
    ));

    // 电池
    final bat = await ProcessRunner.run(
        adbPath, ['-s', serial, 'shell', 'dumpsys', 'battery'],
        timeout: AppConfig.normalTimeout);
    final levelMatch = RegExp(r'level:\s*(\d+)').firstMatch(bat.stdout);
    final tempMatch = RegExp(r'temperature:\s*(\d+)').firstMatch(bat.stdout);
    final healthMatch = RegExp(r'health:\s*(\d+)').firstMatch(bat.stdout);

    if (levelMatch != null) {
      final level = int.tryParse(levelMatch.group(1)!) ?? 0;
      sysItems.add(DiagItem(
        name: '电池电量',
        value: '$level%',
        level: level < 15 ? DiagLevel.warn : DiagLevel.ok,
        hint: level < 15 ? '电量低，刷机前请充电' : null,
      ));
    }
    if (tempMatch != null) {
      final temp = (int.tryParse(tempMatch.group(1)!) ?? 0) / 10;
      sysItems.add(DiagItem(
        name: '电池温度',
        value: '${temp.toStringAsFixed(1)}°C',
        level: temp > 45
            ? DiagLevel.error
            : temp > 40
                ? DiagLevel.warn
                : DiagLevel.ok,
        hint: temp > 45 ? '温度过高，刷机有风险' : null,
      ));
    }
    if (healthMatch != null) {
      final h = int.tryParse(healthMatch.group(1)!) ?? 1;
      // Android BatteryManager: 2=GOOD, 3=OVERHEAT, 4=DEAD, 5=OVER_VOLTAGE, 7=COLD
      final healthText = {1: '未知', 2: '良好', 3: '过热', 4: '损坏', 5: '过压', 7: '过冷'}[h] ?? '未知';
      sysItems.add(DiagItem(
        name: '电池健康',
        value: healthText,
        level: h == 2 ? DiagLevel.ok : DiagLevel.warn,
      ));
    }

    groups.add(DiagGroup(title: '系统状态', items: sysItems));

    // ═══ 4. 刷机能力 ═══
    log('══ 检查刷机能力');
    final flashItems = <DiagItem>[];

    // BL 锁状态（需在 fastboot 模式才能查，这里提示）
    flashItems.add(DiagItem(
      name: 'BL 锁',
      value: '需 fastboot 模式',
      level: DiagLevel.info,
      hint: '重启到 fastboot 后可在「BL 解锁」页查询',
    ));

    // 分区访问
    final partCheck = await ProcessRunner.run(
        adbPath,
        ['-s', serial, 'shell', 'ls', '/dev/block/by-name/'],
        timeout: AppConfig.normalTimeout);
    final partCount =
        partCheck.stdout.split('\n').where((l) => l.trim().isNotEmpty).length;
    flashItems.add(DiagItem(
      name: '分区表',
      value: partCount > 0 ? '$partCount 个分区可访问' : '无法读取',
      level: partCount > 0 ? DiagLevel.ok : DiagLevel.error,
      hint: partCount == 0 ? '可能被 SELinux 限制，需要 root' : null,
    ));

    // vbmeta
    final vbCheck = await ProcessRunner.run(
        adbPath,
        ['-s', serial, 'shell', 'ls', '/dev/block/by-name/vbmeta'],
        timeout: AppConfig.shortTimeout);
    flashItems.add(DiagItem(
      name: 'vbmeta',
      value: vbCheck.stdout.contains('No such') ? '无独立分区' : '存在',
      level: DiagLevel.info,
    ));

    groups.add(DiagGroup(title: '刷机能力', items: flashItems));

    log('══ 诊断完成');
    return groups;
  }
}
