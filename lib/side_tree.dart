import 'package:flutter/material.dart';

import 'accounts.dart';
import 'actions.dart';
import 'drive_index.dart';
import 'explorer.dart';

const sidebarBreakpoint = 900.0;
const sidebarWidth = 300.0;

bool isWide(BuildContext context) => MediaQuery.sizeOf(context).width >= sidebarBreakpoint;

/// Envuelve el cuerpo de una pantalla: en pantallas anchas suma la barra lateral fija.
Widget withSidebar(BuildContext context, Widget body) {
  if (!isWide(context)) return body;
  return Row(children: [
    const SizedBox(width: sidebarWidth, child: SideTree()),
    const VerticalDivider(width: 1),
    Expanded(child: body),
  ]);
}

/// En pantallas angostas, la barra lateral va como menú deslizable.
Widget? sidebarDrawer(BuildContext context) => isWide(context)
    ? null
    : const Drawer(width: sidebarWidth, child: SafeArea(child: SideTree(inDrawer: true)));

/// Botón para abrir la barra lateral en pantallas angostas (cuando el AppBar muestra "volver").
Widget sidebarButton(BuildContext context) => isWide(context)
    ? const SizedBox.shrink()
    : Builder(
        builder: (ctx) => IconButton(
          tooltip: 'Árbol de cuentas',
          icon: const Icon(Icons.account_tree_outlined),
          onPressed: () => Scaffold.of(ctx).openDrawer(),
        ),
      );

/// Árbol de todas las cuentas, con cuotas y tamaño de cada carpeta.
class SideTree extends StatefulWidget {
  final bool inDrawer;
  const SideTree({super.key, this.inDrawer = false});

  @override
  State<SideTree> createState() => _SideTreeState();
}

class _Row {
  final Account account;
  final AccountIndex index;
  final DriveItem item;
  final int depth;
  _Row(this.account, this.index, this.item, this.depth);
}

class _SideTreeState extends State<SideTree> {
  static final Set<String> _open = {}; // se recuerda entre pantallas

  String _key(Account a, String id) => '${a.email}|$id';

  void _toggle(String key) => setState(() => _open.contains(key) ? _open.remove(key) : _open.add(key));

  void _openFolder(Account a, AccountIndex idx, String id) {
    if (widget.inDrawer) Navigator.pop(context);
    Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => ExplorerPage(account: a, index: idx, startId: id)),
    );
  }

  void _addFolders(List<_Row> out, Account a, AccountIndex idx, String parentId, int depth) {
    final folders = (idx.children[parentId] ?? const <DriveItem>[])
        .where((f) => f.isFolder)
        .toList()
      ..sort((x, y) => y.total.compareTo(x.total));
    for (final f in folders) {
      out.add(_Row(a, idx, f, depth));
      if (_open.contains(_key(a, f.id))) _addFolders(out, a, idx, f.id, depth + 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: indexChanged,
      builder: (context, _, __) {
        final store = DriveActions.store;
        final indexes = DriveActions.indexes;
        final t = Theme.of(context).textTheme;
        final scheme = Theme.of(context).colorScheme;
        final total = Quota.sum(store.accounts.where((a) => a.quota != null).map((a) => a.quota!));
        final children = <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text('Cuentas', style: t.titleMedium),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
                'Total: ${formatBytes(total.usage)} de ${formatBytes(total.limit)}'
                '${total.ratio == null ? '' : ' · ${(total.ratio! * 100).round()} %'}',
                style: t.bodySmall),
          ),
          const Divider(height: 1),
        ];
        for (final a in store.accounts) {
          final q = a.quota;
          final key = _key(a, '__account');
          final open = _open.contains(key);
          final idx = indexes.loaded[a.email];
          children.add(InkWell(
            onTap: () => _toggle(key),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(open ? Icons.expand_more : Icons.chevron_right, size: 20),
                  const SizedBox(width: 4),
                  CircleAvatar(radius: 8, backgroundColor: Color(a.color)),
                  const SizedBox(width: 8),
                  Expanded(
                      child: Text(a.title, style: t.titleSmall, overflow: TextOverflow.ellipsis)),
                  if (DriveActions.store.overAlert(a))
                    Icon(Icons.warning_amber, size: 16, color: scheme.error),
                ]),
                if (q != null) ...[
                  const SizedBox(height: 4),
                  Padding(
                    padding: const EdgeInsets.only(left: 24),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(
                          '${formatBytes(q.usage)} de ${formatBytes(q.limit)}'
                          '${q.ratio == null ? '' : ' · ${(q.ratio! * 100).round()} %'}',
                          style: t.bodySmall),
                      if (q.ratio != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: LinearProgressIndicator(
                              value: q.ratio!.clamp(0, 1).toDouble(),
                              minHeight: 4,
                              color: Color(a.color)),
                        ),
                    ]),
                  ),
                ],
              ]),
            ),
          ));
          if (!open) continue;
          if (idx == null) {
            children.add(Padding(
              padding: const EdgeInsets.fromLTRB(48, 0, 12, 10),
              child: Text('Sin índice: indexala desde el panel para ver sus carpetas.',
                  style: t.bodySmall),
            ));
            continue;
          }
          final rows = <_Row>[];
          for (final top in [idx.root, idx.items[otherId]!, idx.items[trashId]!]) {
            rows.add(_Row(a, idx, top, 1));
            if (_open.contains(_key(a, top.id))) _addFolders(rows, a, idx, top.id, 2);
          }
          for (final r in rows) {
            final k = _key(r.account, r.item.id);
            final hasSub = (r.index.children[r.item.id] ?? const <DriveItem>[]).any((c) => c.isFolder);
            children.add(InkWell(
              onTap: () => _openFolder(r.account, r.index, r.item.id),
              child: Padding(
                padding: EdgeInsets.only(left: 12.0 + 16 * r.depth, right: 8),
                child: SizedBox(
                  height: 36,
                  child: Row(children: [
                    SizedBox(
                      width: 28,
                      child: hasSub
                          ? IconButton(
                              padding: EdgeInsets.zero,
                              iconSize: 18,
                              icon: Icon(_open.contains(k) ? Icons.expand_more : Icons.chevron_right),
                              onPressed: () => _toggle(k),
                            )
                          : null,
                    ),
                    Icon(iconFor(r.item), size: 18, color: scheme.primary),
                    const SizedBox(width: 6),
                    Expanded(
                        child: Text(r.item.name,
                            style: t.bodyMedium, overflow: TextOverflow.ellipsis)),
                    Text(formatBytes(r.item.total), style: t.bodySmall),
                  ]),
                ),
              ),
            ));
          }
          children.add(const SizedBox(height: 6));
        }
        if (store.accounts.isEmpty) {
          children.add(const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Todavía no hay cuentas conectadas.'),
          ));
        }
        return ListView(children: children);
      },
    );
  }
}
