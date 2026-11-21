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
      icon: const Icon(Icons.drive_file_move_outline),
      label: const Text('Mover a otra carpeta'),
      onPressed: () async {
        close();
        final dest = await pickFolder(context, idx, it);
        if (dest == null || !context.mounted) return;
        runAction(context, 'Movido: ${it.name}', () => DriveActions.move(a, it, dest));
      },
    ),
    if (others && !it.isFolder) ...[
      OutlinedButton.icon(
        icon: const Icon(Icons.copy),
        label: const Text('Copiar a otra cuenta'),
        onPressed: () async {
          close();
          final to = await pickAccount(context, a, 'Copiar a…');
          if (to == null || !context.mounted) return;
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
              'Se copia "${it.name}" a ${to.title} y el original va a la papelera de ${a.title}.',
              'Mover')) {
            return;
          }
          if (!context.mounted) return;
          runAction(context, 'Movido a ${to.title} (Mi unidad)',
              () => DriveActions.copyToAccount(a, it, to, move: true));
        },
      ),
    ],
  ];
}
