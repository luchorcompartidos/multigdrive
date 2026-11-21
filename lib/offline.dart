import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'accounts.dart';
import 'actions.dart';
import 'drive_index.dart';
import 'explorer.dart';
import 'offline_storage/offline_storage.dart' as files;
import 'side_tree.dart';

/// Un archivo guardado en el equipo para usar sin conexión.
class OfflineEntry {
  final String email;
  final String id;
  String name;
  String path;
  int bytes;
  int modified; // fecha de Drive de la versión guardada
  int savedAt;

  OfflineEntry(this.email, this.id, this.name, this.path, this.bytes, this.modified, this.savedAt);

  Map<String, dynamic> toJson() => {
        'email': email,
        'id': id,
        'name': name,
        'path': path,
        'bytes': bytes,
        'modified': modified,
        'savedAt': savedAt,
      };

  factory OfflineEntry.fromJson(Map<String, dynamic> j) => OfflineEntry(
        j['email'] as String,
        j['id'] as String,
        j['name'] as String,
        j['path'] as String,
        (j['bytes'] as num).toInt(),
        (j['modified'] as num).toInt(),
        (j['savedAt'] as num).toInt(),
      );
}

class Offline {
  static const _key = 'mgd_offline';
  static final List<OfflineEntry> entries = [];
  static final changed = ValueNotifier<int>(0);

  static bool get supported => files.supported;

  static Future<void> load() async {
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    entries.clear();
    if (raw == null) return;
    try {
      for (final j in jsonDecode(raw) as List) {
        entries.add(OfflineEntry.fromJson(j as Map<String, dynamic>));
      }
    } catch (_) {}
  }

  static Future<void> _save() async {
    await (await SharedPreferences.getInstance())
        .setString(_key, jsonEncode(entries.map((e) => e.toJson()).toList()));
    changed.value++;
  }

  static OfflineEntry? find(String email, String id) {
    for (final e in entries) {
      if (e.email == email && e.id == id) return e;
    }
    return null;
  }

  static List<OfflineEntry> of(String email) => entries.where((e) => e.email == email).toList();

  /// Documentos de Google: se guardan convertidos a formato de Office o PDF.
  static (String, String)? _export(String mime) {
    switch (mime) {
      case 'application/vnd.google-apps.document':
        return ('application/vnd.openxmlformats-officedocument.wordprocessingml.document', '.docx');
      case 'application/vnd.google-apps.spreadsheet':
        return ('application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', '.xlsx');
      case 'application/vnd.google-apps.presentation':
        return ('application/vnd.openxmlformats-officedocument.presentationml.presentation', '.pptx');
      case 'application/vnd.google-apps.drawing':
        return ('application/pdf', '.pdf');
    }
    return null;
  }

  static bool canSave(DriveItem it) =>
      !it.isFolder &&
      !it.isVirtual &&
      (!it.mime.startsWith('application/vnd.google-apps.') || _export(it.mime) != null);

  /// Descarga (o vuelve a descargar) un archivo al equipo.
  static Future<void> save(Account a, DriveItem it, {bool notify = true}) async {
    if (!canSave(it)) throw Exception('"${it.name}" no se puede guardar sin conexión.');
    final ex = _export(it.mime);
    final url = ex == null
        ? Uri.https('www.googleapis.com', '/drive/v3/files/${it.id}', {'alt': 'media'})
        : Uri.https('www.googleapis.com', '/drive/v3/files/${it.id}/export', {'mimeType': ex.$1});
    final req = http.Request('GET', url)
      ..headers['Authorization'] = 'Bearer ${await DriveActions.store.tokenFor(a)}';
    final res = await http.Client().send(req);
    if (res.statusCode == 403) {
      final body = await res.stream.bytesToString();
      if (body.contains('insufficient') || body.contains('SCOPE_INSUFFICIENT')) {
        throw NeedsMorePermission();
      }
      throw Exception('Drive no permitió descargar "${it.name}"');
    }
    if (res.statusCode != 200) throw Exception('Drive respondió ${res.statusCode} con "${it.name}"');
    var name = it.name;
    if (ex != null && !name.toLowerCase().endsWith(ex.$2)) name += ex.$2;
    var bytes = 0;
    final path = await files.saveStream(
        a.email, '${it.id}_$name', res.stream.map((chunk) {
      bytes += chunk.length;
      return chunk;
    }));
    final old = find(a.email, it.id);
    if (old != null && old.path != path) await files.deleteFile(old.path);
    entries.removeWhere((e) => e.email == a.email && e.id == it.id);
    entries.add(OfflineEntry(a.email, it.id, name, path, bytes, it.modified,
        DateTime.now().millisecondsSinceEpoch));
    if (notify) await _save();
  }

  static Future<void> remove(OfflineEntry e) async {
    await files.deleteFile(e.path);
    entries.remove(e);
    await _save();
  }

  /// Archivos guardados que cambiaron en Drive desde que se descargaron.
  static List<(OfflineEntry, DriveItem)> outdated(String email) {
    final idx = DriveActions.indexes.loaded[email];
    if (idx == null) return [];
    return [
      for (final e in of(email))
        if (idx.items[e.id] != null && idx.items[e.id]!.modified > e.modified) (e, idx.items[e.id]!)
    ];
  }

  static Future<void> open(OfflineEntry e) => files.openFile(e.path);

  static Future<void> flush() => _save();
}

/// Botón "Guardar sin conexión" / "Quitar de sin conexión" para la hoja de detalle.
List<Widget> offlineButtons(
    BuildContext context, Account a, AccountIndex idx, DriveItem it, VoidCallback close) {
  if (!Offline.supported || it.isVirtual || it.trashed) return const [];
  if (it.isFolder) {
    return [
      OutlinedButton.icon(
        icon: const Icon(Icons.download_for_offline_outlined),
        label: const Text('Guardar carpeta sin conexión'),
        onPressed: () async {
          close();
          final list = [
            for (final id in idx.descendants(it.id))
              if (idx.items[id] != null && Offline.canSave(idx.items[id]!) && !idx.items[id]!.trashed)
                (a, idx.items[id]!)
          ];
          if (list.isEmpty) return;
          final bytes = list.fold<int>(0, (s, e) => s + e.$2.size);
          if (!await confirm(context, 'Guardar sin conexión',
              'Se descargan ${list.length} archivos (≈ ${formatBytes(bytes)}) a este equipo.',
              'Descargar')) {
            return;
          }
          if (!context.mounted) return;
          await runBatch(context, 'Descargando', list, (a, f) => Offline.save(a, f, notify: false),
              done: 'Guardados sin conexión');
          await Offline.flush();
        },
      ),
    ];
  }
  if (!Offline.canSave(it)) return const [];
  final saved = Offline.find(a.email, it.id);
  if (saved != null) {
    return [
      OutlinedButton.icon(
        icon: const Icon(Icons.offline_pin),
        label: const Text('Abrir copia sin conexión'),
        onPressed: () {
          close();
          runAction(context, 'Abriendo…', () => Offline.open(saved));
        },
      ),
      OutlinedButton.icon(
        icon: const Icon(Icons.cloud_off),
        label: const Text('Quitar de sin conexión'),
        onPressed: () {
          close();
          runAction(context, 'Quitado de sin conexión', () => Offline.remove(saved));
        },
      ),
    ];
  }
  return [
    OutlinedButton.icon(
      icon: const Icon(Icons.download_for_offline_outlined),
      label: const Text('Guardar sin conexión'),
      onPressed: () {
        close();
        runAction(context, 'Guardado sin conexión: ${it.name}', () => Offline.save(a, it));
      },
    ),
  ];
}

/// Sección "Archivos SIN CONEXIÓN" de una cuenta.
class OfflinePage extends StatefulWidget {
  final Account account;
  const OfflinePage({super.key, required this.account});

  @override
  State<OfflinePage> createState() => _OfflinePageState();
}

class _OfflinePageState extends State<OfflinePage> {
  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    Offline.changed.addListener(_refresh);
    indexChanged.addListener(_refresh);
  }

  @override
  void dispose() {
    Offline.changed.removeListener(_refresh);
    indexChanged.removeListener(_refresh);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.account;
    final list = Offline.of(a.email)..sort((x, y) => x.name.toLowerCase().compareTo(y.name.toLowerCase()));
    final total = list.fold<int>(0, (s, e) => s + e.bytes);
    final outdated = Offline.outdated(a.email);
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: Text('Sin conexión · ${a.title}', overflow: TextOverflow.ellipsis),
        actions: [sidebarButton(context)],
      ),
      drawer: sidebarDrawer(context),
      body: withSidebar(
        context,
        !Offline.supported
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('Los archivos sin conexión se usan desde la app instalada '
                      '(Android o Windows), no desde la web.', textAlign: TextAlign.center),
                ),
              )
            : ListView(children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Text('${list.length} archivos guardados en este equipo · ${formatBytes(total)}',
                      style: t.titleSmall),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text('Para agregar: en el Explorador, abrí el detalle de un archivo o carpeta '
                      '→ "Guardar sin conexión". Los Documentos de Google se guardan como Word, '
                      'Excel o PowerPoint.'),
                ),
                if (outdated.isNotEmpty)
                  Card(
                    margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    child: ListTile(
                      leading: const Icon(Icons.sync_problem),
                      title: Text('${outdated.length} cambiaron en Drive desde que los guardaste'),
                      trailing: FilledButton(
                        onPressed: () async {
                          await runBatch(context, 'Actualizando', [for (final (_, it) in outdated) (a, it)],
                              (a, it) => Offline.save(a, it, notify: false),
                              done: 'Actualizados');
                          await Offline.flush();
                        },
                        child: const Text('Actualizar'),
                      ),
                    ),
                  ),
                const Divider(),
                if (list.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('Todavía no guardaste archivos sin conexión.', textAlign: TextAlign.center),
                  ),
                for (final e in list)
                  ListTile(
                    leading: const Icon(Icons.offline_pin),
                    title: Text(e.name, overflow: TextOverflow.ellipsis),
                    subtitle: Text('${formatBytes(e.bytes)} · guardado el '
                        '${fmtDay(DateTime.fromMillisecondsSinceEpoch(e.savedAt))}'
                        '${outdated.any((o) => o.$1 == e) ? ' · hay versión nueva' : ''}'),
                    onTap: () => runAction(context, 'Abriendo…', () => Offline.open(e)),
                    trailing: IconButton(
                      tooltip: 'Quitar de sin conexión',
                      icon: const Icon(Icons.cloud_off),
                      onPressed: () => runAction(context, 'Quitado', () => Offline.remove(e)),
                    ),
                  ),
              ]),
      ),
    );
  }
}
