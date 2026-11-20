import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'auth/auth.dart' as auth;

/// Una cuenta de Google conectada y su cuota (about.get).
class Account {
  String email;
  String name;
  String accessToken;
  String? refreshToken;
  DateTime expiry;
  Quota? quota;
  String? error;

  Account({
    required this.email,
    required this.name,
    required this.accessToken,
    this.refreshToken,
    required this.expiry,
    this.quota,
  });

  Map<String, dynamic> toJson() => {
        'email': email,
        'name': name,
        'accessToken': accessToken,
        'refreshToken': refreshToken,
        'expiry': expiry.toIso8601String(),
        'quota': quota?.toJson(),
      };

  factory Account.fromJson(Map<String, dynamic> j) => Account(
        email: j['email'] as String,
        name: (j['name'] as String?) ?? '',
        accessToken: j['accessToken'] as String,
        refreshToken: j['refreshToken'] as String?,
        expiry: DateTime.parse(j['expiry'] as String),
        quota: j['quota'] == null ? null : Quota.fromJson(j['quota'] as Map<String, dynamic>),
      );
}

class Quota {
  final int? limit; // null = sin límite
  final int usage; // todo: Drive + Gmail + Fotos
  final int inDrive;
  final int inTrash;

  Quota({this.limit, required this.usage, required this.inDrive, required this.inTrash});

  int get driveWithoutTrash => max(0, inDrive - inTrash);
  int get others => max(0, usage - inDrive); // Gmail y Fotos

  static int _n(Object? v) => int.tryParse('${v ?? 0}') ?? 0;

  factory Quota.fromApi(Map<String, dynamic> q) => Quota(
        limit: q['limit'] == null ? null : _n(q['limit']),
        usage: _n(q['usage']),
        inDrive: _n(q['usageInDrive']),
        inTrash: _n(q['usageInDriveTrash']),
      );

  Map<String, dynamic> toJson() =>
      {'limit': limit, 'usage': usage, 'usageInDrive': inDrive, 'usageInDriveTrash': inTrash};

  factory Quota.fromJson(Map<String, dynamic> j) => Quota.fromApi(j);
}

class NeedsReconnect implements Exception {}

class AccountStore {
  static const _key = 'mgd_accounts';
  final List<Account> accounts = [];

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    accounts.clear();
    if (raw != null) {
      for (final j in jsonDecode(raw) as List) {
        accounts.add(Account.fromJson(j as Map<String, dynamic>));
      }
    }
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(accounts.map((a) => a.toJson()).toList()));
  }

  /// Agrega (o actualiza, si ya estaba) la cuenta de este acceso.
  Future<Account> addFromAuth(auth.AuthResult r) async {
    final about = await _about(r.accessToken);
    final user = about['user'] as Map<String, dynamic>;
    final email = user['emailAddress'] as String;
    final acc = Account(
      email: email,
      name: (user['displayName'] as String?) ?? '',
      accessToken: r.accessToken,
      refreshToken: r.refreshToken,
      expiry: r.expiry,
      quota: Quota.fromApi(about['storageQuota'] as Map<String, dynamic>),
    );
    accounts.removeWhere((a) => a.email == email);
    accounts.add(acc);
    await save();
    return acc;
  }

  Future<void> remove(Account a) async {
    accounts.remove(a);
    await save();
  }

  /// Vuelve a pedir la cuota de una cuenta, renovando el acceso si hace falta.
  Future<void> refreshQuota(Account a) async {
    a.error = null;
    try {
      await _ensureToken(a);
      final about = await _about(a.accessToken);
      a.quota = Quota.fromApi(about['storageQuota'] as Map<String, dynamic>);
    } on NeedsReconnect {
      a.error = 'Hay que volver a conectar esta cuenta';
    } catch (e) {
      a.error = '$e';
    }
    await save();
  }

  Future<void> _ensureToken(Account a) async {
    if (a.expiry.isAfter(DateTime.now().add(const Duration(minutes: 1)))) return;
    final rt = a.refreshToken;
    if (rt == null) throw NeedsReconnect();
    final r = await auth.refresh(rt);
    if (r == null) throw NeedsReconnect();
    a.accessToken = r.accessToken;
    a.expiry = r.expiry;
    if (r.refreshToken != null) a.refreshToken = r.refreshToken;
  }

  static Future<Map<String, dynamic>> _about(String token) async {
    final res = await http.get(
      Uri.parse('https://www.googleapis.com/drive/v3/about'
          '?fields=user(emailAddress,displayName),storageQuota'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (res.statusCode == 401) throw NeedsReconnect();
    if (res.statusCode != 200) throw Exception('Drive respondió ${res.statusCode}: ${res.body}');
    return jsonDecode(res.body) as Map<String, dynamic>;
  }
}

String formatBytes(int? b) {
  if (b == null) return 'sin límite';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = b.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v >= 100 || i == 0 ? 0 : 1)} ${units[i]}';
}
