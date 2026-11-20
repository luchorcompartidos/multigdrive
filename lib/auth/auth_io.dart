import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import 'auth_result.dart';

const bool isWeb = false;

/// Abre el navegador para elegir una cuenta de Google y devuelve sus tokens.
Future<AuthResult?> signInNewAccount() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final redirect = 'http://127.0.0.1:${server.port}';
  final verifier = randomString(64);
  final challenge =
      base64Url.encode(sha256.convert(ascii.encode(verifier)).bytes).replaceAll('=', '');
  final state = randomString(24);
  final completer = Completer<Map<String, String>>();

  final sub = server.listen((req) async {
    final q = req.uri.queryParameters;
    if (!q.containsKey('code') && !q.containsKey('error')) {
      req.response.statusCode = 404;
      await req.response.close();
      return;
    }
    req.response.headers.contentType = ContentType.html;
    req.response.write('<html><head><meta charset="utf-8"></head>'
        '<body style="font-family:sans-serif;padding:2em">'
        '<h2>Listo, cuenta conectada.</h2><p>Ya podés volver a Multi G-DRIVE.</p>'
        '</body></html>');
    await req.response.close();
    if (!completer.isCompleted) completer.complete(q);
  });

  final url = Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
    'client_id': Config.desktopClientId,
    'redirect_uri': redirect,
    'response_type': 'code',
    'scope': Config.scope,
    'code_challenge': challenge,
    'code_challenge_method': 'S256',
    'state': state,
    'access_type': 'offline',
    'prompt': 'select_account consent',
  });

  try {
    await launchUrl(url, mode: LaunchMode.externalApplication);
    final q = await completer.future.timeout(const Duration(minutes: 5));
    if (q['state'] != state || q['code'] == null) return null;
    final res = await http.post(Uri.parse('https://oauth2.googleapis.com/token'), body: {
      'client_id': Config.desktopClientId,
      'client_secret': Config.desktopClientSecret,
      'code': q['code']!,
      'code_verifier': verifier,
      'grant_type': 'authorization_code',
      'redirect_uri': redirect,
    });
    if (res.statusCode != 200) throw Exception('Google rechazó el código: ${res.body}');
    return AuthResult.fromToken(jsonDecode(res.body) as Map<String, dynamic>);
  } finally {
    await sub.cancel();
    await server.close(force: true);
  }
}

/// Renueva el acceso de una cuenta ya conectada.
Future<AuthResult?> refresh(String refreshToken) async {
  final res = await http.post(Uri.parse('https://oauth2.googleapis.com/token'), body: {
    'client_id': Config.desktopClientId,
    'client_secret': Config.desktopClientSecret,
    'refresh_token': refreshToken,
    'grant_type': 'refresh_token',
  });
  if (res.statusCode != 200) return null;
  return AuthResult.fromToken(jsonDecode(res.body) as Map<String, dynamic>,
      keepRefresh: refreshToken);
}

/// Solo aplica a la web.
AuthResult? consumeRedirectResult() => null;
