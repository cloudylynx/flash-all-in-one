import 'package:flashallinone/services/diagnose_service.dart';

Future<void> main() async {
  print('══ 一键诊断逻辑测试 ══');
  final groups = await DiagnoseService.instance.runAll(
    serial: 'emulator-5554',
    onLine: (s) => print('  $s'),
  );

  print('');
  for (final g in groups) {
    print('【${g.title}】${g.hasIssue ? "有警告" : "正常"}');
    for (final i in g.items) {
      final icon = switch (i.level) {
        DiagLevel.ok => 'OK ',
        DiagLevel.warn => 'WARN',
        DiagLevel.error => 'ERR ',
        DiagLevel.info => 'INFO',
      };
      print('  [$icon] ${i.name}: ${i.value}');
      if (i.hint != null) print('        -> ${i.hint}');
    }
  }
  print('');
  print('诊断完成，共 ${groups.length} 组');
}
