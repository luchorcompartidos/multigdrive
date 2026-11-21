import 'package:flutter/material.dart';

import 'accounts.dart';
import 'actions.dart';
import 'drive_index.dart';
import 'explorer.dart';
import 'side_tree.dart';

class _Missing {
  final DriveItem file;
  final String path;
  _Missing(this.file, this.path);
}

class MirrorPlan {
  final List<_Missing> missing = [];
  final Map<String, String> known = {}; // carpeta origen → carpeta destino que ya existe
  int folders = 0; // carpetas a crear
  int same = 0;
  int get bytes => missing.fold<int>(0, (s, m) => s + m.file.size);
}

/// Espejo / respaldo: compara dos carpetas (de la misma o distinta cuenta) y copia lo que falta.
class MirrorPage extends StatefulWidget {
  const MirrorPage({super.key});

  @override
  State<MirrorPage> createState() => _MirrorPageState();
}

class _MirrorPageState extends State<MirrorPage> {
  Account? _from;
  Account? _to;
  String? _srcId;
  String? _dstId;
  MirrorPlan? _plan;

  List<Account> get _indexed =>
      DriveActions.store.accounts.where((a) => DriveActions.indexes.loaded.containsKey(a.email)).toList();

  AccountIndex? _idx(Account? a) => a == null ? null : DriveActions.indexes.loaded[a.email];

  String _folderName(Account? a, String? id) {
    final idx = _idx(a);
    if (idx == null || id == null) return 'Elegir carpeta…';
    return idx.pathTo(id).map((p) => p.name).join(' / ');
  }

  MirrorPlan _compute(AccountIndex src, String srcTop, AccountIndex dst, String dstTop) {
    final plan = MirrorPlan()..known[srcTop] = dstTop;
    void walk(String srcId, String? dstId, String path) {
      final srcKids = (src.children[srcId] ?? const <DriveItem>[]).where((x) => !x.trashed);
      final dstKids = dstId == null
          ? const <DriveItem>[]
          : (dst.children[dstId] ?? const <DriveItem>[]).where((x) => !x.trashed).toList();
      for (final c in srcKids) {
        final same = dstKids.where((d) => d.name == c.name && d.isFolder == c.isFolder).toList();
        if (c.isFolder) {
          final d = same.isEmpty ? null : same.first;
          if (d == null) {
            plan.folders++;
          } else {
            plan.known[c.id] = d.id;
          }
          walk(c.id, d?.id, '$path/${c.name}');
        } else {
          final equal = same.any((d) =>
              (c.md5 != null && d.md5 == c.md5) || (c.md5 == null && d.size == c.size));
          if (equal) {
            plan.same++;
          } else {
            plan.missing.add(_Missing(c, path));
          }
        }
      }
    }

    walk(srcTop, dstTop, '');
    return plan;
  }

  void _compare() {
    final src = _idx(_from), dst = _idx(_to);
    if (src == null || dst == null || _srcId == null || _dstId == null) return;
    setState(() => _plan = _compute(src, _srcId!, dst, _dstId!));
  }

  Future<CopyReport> _apply(void Function(CopyReport) progress) async {
    final from = _from!, to = _to!;
    final src = _idx(from)!, dst = _idx(to)!;
    final plan = _plan!;
    final report = CopyReport()..total = plan.missing.length;
    progress(report);
    Map<String, dynamic>? perm;
    if (from.email != to.email) {
      perm = await DriveActions.api(from, 'POST', '/drive/v3/files/$_srcId/permissions',
          query: {'sendNotificationEmail': 'false', 'fields': 'id'},
          body: {'role': 'reader', 'type': 'user', 'emailAddress': to.email});
    }
    final map = Map<String, String>.from(plan.known);
    Future<String> ensure(String srcFolder) async {
      final known = map[srcFolder];
      if (known != null) return known;
      final parent = await ensure(src.parentOf[srcFolder]!);
      final j = await DriveActions.api(to, 'POST', '/drive/v3/files', query: {
        'fields': fileFields
      }, body: {
        'name': src.items[srcFolder]!.name,
        'mimeType': folderMime,
        'parents': [parent],
      });
      final created = DriveItem.fromApi(j);
      dst.items[created.id] = created;
      map[srcFolder] = created.id;
      return created.id;
    }

    try {
      for (final m in plan.missing) {
        try {
          final parent = await ensure(m.file.parent!);
          final j = await DriveActions.api(to, 'POST', '/drive/v3/files/${m.file.id}/copy',
              query: {'fields': fileFields}, body: {'name': m.file.name, 'parents': [parent]});
          final c = DriveItem.fromApi(j);
          dst.items[c.id] = c;
        } catch (_) {
          report.failed.add(m.file.name);
        }
        report.done++;
        progress(report);
      }
    } finally {
      if (perm != null) {
        try {
          await DriveActions.api(from, 'DELETE', '/drive/v3/files/$_srcId/permissions/${perm['id']}');
        } catch (_) {}
      }
      await DriveActions.notifyChanged(to.email);
    }
    return report;
  }

  Widget _side(String label, Account? acc, String? folder, void Function(Account?) onAcc,
      void Function(String) onFolder) {
    final accounts = _indexed;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: Theme.of(context).textTheme.titleSmall),
          DropdownButton<String>(
            isExpanded: true,
            hint: const Text('Elegir cuenta (indexada)'),
            value: acc?.email,
            items: [for (final a in accounts) DropdownMenuItem(value: a.email, child: Text(a.title))],
            onChanged: (v) => onAcc(accounts.firstWhere((a) => a.email == v)),
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.folder_open),
            label: Text(_folderName(acc, folder), overflow: TextOverflow.ellipsis),
            onPressed: acc == null
                ? null
                : () async {
                    final id = await pickFolderFor(context, _idx(acc)!, const [],
                        title: 'Elegir carpeta', okLabel: 'Elegir esta');
                    if (id != null) onFolder(id);
                  },
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    final t = Theme.of(context).textTheme;
    final sameFolder = _from?.email == _to?.email && _srcId != null && _srcId == _dstId;
    return Scaffold(
      appBar: AppBar(title: const Text('Espejo / respaldo'), actions: [sidebarButton(context)]),
      drawer: sidebarDrawer(context),
      body: withSidebar(
        context,
        ListView(padding: const EdgeInsets.only(bottom: 96), children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text('Compara dos carpetas (pueden estar en cuentas distintas) y copia al destino '
                'solo los archivos que faltan, respetando las subcarpetas. No borra nada del destino.'),
          ),
          _side('Origen', _from, _srcId, (a) => setState(() {
                _from = a;
                _srcId = _idx(a)?.rootId;
                _plan = null;
              }), (id) => setState(() {
                _srcId = id;
                _plan = null;
              })),
          const Center(child: Icon(Icons.arrow_downward)),
          _side('Destino', _to, _dstId, (a) => setState(() {
                _to = a;
                _dstId = _idx(a)?.rootId;
                _plan = null;
              }), (id) => setState(() {
                _dstId = id;
                _plan = null;
              })),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: FilledButton.icon(
              icon: const Icon(Icons.compare_arrows),
              label: const Text('Comparar'),
              onPressed: _srcId == null || _dstId == null || sameFolder ? null : _compare,
            ),
          ),
          if (plan != null) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text('Faltan ${plan.missing.length} archivos (${formatBytes(plan.bytes)}) · '
                  '${plan.folders} carpetas a crear · ${plan.same} ya están iguales',
                  style: t.titleSmall),
            ),
            for (final m in plan.missing.take(200))
              ListTile(
                dense: true,
                leading: Icon(iconFor(m.file)),
                title: Text(m.file.name, overflow: TextOverflow.ellipsis),
                subtitle: Text(m.path.isEmpty ? '/' : m.path, overflow: TextOverflow.ellipsis),
                trailing: Text(formatBytes(m.file.size)),
              ),
          ],
        ]),
      ),
      bottomNavigationBar: plan == null || plan.missing.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: FilledButton.icon(
                  icon: const Icon(Icons.copy_all),
                  label: Text('Copiar lo que falta (${plan.missing.length} · ${formatBytes(plan.bytes)})'),
                  onPressed: () async {
                    await runWithReport(context, 'Copiando al destino', _apply,
                        (r) => 'Espejo listo: ${r.total} archivos copiados');
                    _compare();
                  },
                ),
              ),
            ),
    );
  }
}
