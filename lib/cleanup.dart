import 'package:flutter/material.dart';

import 'accounts.dart';
import 'actions.dart';
import 'analyzer.dart';
import 'drive_index.dart';
import 'explorer.dart';

enum KeepRule { oldest, newest, account }

/// Limpieza de duplicados: conserva una copia por grupo y manda el resto a la papelera.
class DuplicatesCleanupPage extends StatefulWidget {
  final List<DupGroup> groups;
  const DuplicatesCleanupPage({super.key, required this.groups});

  @override
  State<DuplicatesCleanupPage> createState() => _DuplicatesCleanupPageState();
}

class _DuplicatesCleanupPageState extends State<DuplicatesCleanupPage> {
  KeepRule _rule = KeepRule.oldest;
  String? _preferred; // email de la cuenta preferida
  late final Set<String> _selected = widget.groups.map((g) => g.md5).toSet();
  final Map<String, String> _manual = {}; // md5 → id elegido a mano

  List<Account> get _accounts {
    final seen = <String>{};
    return [
      for (final g in widget.groups)
        for (final f in g.files)
          if (seen.add(f.account.email)) f.account
    ];
  }

  FileRef _keeper(DupGroup g) {
    final manual = _manual[g.md5];
    if (manual != null) {
      for (final f in g.files) {
        if (f.item.id == manual) return f;
      }
    }
    final files = List.of(g.files);
    switch (_rule) {
      case KeepRule.oldest:
        files.sort((x, y) => x.item.modified.compareTo(y.item.modified));
      case KeepRule.newest:
        files.sort((x, y) => y.item.modified.compareTo(x.item.modified));
      case KeepRule.account:
        files.sort((x, y) {
          final px = x.account.email == _preferred ? 0 : 1;
          final py = y.account.email == _preferred ? 0 : 1;
          return px != py ? px - py : x.item.modified.compareTo(y.item.modified);
        });
    }
    return files.first;
  }

  List<(Account, DriveItem)> _toTrash() => [
        for (final g in widget.groups)
          if (_selected.contains(g.md5))
            for (final f in g.files)
              if (f.item.id != _keeper(g).item.id) (f.account, f.item)
      ];

  @override
  Widget build(BuildContext context) {
    final trash = _toTrash();
    final bytes = trash.fold<int>(0, (s, e) => s + e.$2.quota);
    final t = Theme.of(context).textTheme;
    final accounts = _accounts;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Limpiar duplicados'),
        actions: [
          TextButton(
            onPressed: () => setState(() => _selected.length == widget.groups.length
                ? _selected.clear()
                : _selected.addAll(widget.groups.map((g) => g.md5))),
            child: Text(_selected.length == widget.groups.length ? 'Ninguno' : 'Todos'),
          ),
        ],
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('¿Qué copia conservar en cada grupo?', style: t.titleSmall),
            const SizedBox(height: 6),
            Wrap(spacing: 8, runSpacing: 4, children: [
              ChoiceChip(
                  label: const Text('La más vieja'),
                  selected: _rule == KeepRule.oldest,
                  onSelected: (_) => setState(() => _rule = KeepRule.oldest)),
              ChoiceChip(
                  label: const Text('La más nueva'),
                  selected: _rule == KeepRule.newest,
                  onSelected: (_) => setState(() => _rule = KeepRule.newest)),
              ChoiceChip(
                  label: const Text('La de una cuenta'),
                  selected: _rule == KeepRule.account,
                  onSelected: (_) => setState(() {
                        _rule = KeepRule.account;
                        _preferred ??= accounts.isEmpty ? null : accounts.first.email;
                      })),
            ]),
            if (_rule == KeepRule.account)
              DropdownButton<String>(
                value: _preferred,
                isExpanded: true,
                items: [
                  for (final a in accounts)
                    DropdownMenuItem(value: a.email, child: Text('Preferir ${a.title}')),
                ],
                onChanged: (v) => setState(() => _preferred = v),
              ),
            const SizedBox(height: 4),
            Text('Tocá una copia para elegirla a mano como la que se conserva.',
                style: t.bodySmall),
          ]),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            itemCount: widget.groups.length,
            itemBuilder: (context, i) {
              final g = widget.groups[i];
              final keep = _keeper(g);
              final on = _selected.contains(g.md5);
              return Card(
                margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
                child: Column(children: [
                  CheckboxListTile(
                    value: on,
                    onChanged: (v) =>
                        setState(() => v == true ? _selected.add(g.md5) : _selected.remove(g.md5)),
                    title: Text(g.files.first.item.name, overflow: TextOverflow.ellipsis),
                    subtitle: Text('${g.files.length} copias · ${formatBytes(g.size)} c/u · '
                        'libera ${formatBytes(g.recoverable)}'),
                  ),
                  for (final f in g.files)
                    ListTile(
                      dense: true,
                      enabled: on,
                      leading: Icon(
                        f.item.id == keep.item.id ? Icons.check_circle : Icons.delete_outline,
                        color: f.item.id == keep.item.id ? Colors.green : Theme.of(context).colorScheme.error,
                      ),
                      title: Text(
                          '${f.account.title} · ${f.item.modified > 0 ? fmtDay(f.item.modifiedAt) : ''}'),
                      subtitle: Text(f.path, maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: Text(f.item.id == keep.item.id ? 'Conservar' : 'Papelera'),
                      onTap: () => setState(() => _manual[g.md5] = f.item.id),
                    ),
                ]),
              );
            },
          ),
        ),
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton.icon(
            icon: const Icon(Icons.cleaning_services_outlined),
            label: Text('Mandar ${trash.length} copias a la papelera (libera ${formatBytes(bytes)})'),
            onPressed: trash.isEmpty
                ? null
                : () async {
                    if (!await confirm(
                        context,
                        'Limpiar duplicados',
                        'Se mandan ${trash.length} copias a la papelera de sus cuentas y se conserva '
                            'una por grupo. Se pueden restaurar desde la Papelera.',
                        'Limpiar')) {
                      return;
                    }
                    if (!context.mounted) return;
                    await runBatch(context, 'Limpiando duplicados', trash,
                        (a, it) => DriveActions.setTrashed(a, it, true),
                        done: 'Copias enviadas a la papelera');
                    if (context.mounted) Navigator.pop(context);
                  },
          ),
        ),
      ),
    );
  }
}
