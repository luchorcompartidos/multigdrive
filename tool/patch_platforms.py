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


# Exploradores de archivos conocidos (se listan aunque no declaren que abren carpetas)
CONOCIDOS = [
    # Files de Google (com.google.android.apps.nbu.files) no se incluye: ignora la carpeta y abre su inicio.
    "pl.solidexplorer2", "com.mixplorer", "com.mixplorer.silver",
    "com.google.android.documentsui", "com.android.documentsui",
    "com.sec.android.app.myfiles", "com.mi.android.globalFileexplorer", "com.android.fileexplorer",
    "com.coloros.filemanager", "com.oneplus.filemanager", "com.huawei.filemanager",
    "com.motorola.filemanager", "com.lonelycatgames.Xplore", "com.ghisler.android.TotalCommander",
    "com.alphainventor.filemanager", "nextapp.fx", "com.amaze.filemanager",
    "me.zhanghai.android.files", "com.estrongs.android.pop", "bin.mt.plus",
]

MAIN_ACTIVITY = """package com.luchorcompartidos.multigdrive

import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.net.Uri
import android.os.StrictMode
import android.provider.DocumentsContract
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File

private data class OpcionCarpeta(val pkg: String, val variante: String, val intent: Intent, val nivel: Int)

class MainActivity : FlutterActivity() {
    private val opciones = mutableMapOf<String, Intent>()
    private val conocidos = listOf(__CONOCIDOS__)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mgd/carpetas")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "exploradores" -> result.success(
                        exploradores(call.argument<String>("path") ?: "", call.argument<String>("file")))
                    "abrirCon" -> result.success(abrirCon(call.argument<String>("id") ?: ""))
                    else -> result.notImplemented()
                }
            }
    }

    /** content://com.android.externalstorage.documents/document/primary:DCIM/Camera (o la tarjeta SD) */
    private fun docUri(path: String): Uri? {
        val m = Regex("^/storage/([^/]+)/?(.*)").find(path) ?: return null
        var vol = m.groupValues[1]
        var rel = m.groupValues[2]
        if (vol == "emulated") {
            val p = rel.split("/", limit = 2)
            rel = if (p.size > 1) p[1] else ""
            vol = "primary"
        }
        return DocumentsContract.buildDocumentUri(
            "com.android.externalstorage.documents", vol + ":" + rel.trimEnd('/'))
    }

    private fun ver(uri: Uri, tipo: String?): Intent {
        val i = Intent(Intent.ACTION_VIEW)
        if (tipo == null) i.data = uri else i.setDataAndType(uri, tipo)
        return i
    }

    private fun componentes(i: Intent): List<ComponentName> = try {
        packageManager.queryIntentActivities(i, PackageManager.MATCH_DEFAULT_ONLY)
            .map { ComponentName(it.activityInfo.packageName, it.activityInfo.name) }
    } catch (e: Exception) {
        emptyList()
    }

    private fun icono(pkg: String): ByteArray? = try {
        val d = packageManager.getApplicationIcon(pkg)
        val b = Bitmap.createBitmap(96, 96, Bitmap.Config.ARGB_8888)
        d.setBounds(0, 0, 96, 96)
        d.draw(Canvas(b))
        val out = ByteArrayOutputStream()
        b.compress(Bitmap.CompressFormat.PNG, 100, out)
        out.toByteArray()
    } catch (e: Exception) {
        null
    }

    private val sistema = setOf("com.google.android.documentsui", "com.android.documentsui")
    private val ignorar = setOf("com.google.android.apps.nbu.files") // no abre la carpeta pedida

    private fun nombre(pkg: String): String = if (pkg in sistema) "Archivos del sistema (Android)" else try {
        packageManager.getApplicationLabel(packageManager.getApplicationInfo(pkg, 0)).toString()
    } catch (e: Exception) {
        pkg
    }

    /**
     * Exploradores instalados que pueden abrir la CARPETA (no el archivo).
     * nivel 0: declara que abre carpetas · 1: explorador conocido, se le pasa la carpeta ·
     * 2: alternativa genérica (acepta cualquier archivo; puede abrir otra cosa).
     */
    private fun exploradores(path: String, archivoRef: String?): List<Map<String, Any?>> {
        opciones.clear()
        val archivo = Uri.fromFile(File(path))
        val doc = docUri(path)
        val variantes = mutableListOf(
            "carpeta" to ver(archivo, "resource/folder"),
            "inodo" to ver(archivo, "inode/directory"),
        )
        if (doc != null) variantes.add("documento" to ver(doc, DocumentsContract.Document.MIME_TYPE_DIR))
        variantes.add("directorio" to ver(archivo, DocumentsContract.Document.MIME_TYPE_DIR))
        variantes.add("ruta" to ver(archivo, null))

        // Las apps que aceptan cualquier tipo (*/*) tratarían la carpeta como un archivo
        val prueba = "application/x-mgd-prueba"
        val comodines = (componentes(ver(archivo, prueba)) +
            (if (doc != null) componentes(ver(doc, prueba)) else emptyList())).toSet()

        val mejor = linkedMapOf<String, OpcionCarpeta>()
        val genericos = linkedMapOf<String, OpcionCarpeta>()
        for ((variante, base) in variantes) {
            for (c in componentes(base)) {
                val pkg = c.packageName
                if (pkg == packageName || pkg in ignorar) continue
                if (variante == "ruta" && pkg !in conocidos) continue
                val intent = Intent(base).setComponent(c)
                if (c in comodines) {
                    if (pkg !in genericos) genericos[pkg] = OpcionCarpeta(pkg, "generico", intent, 2)
                } else if (pkg !in mejor) {
                    mejor[pkg] = OpcionCarpeta(pkg, variante, intent, 0)
                }
            }
        }
        val lista = mutableListOf<OpcionCarpeta>()
        lista.addAll(mejor.values)
        for (pkg in conocidos) {
            if (pkg in mejor) continue
            val lanzar = packageManager.getLaunchIntentForPackage(pkg) ?: continue
            val i = Intent(Intent.ACTION_VIEW).setComponent(lanzar.component)
                .setDataAndType(archivo, "resource/folder")
            lista.add(OpcionCarpeta(pkg, "inicio", i, 1))
        }
        for (op in genericos.values) {
            if (op.pkg !in mejor && op.pkg in conocidos) lista.add(op)
        }
        // Prueba: pedirle al explorador que abra la carpeta con el archivo marcado.
        // No hay una forma estándar: se le pasa el archivo como "carpeta" más extras que usan algunas apps.
        if (archivoRef != null && archivoRef.isNotEmpty()) {
            val ref = Uri.fromFile(File(archivoRef))
            for (op in lista.toList()) {
                if (op.nivel > 1 || op.pkg !in conocidos || op.pkg in sistema) continue
                if (lista.any { it.pkg == op.pkg && it.nivel == 3 }) continue
                val i = Intent(Intent.ACTION_VIEW).setComponent(op.intent.component)
                    .setDataAndType(ref, "resource/folder")
                    .putExtra("org.openintents.extra.ABSOLUTE_PATH", archivoRef)
                    .putExtra("selected_file", archivoRef)
                    .putExtra("select", archivoRef)
                lista.add(OpcionCarpeta(op.pkg, "marcar", i, 3))
            }
        }
        lista.sortWith(compareBy<OpcionCarpeta>({ it.nivel }, { nombre(it.pkg).lowercase() }))
        return lista.map { op ->
            val id = op.pkg + "|" + op.variante
            opciones[id] = op.intent
            mapOf(
                "id" to id,
                "pkg" to op.pkg,
                "label" to nombre(op.pkg) + when (op.nivel) {
                    2 -> " (alternativa)"
                    3 -> " (marcar archivo, prueba)"
                    else -> ""
                },
                "nivel" to op.nivel,
                "icono" to icono(op.pkg),
            )
        }
    }

    private fun abrirCon(id: String): Boolean {
        val i = opciones[id] ?: return false
        // Algunos exploradores solo aceptan rutas "file://"
        StrictMode.setVmPolicy(StrictMode.VmPolicy.Builder().build())
        return try {
            startActivity(Intent(i).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            true
        } catch (e: Exception) {
            false
        }
    }
}
""".replace("__CONOCIDOS__", ", ".join('"%s"' % p for p in CONOCIDOS))

QUERIES = "\n".join(
    ['        <intent><action android:name="android.intent.action.VIEW" /><data android:mimeType="%s" /></intent>' % t
     for t in ["resource/folder", "inode/directory", "vnd.android.document/directory", "application/x-mgd-prueba"]]
    + ['        <intent><action android:name="android.intent.action.VIEW" /><data android:scheme="file" /></intent>']
    + ['        <package android:name="%s" />' % p for p in CONOCIDOS]
)


def queries(m):
    """Android 11+: sin esto la app no "ve" los exploradores instalados."""
    s = open(m, encoding="utf-8").read()
    if "x-mgd-prueba" in s:
        return
    if "<queries>" in s:
        s = s.replace("<queries>", "<queries>\n" + QUERIES, 1)
    else:
        s = s.replace("<application", "<queries>\n" + QUERIES + "\n    </queries>\n    <application", 1)
    open(m, "w", encoding="utf-8").write(s)
    print(f"OK {m} (queries)")



def android():
    m = "android/app/src/main/AndroidManifest.xml"
    s = open(m, encoding="utf-8").read()
    if "android.permission.INTERNET" not in s:
        patch(m, "<application", '<uses-permission android:name="android.permission.INTERNET" />\n    <application')
    s = open(m, encoding="utf-8").read()
    import re
    s = re.sub(r'android:label="[^"]*"', 'android:label="Multi G-DRIVE"', s, count=1)
    open(m, "w", encoding="utf-8").write(s)
    s = open(m, encoding="utf-8").read()
    if "POST_NOTIFICATIONS" not in s:
        patch(m, "<application", '<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />\n    <application')
    s = open(m, encoding="utf-8").read()
    if "MANAGE_EXTERNAL_STORAGE" not in s:
        patch(m, "<application", '<uses-permission android:name="android.permission.MANAGE_EXTERNAL_STORAGE" />\n'
              '    <uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" android:maxSdkVersion="32" />\n'
              '    <uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" android:maxSdkVersion="29" />\n'
              '    <application')
    s = open(m, encoding="utf-8").read()
    if "requestLegacyExternalStorage" not in s:
        patch(m, "<application", '<application android:requestLegacyExternalStorage="true"')
    import glob
    for ma in glob.glob("android/app/src/main/kotlin/**/MainActivity.kt", recursive=True):
        open(ma, "w", encoding="utf-8").write(MAIN_ACTIVITY)
        print(f"OK {ma}")
    queries(m)
    desugar()
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


SIGNING = """

// Firma fija (la clave llega desde los Secrets del repo)
System.getenv("MGD_KEYSTORE_PATH")?.let { ks ->
    android {
        signingConfigs {
            create("mgd") {
                storeFile = file(ks)
                storePassword = System.getenv("MGD_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("MGD_KEY_ALIAS")
                keyPassword = System.getenv("MGD_KEYSTORE_PASSWORD")
            }
        }
        buildTypes {
            getByName("release") { signingConfig = signingConfigs.getByName("mgd") }
        }
    }
}
"""


DESUGAR = """

// Notificaciones (flutter_local_notifications necesita desugaring)
android {
    compileOptions {
        isCoreLibraryDesugaringEnabled = true
    }
}
dependencies {
    "coreLibraryDesugaring"("com.android.tools:desugar_jdk_libs:2.1.4")
}
"""


def desugar():
    g = "android/app/build.gradle.kts"
    s = open(g, encoding="utf-8").read()
    if "isCoreLibraryDesugaringEnabled" not in s:
        open(g, "a", encoding="utf-8").write(DESUGAR)
        print(f"OK {g}")


def signing():
    g = "android/app/build.gradle.kts"
    s = open(g, encoding="utf-8").read()
    if "MGD_KEYSTORE_PATH" not in s:
        open(g, "a", encoding="utf-8").write(SIGNING)
        print(f"OK {g}")


def web():
    i = "web/index.html"
    patch(i, "</head>", HEAD_SCRIPT)
    patch(i, BOOT_OLD, BOOT_NEW)


if __name__ == "__main__":
    {"android": android, "web": web, "signing": signing}[sys.argv[1]]()
