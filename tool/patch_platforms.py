"""Ajustes a las carpetas que genera `flutter create` en GitHub Actions.

Uso: python3 tool/patch_platforms.py android|web
"""
import sys

SCHEME = "com.luchorcompartidos.multigdrive"


def patch(path, old, new):
    s = open(path, encoding="utf-8").read()
    if new in s:
        return
    if old not in s:
        sys.exit(f"::error::No encontré el punto a modificar en {path}: {old!r}")
    open(path, "w", encoding="utf-8").write(s.replace(old, new, 1))
    print(f"OK {path}")


def android():
    m = "android/app/src/main/AndroidManifest.xml"
    s = open(m, encoding="utf-8").read()
    if "android.permission.INTERNET" not in s:
        patch(m, "<application", '<uses-permission android:name="android.permission.INTERNET" />\n    <application')
    s = open(m, encoding="utf-8").read()
    import re
    s = re.sub(r'android:label="[^"]*"', 'android:label="Multi G-DRIVE"', s, count=1)
    open(m, "w", encoding="utf-8").write(s)
    # Vuelta del inicio de sesión: com.luchorcompartidos.multigdrive://oauth
    patch(m, "</activity>", f"""    <meta-data android:name="flutter_deeplinking_enabled" android:value="false" />
            <intent-filter>
                <action android:name="android.intent.action.VIEW" />
                <category android:name="android.intent.category.DEFAULT" />
                <category android:name="android.intent.category.BROWSABLE" />
                <data android:scheme="{SCHEME}" android:host="oauth" />
            </intent-filter>
        </activity>""")


HEAD_SCRIPT = """<script>
  // Android: Google vuelve acá con ?code=...&state=a_... y la página lo reenvía a la app.
  (function () {
    var p = new URLSearchParams(location.search);
    if ((p.get('state') || '').indexOf('a_') !== 0) return;
    window.__mgdCallback = true;
    var u = 'intent://oauth' + location.search +
      '#Intent;scheme=%(s)s;package=%(s)s;end';
    document.addEventListener('DOMContentLoaded', function () {
      document.title = 'Multi G-DRIVE';
      document.body.innerHTML =
        '<div style="font-family:sans-serif;padding:3em 1.5em;text-align:center">' +
        '<h2>Cuenta autorizada</h2><p>Tocá el botón para volver a la app.</p>' +
        '<p><a href="' + u + '" style="display:inline-block;padding:14px 24px;' +
        'background:#1a73e8;color:#fff;border-radius:24px;text-decoration:none;' +
        'font-size:18px">Volver a Multi G-DRIVE</a></p></div>';
    });
    location.replace(u);
  })();
</script>
</head>""" % {"s": SCHEME}

BOOT_OLD = '<script src="flutter_bootstrap.js" async></script>'
BOOT_NEW = """<script>
    if (!window.__mgdCallback) {
      var s = document.createElement('script');
      s.src = 'flutter_bootstrap.js';
      s.async = true;
      document.body.appendChild(s);
    }
  </script>"""


def web():
    i = "web/index.html"
    patch(i, "</head>", HEAD_SCRIPT)
    patch(i, BOOT_OLD, BOOT_NEW)


if __name__ == "__main__":
    {"android": android, "web": web}[sys.argv[1]]()
