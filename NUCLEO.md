# Núcleo reutilizable (para el Reproductor y otras apps)

Estas piezas no dependen de la pantalla de Multi G-DRIVE y se pueden copiar a otra app Flutter:

| Archivo | Qué hace |
| --- | --- |
| `lib/auth/` | Inicio de sesión con Google multicuenta: Windows (127.0.0.1), Android (vuelta vía página web) y web. |
| `lib/accounts.dart` | Cuentas conectadas, tokens en almacenamiento seguro, renovación automática y cuota. |
| `lib/drive_index.dart` + `lib/index_storage/` | Índice de archivos por cuenta, árbol, tamaños por carpeta y actualización por cambios. |
| `lib/offline.dart` + `lib/offline_storage/` | Descarga de archivos al equipo (sin conexión). |
| `tool/patch_platforms.py` + `.github/workflows/ci.yml` | Compilación de APK, instalador de Windows y web en GitHub Actions. |

Para el Reproductor: mismo proyecto de Google Cloud (agregar el origen/redirección de su web),
filtrar el índice por `mimeType` que empiece con `audio/` y reproducir con la descarga de `lib/offline.dart`
o con la URL `files/{id}?alt=media` y el token de la cuenta.
