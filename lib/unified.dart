import 'package:flutter/material.dart';

import 'accounts.dart';
import 'actions.dart';
import 'drive_index.dart';
import 'explorer.dart';
import 'side_tree.dart';

/// Una carpeta de una cuenta (parte de una carpeta "fusionada").
class Spot {
  final Account account;
  final AccountIndex index;
  final String folderId;
  Spot(this.account, this.index, this.folderId);
}

/// Carpeta fusionada: carpetas del mismo nombre en distintas cuentas, vistas como una.
class MergedFolder {
  final String name;
  final List<Spot> spots;
  MergedFolder(this.name, this.spots);

  int get total => spots.fold<int>(0, (s, p) => s + (p.index.items[p.folderId]?.total ?? 0));
  int get files => spots.fold<int>(0, (s, p) => s + (p.index.items[p.folderId]?.files ?? 0));
  Set<Account> get accounts => spots.map((s) => s.account).toSet();
}

class FileHit {
  final Account account;
  final AccountIndex index;
  final DriveItem item;
  FileHit(this.account, this.index, this.item);
}

/// Contenido de una carpeta fusionada: subcarpetas (fusionadas por nombre) y archivos.
(List<MergedFolder>, List<FileHit>) mergedChildren(MergedFolder f) {
  final folders = <String, List<Spot>>{};
  final files = <FileHit>[];
  for (final s in f.spots) {
    for (final c in s.index.children[s.folderId] ?? const <DriveItem>[]) {
      if (c.trashed) continue;
      if (c.isFolder) {
        (folders[c.name] ??= []).add(Spot(s.account, s.index, c.id));
      } else {
        files.add(FileHit(s.account, s.index, c));
      }
    }
  }
  return ([for (final e in folders.entries) MergedFolder(e.key, e.value)], files);
}

/// Raíz de la unidad unificada: "Mi unidad" de todas las cuentas indexadas.
MergedFolder unifiedRoot([List<Account>? only]) => MergedFolder('Mi Drive total', [
      for (final a in only ?? DriveActions.store.accounts)
        if (DriveActions.indexes.loaded[a.email] != null)
          Spot(a, DriveActions.indexes.loaded[a.email]!, DriveActions.indexes.loaded[a.email]!.rootId)
    ]);

/// Capacidad sumada de un grupo de cuentas.
(int used, int? limit) capacityOf(Iterable<Account> accounts) {
  var used = 0;
  int? limit = 0;
  for (final a in accounts) {
    final q = a.quota;
    if (q == null) continue;
    used += q.usage;
    limit = (limit == null || q.limit == null) ? null : limit + q.limit!;
  }
  return (used, limit);
}

/// Hook para E24 (subir archivos): botón que recibe la carpeta fusionada actual.
typedef UnifiedUpload = Future<void> Function(BuildContext context, List<MergedFolder> path);
UnifiedUpload? unifiedUpload;

/// Unidad unificada: todas las cuentas como un solo disco.
class UnifiedPage extends StatefulWidget {
  final MergedFolder? root;
  final String title;
  const UnifiedPage({super.key, this.root, this.title = 'Mi Drive total'});

  @override
  State<UnifiedPage> createState() => _UnifiedPageState();
}

class _UnifiedPageState extends State<UnifiedPage> {
  late List<MergedFolder> _path = [widget.root ?? unifiedRoot()];
  SortBy _sort = SortBy.size;

  void _refresh() {
    if (!mounted) return;
    // reconstruir la ruta con los índices nuevos (por nombre)
    final names = _path.skip(1).map((p) => p.name).toList();
    final fresh = <MergedFolder>[
      widget.root == null
          ? unifiedRoot()
          : MergedFolder(widget.root!.name, [
              for (final s in widget.root!.spots)
                if (DriveActions.indexes.loaded[s.account.email] != null)
                  Spot(s.account, DriveActions.indexes.loaded[s.account.email]!, s.folderId)
            ])
    ];
    for (final n in names) {
      final next = mergedChildren(fresh.last).$1.where((f) => f.name == n).firstOrNull;
      if (next == null) break;
      fresh.add(next);
    }
    setState(() => _path = fresh);
  }

  @override
  void initState() {
    super.initState();
    indexChanged.addListener(_refresh);
  }

  @override
  void dispose() {
    indexChanged.removeListener(_refresh);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final here = _path.last;
    final (folders, files) = mergedChildren(here);
    switch (_sort) {
      case SortBy.size:
        folders.sort((a, b) => b.total.compareTo(a.total));
        files.sort((a, b) => b.item.size.compareTo(a.item.size));
      case SortBy.name:
        folders.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        files.sort((a, b) => a.item.name.toLowerCase().compareTo(b.item.name.toLowerCase()));
      case SortBy.date:
        files.sort((a, b) => b.item.modified.compareTo(a.item.modified));
    }
    final accounts = _path.first.accounts;
    final (used, limit) = capacityOf(accounts);
    final t = Theme.of(context).textTheme;
    final missing = DriveActions.store.accounts
        .where((a) => DriveActions.indexes.loaded[a.email] == null)
        .length;

    return PopScope(
      canPop: _path.length == 1,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _path = _path.sublist(0, _path.length - 1));
      },
      child: Scaffold(
        appBar: AppBar(title: Text(widget.title), actions: [
          sidebarButton(context),
          PopupMenuButton<SortBy>(
            icon: const Icon(Icons.sort),
            initialValue: _sort,
            onSelected: (v) => setState(() => _sort = v),
            itemBuilder: (_) => const [
              PopupMenuItem(value: SortBy.size, child: Text('Por tamaño')),
              PopupMenuItem(value: SortBy.name, child: Text('Por nombre')),
              PopupMenuItem(value: SortBy.date, child: Text('Por fecha')),
            ],
          ),
        ]),
        drawer: sidebarDrawer(context),
        floatingActionButton: unifiedUpload == null
            ? null
            : FloatingActionButton.extended(
                onPressed: () => unifiedUpload!(context, _path),
                icon: const Icon(Icons.upload_file),
                label: const Text('Subir'),
              ),
        body: withSidebar(
          context,
          Column(children: [
            Card(
              margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${formatBytes(used)} usados de ${formatBytes(limit)}'
                      '${limit == null ? '' : ' · libre ${formatBytes(limit - used)}'}',
                      style: t.titleMedium),
                  if (limit != null && limit > 0) ...[
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(5),
                      child: SizedBox(
                        height: 10,
                        child: Row(children: [
                          for (final a in accounts)
                            if (a.quota != null && a.quota!.usage > 0)
                              Expanded(
                                  flex: (a.quota!.usage * 1000 / limit).round().clamp(1, 1000).toInt(),
                                  child: ColoredBox(color: Color(a.color))),
                          if (limit - used > 0)
                            Expanded(
                                flex: ((limit - used) * 1000 / limit).round().clamp(1, 1000).toInt(),
                                child: ColoredBox(
                                    color: Theme.of(context).colorScheme.surfaceContainerHighest)),
                        ]),
                      ),
                    ),
                  ],
                  const SizedBox(height: 6),
                  Wrap(spacing: 10, runSpacing: 2, children: [
                    for (final a in accounts)
                      Row(mainAxisSize: MainAxisSize.min, children: [
                        CircleAvatar(radius: 5, backgroundColor: Color(a.color)),
                        const SizedBox(width: 4),
                        Text(a.title, style: t.bodySmall),
                      ]),
                  ]),
                  if (missing > 0)
                    Text('$missing cuenta(s) sin indexar no aparecen en esta vista.', style: t.bodySmall),
                ]),
              ),
            ),
            SizedBox(
              height: 44,
              child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8), children: [
                for (var i = 0; i < _path.length; i++) ...[
                  if (i > 0) const Icon(Icons.chevron_right, size: 18),
                  TextButton(
                    onPressed: () => setState(() => _path = _path.sublist(0, i + 1)),
                    child: Text(_path[i].name),
                  ),
                ],
              ]),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(children: [
                for (final f in folders)
                  ListTile(
                    leading: Icon(Icons.folder, color: Theme.of(context).colorScheme.primary),
                    title: Text(f.name, overflow: TextOverflow.ellipsis),
                    subtitle: Row(children: [
                      for (final a in f.accounts) ...[
                        CircleAvatar(radius: 5, backgroundColor: Color(a.color)),
                        const SizedBox(width: 3),
                      ],
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text('${f.files} archivos'
                            '${f.accounts.length > 1 ? ' · en ${f.accounts.length} cuentas' : ''}',
                            overflow: TextOverflow.ellipsis),
                      ),
                    ]),
                    trailing: Text(formatBytes(f.total)),
                    onTap: () => setState(() => _path = [..._path, f]),
                    onLongPress: f.spots.length == 1
                        ? () => showItemDetails(context, f.spots.first.account, f.spots.first.index,
                            f.spots.first.index.items[f.spots.first.folderId]!)
                        : null,
                  ),
                for (final h in files)
                  ListTile(
                    leading: Icon(iconFor(h.item), color: Color(h.account.color)),
                    title: Text(h.item.name, overflow: TextOverflow.ellipsis),
                    subtitle: Text('${h.account.title}'
                        '${h.item.modified > 0 ? ' · ${fmtDay(h.item.modifiedAt)}' : ''}'),
                    trailing: Text(formatBytes(h.item.size)),
                    onTap: () => showItemDetails(context, h.account, h.index, h.item),
                  ),
                if (folders.isEmpty && files.isEmpty)
                  const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('Carpeta vacía'))),
                const SizedBox(height: 80),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}
