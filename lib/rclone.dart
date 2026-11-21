import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'accounts.dart';
import 'actions.dart';
import 'config.dart';
import 'disks.dart';
import 'side_tree.dart';

bool get rcloneSupported => !kIsWeb && Platform.isWindows;

String _remote(Account a) => 'mgd_${a.email.split('@').first.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_')}';
String _safe(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_');

/// Arma el rclone.conf: un remoto por cuenta + una unión "multigdrive" + una unión por disco.
String buildRcloneConfig() {
  final b = StringBuffer();
  final accounts = DriveActions.store.accounts.where((a) => a.refreshToken != null).toList();
  for (final a in accounts) {
    final token = jsonEncode({
      'access_token': a.accessToken,
      'token_type': 'Bearer',
      'refresh_token': a.refreshToken,
      'expiry': a.expiry.toUtc().toIso8601String(),
    });
    b
      ..writeln('[${_remote(a)}]')
      ..writeln('type = drive')
      ..writeln('client_id = ${Config.desktopClientId}')
      ..writeln('client_secret = ${Config.desktopClientSecret}')
      ..writeln('scope = drive')
      ..writeln('token = $token')
      ..writeln();
  }
  b
    ..writeln('[multigdrive]')
    ..writeln('type = union')
    ..writeln('upstreams = ${accounts.map((a) => '${_remote(a)}:').join(' ')}')
    ..writeln('create_policy = mfs')
    ..writeln('action_policy = epall')
    ..writeln('search_policy = ff')
    ..writeln();
  for (final d in Disks.list) {
    final ups = <String>[];
    for (final m in d.members) {
      final a = accounts.where((x) => x.email == m.email).firstOrNull;
      final idx = DriveActions.indexes.loaded[m.email];
      if (a == null || idx == null) continue;
      final path = idx.pathTo(m.folderId).skip(1).map((p) => p.name).join('/');
      ups.add('"${_remote(a)}:$path"');
    }
    if (ups.isEmpty) continue;
    b
      ..writeln('[disco_${_safe(d.name)}]')
      ..writeln('type = union')
      ..writeln('upstreams = ${ups.join(' ')}')
      ..writeln('create_policy = mfs')
      ..writeln('action_policy = epall')
      ..writeln('search_policy = ff')
      ..writeln();
  }
  return b.toString();
}

/// Pantalla para dejar "Mi Drive total" (y cada disco) como unidad de Windows con rclone.
class RclonePage extends StatefulWidget {
  const RclonePage({super.key});

  @override
  State<RclonePage> createState() => _RclonePageState();
}

class _RclonePageState extends State<RclonePage> {
  String _letter = 'G';
  String? _folder;

  Future<void> _generate() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}${Platform.pathSeparator}Multi G-DRIVE');
    if (!await dir.exists()) await dir.create(recursive: true);
    String f(String name) => '${dir.path}${Platform.pathSeparator}$name';
    await File(f('rclone.conf')).writeAsString(buildRcloneConfig());
    await File(f('1-instalar-requisitos.bat')).writeAsString('@echo off\r\n'
        'echo Instalando rclone y WinFsp (una sola vez)...\r\n'
        'winget install -e --id Rclone.Rclone --accept-source-agreements --accept-package-agreements\r\n'
        'winget install -e --id WinFsp.WinFsp --accept-source-agreements --accept-package-agreements\r\n'
        'echo Listo. Cerra esta ventana y abri 2-montar-unidad.bat\r\npause\r\n');
    final letters = 'GHIJKLMNOPQRSTUVWXYZ'.split('');
    var i = letters.indexOf(_letter);
    final mount = StringBuffer('@echo off\r\n'
        'rem Deja abierta esta ventana mientras uses la unidad.\r\n'
        'start "Mi Drive total" rclone mount multigdrive: ${letters[i]}: --config "%~dp0rclone.conf" '
        '--vfs-cache-mode full --volname "Mi Drive total"\r\n');
    for (final d in Disks.list) {
      i++;
      if (i >= letters.length) break;
      mount.write('start "${d.name}" rclone mount disco_${_safe(d.name)}: ${letters[i]}: '
          '--config "%~dp0rclone.conf" --vfs-cache-mode full --volname "${d.name}"\r\n');
    }
    await File(f('2-montar-unidad.bat')).writeAsString(mount.toString());
    setState(() => _folder = dir.path);
    await launchUrl(Uri.file(dir.path));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final letters = 'GHIJKLMNOPQRSTUVWXYZ'.split('');
    var i = letters.indexOf(_letter);
    return Scaffold(
      appBar: AppBar(title: const Text('Unidad de Windows'), actions: [sidebarButton(context)]),
      drawer: sidebarDrawer(context),
      body: withSidebar(
        context,
        ListView(padding: const EdgeInsets.all(16), children: [
          const Text('Muestra "Mi Drive total" (y cada disco virtual) como una unidad con letra en el '
              'Explorador de Windows, para usarla desde cualquier programa. Usa rclone y WinFsp, '
              'dos programas gratuitos.'),
          const SizedBox(height: 16),
          if (!rcloneSupported)
            const Text('Esta función es solo para la app de Windows.')
          else ...[
            Row(children: [
              const Text('Letra para Mi Drive total: '),
              DropdownButton<String>(
                value: _letter,
                items: [for (final l in letters.take(12)) DropdownMenuItem(value: l, child: Text('$l:'))],
                onChanged: (v) => setState(() => _letter = v ?? _letter),
              ),
            ]),
            for (final d in Disks.list)
              if (++i < letters.length) Text('${d.name} → ${letters[i]}:', style: t.bodyMedium),
            const SizedBox(height: 12),
            FilledButton.icon(
              icon: const Icon(Icons.build_outlined),
              label: const Text('Generar archivos'),
              onPressed: _generate,
            ),
            const SizedBox(height: 16),
            Text('Pasos', style: t.titleSmall),
            const Text('1. Tocá "Generar archivos": se abre la carpeta "Documentos\\Multi G-DRIVE".\n'
                '2. Ejecutá 1-instalar-requisitos.bat (una sola vez).\n'
                '3. Ejecutá 2-montar-unidad.bat: aparece la unidad en "Este equipo". '
                'Mientras esa ventana esté abierta, la unidad funciona.\n'
                '4. Si agregás cuentas o discos, volvé a generar los archivos.'),
            const SizedBox(height: 12),
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Text('El archivo rclone.conf contiene el acceso a tus cuentas: no lo compartas '
                    'ni lo subas a ningún lado.'),
              ),
            ),
            if (_folder != null) Text('Generado en: $_folder', style: t.bodySmall),
          ],
        ]),
      ),
    );
  }
}
