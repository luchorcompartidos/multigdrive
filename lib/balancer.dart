import 'package:flutter/material.dart';

import 'accounts.dart';
import 'actions.dart';
import 'drive_index.dart';
import 'explorer.dart';
import 'side_tree.dart';

/// Una propuesta: mover [item] de [from] a [to].
class Move {
  final Account from;
  final AccountIndex index;
  final DriveItem item;
  Account to;
  bool on = true;
  Move(this.from, this.index, this.item, this.to);

  String get path =>
      index.pathTo(index.parentOf[item.id] ?? topId).map((p) => p.name).join(' / ');
}

/// Forma de pasar algo de una cuenta a otra.
enum MoveMethod { copy, transfer }

/// Hook para que otras entregas sumen métodos (E16: pasar la propiedad).
typedef MoveRunner = Future<CopyReport> Function(
    Account from, DriveItem item, Account to, void Function(CopyReport) progress);

final Map<MoveMethod, MoveRunner> moveRunners = {
  MoveMethod.copy: (from, item, to, progress) async {
    if (item.isFolder) {
      return FolderOps.copyFolder(from, item, to, move: true, progress: progress);
    }
    final r = CopyReport()..total = 1;
    progress(r);
    try {
      await DriveActions.copyToAccount(from, item, to, move: true);
    } catch (_) {
      r.failed.add(item.name);
    }
    r.done = 1;
    progress(r);
    return r;
  },
  // E16: mover sin duplicar (pasar la propiedad entre cuentas personales).
  MoveMethod.transfer: (from, item, to, progress) =>
      DriveActions.transferToAccount(from, item, to, progress: progress),
};

const moveMethodNames = {
  MoveMethod.copy: 'Copiar y mandar el original a la papelera',
  MoveMethod.transfer: 'Pasar la propiedad (rápido, conserva links)',
};

/// Balanceador: propone qué mover para dejar todas las cuentas debajo de un % de uso.
class BalancerPage extends StatefulWidget {
  const BalancerPage({super.key});

  @override
  State<BalancerPage> createState() => _BalancerPageState();
}

class _BalancerPageState extends State<BalancerPage> {
  late double _target = DriveActions.store.alertPercent.clamp(50, 95).toDouble();
  MoveMethod _method =
      moveRunners.containsKey(MoveMethod.transfer) ? MoveMethod.transfer : MoveMethod.copy;
  List<Move> _plan = [];
  List<String> _notes = [];

  List<Account> get _accounts =>
      DriveActions.store.accounts.where((a) => a.quota?.limit != null).toList();

  @override
  void initState() {
    super.initState();
    _compute();
  }

  /// Arma la propuesta: de las cuentas por encima del objetivo, toma carpetas y archivos
  /// grandes (sin repetir uno que esté dentro de otro) y los asigna a las cuentas con lugar.
  void _compute() {
    final ratio = _target / 100;
    final cap = <String, int>{}; // espacio que puede recibir cada cuenta sin pasar el objetivo
    for (final a in _accounts) {
      final q = a.quota!;
      cap[a.email] = (q.limit! * ratio - q.usage).floor();
    }
    final plan = <Move>[];
    final notes = <String>[];
    final full = _accounts.where((a) => cap[a.email]! < 0).toList()
      ..sort((x, y) => cap[x.email]!.compareTo(cap[y.email]!));
    for (final a in full) {
      var need = -cap[a.email]!;
      final idx = DriveActions.indexes.loaded[a.email];
      if (idx == null) {
        notes.add('${a.title}: indexala para poder proponer qué mover.');
        continue;
      }
      final picked = <String>{};
      final candidates = idx.items.values
          .where((i) =>
              !i.isVirtual && i.mine && !i.trashed && i.total >= 20 * 1024 * 1024 && i.id != idx.rootId)
          .toList()
        ..sort((x, y) => y.total.compareTo(x.total));
      for (final c in candidates) {
        if (need <= 0) break;
        final chain = idx.pathTo(c.id).map((p) => p.id).toSet();
        if (chain.first != idx.rootId) continue; // solo lo que está en Mi unidad
        if (picked.any(chain.contains)) continue; // ya se mueve una carpeta que lo contiene
        if (picked.any((p) => idx.pathTo(p).any((x) => x.id == c.id))) continue; // contiene algo elegido
        // no mover algo mucho más grande que lo necesario si hay opciones más chicas
        if (c.total > need * 3 && candidates.any((o) => o.total >= need && o.total < c.total)) {
          continue;
        }
        final dests = _accounts.where((d) => d.email != a.email && cap[d.email]! >= c.total).toList()
          ..sort((x, y) => cap[y.email]!.compareTo(cap[x.email]!));
        if (dests.isEmpty) continue;
        final to = dests.first;
        plan.add(Move(a, idx, c, to));
        picked.add(c.id);
        cap[to.email] = cap[to.email]! - c.total;
        need -= c.total;
      }
      if (need > 0) {
        notes.add('${a.title}: con lo que hay lugar en las otras cuentas faltan '
            '${formatBytes(need)} para llegar al ${_target.round()} %.');
      }
    }
    if (full.isEmpty) notes.add('Todas las cuentas están debajo del ${_target.round()} %.');
    setState(() {
      _plan = plan;
      _notes = notes;
    });
  }

  /// Uso estimado de cada cuenta si se aplica la propuesta.
  Map<String, int> _after() {
    final m = {for (final a in _accounts) a.email: a.quota!.usage};
    for (final p in _plan.where((p) => p.on)) {
      m[p.from.email] = m[p.from.email]! - p.item.total;
      m[p.to.email] = m[p.to.email]! + p.item.total;
    }
    return m;
  }

  Future<void> _apply() async {
    final moves = _plan.where((p) => p.on).toList();
    final total = moves.fold<int>(0, (s, p) => s + p.item.total);
    if (!await confirm(
        context,
        'Aplicar balanceo',
        'Se mueven ${moves.length} elementos (${formatBytes(total)}) entre cuentas.\n'
            'Método: ${moveMethodNames[_method]}.',
        'Aplicar')) {
      return;
    }
    if (!mounted) return;
    final runner = moveRunners[_method]!;
    await runWithReport(context, 'Balanceando cuentas', (progress) async {
      final all = CopyReport();
      for (final m in moves) {
        final base = all.done;
        final r = await runner(m.from, m.item, m.to, (r) {
          all.total = base + r.total;
          all.done = base + r.done;
          progress(all);
        });
        all.failed.addAll(r.failed);
        all.done = base + r.total;
        all.total = all.done;
        progress(all);
      }
      return all;
    }, (r) => 'Balanceo terminado (${moves.length} movimientos)');
    for (final a in DriveActions.store.accounts) {
      await DriveActions.store.refreshQuota(a);
    }
    indexChanged.value++;
    if (mounted) _compute();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final after = _after();
    final selected = _plan.where((p) => p.on).toList();
    final bytes = selected.fold<int>(0, (s, p) => s + p.item.total);
    return Scaffold(
      appBar: AppBar(title: const Text('Balanceador de espacio'), actions: [sidebarButton(context)]),
      drawer: sidebarDrawer(context),
      body: withSidebar(
        context,
        ListView(padding: const EdgeInsets.only(bottom: 96), children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Text('Dejar todas las cuentas debajo del ${_target.round()} % de uso',
                style: t.titleSmall),
          ),
          Slider(
            value: _target,
            min: 50,
            max: 95,
            divisions: 9,
            label: '${_target.round()} %',
            onChanged: (v) => setState(() => _target = v),
            onChangeEnd: (_) => _compute(),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: DropdownButton<MoveMethod>(
              value: _method,
              isExpanded: true,
              items: [
                for (final m in moveRunners.keys)
                  DropdownMenuItem(value: m, child: Text(moveMethodNames[m]!)),
              ],
              onChanged: (v) => setState(() => _method = v ?? _method),
            ),
          ),
          const SizedBox(height: 8),
          for (final a in _accounts)
            ListTile(
              dense: true,
              leading: CircleAvatar(radius: 8, backgroundColor: Color(a.color)),
              title: Text(a.title),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(children: [
                  Expanded(
                      child: LinearProgressIndicator(
                          value: (a.quota!.usage / a.quota!.limit!).clamp(0, 1).toDouble(),
                          minHeight: 6)),
                  const SizedBox(width: 6),
                  const Icon(Icons.arrow_forward, size: 14),
                  const SizedBox(width: 6),
                  Expanded(
                      child: LinearProgressIndicator(
                          value: (after[a.email]! / a.quota!.limit!).clamp(0, 1).toDouble(),
                          minHeight: 6,
                          color: Color(a.color))),
                ]),
              ),
              trailing: Text('${(a.quota!.usage * 100 / a.quota!.limit!).round()} % → '
                  '${(after[a.email]! * 100 / a.quota!.limit!).round()} %'),
            ),
          for (final n in _notes)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Row(children: [
                const Icon(Icons.info_outline, size: 18),
                const SizedBox(width: 8),
                Expanded(child: Text(n, style: t.bodySmall)),
              ]),
            ),
          const Divider(),
          if (_plan.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Text('Propuesta: ${_plan.length} movimientos. Podés destildar o cambiar el destino.',
                  style: t.titleSmall),
            ),
          for (final p in _plan)
            CheckboxListTile(
              value: p.on,
              onChanged: (v) => setState(() => p.on = v ?? false),
              secondary: Icon(iconFor(p.item)),
              title: Text(p.item.name, overflow: TextOverflow.ellipsis),
              subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${formatBytes(p.item.total)} · ${p.from.title} · ${p.path}',
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                DropdownButton<String>(
                  value: p.to.email,
                  isDense: true,
                  items: [
                    for (final a in _accounts)
                      if (a.email != p.from.email)
                        DropdownMenuItem(value: a.email, child: Text('→ ${a.title}')),
                  ],
                  onChanged: (v) => setState(() =>
                      p.to = _accounts.firstWhere((a) => a.email == v, orElse: () => p.to)),
                ),
              ]),
            ),
        ]),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton.icon(
            icon: const Icon(Icons.balance),
            label: Text('Aplicar ${selected.length} movimientos (${formatBytes(bytes)})'),
            onPressed: selected.isEmpty ? null : _apply,
          ),
        ),
      ),
    );
  }
}
