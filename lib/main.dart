import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'accounts.dart';
import 'actions.dart';
import 'analyzer.dart';
import 'audit.dart';
import 'background.dart';
import 'history.dart';
import 'balancer.dart';
import 'auth/auth.dart' as auth;
import 'config.dart';
import 'drive_index.dart';
import 'explorer.dart';
import 'mirror.dart';
import 'evolution.dart';
import 'rules.dart';
import 'gmail.dart';
import 'offline.dart';
import 'side_tree.dart';
import 'platform/platform.dart' as platform;
import 'updates.dart';

const colorDrive = Color(0xFF1A73E8);
const colorTrash = Color(0xFFF29900);
const colorOthers = Color(0xFF188038);

Future<void> main() async {
  usePathUrlStrategy();
  WidgetsFlutterBinding.ensureInitialized();
  // Web: al volver de Google, el acceso viene en la dirección.
  final pending = auth.consumeRedirectResult();
  await auth.initAuth();
  final store = AccountStore();
  await store.load();
  await Offline.load();
  Background.setup();
  runApp(MultiGDriveApp(store: store, pending: pending));
}

class MultiGDriveApp extends StatelessWidget {
  final AccountStore store;
  final auth.AuthResult? pending;
  const MultiGDriveApp({super.key, required this.store, this.pending});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF1A73E8);
    return MaterialApp(
      title: 'Multi G-DRIVE',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: ThemeData(colorSchemeSeed: seed, useMaterial3: true),
      darkTheme: ThemeData(
          colorSchemeSeed: seed, brightness: Brightness.dark, useMaterial3: true),
      home: HomePage(store: store, pending: pending),
    );
  }
}

class HomePage extends StatefulWidget {
  final AccountStore store;
  final auth.AuthResult? pending;
  const HomePage({super.key, required this.store, this.pending});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool _busy = false;
  StreamSubscription<auth.AuthResult>? _sub;
  List<ReleaseInfo> _releases = [];
  final IndexStore _indexes = IndexStore();

  AccountStore get store => widget.store;

  ReleaseInfo? get _newer {
    if (_releases.isEmpty) return null;
    final latest = _releases.first;
    return Updates.compare(latest.version, Config.appVersion) > 0 ? latest : null;
  }

  void _onIndexChange() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    DriveActions.store = store;
    DriveActions.indexes = _indexes;
    indexChanged.addListener(_onIndexChange);
    Offline.changed.addListener(_onIndexChange);
    // Android: la cuenta vuelve desde el navegador.
    _sub = auth.authResults.listen(
      (r) => _run(() async {
        final a = await store.addFromAuth(r);
        _snack('Cuenta conectada: ${a.email}');
      }),
      onError: (Object e) => _snack('Error: $e'),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (widget.pending != null) {
        await _run(() => store.addFromAuth(widget.pending!));
      } else {
        await _refreshAll();
      }
    });
    _indexes.loadAll(store.accounts.map((a) => a.email)).then((_) async {
      if (mounted) setState(() {});
      for (final a in List.of(store.accounts)) {
        if (_indexes.loaded.containsKey(a.email)) await _update(a, quiet: true);
      }
    });
    Updates.fetch().then((r) {
      if (mounted) setState(() => _releases = r);
    });
  }

  @override
  void dispose() {
    indexChanged.removeListener(_onIndexChange);
    Offline.changed.removeListener(_onIndexChange);
    _sub?.cancel();
    super.dispose();
  }

  void _snack(String text) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _run(Future<void> Function() task) async {
    setState(() => _busy = true);
    try {
      await task();
    } catch (e) {
      _snack('Error: $e');
    } finally {
      indexChanged.value++; // refresca la barra lateral
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refreshAll() => _run(() async {
        for (final a in List.of(store.accounts)) {
          await store.refreshQuota(a);
        }
        await Usage.record(store.accounts);
        _quotaAlert();
      });

  bool _alertShown = false;

  /// Aviso de cuota al abrir la app, si alguna cuenta supera el % configurado.
  void _quotaAlert() {
    if (_alertShown || !mounted) return;
    final over = store.accounts.where(store.overAlert).toList();
    if (over.isEmpty) return;
    _alertShown = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.warning_amber),
          title: const Text('Cuentas casi llenas'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
              children: [
            Text('Superan el ${store.alertPercent} % de uso:'),
            const SizedBox(height: 8),
            for (final a in over)
              Text('• ${a.title}: ${(a.quota!.ratio! * 100).round()} % '
                  '(libre ${formatBytes(a.quota!.free)})'),
            const SizedBox(height: 8),
            const Text('El Analizador te ayuda a encontrar qué limpiar.'),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Entendido')),
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                        builder: (_) => AnalyzerPage(accounts: store.accounts, indexes: _indexes)));
              },
              child: const Text('Abrir Analizador'),
            ),
          ],
        ),
      );
    });
  }

  Future<void> _addAccount() => _run(() async {
        final r = await auth.signInNewAccount();
        if (r != null) {
          final a = await store.addFromAuth(r);
          _snack('Cuenta conectada: ${a.email}');
        }
      });

  Future<void> _index(Account a) async {
    if (_indexes.progress.containsKey(a.email)) return;
    try {
      final idx = await _indexes.build(a.email, () => store.tokenFor(a), () {
        if (mounted) setState(() {});
      });
      _snack('${a.title}: ${idx.fileCount} archivos indexados');
    } catch (e) {
      _snack('${a.title}: no se pudo indexar ($e)');
    }
  }

  /// Actualiza el índice con los cambios; si no se puede, lo arma completo.
  Future<void> _update(Account a, {bool quiet = false}) async {
    if (_indexes.progress.containsKey(a.email)) return;
    final n = await _indexes.update(a.email, () => store.tokenFor(a), () {
      if (mounted) setState(() {});
    });
    if (n == null) {
      if (!quiet) await _index(a);
      return;
    }
    indexChanged.value++;
    if (!quiet) _snack(n == 0 ? '${a.title}: el índice ya estaba al día' : '${a.title}: $n cambios aplicados');
  }

  Future<void> _indexAll() async {
    for (final a in List.of(store.accounts)) {
      await _index(a);
    }
  }

  void _explore(Account a) {
    final idx = _indexes.loaded[a.email];
    if (idx == null) {
      _index(a);
      return;
    }
    Navigator.push(context,
        MaterialPageRoute<void>(builder: (_) => ExplorerPage(account: a, index: idx)));
  }

  void _openSearch() {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
          builder: (_) => SearchPage(accounts: store.accounts, indexes: _indexes)),
    );
  }

  String? _indexInfo(Account a) {
    final p = _indexes.progress[a.email];
    if (p != null) return 'Indexando… $p elementos leídos';
    final idx = _indexes.loaded[a.email];
    if (idx == null) return null;
    return 'Índice: ${idx.fileCount} archivos · ${_fmtDate(idx.date)}';
  }

  void _openUpdate(ReleaseInfo r) {
    final ext = platform.installerExtension();
    if (ext.isEmpty) {
      platform.reloadPage();
      return;
    }
    launchUrl(Uri.parse(r.assetEndingWith(ext) ?? r.htmlUrl),
        mode: LaunchMode.externalApplication);
  }

  void _showVersion() {
    final current = _releases.where((r) => r.version == Config.appVersion).firstOrNull;
    final newer = _newer;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Multi G-DRIVE v${Config.appVersion}'),
        content: SizedBox(
          width: 420,
          child: ListView(shrinkWrap: true, children: [
            if (current != null && current.date != null)
              Text('Publicada: ${_fmtDate(current.date!)}'),
            if (newer != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('Hay una versión nueva: v${newer.version}',
                    style: TextStyle(color: Theme.of(ctx).colorScheme.primary)),
              ),
            const SizedBox(height: 16),
            Text('Changelog', style: Theme.of(ctx).textTheme.titleMedium),
            if (_releases.isEmpty) const Text('Sin conexión y sin copia guardada.'),
            for (final r in _releases.take(15)) ...[
              const SizedBox(height: 10),
              Text('v${r.version}${r.date == null ? '' : ' · ${_fmtDate(r.date!)}'}',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              if (r.notes.isNotEmpty) Text(r.notes),
            ],
          ]),
        ),
        actions: [
          TextButton(
            onPressed: () => launchUrl(Uri.parse('${Config.repoUrl}/releases')),
            child: const Text('Ver en GitHub'),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cerrar')),
        ],
      ),
    );
  }

  Future<void> _showSettings() async {
    var value = store.alertPercent.toDouble();
    var daily = (await SharedPreferences.getInstance()).getBool(Background.enabledKey) ?? true;
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Ajustes'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('Avisar cuando una cuenta supere el ${value.round()} % de uso'),
            Slider(
              value: value,
              min: 50,
              max: 100,
              divisions: 10,
              label: '${value.round()} %',
              onChanged: (v) => setLocal(() => value = v),
            ),
            if (Background.supported)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Revisión diaria con la app cerrada'),
                subtitle: const Text('Notifica si alguna cuenta supera ese %'),
                value: daily,
                onChanged: (v) => setLocal(() => daily = v),
              ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
            FilledButton(
              onPressed: () async {
                await store.setAlertPercent(value.round());
                if (Background.supported) await Background.setEnabled(daily);
                if (ctx.mounted) Navigator.pop(ctx);
                if (mounted) setState(() {});
              },
              child: const Text('Guardar'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editAccount(Account a) async {
    final ctrl = TextEditingController(text: a.nickname);
    var color = a.color;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(a.email, style: Theme.of(ctx).textTheme.titleMedium),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: ctrl,
              decoration: const InputDecoration(
                  labelText: 'Apodo', hintText: 'Ej.: Personal, Trabajo, Fotos'),
            ),
            const SizedBox(height: 16),
            Wrap(spacing: 10, runSpacing: 10, children: [
              for (final c in accountColors)
                InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => setLocal(() => color = c),
                  child: CircleAvatar(
                    radius: 18,
                    backgroundColor: Color(c),
                    child: c == color ? const Icon(Icons.check, color: Colors.white) : null,
                  ),
                ),
            ]),
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true), child: const Text('Guardar')),
          ],
        ),
      ),
    );
    if (ok == true) {
      a.nickname = ctrl.text.trim();
      a.color = color;
      await _run(store.save);
    }
  }

  Future<void> _confirmRemove(Account a) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Quitar cuenta'),
        content: Text('¿Quitar ${a.email} de la app? No se borra nada de tu Drive.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Quitar')),
        ],
      ),
    );
    if (ok == true) {
      await _run(() async {
        await store.remove(a);
        await _indexes.remove(a.email);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final accounts = store.accounts;
    final quotas = accounts.where((a) => a.quota != null).map((a) => a.quota!);
    final total = Quota.sum(quotas);
    final alerts = accounts.where(store.overAlert).length;
    final newer = _newer;

    final header = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (newer != null)
        Card(
          color: Theme.of(context).colorScheme.primaryContainer,
          child: ListTile(
            leading: const Icon(Icons.system_update),
            title: Text('Hay una versión nueva (v${newer.version})'),
            trailing: FilledButton(
              onPressed: () => _openUpdate(newer),
              child: Text(platform.installerExtension().isEmpty ? 'Recargar' : 'Descargar'),
            ),
          ),
        ),
      if (!auth.configOk())
        const _Banner(
          icon: Icons.warning_amber,
          text: 'Faltan los datos de Google Cloud en esta compilación '
              '(Secrets del repo). Revisá la guía de E0.',
        ),
      if (auth.isWeb)
        const _Banner(
          icon: Icons.info_outline,
          text: 'Versión web limitada: el acceso a cada cuenta dura cerca de 1 hora '
              'y el índice no se guarda al cerrar la página.',
        ),
      if (auth.isWeb && _releases.isNotEmpty)
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Instalá la app completa (v${_releases.first.version})',
                  style: Theme.of(context).textTheme.titleSmall),
              const Text('Guarda las cuentas y el índice, sin reconectar cada hora.'),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final (label, ext, icon) in [
                  ('Android (APK)', '.apk', Icons.android),
                  ('Windows (instalador)', '.exe', Icons.desktop_windows),
                ])
                  if (_releases.first.assetEndingWith(ext) != null)
                    OutlinedButton.icon(
                      onPressed: () =>
                          launchUrl(Uri.parse(_releases.first.assetEndingWith(ext)!)),
                      icon: Icon(icon),
                      label: Text(label),
                    ),
              ]),
            ]),
          ),
        ),
      if (accounts.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 48),
          child: Text(
            'Todavía no hay cuentas.\nTocá "Agregar cuenta" para conectar la primera.',
            textAlign: TextAlign.center,
          ),
        )
      else ...[
        _TotalCard(
            count: accounts.length,
            quota: total,
            alerts: alerts,
            alertPercent: store.alertPercent,
            onIndexAll: _indexes.progress.isEmpty ? _indexAll : null),
        const _Legend(),
        if (accounts.length > 1)
          Padding(
            padding: const EdgeInsets.all(4),
            child: Text('Arrastrá ⠿ para ordenar las cuentas.',
                style: Theme.of(context).textTheme.bodySmall),
          ),
      ],
    ]);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Multi G-DRIVE'),
        actions: [
          TextButton(onPressed: _showVersion, child: Text('v${Config.appVersion}')),
          IconButton(
            tooltip: 'Balanceador de espacio',
            onPressed: accounts.length < 2
                ? null
                : () => Navigator.push(
                    context, MaterialPageRoute<void>(builder: (_) => const BalancerPage())),
            icon: const Icon(Icons.balance),
          ),
          IconButton(
            tooltip: 'Analizador',
            onPressed: accounts.isEmpty
                ? null
                : () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                          builder: (_) =>
                              AnalyzerPage(accounts: store.accounts, indexes: _indexes)),
                    ),
            icon: const Icon(Icons.insights),
          ),
          IconButton(
            tooltip: 'Buscar en todas las cuentas',
            onPressed: accounts.isEmpty ? null : _openSearch,
            icon: const Icon(Icons.search),
          ),
          IconButton(
            tooltip: 'Actualizar',
            onPressed: _busy || accounts.isEmpty ? null : _refreshAll,
            icon: const Icon(Icons.refresh),
          ),
          PopupMenuButton<String>(
            tooltip: 'Más',
            onSelected: (v) {
              if (v == 'ajustes') {
                _showSettings();
              } else if (v == 'auditoria') {
                Navigator.push(
                    context, MaterialPageRoute<void>(builder: (_) => const AuditPage()));
              } else if (v == 'gmail') {
                Navigator.push(
                    context, MaterialPageRoute<void>(builder: (_) => const GmailPage()));
              } else if (v == 'reglas') {
                Navigator.push(
                    context, MaterialPageRoute<void>(builder: (_) => const RulesPage()));
              } else if (v == 'evolucion') {
                Navigator.push(
                    context, MaterialPageRoute<void>(builder: (_) => const EvolutionPage()));
              } else if (v == 'espejo') {
                Navigator.push(
                    context, MaterialPageRoute<void>(builder: (_) => const MirrorPage()));
              } else if (v == 'historial') {
                Navigator.push(
                    context, MaterialPageRoute<void>(builder: (_) => const HistoryPage()));
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                  value: 'historial',
                  child: ListTile(leading: Icon(Icons.history), title: Text('Historial'))),
              PopupMenuItem(
                  value: 'espejo',
                  child: ListTile(leading: Icon(Icons.copy_all), title: Text('Espejo / respaldo'))),
              PopupMenuItem(
                  value: 'evolucion',
                  child: ListTile(leading: Icon(Icons.show_chart), title: Text('Evolución del uso'))),
              PopupMenuItem(
                  value: 'reglas',
                  child: ListTile(
                      leading: Icon(Icons.rule), title: Text('Reglas automáticas'))),
              PopupMenuItem(
                  value: 'gmail',
                  child: ListTile(
                      leading: Icon(Icons.mark_email_unread_outlined), title: Text('Gmail pesado'))),
              PopupMenuItem(
                  value: 'auditoria',
                  child: ListTile(
                      leading: Icon(Icons.policy_outlined), title: Text('Auditoría de compartidos'))),
              PopupMenuItem(
                  value: 'ajustes',
                  child: ListTile(leading: Icon(Icons.settings), title: Text('Ajustes'))),
            ],
          ),
        ],
        bottom: _busy
            ? const PreferredSize(
                preferredSize: Size.fromHeight(4), child: LinearProgressIndicator())
            : null,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy || !auth.configOk() ? null : _addAccount,
        icon: const Icon(Icons.person_add_alt_1),
        label: const Text('Agregar cuenta'),
      ),
      drawer: sidebarDrawer(context),
      body: withSidebar(context, ReorderableListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        header: header,
        buildDefaultDragHandles: false,
        itemCount: accounts.length,
        onReorder: (o, n) => _run(() => store.reorder(o, n)),
        itemBuilder: (context, i) {
          final a = accounts[i];
          return _AccountCard(
            key: ValueKey(a.email),
            index: i,
            account: a,
            alert: store.overAlert(a),
            alertPercent: store.alertPercent,
            onEdit: () => _editAccount(a),
            onRemove: () => _confirmRemove(a),
            onReconnect: _addAccount,
            indexInfo: _indexInfo(a),
            indexing: _indexes.progress.containsKey(a.email),
            indexed: _indexes.loaded.containsKey(a.email),
            onExplore: () => _explore(a),
            onIndex: () => _update(a),
            onFullIndex: () => _index(a),
            offlineCount: Offline.of(a.email).length,
            onOffline: () => Navigator.push(context,
                MaterialPageRoute<void>(builder: (_) => OfflinePage(account: a))),
          );
        },
      )),
    );
  }
}

String _fmtDate(DateTime d) {
  final l = d.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(l.day)}/${two(l.month)}/${l.year} ${two(l.hour)}:${two(l.minute)}';
}

class _Banner extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Banner({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) => Card(
        color: Theme.of(context).colorScheme.secondaryContainer,
        child: ListTile(leading: Icon(icon), title: Text(text)),
      );
}

/// Barra apilada: Drive · Papelera · Gmail y Fotos · Libre.
class UsageBar extends StatelessWidget {
  final Quota quota;
  final double height;
  const UsageBar({super.key, required this.quota, this.height = 10});

  @override
  Widget build(BuildContext context) {
    final q = quota;
    final total = q.limit ?? q.usage;
    if (total <= 0) return const SizedBox.shrink();
    final parts = <(int, Color)>[
      (q.driveWithoutTrash, colorDrive),
      (q.inTrash, colorTrash),
      (q.others, colorOthers),
      (q.free ?? 0, Theme.of(context).colorScheme.surfaceContainerHighest),
    ];
    return ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: SizedBox(
        height: height,
        child: Row(children: [
          for (final (value, color) in parts)
            if (value > 0)
              Expanded(
                flex: (value * 1000 / total).round().clamp(1, 1000).toInt(),
                child: ColoredBox(color: color),
              ),
        ]),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) {
    Widget item(Color c, String t) => Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text(t, style: Theme.of(context).textTheme.bodySmall),
        ]);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
      child: Wrap(spacing: 16, runSpacing: 4, children: [
        item(colorDrive, 'Drive'),
        item(colorTrash, 'Papelera'),
        item(colorOthers, 'Gmail y Fotos'),
        item(Theme.of(context).colorScheme.surfaceContainerHighest, 'Libre'),
      ]),
    );
  }
}

class _TotalCard extends StatelessWidget {
  final int count;
  final Quota quota;
  final int alerts;
  final int alertPercent;
  final VoidCallback? onIndexAll;
  const _TotalCard(
      {required this.count,
      required this.quota,
      required this.alerts,
      required this.alertPercent,
      this.onIndexAll});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final ratio = quota.ratio;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Total · $count ${count == 1 ? 'cuenta' : 'cuentas'}', style: t.titleMedium),
          const SizedBox(height: 8),
          Text(
              '${formatBytes(quota.usage)} de ${formatBytes(quota.limit)}'
              '${ratio == null ? '' : ' · ${(ratio * 100).round()} %'}',
              style: t.headlineSmall),
          if (quota.free != null) Text('Libre: ${formatBytes(quota.free)}', style: t.bodyMedium),
          const SizedBox(height: 10),
          UsageBar(quota: quota, height: 14),
          if (alerts > 0) ...[
            const SizedBox(height: 10),
            Row(children: [
              Icon(Icons.warning_amber, color: Theme.of(context).colorScheme.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text('$alerts ${alerts == 1 ? 'cuenta supera' : 'cuentas superan'} '
                    'el $alertPercent % de uso'),
              ),
            ]),
          ],
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: onIndexAll,
              icon: const Icon(Icons.manage_search),
              label: const Text('Indexar todas'),
            ),
          ),
        ]),
      ),
    );
  }
}

class _AccountCard extends StatelessWidget {
  final int index;
  final Account account;
  final bool alert;
  final int alertPercent;
  final VoidCallback onEdit;
  final VoidCallback onRemove;
  final VoidCallback onReconnect;
  final String? indexInfo;
  final bool indexing;
  final bool indexed;
  final VoidCallback onExplore;
  final VoidCallback onIndex;
  final VoidCallback onFullIndex;
  final int offlineCount;
  final VoidCallback onOffline;
  const _AccountCard({
    super.key,
    required this.index,
    required this.account,
    required this.alert,
    required this.alertPercent,
    required this.onEdit,
    required this.onRemove,
    required this.onReconnect,
    this.indexInfo,
    required this.indexing,
    required this.indexed,
    required this.onExplore,
    required this.onIndex,
    required this.onFullIndex,
    required this.offlineCount,
    required this.onOffline,
  });

  @override
  Widget build(BuildContext context) {
    final a = account;
    final q = a.quota;
    final ratio = q?.ratio;
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Color(a.color), width: 2),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            ReorderableDragStartListener(
              index: index,
              child: const Padding(
                padding: EdgeInsets.all(8),
                child: Icon(Icons.drag_indicator),
              ),
            ),
            CircleAvatar(
              radius: 16,
              backgroundColor: Color(a.color),
              child: Text(a.title.characters.first.toUpperCase(),
                  style: const TextStyle(color: Colors.white)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(a.title, style: t.titleMedium, overflow: TextOverflow.ellipsis),
                if (a.nickname.isNotEmpty || a.name.isNotEmpty)
                  Text(a.nickname.isNotEmpty ? a.email : a.name,
                      style: t.bodySmall, overflow: TextOverflow.ellipsis),
              ]),
            ),
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'editar') {
                  onEdit();
                } else if (v == 'quitar') {
                  onRemove();
                } else {
                  onReconnect();
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'editar', child: Text('Apodo y color')),
                PopupMenuItem(value: 'reconectar', child: Text('Volver a conectar')),
                PopupMenuItem(value: 'quitar', child: Text('Quitar de la app')),
              ],
            ),
          ]),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (a.error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(a.error!, style: t.bodySmall?.copyWith(color: scheme.error)),
                ),
              if (q != null) ...[
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                    child: Text(
                        '${formatBytes(q.usage)} de ${formatBytes(q.limit)}'
                        '${ratio == null ? '' : ' · ${(ratio * 100).round()} %'}',
                        style: t.titleSmall),
                  ),
                  if (alert)
                    Tooltip(
                      message: 'Supera el $alertPercent % de uso',
                      child: Icon(Icons.warning_amber, color: scheme.error),
                    ),
                ]),
                const SizedBox(height: 6),
                UsageBar(quota: q),
                const SizedBox(height: 8),
                Wrap(spacing: 16, runSpacing: 4, children: [
                  Text('Drive: ${formatBytes(q.driveWithoutTrash)}'),
                  Text('Papelera: ${formatBytes(q.inTrash)}'),
                  Text('Gmail y Fotos: ${formatBytes(q.others)}'),
                  if (q.free != null) Text('Libre: ${formatBytes(q.free)}'),
                ]),
              ],
              const SizedBox(height: 8),
              if (indexInfo != null) Text(indexInfo!, style: t.bodySmall),
              if (indexing) const LinearProgressIndicator(minHeight: 3),
              Wrap(spacing: 8, children: [
                FilledButton.tonalIcon(
                  onPressed: indexing ? null : onExplore,
                  icon: const Icon(Icons.folder_open),
                  label: Text(indexed ? 'Explorar' : 'Indexar y explorar'),
                ),
                if (indexed)
                  TextButton.icon(
                    onPressed: indexing ? null : onIndex,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Actualizar índice'),
                  ),
                if (indexed)
                  TextButton(
                    onPressed: indexing ? null : onFullIndex,
                    child: const Text('Reindexar todo'),
                  ),
                if (Offline.supported)
                  TextButton.icon(
                    onPressed: onOffline,
                    icon: const Icon(Icons.offline_pin_outlined),
                    label: Text('Sin conexión ($offlineCount)'),
                  ),
              ]),
            ]),
          ),
        ]),
      ),
    );
  }
}
