import 'dart:convert';

import 'package:flutter/services.dart';

/// 品牌解锁可行性
class BrandUnlockInfo {
  /// 品牌 ID（英文，如 xiaomi）
  final String id;

  /// 品牌显示名
  final String name;

  /// 结论标签（从 "Verdict:" 行提取）
  final List<String> verdicts;

  /// 完整 Markdown 内容
  final String markdown;

  /// 是否支持官方解锁
  final bool officialSupport;

  BrandUnlockInfo({
    required this.id,
    required this.name,
    required this.verdicts,
    required this.markdown,
    required this.officialSupport,
  });

  /// 结论摘要（去掉 emoji 和加粗标记）
  String get verdictSummary {
    if (verdicts.isEmpty) return '未知';
    return verdicts
        .map((v) => v
            .replaceAll(RegExp(r'\*\*'), '')
            .replaceAll('Verdict:', '')
            .trim())
        .join(' · ');
  }
}

/// 解锁可行性查询
///
/// 数据来源：zenfyrdev/bootloader-unlock-wall-of-shame（5613★）
/// 许可证：CC BY-NC-SA 4.0
///
/// 覆盖 37 个主流品牌的解锁政策、前置条件、可行性评级。
class UnlockGuide {
  UnlockGuide._();
  static final UnlockGuide instance = UnlockGuide._();

  Map<String, BrandUnlockInfo>? _cache;

  static const _brandNames = {
    'xiaomi': '小米 / Redmi / POCO',
    'huawei': '华为',
    'honor': '荣耀',
    'samsung': '三星',
    'oneplus': '一加',
    'oppo': 'OPPO',
    'realme': 'realme',
    'vivo': 'vivo / iQOO',
    'google': 'Google Pixel',
    'motorola': '摩托罗拉',
    'sony': '索尼',
    'asus': '华硕',
    'nothing': 'Nothing',
    'fairphone': 'Fairphone',
    'nokia': '诺基亚',
    'lenovo': '联想',
    'zte': '中兴',
    'meizu': '魅族',
    'lg': 'LG',
    'htc': 'HTC',
    'alcatel': '阿尔卡特',
    'amazon': '亚马逊',
    'apple': '苹果',
    'blackview': 'Blackview',
    'cat': 'CAT',
    'coolpad': '酷派',
    'cubot': 'Cubot',
    'doogee': 'Doogee',
    'energizer': 'Energizer',
    'hisense': '海信',
    'infinix': 'Infinix',
    'itel': 'itel',
    'tecno': 'TECNO',
    'tcl': 'TCL',
    'umidigi': 'Umidigi',
    'ulefone': 'Ulefone',
    'vsmart': 'Vsmart',
    'wiko': 'Wiko',
    'sharp': '夏普',
    'panasonic': '松下',
    'fujitsu': '富士通',
    'micromax': 'Micromax',
    'lava': 'Lava',
    'blackberry': '黑莓',
    'essential': 'Essential',
    'unisoc': '紫光展锐',
  };

  /// 加载数据
  Future<void> load() async {
    if (_cache != null) return;

    final raw = await rootBundle.loadString('assets/data/unlock_guide.json');
    final map = json.decode(raw) as Map<String, dynamic>;

    final result = <String, BrandUnlockInfo>{};
    for (final entry in map.entries) {
      final id = entry.key;
      final md = entry.value as String;

      // 提取 Verdict 行
      final verdicts = <String>[];
      for (final line in md.split('\n')) {
        if (line.contains('Verdict:')) {
          final m = RegExp(r'Verdict:\s*(.+)$').firstMatch(line);
          if (m != null) verdicts.add(m.group(1)!.trim());
        }
      }

      // 判断是否支持官方解锁（粗判）
      final lower = md.toLowerCase();
      final official = !lower.contains('cannot be unlocked') &&
          !lower.contains('never be officially') &&
          !lower.contains('no official');

      result[id] = BrandUnlockInfo(
        id: id,
        name: _brandNames[id] ?? id,
        verdicts: verdicts,
        markdown: md,
        officialSupport: official,
      );
    }

    _cache = result;
  }

  /// 全部品牌（按名称排序）
  List<BrandUnlockInfo> get all {
    final list = _cache?.values.toList() ?? [];
    list.sort((a, b) => a.name.compareTo(b.name));
    return list;
  }

  /// 搜索品牌
  List<BrandUnlockInfo> search(String query) {
    if (query.trim().isEmpty) return all;
    final q = query.toLowerCase();
    return all.where((b) {
      return b.id.toLowerCase().contains(q) ||
          b.name.toLowerCase().contains(q);
    }).toList();
  }

  /// 按 ID 查
  BrandUnlockInfo? byId(String id) => _cache?[id];

  /// 根据设备信息推断品牌
  ///
  /// 依据 ro.product.brand / ro.product.manufacturer
  String? guessBrand({String? brand, String? manufacturer}) {
    final candidates = [brand, manufacturer]
        .whereType<String>()
        .map((s) => s.toLowerCase())
        .toList();

    for (final c in candidates) {
      if (c.isEmpty) continue;
      // 直接匹配
      if (_brandNames.containsKey(c)) return c;
      // 别名映射
      final aliases = {
        'redmi': 'xiaomi',
        'poco': 'xiaomi',
        'mi': 'xiaomi',
        'honor': 'honor',
        'huawei': 'huawei',
        'samsung': 'samsung',
        'oneplus': 'oneplus',
        'oppo': 'oppo',
        'realme': 'realme',
        'vivo': 'vivo',
        'iqoo': 'vivo',
        'google': 'google',
        'motorola': 'motorola',
        'sony': 'sony',
        'asus': 'asus',
        'nothing': 'nothing',
        'fairphone': 'fairphone',
        'nokia': 'nokia',
        'lenovo': 'lenovo',
        'zte': 'zte',
        'meizu': 'meizu',
        'lg': 'lg',
        'htc': 'htc',
        'sharp': 'sharp',
      };
      for (final e in aliases.entries) {
        if (c.contains(e.key)) return e.value;
      }
    }
    return null;
  }
}
