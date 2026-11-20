import 'package:flutter/material.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:url_launcher/url_launcher.dart';

import 'accounts.dart';
import 'auth/auth.dart' as auth;
import 'config.dart';

Future<void> main() async {
  usePathUrlStrategy();
  WidgetsFlutterBinding.ensureInitialized();
  // Web: al volver de Google, el acceso viene en la dirección.
  final pending = auth.consumeRedirectResult();
  final store = AccountStore();
  await store.load();
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

  AccountStore get store => widget.store;

  bool get _configOk => auth.isWeb
      ? Config.webClientId.isNotEmpty
      : Config.desktopClientId.isNotEmpty && Config.desktopClientSecret.isNotEmpty;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (widget.pending != null) {
        await _run(() => store.addFromAuth(widget.pending!));
      } else {
        await _refreshAll();
      }
    });
  }

  Future<void> _run(Future<void> Function() task) async {
    setState(() => _busy = true);
    try {
      await task();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refreshAll() => _run(() async {
        for (final a in List.of(store.accounts)) {
          await store.refreshQuota(a);
        }
      });

  Future<void> _addAccount() => _run(() async {
        final r = await auth.signInNewAccount();
        if (r != null) {
          final a = await store.addFromAuth(r);
          if (mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text('Cuenta conectada: ${a.email}')));
          }
        }
      });

  void _showVersion() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Multi G-DRIVE v${Config.appVersion}'),
        content: const Text('Explorador y analizador de almacenamiento para varias '
            'cuentas de Google Drive. Solo lectura.'),
        actions: [
          TextButton(
            onPressed: () => launchUrl(Uri.parse('${Config.repoUrl}/releases')),
            child: const Text('Changelog'),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cerrar')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final accounts = store.accounts;
    final withQuota = accounts.where((a) => a.quota != null).toList();
    final totalUsage = withQuota.fold<int>(0, (s, a) => s + a.quota!.usage);
    final limited = withQuota.every((a) => a.quota!.limit != null);
    final totalLimit =
        limited ? withQuota.fold<int>(0, (s, a) => s + a.quota!.limit!) : null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Multi G-DRIVE'),
        actions: [
          TextButton(onPressed: _showVersion, child: Text('v${Config.appVersion}')),
          IconButton(
            tooltip: 'Actualizar',
            onPressed: _busy || accounts.isEmpty ? null : _refreshAll,
            icon: const Icon(Icons.refresh),
          ),
        ],
        bottom: _busy
            ? const PreferredSize(
                preferredSize: Size.fromHeight(4), child: LinearProgressIndicator())
            : null,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy || !_configOk ? null : _addAccount,
        icon: const Icon(Icons.person_add_alt_1),
        label: const Text('Agregar cuenta'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          if (!_configOk)
            const _Banner(
              icon: Icons.warning_amber,
              text: 'Faltan los datos de Google Cloud en esta compilación '
                  '(Variables y Secret del repo). Revisá la guía de E0.',
            ),
          if (auth.isWeb)
            const _Banner(
              icon: Icons.info_outline,
              text: 'Versión web limitada: el acceso a cada cuenta dura cerca de 1 hora; '
                  'después hay que volver a conectarla.',
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
            _TotalCard(count: accounts.length, usage: totalUsage, limit: totalLimit),
            const SizedBox(height: 8),
            for (final a in accounts)
              _AccountCard(
                account: a,
                onRemove: () => _run(() => store.remove(a)),
                onReconnect: _addAccount,
              ),
          ],
        ],
      ),
    );
  }
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

class _TotalCard extends StatelessWidget {
  final int count;
  final int usage;
  final int? limit;
  const _TotalCard({required this.count, required this.usage, this.limit});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final ratio = (limit == null || limit == 0) ? null : usage / limit!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Total · $count ${count == 1 ? 'cuenta' : 'cuentas'}', style: t.titleMedium),
          const SizedBox(height: 8),
          Text('${formatBytes(usage)} de ${formatBytes(limit)}', style: t.headlineSmall),
          if (ratio != null) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(value: ratio.clamp(0, 1).toDouble(), minHeight: 8),
          ],
        ]),
      ),
    );
  }
}

class _AccountCard extends StatelessWidget {
  final Account account;
  final VoidCallback onRemove;
  final VoidCallback onReconnect;
  const _AccountCard(
      {required this.account, required this.onRemove, required this.onReconnect});

  @override
  Widget build(BuildContext context) {
    final q = account.quota;
    final t = Theme.of(context).textTheme;
    final ratio = (q == null || q.limit == null || q.limit == 0) ? null : q.usage / q.limit!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(account.email, style: t.titleMedium),
                if (account.name.isNotEmpty) Text(account.name, style: t.bodySmall),
              ]),
            ),
            PopupMenuButton<String>(
              onSelected: (v) => v == 'quitar' ? onRemove() : onReconnect(),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'reconectar', child: Text('Volver a conectar')),
                PopupMenuItem(value: 'quitar', child: Text('Quitar de la app')),
              ],
            ),
          ]),
          if (account.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(account.error!,
                  style: t.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error)),
            ),
          if (q != null) ...[
            const SizedBox(height: 8),
            Text('${formatBytes(q.usage)} de ${formatBytes(q.limit)}', style: t.titleSmall),
            if (ratio != null) ...[
              const SizedBox(height: 6),
              LinearProgressIndicator(value: ratio.clamp(0, 1).toDouble(), minHeight: 6),
            ],
            const SizedBox(height: 8),
            Wrap(spacing: 16, runSpacing: 4, children: [
              Text('Drive: ${formatBytes(q.driveWithoutTrash)}'),
              Text('Papelera: ${formatBytes(q.inTrash)}'),
              Text('Gmail y Fotos: ${formatBytes(q.others)}'),
            ]),
          ],
        ]),
      ),
    );
  }
}
