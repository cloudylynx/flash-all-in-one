import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/android_device.dart';
import '../../core/config.dart';
import '../../core/process_runner.dart';
import '../../services/adb_service.dart';
import '../../services/fastboot_service.dart';
import '../../services/device_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

/// 设备总览（默认首页）
///
/// 合并了原「设备」「设备信息」「系统信息」三个页面：
/// · 顶部：设备选择器
/// · 基础信息：型号/品牌/系统/ABI/屏幕
/// · 实时状态：电池/内存/存储
/// · 详细属性：getprop 全量
class OverviewPage extends StatefulWidget {
  const OverviewPage({super.key});

  @override
  State<OverviewPage> createState() => _OverviewPageState();
}

class _OverviewPageState extends State<OverviewPage> {
  Map<String, String> _battery = {};
  Map<String, String> _mem = {};
  List<Map<String, String>> _storage = [];
  Map<String, String> _cpu = {};
  Map<String, String> _props = {};
  Map<String, String> _fastbootVars = {};
  bool _loading = false;
  String? _loadedSerial;
  bool _showAllProps = false;

  Future<void> _load() async {
    final device = context.read<DeviceProvider>().selectedDevice;
    if (device == null) return;

    setState(() => _loading = true);

    // fastboot 模式：用 getvar all 读信息
    if (device.state == 'fastboot' || device.state == 'bootloader') {
      await _loadFastboot(device.serial);
      return;
    }

    final adb = AdbService.instance;

    final results = await Future.wait([
      adb.batteryInfo(device.serial),
      adb.memInfo(device.serial),
      adb.storageInfo(device.serial),
      adb.cpuInfo(device.serial),
      adb.shell(device.serial, ['getprop']),
    ]);

    // 解析 getprop
    final props = <String, String>{};
    final regex = RegExp(r'\[([^\]]+)\]:\s*\[([^\]]*)\]');
    for (final m
        in regex.allMatches((results[4] as dynamic).output as String)) {
      props[m.group(1)!] = m.group(2)!;
    }

    if (!mounted) return;
    setState(() {
      _battery = results[0] as Map<String, String>;
      _mem = results[1] as Map<String, String>;
      _storage = results[2] as List<Map<String, String>>;
      _cpu = results[3] as Map<String, String>;
      _props = props;
      _loading = false;
      _loadedSerial = device.serial;
    });
  }

  String _memMb(String? raw) {
    if (raw == null) return '?';
    final kb = int.tryParse(raw.split(' ').first);
    if (kb == null) return raw;
    if (kb >= 1024 * 1024) {
      return '${(kb / 1024 / 1024).toStringAsFixed(1)} GB';
    }
    return '${(kb / 1024).toStringAsFixed(0)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final dp = context.watch<DeviceProvider>();
    final device = dp.selectedDevice;

    if (!dp.adbReady) {
      return EmptyState(
        icon: Icons.error_outline,
        title: 'adb 未就绪',
        subtitle: dp.error ?? '请检查 adb',
        action: ElevatedButton.icon(
          onPressed: () => dp.restartAdb(),
          icon: const Icon(Icons.refresh, size: 16),
          label: const Text('重试'),
        ),
      );
    }

    if (dp.devices.isEmpty) {
      return EmptyState(
        icon: Icons.usb_off,
        title: '未检测到设备',
        subtitle: '用 USB 连接手机并开启「USB 调试」\n或使用「无线 ADB」通过 Wi-Fi 连接',
        action: OutlinedButton.icon(
          onPressed: () => dp.refresh(),
          icon: const Icon(Icons.refresh, size: 16),
          label: const Text('重新扫描'),
        ),
      );
    }

    // 设备切换时自动加载
    if (device != null &&
        _loadedSerial != device.serial &&
        !_loading) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }

    return Column(
      children: [
        // ═══ 设备选择器 ═══
        _DeviceSelector(
          devices: dp.devices,
          selected: device,
          onSelect: (s) => dp.selectDevice(s),
          onRefresh: () => dp.refresh(),
          loading: _loading,
        ),
        const Divider(height: 1),

        // ═══ 内容 ═══
        Expanded(
          child: device == null
              ? const EmptyState(
                  icon: Icons.touch_app,
                  title: '请选择一台设备',
                  subtitle: '点击上方设备卡片切换',
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // 基础信息
                      _buildBasicCard(device),
                      const SizedBox(height: 14),

                        // fastboot 模式：显示 fastboot 详情，不显示电池/内存
                        if (device.isFastboot) ...[
                          if (_fastbootVars.isNotEmpty) ...[
                            _buildFastbootCard(),
                            const SizedBox(height: 14),
                          ] else
                            const AppCard(
                              title: 'Fastboot 信息',
                              child: Text(
                                '正在读取设备变量…\n如果一直空白，可能是驱动未安装',
                                style: TextStyle(
                                    fontSize: 11.5, color: AppTheme.textMuted),
                              ),
                            ),
                          if (_fastbootVars.isNotEmpty)
                            const SizedBox(height: 0),
                        ] else ...[
                          // 电池 + 内存（并排，强制等高对齐）
                          IntrinsicHeight(
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(child: _buildBatteryCard()),
                                const SizedBox(width: 14),
                                Expanded(child: _buildMemoryCard()),
                              ],
                            ),
                          ),
                        ],
                      const SizedBox(height: 14),


                      // 存储
                      if (_storage.isNotEmpty) _buildStorageCard(),
                      if (_storage.isNotEmpty) const SizedBox(height: 14),

                      // CPU
                      if (_cpu.isNotEmpty) _buildCpuCard(),
                      if (_cpu.isNotEmpty) const SizedBox(height: 14),

                      // 详细属性（可展开）
                      _buildPropsCard(),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildBasicCard(AndroidDevice d) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ═══ Hero 区：设备身份 + 关键状态 ═══
        _buildHeroSection(d),
        const SizedBox(height: 12),

        // ═══ 重启与模式切换（首页顶部，一眼可见）═══
        _buildRebootCard(),
        const SizedBox(height: 14),

        // ═══ 关键指标（横排 4 格）═══
        _buildKeyMetrics(d),
        const SizedBox(height: 14),

        // ═══ 详细信息（两列网格）═══
        _buildDetailGrid(d),
      ],
    );
  }

  /// Hero 区：大图标 + 设备名 + 状态徽章
  Widget _buildHeroSection(AndroidDevice d) {
    final isOnline = d.state == 'device';
    final statusColor = isOnline
        ? AppTheme.success
        : (d.isFastboot ? AppTheme.warning : AppTheme.danger);
    final statusText = isOnline
        ? '在线'
        : (d.isFastboot ? 'Fastboot' : (d.state == 'unauthorized' ? '未授权' : '离线'));

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            AppTheme.primary.withValues(alpha: 0.12),
            AppTheme.accent.withValues(alpha: 0.05),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.primary.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          // 设备图标
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: AppTheme.bgElevated.withValues(alpha: 0.8),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                  color: AppTheme.primary.withValues(alpha: 0.3), width: 1.5),
            ),
            child: Icon(
              d.isEmulator ? Icons.desktop_windows : Icons.smartphone,
              size: 32,
              color: AppTheme.primary,
            ),
          ),
          const SizedBox(width: 18),

          // 设备名 + 副标题
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        d.displayName,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textPrimary,
                          letterSpacing: -0.3,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 10),
                    // 状态徽章
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: statusColor.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                            color: statusColor.withValues(alpha: 0.4)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: statusColor,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 5),
                          Text(
                            statusText,
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600,
                              color: statusColor,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    if (d.brand != null && d.brand!.isNotEmpty) ...[
                      Text(
                        d.brand![0].toUpperCase() + d.brand!.substring(1),
                        style: const TextStyle(
                            fontSize: 12.5, color: AppTheme.textSecondary),
                      ),
                      const SizedBox(width: 8),
                      const Text('·',
                          style: TextStyle(color: AppTheme.textMuted)),
                      const SizedBox(width: 8),
                    ],
                    if (d.androidVersion != null) ...[
                      Text(
                        'Android ${d.androidVersion}',
                        style: const TextStyle(
                            fontSize: 12.5, color: AppTheme.textSecondary),
                      ),
                      const SizedBox(width: 8),
                      const Text('·',
                          style: TextStyle(color: AppTheme.textMuted)),
                      const SizedBox(width: 8),
                    ],
                    Text(
                      d.serial,
                      style: const TextStyle(
                        fontSize: 11.5,
                        fontFamily: 'monospace',
                        color: AppTheme.textMuted,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // 右侧：状态摘要 + 刷新
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.refresh, size: 18),
                color: AppTheme.textSecondary,
                tooltip: '刷新',
                visualDensity: VisualDensity.compact,
                onPressed: _loading ? null : _load,
              ),
              const SizedBox(height: 4),
              // 连接类型标记
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AppTheme.bgElevated.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      d.connectionType == 'tcp'
                          ? Icons.wifi
                          : (d.isEmulator
                              ? Icons.desktop_windows
                              : Icons.usb),
                      size: 11,
                      color: AppTheme.textMuted,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      d.connectionType.toUpperCase(),
                      style: const TextStyle(
                          fontSize: 9.5,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 关键指标（4 格横排）——只显示下面大卡片里没有的信息
  Widget _buildKeyMetrics(AndroidDevice d) {
    return Row(
      children: [
        Expanded(
          child: _metricTile(
            icon: Icons.aspect_ratio,
            label: '分辨率',
            value: d.screenResolution ?? '—',
            color: AppTheme.accent,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _metricTile(
            icon: Icons.security,
            label: 'Root',
            value: d.isRooted == null
                ? '…'
                : (d.isRooted! ? '已 Root' : '未 Root'),
            color: d.isRooted == true ? AppTheme.success : AppTheme.textMuted,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _metricTile(
            icon: d.connectionType == 'tcp' ? Icons.wifi : Icons.usb,
            label: '连接方式',
            value: d.connectionType.toUpperCase(),
            color: AppTheme.primary,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _metricTile(
            icon: Icons.android,
            label: 'Android',
            value: d.androidVersion ?? '—',
            color: AppTheme.success,
          ),
        ),
      ],
    );
  }

  /// 单个指标块
  Widget _metricTile({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppTheme.bgSurface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 13, color: color),
              const SizedBox(width: 5),
              Text(
                label,
                style: const TextStyle(
                    fontSize: 10.5,
                    color: AppTheme.textMuted,
                    letterSpacing: 0.2),
              ),
            ],
          ),
          const SizedBox(height: 7),
          Text(
            value,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              fontFamily: 'monospace',
              color: color,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  /// 详细信息（两列网格）
  Widget _buildDetailGrid(AndroidDevice d) {
    final items = <MapEntry<String, String>>[
      if (d.model != null) MapEntry('型号', d.model!),
      if (d.manufacturer != null) MapEntry('厂商', d.manufacturer!),
      if (d.abi != null) MapEntry('ABI', d.abi!),
      if (d.buildId != null) MapEntry('Build', d.buildId!),
      if (d.sdkVersion != null) MapEntry('SDK', d.sdkVersion!),
      if (d.securityPatch != null) MapEntry('补丁', d.securityPatch!),
      if (d.screenDensity != null) MapEntry('DPI', d.screenDensity!),
      MapEntry('连接', d.connectionType.toUpperCase()),
    ];

    if (items.isEmpty) return const SizedBox.shrink();

    // 两列布局
    final rows = <Widget>[];
    for (var i = 0; i < items.length; i += 2) {
      rows.add(Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          children: [
            Expanded(child: _detailItem(items[i].key, items[i].value)),
            const SizedBox(width: 16),
            Expanded(
              child: i + 1 < items.length
                  ? _detailItem(items[i + 1].key, items[i + 1].value)
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ));
    }

    return AppCard(
      title: '详细信息',
      child: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Column(children: rows),
      ),
    );
  }

  Widget _detailItem(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 10, color: AppTheme.textMuted),
        ),
        const SizedBox(height: 3),
        Text(
          value,
          style: const TextStyle(
            fontSize: 12.5,
            color: AppTheme.textPrimary,
            fontFamily: 'monospace',
          ),
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }

  /// 加载 fastboot 设备信息
  Future<void> _loadFastboot(String serial) async {
    Map<String, String> vars;

    if (Platform.environment['GAOJI_MOCK_FASTBOOT'] == '1') {
      // 测试用假数据
      vars = {
        'product': 'raven',
        'variant': 'SM7',
        'serialno': '1A2B3C4D',
        'secure': 'yes',
        'unlocked': 'yes',
        'hw-revision': 'MP1',
        'battery-voltage': '4321',
        'battery-soc-ok': 'yes',
        'slot-count': '2',
        'current-slot': 'a',
        'slot-successful:_a': 'yes',
        'slot-successful:_b': 'no',
        'max-download-size': '0x10000000',
        'is-userspace': 'no',
        'version-bootloader': 'slider-1.0',
        'version-baseband': 'g5123b',
      };
    } else {
      vars = await FastbootService.instance.getVars(serial);
    }

    if (!mounted) return;
    setState(() {
      _fastbootVars = vars;
      _props = {};
      _battery = {};
      _mem = {};
      _storage = [];
      _cpu = {};
      _loading = false;
      _loadedSerial = serial;
    });
  }


  /// fastboot 设备信息卡
  Widget _buildFastbootCard() {
    // 常用字段优先显示
    const priority = [
      'product', 'variant', 'serialno', 'secure', 'unlocked',
      'hw-revision', 'battery-voltage', 'battery-soc-ok',
      'slot-count', 'current-slot', 'slot-successful:_a',
      'slot-successful:_b', 'slot-unbootable:_a', 'slot-unbootable:_b',
      'max-download-size', 'is-userspace', 'version-bootloader',
      'version-baseband', 'partition-type:boot', 'partition-size:boot',
    ];

    final shown = <String, String>{};
    for (final k in priority) {
      if (_fastbootVars.containsKey(k)) {
        shown[k] = _fastbootVars[k]!;
      }
    }

    return AppCard(
      title: 'Fastboot 信息',
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: AppTheme.warning.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          '${_fastbootVars.length} 项变量',
          style: const TextStyle(fontSize: 9.5, color: AppTheme.warning),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppTheme.warning.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                  color: AppTheme.warning.withValues(alpha: 0.25)),
            ),
            child: const Row(
              children: [
                Icon(Icons.flash_on, size: 14, color: AppTheme.warning),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '设备处于 Fastboot 模式，电池/内存等系统信息不可用',
                    style: TextStyle(
                        fontSize: 11, color: AppTheme.textSecondary),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          if (shown.isEmpty)
            const Text('未读取到变量（可能需要驱动）',
                style: TextStyle(fontSize: 11, color: AppTheme.textMuted))
          else
            for (final e in shown.entries)
              InfoRow(
                label: e.key,
                value: e.value.isEmpty ? '（空）' : e.value,
                monospace: true,
              ),
          if (_fastbootVars.length > shown.length) ...[
            const SizedBox(height: 10),
            ExpansionTile(
              title: Text(
                '全部变量（${_fastbootVars.length} 项）',
                style: const TextStyle(
                    fontSize: 11.5, color: AppTheme.textSecondary),
              ),
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(left: 8),
              children: [
                for (final e in _fastbootVars.entries)
                  if (!shown.containsKey(e.key))
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 180,
                            child: Text(
                              e.key,
                              style: const TextStyle(
                                  fontSize: 10.5,
                                  fontFamily: 'monospace',
                                  color: AppTheme.textMuted),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              e.value.isEmpty ? '（空）' : e.value,
                              style: const TextStyle(
                                  fontSize: 10.5,
                                  fontFamily: 'monospace',
                                  color: AppTheme.textSecondary),
                            ),
                          ),
                        ],
                      ),
                    ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBatteryCard() {
    final level = int.tryParse(_battery['level'] ?? '') ?? 0;
    final temp = int.tryParse(_battery['temperature'] ?? '');
    final tempC = temp != null ? temp / 10 : null;
    final voltage = _battery['voltage'];
    final status = _battery['status'];
    final health = _battery['health'];

    return AppCard(
      title: '电池',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                level > 80
                    ? Icons.battery_full
                    : level > 40
                        ? Icons.battery_5_bar
                        : level > 20
                            ? Icons.battery_3_bar
                            : Icons.battery_alert,
                size: 36,
                color: level > 20 ? AppTheme.success : AppTheme.danger,
              ),
              const SizedBox(width: 12),
              Text(
                '$level%',
                style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w300,
                  color: AppTheme.textPrimary,
                ),
              ),
              const Spacer(),
              if (tempC != null)
                _chip(
                  '${tempC.toStringAsFixed(1)}°C',
                  tempC > 42 ? AppTheme.danger : AppTheme.success,
                ),
            ],
          ),
          const SizedBox(height: 10),
          if (status != null) InfoRow(label: '状态', value: status),
          if (health != null) InfoRow(label: '健康', value: health),
          if (voltage != null) InfoRow(label: '电压', value: '$voltage mV'),
          if (_battery['technology'] != null)
            InfoRow(label: '技术', value: _battery['technology']!),
        ],
      ),
    );
  }

  Widget _buildMemoryCard() {
    final total = int.tryParse((_mem['MemTotal'] ?? '').split(' ').first) ?? 0;
    final avail =
        int.tryParse((_mem['MemAvailable'] ?? '').split(' ').first) ?? 0;
    final used = total - avail;
    final pct = total > 0 ? (used / total * 100) : 0.0;

    return AppCard(
      title: '内存',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.memory, size: 30, color: AppTheme.accent),
              const SizedBox(width: 12),
              Text(
                '${pct.toStringAsFixed(0)}%',
                style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w300,
                  color: AppTheme.textPrimary,
                ),
              ),
              const Spacer(),
              Text(
                _memMb('$used kB'),
                style: const TextStyle(
                    fontSize: 12, color: AppTheme.textSecondary),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: pct / 100,
              minHeight: 6,
              backgroundColor: AppTheme.bgElevated,
              valueColor: AlwaysStoppedAnimation(
                pct > 85 ? AppTheme.danger : AppTheme.primary,
              ),
            ),
          ),
          const SizedBox(height: 10),
          InfoRow(label: '总内存', value: _memMb(_mem['MemTotal'])),
          InfoRow(label: '可用', value: _memMb(_mem['MemAvailable'])),
          InfoRow(label: 'Swap 总', value: _memMb(_mem['SwapTotal'])),
          InfoRow(label: 'Swap 空闲', value: _memMb(_mem['SwapFree'])),
        ],
      ),
    );
  }

  /// 重启与模式切换
  ///
  /// 根据当前设备所处模式（系统/fastboot/recovery），
  /// 显示可切换的目标模式。
  Widget _buildRebootCard() {
    final inSystem = _loadedSerial != null && _props.isNotEmpty;

    return AppCard(
      title: '重启与模式切换',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 当前模式提示
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: AppTheme.bgElevated,
              borderRadius: BorderRadius.circular(5),
            ),
            child: Row(
              children: [
                Icon(
                  inSystem ? Icons.phone_android : Icons.usb,
                  size: 14,
                  color: inSystem ? AppTheme.success : AppTheme.warning,
                ),
                const SizedBox(width: 8),
                Text(
                  inSystem ? '当前：系统（Android）' : '当前：fastboot / 其他模式',
                  style: const TextStyle(
                      fontSize: 11.5, color: AppTheme.textSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          if (inSystem) ...[
            const Text('从系统重启到：',
                style: TextStyle(
                    fontSize: 11, color: AppTheme.textMuted)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _rebootButton('系统（软重启）', Icons.restart_alt,
                    AppTheme.primary, () => _reboot('')),
                _rebootButton('Recovery', Icons.healing,
                    AppTheme.warning, () => _reboot('recovery')),
                _rebootButton('Fastboot', Icons.flash_on,
                    AppTheme.accent, () => _reboot('bootloader')),
                _rebootButton('Fastbootd', Icons.usb,
                    AppTheme.accent, () => _reboot('fastboot')),
                _rebootButton('Download 模式', Icons.download,
                    AppTheme.danger, () => _reboot('download')),
                _rebootButton('9008 (EDL)', Icons.build_circle,
                    AppTheme.danger, () => _rebootEdl()),
                _rebootButton('关机', Icons.power_settings_new,
                    AppTheme.textSecondary, () => _shutdown()),
              ],
            ),
          ] else ...[
            const Text('设备在 fastboot 模式，请用「Fastboot 刷机」页操作：',
                style: TextStyle(fontSize: 11, color: AppTheme.textMuted)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _fbButton('重启到系统', Icons.restart_alt,
                    AppTheme.primary, () => _fastbootReboot('')),
                _fbButton('重启到 Recovery', Icons.healing,
                    AppTheme.warning, () => _fastbootReboot('recovery')),
                _fbButton('重启到 Fastbootd', Icons.usb,
                    AppTheme.accent, () => _fastbootReboot('fastboot')),
                _fbButton('重启到 9008', Icons.build_circle,
                    AppTheme.danger, () => _fastbootOemEdl()),
                _fbButton('关机', Icons.power_settings_new,
                    AppTheme.textSecondary, () => _fastbootReboot('')),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _rebootButton(
      String label, IconData icon, Color color, VoidCallback onTap) {
    return OutlinedButton.icon(
      onPressed: _loading ? null : onTap,
      icon: Icon(icon, size: 14),
      label: Text(label, style: const TextStyle(fontSize: 11.5)),
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        side: BorderSide(color: color.withValues(alpha: 0.4)),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
    );
  }

  Widget _fbButton(
      String label, IconData icon, Color color, VoidCallback onTap) {
    return _rebootButton(label, icon, color, onTap);
  }

  /// adb reboot 指定目标
  Future<void> _reboot(String target) async {
    final device = context.read<DeviceProvider>().selectedDevice;
    if (device == null) return;

    final adb = await AppConfig.adbPath();
    final args = ['-s', device.serial, 'reboot'];
    if (target.isNotEmpty) args.add(target);

    await ProcessRunner.run(adb, args,
        timeout: AppConfig.shortTimeout);

    if (!mounted) return;
    final label = target.isEmpty ? '系统' : target;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已发送重启命令（$label）')),
    );
  }

  /// 重启到 9008（高通 EDL）
  Future<void> _rebootEdl() async {
    final device = context.read<DeviceProvider>().selectedDevice;
    if (device == null) return;

    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bgElevated,
        title: const Text('重启到 9008 (EDL)'),
        content: const Text(
            '将尝试让设备进入高通 EDL 模式。\n\n'
            '⚠️ 需要 root 权限\n'
            '⚠️ 进入后屏幕全黑是正常的\n'
            '⚠️ 退出需长按电源键 10 秒\n\n'
            '继续？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.danger,
              foregroundColor: Colors.white,
            ),
            child: const Text('进入'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    final adb = await AppConfig.adbPath();
    final r = await ProcessRunner.run(
      adb,
      ['-s', device.serial, 'shell', 'su', '-c',
       'echo 1 > /sys/kernel/edl_mode'],
      timeout: AppConfig.normalTimeout,
    );

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(r.ok
          ? '✅ 已发送 EDL 命令，设备应进入 9008'
          : '❌ 失败（需要 root）：${r.output.trim()}'),
    ));
  }

  /// 关机
  Future<void> _shutdown() async {
    final device = context.read<DeviceProvider>().selectedDevice;
    if (device == null) return;

    final adb = await AppConfig.adbPath();
    await ProcessRunner.run(
        adb, ['-s', device.serial, 'shell', 'reboot', '-p'],
        timeout: AppConfig.shortTimeout);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已发送关机命令')),
    );
  }

  /// fastboot reboot 指定目标
  Future<void> _fastbootReboot(String target) async {
    final fb = await AppConfig.fastbootPath();
    final args = ['reboot'];
    if (target.isNotEmpty) args.add(target);

    final r = await ProcessRunner.run(fb, args,
        timeout: AppConfig.normalTimeout);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(r.ok ? '已发送命令' : '失败：${r.output.trim()}'),
    ));
  }

  /// fastboot oem edl（进 9008）
  Future<void> _fastbootOemEdl() async {
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bgElevated,
        title: const Text('重启到 9008 (EDL)'),
        content: const Text(
            '将从 fastboot 进入高通 EDL 模式。\n\n'
            '⚠️ 屏幕全黑是正常的\n'
            '⚠️ 退出需长按电源键 10 秒\n\n'
            '继续？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.danger,
              foregroundColor: Colors.white,
            ),
            child: const Text('进入'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    final fb = await AppConfig.fastbootPath();
    // 依次尝试几种 EDL 命令
    for (final cmd in [
      ['oem', 'edl'],
      ['oem', 'enter-9008'],
      ['reboot-edl'],
    ]) {
      final r = await ProcessRunner.run(fb, cmd,
          timeout: AppConfig.shortTimeout);
      if (r.ok && !r.output.contains('FAILED') &&
          !r.output.contains('unknown')) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('✅ 已发送 ${cmd.join(" ")}')),
        );
        return;
      }
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('❌ 该设备不支持 fastboot 进 EDL')),
    );
  }

  Widget _buildStorageCard() {
    return AppCard(
      title: '存储',
      child: Column(
        children: [
          for (final s in _storage)
            if ((s['mounted'] ?? '').isNotEmpty &&
                !(s['mounted']!).startsWith('/proc') &&
                !(s['mounted']!).startsWith('/sys') &&
                !(s['mounted']!).startsWith('/apex'))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  children: [
                    const Icon(Icons.folder_outlined,
                        size: 14, color: AppTheme.textMuted),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 2,
                      child: Text(
                        s['mounted']!,
                        style: const TextStyle(
                            fontSize: 12,
                            fontFamily: 'monospace',
                            color: AppTheme.textPrimary),
                      ),
                    ),
                    Expanded(
                      flex: 2,
                      child: Text(
                        '${s['used']} / ${s['size']}',
                        style: const TextStyle(
                            fontSize: 11.5, color: AppTheme.textSecondary),
                      ),
                    ),
                    SizedBox(
                      width: 50,
                      child: Text(
                        s['usePercent'] ?? '',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: (int.tryParse(
                                          (s['usePercent'] ?? '')
                                              .replaceAll('%', '')) ??
                                      0) >
                                  90
                              ? AppTheme.danger
                              : AppTheme.textMuted,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }

  Widget _buildCpuCard() {
    final cores = _props['ro.product.cpu.abilist'] ??
        _cpu['Processor'] ??
        '?';
    return AppCard(
      title: 'CPU',
      child: Column(
        children: [
          if (_cpu['Processor'] != null)
            InfoRow(label: '型号', value: _cpu['Processor']!),
          if (_cpu['BogoMIPS'] != null)
            InfoRow(label: 'BogoMIPS', value: _cpu['BogoMIPS']!),
          InfoRow(label: 'ABI 列表', value: cores, monospace: true),
          if (_cpu['Hardware'] != null)
            InfoRow(label: '硬件', value: _cpu['Hardware']!),
        ],
      ),
    );
  }

  Widget _buildPropsCard() {
    final entries = _props.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final shown = _showAllProps ? entries : entries.take(15).toList();

    return AppCard(
      title: '系统属性（getprop）',
      trailing: TextButton(
        onPressed: () => setState(() => _showAllProps = !_showAllProps),
        child: Text(
          _showAllProps ? '收起' : '展开全部（${entries.length}）',
          style: const TextStyle(fontSize: 11.5),
        ),
      ),
      child: Column(
        children: [
          for (final e in shown)
            if (e.value.isNotEmpty)
              InfoRow(label: e.key, value: e.value, monospace: true),
        ],
      ),
    );
  }

  Widget _chip(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(text, style: TextStyle(fontSize: 11, color: color)),
    );
  }
}

/// 顶部设备选择器（横向卡片列表）
class _DeviceSelector extends StatelessWidget {
  final List<AndroidDevice> devices;
  final AndroidDevice? selected;
  final ValueChanged<String> onSelect;
  final VoidCallback onRefresh;
  final bool loading;

  const _DeviceSelector({
    required this.devices,
    required this.selected,
    required this.onSelect,
    required this.onRefresh,
    required this.loading,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 74,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: devices.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (context, i) {
                final d = devices[i];
                final sel = d.serial == selected?.serial;
                return _DeviceChip(
                  device: d,
                  selected: sel,
                  onTap: () => onSelect(d.serial),
                );
              },
            ),
          ),
          const SizedBox(width: 10),
          if (loading)
            const InlineLoader()
          else
            IconButton(
              icon: const Icon(Icons.refresh, size: 18),
              color: AppTheme.textSecondary,
              tooltip: '重新扫描设备',
              onPressed: onRefresh,
            ),
        ],
      ),
    );
  }
}

class _DeviceChip extends StatefulWidget {
  final AndroidDevice device;
  final bool selected;
  final VoidCallback onTap;

  const _DeviceChip({
    required this.device,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_DeviceChip> createState() => _DeviceChipState();
}

class _DeviceChipState extends State<_DeviceChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final d = widget.device;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: widget.selected
                ? AppTheme.primary.withValues(alpha: 0.12)
                : (_hover ? AppTheme.bgHover : AppTheme.bgSurface),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: widget.selected
                  ? AppTheme.primary.withValues(alpha: 0.5)
                  : AppTheme.border,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                d.isEmulator ? Icons.desktop_windows : Icons.smartphone,
                size: 15,
                color: widget.selected
                    ? AppTheme.primary
                    : AppTheme.textSecondary,
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    d.displayName,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight:
                          widget.selected ? FontWeight.w600 : FontWeight.w400,
                      color: widget.selected
                          ? AppTheme.primary
                          : AppTheme.textPrimary,
                    ),
                  ),
                  Text(
                    d.subtitle.isNotEmpty ? d.subtitle : d.serial,
                    style: const TextStyle(
                        fontSize: 10, color: AppTheme.textMuted),
                  ),
                ],
              ),
              if (widget.selected) ...[
                const SizedBox(width: 8),
                const Icon(Icons.check_circle,
                    size: 13, color: AppTheme.primary),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
