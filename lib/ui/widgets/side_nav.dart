import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'common.dart';

/// 侧边栏导航项
class NavItem {
  final String id;
  final String label;
  final IconData icon;
  final String group;
  final bool advanced;

  const NavItem({
    required this.id,
    required this.label,
    required this.icon,
    required this.group,
    this.advanced = false,
  });
}

/// 侧边栏
///
/// 结构（精简后）：
///   设备  —— 总览 / 屏幕 / 投屏 / Shell / 无线
///   应用  —— 管理 / 安装 / 批量
///   文件  —— 文件管理
///   刷机  —— Fastboot / MTK / 厂商专用 / Root
///   工具  —— 日志 / 脚本 / 设置
///   高级  —— EDL / 镜像 / 分区 / BL解锁
class SideNav extends StatefulWidget {
  final String selected;
  final ValueChanged<String> onSelect;
  final String adbVersion;
  final int deviceCount;

  const SideNav({
    super.key,
    required this.selected,
    required this.onSelect,
    required this.adbVersion,
    required this.deviceCount,
  });

  @override
  State<SideNav> createState() => _SideNavState();

  /// 常规功能（安全，直接可用）
  static const List<NavItem> regularItems = [
    // 设备
    NavItem(
        id: 'overview',
        label: '设备总览',
        icon: Icons.phone_iphone,
        group: '设备'),
    NavItem(
        id: 'screen',
        label: '屏幕（截图/投屏）',
        icon: Icons.smartphone,
        group: '设备'),
    NavItem(
        id: 'shell', label: 'Shell 终端', icon: Icons.terminal, group: '设备'),
    NavItem(id: 'wireless', label: '无线 ADB', icon: Icons.wifi, group: '设备'),

    // 应用
    NavItem(id: 'apps', label: '应用管理', icon: Icons.apps, group: '应用'),
    NavItem(
        id: 'install',
        label: '安装 APK',
        icon: Icons.add_box_outlined,
        group: '应用'),
    NavItem(
        id: 'apk',
        label: 'APK 工具（反编译/签名）',
        icon: Icons.build,
        group: '应用'),
    NavItem(
        id: 'debloat',
        label: '系统精简',
        icon: Icons.cleaning_services,
        group: '应用'),
    NavItem(id: 'batch', label: '批量操作', icon: Icons.layers, group: '应用'),

    // 文件
    NavItem(
        id: 'files', label: '文件管理', icon: Icons.folder_outlined, group: '文件'),

    // 刷机（常规）
    NavItem(
        id: 'fastboot',
        label: 'Fastboot 刷机',
        icon: Icons.flash_on,
        group: '刷机'),
    NavItem(id: 'mtk', label: 'MTK 刷机', icon: Icons.memory, group: '刷机'),
    NavItem(
        id: 'vendor',
        label: '厂商专用（三星/OTA）',
        icon: Icons.business,
        group: '刷机'),
    NavItem(
        id: 'root', label: '一键 Root', icon: Icons.security, group: '刷机'),

    // 工具
    NavItem(
        id: 'diagnose',
        label: '一键诊断',
        icon: Icons.health_and_safety,
        group: '工具'),
    NavItem(
        id: 'perfetto',
        label: '性能追踪',
        icon: Icons.speed,
        group: '工具'),
    NavItem(
        id: 'logcat',
        label: '日志查看',
        icon: Icons.article_outlined,
        group: '工具'),
    NavItem(
        id: 'scripts',
        label: '脚本录制',
        icon: Icons.play_circle_outline,
        group: '工具'),
  ];

  /// 高级功能（危险，需协议确认）
  static const List<NavItem> advancedItems = [
    NavItem(
        id: 'bl_unlock',
        label: 'Bootloader 解锁',
        icon: Icons.lock_open,
        group: '高级',
        advanced: true),
    NavItem(
        id: 'edl',
        label: 'EDL 深度刷机（9008）',
        icon: Icons.build_circle,
        group: '高级',
        advanced: true),
    NavItem(
        id: 'imgtool',
        label: '镜像工具（解包/vbmeta）',
        icon: Icons.tune,
        group: '高级',
        advanced: true),
    NavItem(
        id: 'ota',
        label: 'OTA 造包/重签',
        icon: Icons.system_update_alt,
        group: '高级',
        advanced: true),
    NavItem(
        id: 'recovery',
        label: '数据恢复/分区修复',
        icon: Icons.healing,
        group: '高级',
        advanced: true),
    NavItem(
        id: 'sbc',
        label: '单板电脑刷写（RK/全志）',
        icon: Icons.developer_board,
        group: '高级',
        advanced: true),
    NavItem(
        id: 'partitions',
        label: '分区读写',
        icon: Icons.grid_view,
        group: '高级',
        advanced: true),
  ];

  /// 智能穿戴 / 开发板 + 设置（不在危险框内）
  static const List<NavItem> extraItems = [
    NavItem(
        id: 'ios',
        label: 'iOS 设备管理',
        icon: Icons.phone_iphone,
        group: 'iOS'),
    NavItem(
        id: 'jailbreak',
        label: 'iOS 越狱',
        icon: Icons.lock_open,
        group: 'iOS'),
    NavItem(
        id: 'serial',
        label: 'TTL / 串口',
        icon: Icons.cable,
        group: '穿戴'),
    NavItem(
        id: 'wearable',
        label: '智能穿戴/开发板',
        icon: Icons.watch,
        group: '穿戴'),
    NavItem(
        id: 'settings', label: '设置', icon: Icons.settings, group: '穿戴'),
  ];


  /// 全部
  static List<NavItem> get items =>
      [...regularItems, ...advancedItems, ...extraItems];

  /// 按 id 查
  static NavItem? byId(String id) {
    for (final item in items) {
      if (item.id == id) return item;
    }
    return null;
  }

  /// 是否高级功能
  static bool isAdvanced(String id) => byId(id)?.advanced ?? false;
}

class _SideNavState extends State<SideNav> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  bool _matches(NavItem item) {
    if (_query.isEmpty) return true;
    final q = _query.toLowerCase();
    return item.label.toLowerCase().contains(q) ||
        item.id.toLowerCase().contains(q) ||
        item.group.toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final regularGroups = <String, List<NavItem>>{};
    for (final item in SideNav.regularItems.where(_matches)) {
      regularGroups.putIfAbsent(item.group, () => []).add(item);
    }

    return Container(
      width: 196,
      decoration: const BoxDecoration(
        color: AppTheme.bgSurface,
        border: Border(right: BorderSide(color: AppTheme.border)),
      ),
      child: Column(
        children: [
          // Logo
          Container(
            height: 58,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: const Row(
              children: [
                Icon(Icons.developer_board, size: 19, color: AppTheme.primary),
                SizedBox(width: 9),
                Expanded(
                  child: Text(
                    'Flash All In One',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textPrimary,
                      letterSpacing: 0.2,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),

          // 搜索
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 4),
            child: SizedBox(
              height: 30,
              child: TextField(
                controller: _searchController,
                style: const TextStyle(fontSize: 11.5),
                decoration: InputDecoration(
                  hintText: '搜索功能…',
                  hintStyle: const TextStyle(fontSize: 11),
                  prefixIcon: const Icon(Icons.search, size: 14),
                  suffixIcon: _query.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.close, size: 13),
                          visualDensity: VisualDensity.compact,
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _query = '');
                          },
                        )
                      : null,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 6),
                ),
                onChanged: (v) => setState(() => _query = v.trim()),
              ),
            ),
          ),
          const Divider(height: 1),

          // 导航
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 6),
              children: [
                for (final entry in regularGroups.entries) ...[
                  _groupHeader(entry.key),
                  for (final item in entry.value)
                    _NavTile(
                      item: item,
                      selected: widget.selected == item.id,
                      onTap: () => widget.onSelect(item.id),
                    ),
                ],

                // 高级功能区
                const SizedBox(height: 8),
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(
                    color: AppTheme.danger.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                        color: AppTheme.danger.withValues(alpha: 0.2)),
                  ),
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 7),
                        child: Row(
                          children: [
                            const Icon(Icons.warning_amber_rounded,
                                size: 12, color: AppTheme.danger),
                            const SizedBox(width: 5),
                            const Expanded(
                              child: Text(
                                '高级功能',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  color: AppTheme.danger,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ),
                            Icon(Icons.lock_outline,
                                size: 10,
                                color:
                                    AppTheme.danger.withValues(alpha: 0.7)),
                          ],
                        ),
                      ),
                      for (final item in SideNav.advancedItems.where(_matches))
                        _NavTile(
                          item: item,
                          selected: widget.selected == item.id,
                          onTap: () => widget.onSelect(item.id),
                          danger: true,
                        ),
                      const SizedBox(height: 4),
                    ],
                  ),
                ),
                  // ═══ iOS 组（独立）═══
                  if (SideNav.extraItems
                      .where((i) => i.group == 'iOS' && _matches(i))
                      .isNotEmpty) ...[
                    const SizedBox(height: 10),
                    _groupHeader('iOS'),
                    for (final item in SideNav.extraItems
                        .where((i) => i.group == 'iOS' && _matches(i)))
                      _NavTile(
                        item: item,
                        selected: widget.selected == item.id,
                        onTap: () => widget.onSelect(item.id),
                      ),
                  ],

                  // ═══ 调试 / 开发板组 ═══
                  if (SideNav.extraItems
                      .where((i) => i.group == '穿戴' && _matches(i))
                      .isNotEmpty) ...[
                    const SizedBox(height: 10),
                    _groupHeader('调试 / 开发板'),
                    for (final item in SideNav.extraItems
                        .where((i) => i.group == '穿戴' && _matches(i)))
                      _NavTile(
                        item: item,
                        selected: widget.selected == item.id,
                        onTap: () => widget.onSelect(item.id),
                      ),
                  ],
                ],
            ),
          ),

          // 底部状态
          const Divider(height: 1),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    StatusDot(
                      color: widget.adbVersion.isEmpty
                          ? AppTheme.danger
                          : AppTheme.success,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      widget.adbVersion.isEmpty
                          ? 'adb 不可用'
                          : 'adb ${widget.adbVersion}',
                      style: const TextStyle(
                          fontSize: 10, color: AppTheme.textMuted),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  '${widget.deviceCount} 台设备',
                  style: const TextStyle(
                      fontSize: 10, color: AppTheme.textMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _groupHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 16, top: 9, bottom: 3),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 9.5,
          fontWeight: FontWeight.w600,
          color: AppTheme.textMuted,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

class _NavTile extends StatefulWidget {
  final NavItem item;
  final bool selected;
  final VoidCallback onTap;
  final bool danger;

  const _NavTile({
    required this.item,
    required this.selected,
    required this.onTap,
    this.danger = false,
  });

  @override
  State<_NavTile> createState() => _NavTileState();
}

class _NavTileState extends State<_NavTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final sel = widget.selected;
    final baseColor = widget.danger ? AppTheme.danger : AppTheme.primary;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          margin: widget.danger
              ? const EdgeInsets.symmetric(horizontal: 4, vertical: 1)
              : const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: sel
                ? baseColor.withValues(alpha: 0.12)
                : (_hover ? AppTheme.bgHover : Colors.transparent),
            borderRadius: BorderRadius.circular(6),
            border: sel
                ? Border.all(color: baseColor.withValues(alpha: 0.3))
                : null,
          ),
          child: Row(
            children: [
              Icon(
                widget.item.icon,
                size: 14,
                color: sel
                    ? baseColor
                    : (widget.danger
                        ? AppTheme.danger.withValues(alpha: 0.7)
                        : AppTheme.textSecondary),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  widget.item.label,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: sel ? FontWeight.w600 : FontWeight.w400,
                    color: sel ? baseColor : AppTheme.textPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
