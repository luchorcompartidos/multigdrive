import 'package:web/web.dart' as web;

import '../config.dart';
import 'auth_result.dart';

const bool isWeb = true;

Future<void> initAuth() async {}

Stream<AuthResult> get authResults => const Stream.empty();

bool configOk() => Config.webClientId.isNotEmpty;

String _redirectUri() {
  final l = web.window.location;
  return '${l.origin}${l.pathname}';
}

/// Redirige a Google; al volver, [consumeRedirectResult] toma el acceso.
Future<AuthResult?> signInNewAccount() async {
  final state = randomString(24);
  web.window.sessionStorage.setItem('mgd_state', state);
  final url = Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
    'client_id': Config.webClientId,
    'redirect_uri': _redirectUri(),
    'response_type': 'token',
    'scope': Config.scope,
    'state': state,
    'prompt': 'select_account',
  });
  web.window.location.href = url.toString();
  return null;
}

/// En la web no hay renovación: después de ~1 hora se vuelve a conectar.
Future<AuthResult?> refresh(String refreshToken) async => null;

/// Lee el acceso que Google dejó en la dirección (#access_token=...).
AuthResult? consumeRedirectResult() {
  final hash = web.window.location.hash;
  if (!hash.contains('access_token=')) return null;
  final p = Uri.splitQueryString(hash.substring(1));
  final saved = web.window.sessionStorage.getItem('mgd_state');
  web.window.sessionStorage.removeItem('mgd_state');
  web.window.history.replaceState(null, '', _redirectUri());
  if (saved == null || p['state'] != saved || p['access_token'] == null) return null;
  final secs = int.tryParse(p['expires_in'] ?? '') ?? 3600;
  return AuthResult(
    accessToken: p['access_token']!,
    expiry: DateTime.now().add(Duration(seconds: secs)),
  );
}
