import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'accounts.dart';
import 'actions.dart';
import 'analyzer.dart';
import 'balancer.dart';
import 'drive_index.dart';
import 'explorer.dart';
import 'side_tree.dart';

const _types = [
  'Todos', 'Imágenes', 'Videos', 'Audio', 'PDF', 'Documentos', 'Planillas', 'Presentaciones',
  'Comprimidos', 'Instaladores', 'Otros',
];

/// Una regla: qué archivos (filtro) y qué hacer con ellos.
class Rule {
  String name;
  String? fromEmail; // null = todas las cuentas
  String type;
  int minMb;
  int olderYears; // 0 = cualquier fecha
  String action; // trash | move
  String? toEmail;

  Rule({
    required this.name,
    this.fromEmail,
    this.type = 'Todos',
    this.minMb = 100,
    this.olderYears = 2,
    this.action = 'trash',
    this.toEmail,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'from': fromEmail,
        'type': type,
        'minMb': minMb,
        'olderYears': olderYears,
        'action': action,
        'to': toEmail,
      };

  factory Rule.fromJson(Map<String, dynamic> j) => Rule(
        name: j['name'] as String,
        fromEmail: j['from'] as String?,
        type: (j['type'] as String?) ?? 'Todos',
        minMb: (j['minMb'] as num?)?.toInt() ?? 0,
        olderYears: (j['olderYears'] as num?)?.toInt() ?? 0,
        action: (j['action'] as String?) ?? 'trash',
        toEmail: j['to'] as String?,
      );

  String describe(String Function(String) who) => [
        type == 'Todos' ? 'Archivos' : type,
        if (minMb > 0) 'de más de $minMb MB',
        if (olderYears > 0) 'sin cambios hace más de $olderYears ${olderYears == 1 ? 'año' : 'años'}',
        fromEmail == null ? 'en todas las cuentas' : 'en ${who(fromEmail!)}',
        action == 'trash' ? '→ papelera' : '→ pasar a ${toEmail == null ? '?' : who(toEmail!)}',
      ].join(' ');

  /// Archivos que cumplen la regla (de las cuentas indexadas).
  List<FileRef> matches() {
    final limit = olderYears == 0
        ? null
        : DateTime.now().subtract(Duration(days: 365 * olderYears)).millisecondsSinceEpoch;
    final out = <FileRef>[];
    for (final a in DriveActions.store.accounts) {
      if (fromEmail != null && a.email != fromEmail) continue;
      if (action == 'move' && a.email == toEmail) continue;
      final idx = DriveActions.indexes.loaded[a.email];
      if (idx == null) continue;
      for (final it in idx.items.values) {
        if (it.isFolder || it.isVirtual || !it.mine || it.trashed) continue;
        if (it.size < minMb * 1024 * 1024) continue;
        if (limit != null && (it.modified == 0 || it.modified > limit)) continue;
        if (type != 'Todos' && typeOf(it) != type) continue;
        out.add(FileRef(a, idx, it));
      }
    }
    out.sort((x, y) => y.item.quota.compareTo(x.item.quota));
    return out;
  }
}

class Rules {
  static const _key = 'mgd_rules';
  static final List<Rule> list = [];

  static Future<void> load() async {
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    list.clear();
    if (raw == null) return;
    try {
      for (final j in jsonDecode(raw) as List) {
        list.add(Rule.fromJson(j as Map<String, dynamic>));
      }
    } catch (_) {}
  }

  static Future<void> save() async => (await SharedPreferences.getInstance())
      .setString(_key, jsonEncode(list.map((r) => r.toJson()).toList()));
}

String _who(String email) {
  for (final a in DriveActions.store.accounts) {
    if (a.email == email) return a.title;
  }
  return email;
}

/// Pantalla de reglas automáticas.
class RulesPage extends StatefulWidget {
  const RulesPage({super.key});

  @override
  State<RulesPage> createState() => _RulesPageState();
}

class _RulesPageState extends State<RulesPage> {
  @override
  void initState() {
    super.initState();
    Rules.load().then((_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _edit([Rule? r]) async {
    final rule = r ??
        Rule(name: 'Regla ${Rules.list.length + 1}', type: 'Videos', minMb: 1024, olderYears: 2);
    final accounts = DriveActions.store.accounts;
    final name = TextEditingController(text: rule.name);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(r == null ? 'Nueva regla' : 'Editar regla'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              TextField(controller: name, decoration: const InputDecoration(labelText: 'Nombre')),
              const SizedBox(height: 12),
              DropdownButton<String>(
                isExpanded: true,
                value: rule.type,
                items: [for (final t in _types) DropdownMenuItem(value: t, child: Text('Tipo: $t'))],
                onChanged: (v) => setLocal(() => rule.type = v ?? rule.type),
              ),
              DropdownButton<int>(
                isExpanded: true,
                value: rule.minMb,
                items: [
                  for (final mb in [0, 10, 50, 100, 500, 1024, 2048])
                    DropdownMenuItem(
                        value: mb,
                        child: Text(mb == 0 ? 'Cualquier tamaño' : 'Más de ${mb >= 1024 ? '${mb ~/ 1024} GB' : '$mb MB'}')),
                ],
                onChanged: (v) => setLocal(() => rule.minMb = v ?? rule.minMb),
              ),
              DropdownButton<int>(
                isExpanded: true,
                value: rule.olderYears,
                items: [
                  for (final y in [0, 1, 2, 3, 5])
                    DropdownMenuItem(
                        value: y,
                        child: Text(y == 0 ? 'Cualquier fecha' : 'Sin cambios hace más de $y ${y == 1 ? 'año' : 'años'}')),
                ],
                onChanged: (v) => setLocal(() => rule.olderYears = v ?? rule.olderYears),
              ),
              DropdownButton<String?>(
                isExpanded: true,
                value: rule.fromEmail,
                items: [
                  const DropdownMenuItem<String?>(value: null, child: Text('En todas las cuentas')),
                  for (final a in accounts)
                    DropdownMenuItem<String?>(value: a.email, child: Text('En ${a.title}')),
                ],
                onChanged: (v) => setLocal(() => rule.fromEmail = v),
              ),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'trash', label: Text('Papelera')),
                  ButtonSegment(value: 'move', label: Text('Pasar a cuenta')),
                ],
                selected: {rule.action},
                onSelectionChanged: (v) => setLocal(() {
                  rule.action = v.first;
                  if (rule.action == 'move' && rule.toEmail == null && accounts.isNotEmpty) {
                    rule.toEmail = accounts.last.email;
                  }
                }),
              ),
              if (rule.action == 'move')
                DropdownButton<String>(
                  isExpanded: true,
                  value: rule.toEmail,
                  items: [
                    for (final a in accounts)
                      DropdownMenuItem(value: a.email, child: Text('Destino: ${a.title}')),
                  ],
                  onChanged: (v) => setLocal(() => rule.toEmail = v),
                ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Guardar')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    rule.name = name.text.trim().isEmpty ? rule.name : name.text.trim();
    if (r == null) Rules.list.add(rule);
    await Rules.save();
    if (mounted) setState(() {});
  }

  Future<void> _preview(Rule r) async {
    final found = r.matches();
    final bytes = found.fold<int>(0, (s, f) => s + f.item.quota);
    final to = r.toEmail == null
        ? null
        : DriveActions.store.accounts.where((a) => a.email == r.toEmail).firstOrNull;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(r.name),
        content: SizedBox(
          width: 480,
          height: 420,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(r.describe(_who)),
            const SizedBox(height: 8),
            Text('${found.length} archivos · ${formatBytes(bytes)}',
                style: Theme.of(ctx).textTheme.titleSmall),
            const Divider(),
            Expanded(
              child: ListView(children: [
                for (final f in found.take(200))
                  ListTile(
                    dense: true,
                    leading: Icon(iconFor(f.item), color: Color(f.account.color)),
                    title: Text(f.item.name, overflow: TextOverflow.ellipsis),
                    subtitle: Text('${f.account.title} · ${f.path}', maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: Text(formatBytes(f.item.quota)),
                  ),
              ]),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cerrar')),
          FilledButton(
            onPressed: found.isEmpty || (r.action == 'move' && to == null) ? null : () => Navigator.pop(ctx, true),
            child: const Text('Aplicar'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    final pairs = [for (final f in found) (f.account, f.item)];
    if (r.action == 'trash') {
      await runBatch(context, r.name, pairs, (a, it) => DriveActions.setTrashed(a, it, true),
          done: 'Regla aplicada: a la papelera');
    } else {
      final runner = moveRunners[MoveMethod.transfer] ?? moveRunners[MoveMethod.copy]!;
      await runBatch(context, r.name, pairs, (a, it) async {
        final rep = await runner(a, it, to!, (_) {});
        if (rep.failed.isNotEmpty) throw Exception(rep.failed.first);
      }, done: 'Regla aplicada: pasados a ${to!.title}');
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Reglas automáticas'), actions: [sidebarButton(context)]),
      drawer: sidebarDrawer(context),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(),
        icon: const Icon(Icons.add),
        label: const Text('Nueva regla'),
      ),
      body: withSidebar(
        context,
        ListView(padding: const EdgeInsets.only(bottom: 96), children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text('Una regla elige archivos por tipo, tamaño, antigüedad y cuenta, y los manda a la '
                'papelera o los pasa a otra cuenta. Siempre ves la lista antes de aplicar. '
                'Usa el índice: actualizalo antes para que esté al día.'),
          ),
          if (Rules.list.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('Todavía no hay reglas.', textAlign: TextAlign.center),
            ),
          for (final r in Rules.list)
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: ListTile(
                leading: Icon(r.action == 'trash' ? Icons.delete_sweep_outlined : Icons.swap_horiz),
                title: Text(r.name),
                subtitle: Text(r.describe(_who)),
                onTap: () => _preview(r),
                trailing: PopupMenuButton<String>(
                  onSelected: (v) async {
                    if (v == 'editar') {
                      await _edit(r);
                    } else {
                      Rules.list.remove(r);
                      await Rules.save();
                      if (mounted) setState(() {});
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'editar', child: Text('Editar')),
                    PopupMenuItem(value: 'borrar', child: Text('Borrar regla')),
                  ],
                ),
              ),
            ),
        ]),
      ),
    );
  }
}
