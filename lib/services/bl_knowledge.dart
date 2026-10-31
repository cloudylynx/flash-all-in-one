import 'dart:convert';

import 'package:flutter/services.dart';

/// 知识库章节
class KnowledgeSection {
  final String title;
  final String content;
  KnowledgeSection({required this.title, required this.content});
}

/// 小米机型解锁状态
class XiaomiDevice {
  final String name;
  final String code;
  final String release;
  final String os;
  /// open / blocked / unsupported / unknown
  final String status;

  XiaomiDevice({
    required this.name,
    required this.code,
    required this.release,
    required this.os,
    required this.status,
  });

  String get statusText {
    switch (status) {
      case 'open':
        return '可解锁';
      case 'blocked':
        return '已封堵';
      case 'unsupported':
        return '禁止解锁';
      default:
        return '未知';
    }
  }
}

/// 解锁技术方法
class UnlockMethodInfo {
  final String id;
  final String platform;
  final String name;
  final String risk;
  final List<String> requirements;
  final List<String> steps;
  final String note;
  final bool integrated;
  final Map<String, dynamic>? detail;

  UnlockMethodInfo({
    required this.id,
    required this.platform,
    required this.name,
    required this.risk,
    required this.requirements,
    required this.steps,
    required this.note,
    required this.integrated,
    this.detail,
  });
}

/// BL 解锁知识库
///
/// 数据来源：
/// · AdaUnlocked/2026-All-Brands-Bootloader-Unlock-Status (583★)
/// · MlgmXyysd/Xiaomi-HyperOS-BootLoader-Bypass (4813★)
/// · 自建技术知识（unlock_tech.json）
class BlKnowledge {
  BlKnowledge._();
  static final BlKnowledge instance = BlKnowledge._();

  List<KnowledgeSection>? _sections;
  List<XiaomiDevice>? _xiaomi;
  List<UnlockMethodInfo>? _methods;
  Map<String, dynamic>? _tech;

  /// 加载全部
  Future<void> load() async {
    if (_sections != null) return;

    // 1. 2026 汇总文档
    final doc = await rootBundle.loadString('assets/data/bl_unlock_2026.json');
    final docMap = json.decode(doc) as Map<String, dynamic>;
    _sections = (docMap['sections'] as List)
        .map((s) => KnowledgeSection(
              title: s['title'] as String,
              content: s['content'] as String,
            ))
        .toList();

    // 2. 小米机型状态
    final mi = await rootBundle.loadString('assets/data/xiaomi_devices.json');
    final miMap = json.decode(mi) as Map<String, dynamic>;
    _xiaomi = (miMap['devices'] as List)
        .map((d) => XiaomiDevice(
              name: d['name'] as String,
              code: d['code'] as String,
              release: d['release'] as String,
              os: d['os'] as String,
              status: d['status'] as String,
            ))
        .toList();

    // 3. 技术方法
    final tech = await rootBundle.loadString('assets/data/unlock_tech.json');
    final techMap = json.decode(tech) as Map<String, dynamic>;
    _tech = techMap;
    _methods = (techMap['methods'] as List)
        .map((m) => UnlockMethodInfo(
              id: m['id'] as String,
              platform: m['platform'] as String,
              name: m['name'] as String,
              risk: m['risk'] as String,
              requirements:
                  (m['requirements'] as List).map((e) => e as String).toList(),
              steps: (m['steps'] as List).map((e) => e as String).toList(),
              note: m['note'] as String,
              integrated: m['integrated'] as bool? ?? false,
              detail: m['detail'] as Map<String, dynamic>?,
            ))
        .toList();
  }

  List<KnowledgeSection> get sections => _sections ?? [];
  List<XiaomiDevice> get xiaomiDevices => _xiaomi ?? [];
  List<UnlockMethodInfo> get methods => _methods ?? [];
  Map<String, dynamic>? get tech => _tech;

  /// 骁龙平台代号
  Map<String, dynamic> get qualcommCodenames {
    final m = _tech?['qualcomm_codenames'] as Map<String, dynamic>? ?? {};
    return Map.fromEntries(
        m.entries.where((e) => !e.key.startsWith('_')));
  }

  /// 按关键字搜机型
  List<XiaomiDevice> searchXiaomi(String query) {
    if (query.trim().isEmpty) return xiaomiDevices;
    final q = query.toLowerCase();
    return xiaomiDevices.where((d) {
      return d.name.toLowerCase().contains(q) ||
          d.code.toLowerCase().contains(q);
    }).toList();
  }

  /// 按关键字搜章节
  List<KnowledgeSection> searchSections(String query) {
    if (query.trim().isEmpty) return sections;
    final q = query.toLowerCase();
    return sections.where((s) {
      return s.title.toLowerCase().contains(q) ||
          s.content.toLowerCase().contains(q);
    }).toList();
  }
}
