import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'accounts.dart';
import 'drive_index.dart';

/// Avisa a las pantallas abiertas que cambió algún índice.
final indexChanged = ValueNotifier<int>(0);

class NeedsMorePermission implements Exception {
  @override
  String toString() => 'Para hacer cambios, volvé a conectar esta cuenta '
      '(menú ⋮ → Volver a conectar) y aceptá el permiso nuevo.';
}

/// Cambios reales en Drive: papelera, restaurar, vaciar, mover y copiar entre cuentas.
class DriveActions {
  static late AccountStore store;
  static late IndexStore indexes;

  static Future<Map<String, dynamic>> _call(Account a, String method, String path,
      {Map<String, String>? query, Object? body}) async {
    final req = http.Request(method, Uri.https('www.googleapis.com', path, query))
      ..headers['Authorization'] = 'Bearer ${await store.tokenFor(a)}';
    if (body != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    final res = await http.Response.fromStream(await req.send());
    if (res.statusCode >= 200 && res.statusCode < 300) {
      return res.body.trim().isEmpty ? {} : jsonDecode(res.body) as Map<String, dynamic>;
    }
    if (res.statusCode == 403 &&
        (res.body.contains('insufficient') || res.body.contains('SCOPE_INSUFFICIENT'))) {
      throw NeedsMorePermission();
    }
    String msg = res.body;
    try {
      msg = (jsonDecode(res.body)['error']['message']) as String;
    } catch (_) {}
    throw Exception('Drive respondió ${res.statusCode}: $msg');
  }

  static Future<void> _changed(String email) async {
    final idx = indexes.loaded[email];
    if (idx != null) {
      idx.rebuild();
      await indexes.save(email);
    }
    indexChanged.value++;
  }

  /// Manda a la papelera (o restaura) un archivo o una carpeta con todo su contenido.
  static Future<void> setTrashed(Account a, DriveItem it, bool trashed) async {
    await _call(a, 'PATCH', '/drive/v3/files/${it.id}',
        query: {'fields': 'id'}, body: {'trashed': trashed});
    final idx = indexes.loaded[a.email];
    if (idx != null) {
      for (final id in [it.id, ...idx.descendants(it.id)]) {
        final x = idx.items[id];
        if (x != null) idx.items[id] = x.copyWith(trashed: trashed);
      }
    }
    await _changed(a.email);
  }

  /// Vacía la papelera de la cuenta (borrado definitivo).
  static Future<void> emptyTrash(Account a) async {
    await _call(a, 'DELETE', '/drive/v3/files/trash');
    indexes.loaded[a.email]?.items.removeWhere((_, x) => x.trashed && !x.isVirtual);
    await _changed(a.email);
  }

  /// Mueve a otra carpeta de la misma cuenta.
  static Future<void> move(Account a, DriveItem it, String newParent) async {
    await _call(a, 'PATCH', '/drive/v3/files/${it.id}', query: {
      'addParents': newParent,
      if (it.parent != null) 'removeParents': it.parent!,
      'fields': 'id,parents',
    }, body: {});
    final idx = indexes.loaded[a.email];
    if (idx != null) idx.items[it.id] = it.copyWith(parent: newParent);
    await _changed(a.email);
  }

  /// Copia un archivo a "Mi unidad" de otra cuenta (y opcionalmente lo manda a la papelera).
  /// Se comparte un momento como lector con la cuenta destino, que hace la copia.
  static Future<void> copyToAccount(Account from, DriveItem it, Account to,
      {bool move = false}) async {
    if (it.isFolder) throw Exception('Por ahora se copian archivos, no carpetas.');
    final perm = await _call(from, 'POST', '/drive/v3/files/${it.id}/permissions',
        query: {'sendNotificationEmail': 'false', 'fields': 'id'},
        body: {'role': 'reader', 'type': 'user', 'emailAddress': to.email});
    try {
      final copy = await _call(to, 'POST', '/drive/v3/files/${it.id}/copy',
          query: {'fields': fileFields}, body: {'name': it.name, 'parents': ['root']});
      final dest = indexes.loaded[to.email];
      if (dest != null) {
        final c = DriveItem.fromApi(copy);
        dest.items[c.id] = c.copyWith(parent: dest.rootId);
        await _changed(to.email);
      }
    } finally {
      try {
        await _call(from, 'DELETE', '/drive/v3/files/${it.id}/permissions/${perm['id']}');
      } catch (_) {}
    }
    if (move) await setTrashed(from, it, true);
  }
}

/// Resultado de copiar una carpeta.
class CopyReport {
  int done = 0;
  int total = 0;
  final List<String> failed = [];
}

class FolderOps {
  /// Renombra un archivo o carpeta.
  static Future<void> rename(Account a, DriveItem it, String name) async {
    await DriveActions._call(a, 'PATCH', '/drive/v3/files/${it.id}',
        query: {'fields': 'id'}, body: {'name': name});
    final idx = DriveActions.indexes.loaded[a.email];
    if (idx != null) {
      idx.items[it.id] = DriveItem(it.id, name, it.mime, it.size, it.quota, it.parent,
          it.modified, it.md5, it.trashed, it.mine);
    }
    await DriveActions._changed(a.email);
  }

  /// Crea una carpeta nueva dentro de [parentId].
  static Future<void> createFolder(Account a, String parentId, String name) async {
    final j = await DriveActions._call(a, 'POST', '/drive/v3/files',
        query: {'fields': fileFields},
        body: {'name': name, 'mimeType': folderMime, 'parents': [parentId]});
    final idx = DriveActions.indexes.loaded[a.email];
    if (idx != null) {
      final it = DriveItem.fromApi(j);
      idx.items[it.id] = it;
    }
    await DriveActions._changed(a.email);
  }

  /// Copia una carpeta completa (estructura y archivos) a [to], dentro de [destParent]
  /// ('root' = Mi unidad). Si [move], al terminar sin errores el original va a la papelera.
  static Future<CopyReport> copyFolder(Account from, DriveItem folder, Account to,
      {String destParent = 'root', bool move = false, void Function(CopyReport)? progress}) async {
    final idx = DriveActions.indexes.loaded[from.email];
    if (idx == null) throw Exception('Primero indexá ${from.title}.');
    final report = CopyReport();
    final inside = idx
        .descendants(folder.id)
        .map((id) => idx.items[id]!)
        .where((x) => !x.trashed)
        .toList();
    final folders = [folder, ...inside.where((x) => x.isFolder)];
    final files = inside.where((x) => !x.isFolder).toList();
    report.total = folders.length + files.length;
    progress?.call(report);

    final same = from.email == to.email;
    Map<String, dynamic>? perm;
    if (!same) {
      perm = await DriveActions._call(from, 'POST', '/drive/v3/files/${folder.id}/permissions',
          query: {'sendNotificationEmail': 'false', 'fields': 'id'},
          body: {'role': 'reader', 'type': 'user', 'emailAddress': to.email});
    }
    final dest = DriveActions.indexes.loaded[to.email];
    final newId = <String, String>{};
    try {
      // 1) carpetas, de arriba hacia abajo (folders ya está en ese orden)
      for (final f in folders) {
        final parent = f.id == folder.id ? destParent : newId[f.parent];
        if (parent == null) {
          report.failed.add(f.name);
          continue;
        }
        try {
          final j = await DriveActions._call(to, 'POST', '/drive/v3/files',
              query: {'fields': fileFields},
              body: {'name': f.name, 'mimeType': folderMime, 'parents': [parent]});
          newId[f.id] = j['id'] as String;
          if (dest != null) {
            final c = DriveItem.fromApi(j);
            dest.items[c.id] = parent == 'root' ? c.copyWith(parent: dest.rootId) : c;
          }
        } catch (_) {
          report.failed.add(f.name);
        }
        report.done++;
        progress?.call(report);
      }
      // 2) archivos
      for (final f in files) {
        final parent = newId[f.parent];
        if (parent == null) {
          report.failed.add(f.name);
        } else {
          try {
            final j = await DriveActions._call(to, 'POST', '/drive/v3/files/${f.id}/copy',
                query: {'fields': fileFields}, body: {'name': f.name, 'parents': [parent]});
            if (dest != null) {
              final c = DriveItem.fromApi(j);
              dest.items[c.id] = c;
            }
          } catch (_) {
            report.failed.add(f.name);
          }
        }
        report.done++;
        progress?.call(report);
      }
    } finally {
      if (perm != null) {
        try {
          await DriveActions._call(
              from, 'DELETE', '/drive/v3/files/${folder.id}/permissions/${perm['id']}');
        } catch (_) {}
      }
      await DriveActions._changed(to.email);
    }
    if (move && report.failed.isEmpty) await DriveActions.setTrashed(from, folder, true);
    return report;
  }
}

/// Diálogo con barra de progreso para la copia de carpetas.
Future<void> runFolderCopy(BuildContext context, String title, Account from, DriveItem folder,
    Account to, {bool move = false}) async {
  final tick = ValueNotifier<int>(0);
  CopyReport? current;
  final nav = Navigator.of(context);
  final messenger = ScaffoldMessenger.of(context);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: ValueListenableBuilder<int>(
        valueListenable: tick,
        builder: (_, __, ___) {
          final r = current;
          return Column(mainAxisSize: MainAxisSize.min, children: [
          LinearProgressIndicator(
              value: (r == null || r.total == 0) ? null : r.done / r.total),
          const SizedBox(height: 12),
          Text(r == null
              ? 'Preparando…'
              : '${r.done} de ${r.total} elementos'
                  '${r.failed.isEmpty ? '' : ' · ${r.failed.length} con error'}'),
          const SizedBox(height: 8),
          const Text('No cierres la app hasta que termine.'),
        ]);
        },
      ),
    ),
  );
  try {
    final r = await FolderOps.copyFolder(from, folder, to,
        move: move, progress: (r) {
      current = r;
      tick.value++;
    });
    nav.pop();
    messenger.showSnackBar(SnackBar(
      duration: const Duration(seconds: 8),
      content: Text(r.failed.isEmpty
          ? '${move ? 'Movida' : 'Copiada'}: "${folder.name}" → ${to.title} (${r.total} elementos)'
          : '${r.total - r.failed.length} de ${r.total} copiados. Con error: '
              '${r.failed.take(5).join(', ')}${r.failed.length > 5 ? '…' : ''}'
              '${move ? '. El original NO se movió a la papelera.' : ''}'),
    ));
  } catch (e) {
    nav.pop();
    messenger.showSnackBar(
        SnackBar(content: Text('$e'), duration: const Duration(seconds: 8)));
  }
}

Future<String?> askText(BuildContext context, String title, String label, String initial) {
  final ctrl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        decoration: InputDecoration(labelText: label),
        onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Aceptar')),
      ],
    ),
  );
}

// ---------- diálogos ----------

Future<bool> confirm(BuildContext context, String title, String text, String ok) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(text),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ok)),
        ],
      ),
    ) ==
    true;

Future<void> runAction(BuildContext context, String done, Future<void> Function() task) async {
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(const SnackBar(content: Text('Procesando…')));
  try {
    await task();
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(done)));
  } catch (e) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('$e'), duration: const Duration(seconds: 6)));
  }
}

Future<Account?> pickAccount(BuildContext context, Account except, String title) =>
    showDialog<Account>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(title),
        children: [
          for (final a in DriveActions.store.accounts)
            if (a.email != except.email)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, a),
                child: Row(children: [
                  CircleAvatar(radius: 10, backgroundColor: Color(a.color)),
                  const SizedBox(width: 12),
                  Expanded(child: Text(a.title)),
                ]),
              ),
        ],
      ),
    );

/// Elegir carpeta de destino dentro de la misma cuenta.
Future<String?> pickFolder(BuildContext context, AccountIndex idx, DriveItem moving) =>
    showDialog<String>(
      context: context,
      builder: (ctx) {
        var current = idx.rootId;
        final blocked = {moving.id, ...idx.descendants(moving.id)};
        return StatefulBuilder(builder: (ctx, setLocal) {
          final folders = (idx.children[current] ?? const <DriveItem>[])
              .where((f) => f.isFolder && !blocked.contains(f.id))
              .toList()
            ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
          final path = idx.pathTo(current).map((p) => p.name).join(' / ');
          return AlertDialog(
            title: const Text('Mover a…'),
            content: SizedBox(
              width: 400,
              height: 360,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  if (current != idx.rootId)
                    IconButton(
                      icon: const Icon(Icons.arrow_upward),
                      onPressed: () =>
                          setLocal(() => current = idx.parentOf[current] ?? idx.rootId),
                    ),
                  Expanded(child: Text(path, style: Theme.of(ctx).textTheme.titleSmall)),
                ]),
                const Divider(),
                Expanded(
                  child: folders.isEmpty
                      ? const Center(child: Text('Sin subcarpetas'))
                      : ListView(children: [
                          for (final f in folders)
                            ListTile(
                              leading: const Icon(Icons.folder),
                              title: Text(f.name, overflow: TextOverflow.ellipsis),
                              onTap: () => setLocal(() => current = f.id),
                            ),
                        ]),
                ),
              ]),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
              FilledButton(
                onPressed: current == moving.parent ? null : () => Navigator.pop(ctx, current),
                child: const Text('Mover acá'),
              ),
            ],
          );
        });
      },
    );

/// Botones de acción para un elemento (van en la hoja de detalle).
List<Widget> actionButtons(
    BuildContext context, Account a, AccountIndex idx, DriveItem it, VoidCallback close) {
  if (it.isVirtual || !it.mine) return const [];
  final others = DriveActions.store.accounts.length > 1;
  final kind = it.isFolder ? 'la carpeta' : 'el archivo';
  if (it.trashed) {
    return [
      OutlinedButton.icon(
        icon: const Icon(Icons.restore_from_trash),
        label: const Text('Restaurar'),
        onPressed: () {
          close();
          runAction(context, 'Restaurado: ${it.name}', () => DriveActions.setTrashed(a, it, false));
        },
      ),
    ];
  }
  return [
    OutlinedButton.icon(
      icon: const Icon(Icons.delete_outline),
      label: const Text('Mover a la papelera'),
      onPressed: () async {
        close();
        if (await confirm(context, 'Mover a la papelera',
            '¿Mandar $kind "${it.name}" a la papelera de ${a.title}? Se puede restaurar.',
            'A la papelera')) {
          if (!context.mounted) return;
          runAction(context, 'En la papelera: ${it.name}', () => DriveActions.setTrashed(a, it, true));
        }
      },
    ),
    OutlinedButton.icon(
      icon: const Icon(Icons.edit_outlined),
      label: const Text('Renombrar'),
      onPressed: () async {
        close();
        final name = await askText(context, 'Renombrar', 'Nombre', it.name);
        if (name == null || name.isEmpty || name == it.name || !context.mounted) return;
        runAction(context, 'Renombrado: $name', () => FolderOps.rename(a, it, name));
      },
    ),
    if (it.isFolder)
      OutlinedButton.icon(
        icon: const Icon(Icons.folder_copy_outlined),
        label: const Text('Duplicar carpeta'),
        onPressed: () {
          close();
          runFolderCopy(context, 'Duplicando "${it.name}"', a, it, a);
        },
      ),
    OutlinedButton.icon(
      icon: const Icon(Icons.drive_file_move_outline),
      label: const Text('Mover a otra carpeta'),
      onPressed: () async {
        close();
        final dest = await pickFolder(context, idx, it);
        if (dest == null || !context.mounted) return;
        runAction(context, 'Movido: ${it.name}', () => DriveActions.move(a, it, dest));
      },
    ),
    if (others) ...[
      OutlinedButton.icon(
        icon: const Icon(Icons.copy),
        label: const Text('Copiar a otra cuenta'),
        onPressed: () async {
          close();
          final to = await pickAccount(context, a, 'Copiar a…');
          if (to == null || !context.mounted) return;
          if (it.isFolder) {
            runFolderCopy(context, 'Copiando "${it.name}" a ${to.title}', a, it, to);
            return;
          }
          runAction(context, 'Copiado a ${to.title} (Mi unidad)',
              () => DriveActions.copyToAccount(a, it, to));
        },
      ),
      OutlinedButton.icon(
        icon: const Icon(Icons.move_up),
        label: const Text('Mover a otra cuenta'),
        onPressed: () async {
          close();
          final to = await pickAccount(context, a, 'Mover a…');
          if (to == null || !context.mounted) return;
          if (!await confirm(
              context,
              'Mover a otra cuenta',
              'Se copia ${it.isFolder ? 'la carpeta completa' : 'el archivo'} "${it.name}" a '
                  '${to.title} (Mi unidad) y, si todo sale bien, el original va a la papelera '
                  'de ${a.title}.',
              'Mover')) {
            return;
          }
          if (!context.mounted) return;
          if (it.isFolder) {
            runFolderCopy(context, 'Moviendo "${it.name}" a ${to.title}', a, it, to, move: true);
            return;
          }
          runAction(context, 'Movido a ${to.title} (Mi unidad)',
              () => DriveActions.copyToAccount(a, it, to, move: true));
        },
      ),
    ],
  ];
}
