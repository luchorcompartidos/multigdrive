import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'accounts.dart';
import 'actions.dart';
import 'drive_index.dart';
import 'side_tree.dart';

/// Una acción hecha desde la app.
class LogEntry {
  final int at;
  final String kind; // trash, restore, move, rename, create, copy, transfer, empty
  final String email;
  final String? toEmail;
  final String id;
  final String name;
  final int bytes;
  final Map<String, dynamic> undo;
  bool undone;

  LogEntry(this.at, this.kind, this.email, this.toEmail, this.id, this.name, this.bytes, this.undo,
      {this.undone = false});

  Map<String, dynamic> toJson() => {
        'at': at,
        'kind': kind,
        'email': email,
        'to': toEmail,
        'id': id,
        'name': name,
        'bytes': bytes,
        'undo': undo,
        'undone': undone,
      };

  factory LogEntry.fromJson(Map<String, dynamic> j) => LogEntry(
        (j['at'] as num).toInt(),
        j['kind'] as String,
        j['email'] as String,
        j['to'] as String?,
        j['id'] as String,
        j['name'] as String,
        (j['bytes'] as num?)?.toInt() ?? 0,
        (j['undo'] as Map?)?.cast<String, dynamic>() ?? {},
        undone: j['undone'] == true,
      );
}

const _labels = {
  'trash': 'A la papelera',
  'restore': 'Restaurado',
  'move': 'Movido de carpeta',
  'rename': 'Renombrado',
  'create': 'Carpeta creada',
  'copy': 'Copiado a otra cuenta',
  'transfer': 'Pasado a otra cuenta',
  'empty': 'Papelera vaciada',
};

const _icons = {
  'trash': Icons.delete_outline,
  'restore': Icons.restore_from_trash,
  'move': Icons.drive_file_move_outline,
  'rename': Icons.edit_outlined,
  'create': Icons.create_new_folder_outlined,
  'copy': Icons.copy,
  'transfer': Icons.swap_horiz,
  'empty': Icons.delete_forever,
};

/// Historial de acciones (se guarda en el equipo, hasta 1000 entradas).
class History {
  static const _key = 'mgd_history';
  static const _max = 1000;
  static final List<LogEntry> entries = [];
  static final changed = ValueNotifier<int>(0);
  static bool _loaded = false;
  static bool _paused = false; // al deshacer no se registra de nuevo

  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    if (raw == null) return;
    try {
      for (final j in jsonDecode(raw) as List) {
        entries.add(LogEntry.fromJson(j as Map<String, dynamic>));
      }
    } catch (_) {}
  }

  static Future<void> _save() async {
    if (entries.length > _max) entries.removeRange(_max, entries.length);
    await (await SharedPreferences.getInstance())
        .setString(_key, jsonEncode(entries.map((e) => e.toJson()).toList()));
    changed.value++;
  }

  static Future<void> add(String kind, Account a, DriveItem it,
      {Account? to, int? bytes, Map<String, dynamic> undo = const {}}) async {
    if (_paused) return;
    await load();
    entries.insert(
        0,
        LogEntry(DateTime.now().millisecondsSinceEpoch, kind, a.email, to?.email, it.id, it.name,
            bytes ?? it.total, undo));
    await _save();
  }

  static bool canUndo(LogEntry e) =>
      !e.undone && e.kind != 'empty' && _account(e.email) != null &&
      (e.toEmail == null || _account(e.toEmail!) != null);

  static Account? _account(String email) {
    for (final a in DriveActions.store.accounts) {
      if (a.email == email) return a;
    }
    return null;
  }

  static DriveItem _item(String email, String id, String name) =>
      DriveActions.indexes.loaded[email]?.items[id] ??
      DriveItem(id, name, '', 0, 0, null, 0, null, false, true);

  static Future<void> undo(LogEntry e) async {
    final a = _account(e.email)!;
    final to = e.toEmail == null ? null : _account(e.toEmail!);
    _paused = true;
    try {
      switch (e.kind) {
        case 'trash':
          await DriveActions.setTrashed(a, _item(e.email, e.id, e.name), false);
        case 'restore':
          await DriveActions.setTrashed(a, _item(e.email, e.id, e.name), true);
        case 'move':
          await DriveActions.move(a, _item(e.email, e.id, e.name), e.undo['parent'] as String);
        case 'rename':
          await FolderOps.rename(a, _item(e.email, e.id, e.name), e.undo['name'] as String);
        case 'create':
          await DriveActions.setTrashed(a, _item(e.email, e.id, e.name), true);
        case 'copy':
          final newId = e.undo['newId'] as String;
          await DriveActions.setTrashed(to!, _item(to.email, newId, e.name), true);
        case 'transfer':
          await DriveActions.transferToAccount(to!, _item(to.email, e.id, e.name), a);
      }
      e.undone = true;
      await _save();
    } finally {
      _paused = false;
    }
  }
}

/// Pantalla de historial.
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    History.changed.addListener(_refresh);
    History.load().then((_) => _refresh());
  }

  @override
  void dispose() {
    History.changed.removeListener(_refresh);
    super.dispose();
  }

  String _who(String email) {
    for (final a in DriveActions.store.accounts) {
      if (a.email == email) return a.title;
    }
    return email;
  }

  @override
  Widget build(BuildContext context) {
    final list = History.entries;
    final t = Theme.of(context).textTheme;
    final emptied = list.where((e) => e.kind == 'empty').fold<int>(0, (s, e) => s + e.bytes);
    final trashed =
        list.where((e) => e.kind == 'trash' && !e.undone).fold<int>(0, (s, e) => s + e.bytes);
    final moved =
        list.where((e) => (e.kind == 'transfer') && !e.undone).fold<int>(0, (s, e) => s + e.bytes);
    String two(int n) => n.toString().padLeft(2, '0');
    String when(int ms) {
      final d = DateTime.fromMillisecondsSinceEpoch(ms);
      return '${two(d.day)}/${two(d.month)} ${two(d.hour)}:${two(d.minute)}';
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Historial'), actions: [sidebarButton(context)]),
      drawer: sidebarDrawer(context),
      body: withSidebar(
        context,
        ListView(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Wrap(spacing: 16, runSpacing: 4, children: [
              Text('Liberado al vaciar papeleras: ${formatBytes(emptied)}', style: t.titleSmall),
              Text('Enviado a la papelera: ${formatBytes(trashed)}'),
              Text('Pasado entre cuentas: ${formatBytes(moved)}'),
            ]),
          ),
          const Divider(),
          if (list.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('Todavía no hay acciones registradas.', textAlign: TextAlign.center),
            ),
          for (final e in list)
            ListTile(
              leading: Icon(_icons[e.kind] ?? Icons.history),
              title: Text('${_labels[e.kind] ?? e.kind}: ${e.name}', overflow: TextOverflow.ellipsis),
              subtitle: Text([
                when(e.at),
                _who(e.email) + (e.toEmail == null ? '' : ' → ${_who(e.toEmail!)}'),
                if (e.bytes > 0) formatBytes(e.bytes),
                if (e.undone) 'deshecho',
              ].join(' · ')),
              trailing: History.canUndo(e)
                  ? TextButton(
                      onPressed: () => runAction(context, 'Deshecho: ${e.name}', () => History.undo(e)),
                      child: const Text('Deshacer'),
                    )
                  : null,
            ),
        ]),
      ),
    );
  }
}
