import 'package:flashallinone/services/uad_service.dart';

Future<void> main() async {
  print('══ UAD 服务实测 ══');

  final ok = await UadService.instance.init();
  print('  init: $ok');
  print('  version: ${await UadService.instance.version()}');

  print('');
  print('── listPackages(emulator-5554) ──');
  final pkgs = await UadService.instance.listPackages(
    serial: 'emulator-5554',
    onLine: (s) => print('    $s'),
  );
  print('  解析出 ${pkgs.length} 个包');

  for (final p in pkgs.take(5)) {
    print('    [${p.removal.label}] ${p.name} enabled=${p.enabled}');
  }
}
