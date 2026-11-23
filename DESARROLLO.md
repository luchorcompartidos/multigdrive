# DESARROLLO — Multi G-DRIVE Admin Explorer&Analyzer

Documento para retomar el trabajo en un chat nuevo: **"leé DESARROLLO.md del repo luchorcompartidos/multigdrive"**.
Última actualización: 23/11/2026 · versión publicada: **v0.3.5**.

## 1. Qué es
App para administrar desde un solo lugar el almacenamiento de **varias cuentas de Google Drive**:
ver cuotas, explorar, analizar, limpiar, mover entre cuentas, usar todas como una sola unidad
("Mi Drive total" y discos virtuales) y comparar con los archivos del celular o la PC.

| Plataforma | Entrega | Notas |
| --- | --- | --- |
| Android | APK firmado (Release) | Experiencia completa, revisión diaria en segundo plano |
| Windows | Instalador `multigdrive-setup-vX.exe` (+ .zip portable) | Experiencia completa, unidad G: con rclone |
| Web | https://luchorcompartidos.github.io/multigdrive/ (rama `gh-pages`) | Limitada: acceso ~1 h, índice no persiste |

Mi Panel: filas `https://luchorcompartidos.github.io/multigdrive/` y `github-apk:luchorcompartidos/multigdrive`.

## 2. Tecnología y estructura
Flutter (un solo código). Las carpetas `android/`, `windows/` y `web/` **no están en el repo**: las genera
`flutter create` en GitHub Actions y `tool/patch_platforms.py` les aplica los ajustes.

| Archivo | Qué hace |
| --- | --- |
| `lib/config.dart` | IDs de cliente OAuth, scopes, versión (`APP_VERSION` por `--dart-define`) |
| `lib/auth/` | Inicio de sesión: Windows (127.0.0.1 + PKCE, cliente Escritorio), Android (cliente Web → página web → `com.luchorcompartidos.multigdrive://oauth`), web (token implícito) |
| `lib/accounts.dart` | Cuentas, tokens en almacenamiento seguro, renovación, cuota (`about.get`) |
| `lib/drive_index.dart`, `lib/index_storage/` | Índice por cuenta (gzip en el equipo), árbol, tamaños por carpeta, actualización por Changes API |
| `lib/actions.dart` | Papelera, restaurar, vaciar, mover, renombrar, crear carpeta, copiar/mover entre cuentas, pasar la propiedad, Sheets, lotes con progreso |
| `lib/main.dart` | Panel principal, menú ⋮, ajustes |
| `lib/side_tree.dart` | Barra lateral (árbol de cuentas) |
| `lib/explorer.dart` | Explorador por cuenta, búsqueda global, hoja de detalle |
| `lib/analyzer.dart`, `lib/cleanup.dart` | Analizador (pesados, duplicados, tipos, viejos, papelera) y limpieza de duplicados |
| `lib/balancer.dart` | Balanceador de espacio entre cuentas |
| `lib/unified.dart`, `lib/upload.dart`, `lib/disks.dart` | Mi Drive total, subir archivos, discos virtuales |
| `lib/rclone.dart` | Unidad de Windows (rclone + WinFsp) |
| `lib/device_compare.dart` | Equipo (Android/Windows) ↔ Drive: comparación, buscador, filtros, orden, abrir carpeta |
| `lib/offline.dart`, `lib/offline_storage/` | Archivos sin conexión |
| `lib/history.dart` | Historial y deshacer |
| `lib/audit.dart` | Auditoría de compartidos |
| `lib/gmail.dart` | Gmail pesado |
| `lib/rules.dart` | Reglas automáticas |
| `lib/evolution.dart` | Evolución del uso (foto diaria) |
| `lib/background.dart` | Revisión diaria con la app cerrada (Android, workmanager + notificaciones) |
| `lib/updates.dart` | Aviso de versión nueva y Changelog desde Releases |
| `tool/patch_platforms.py` | Permisos Android, intent de vuelta OAuth, MainActivity (selector de exploradores para abrir carpetas), `<queries>` de exploradores, firma, desugaring, web |
| `installer/multigdrive.iss` | Instalador de Windows (Inno Setup) |
| `NUCLEO.md` | Qué partes reutilizar en otras apps (Reproductor) |

## 3. Google Cloud
Proyecto `multi-gdrive-admin` · Google Auth Platform · **Producción sin verificar** (aviso "Google no verificó esta app").

| Cliente | Uso | Configuración |
| --- | --- | --- |
| MGD Web (`…ac53pi41embhn1k8e004dnr99m20fqao…`) | Web y Android | Origen `https://luchorcompartidos.github.io` · Redirección `…/multigdrive/` (y `…/reproductor/`) |
| MGD Windows (`…2j5f3pa1gb4ajf4v5g6965pjekt2qk5a…`) | Windows | App de escritorio |

Permisos en "Acceso a los datos": `drive` (y `drive.metadata.readonly` del inicio) · `gmail.modify` (solo para Gmail pesado, se pide por cuenta).

## 4. Secrets del repo
`DESKTOP_CLIENT_SECRET`, `WEB_CLIENT_SECRET`, `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`
(misma firma que Notas). GitHub no permite leerlos: los valores salen de los JSON de Google y de la clave de Notas.

## 5. Compilación y versiones
- `.github/workflows/ci.yml`: en cada push a `main` compila web (→ rama `gh-pages`), APK y Windows (.exe + .zip).
- Versión SemVer desde los tags: en el mensaje del commit `[patch]`, `[minor]` o `[major]` crea la Release
  (notas = commits desde la anterior). Sin marca: compilación de prueba sin Release (`-prueba`). `[skip ci]` no compila.
- Preferencia: cada entrega como **Release Patch** salvo que se indique otra cosa; avisar tipo y número.
- GitHub Pages: *Settings → Pages → Deploy from a branch → gh-pages / (root)*.
- Ajustes conocidos: Windows compila con `CL=/D_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS`;
  `file_picker` ^10 (la 8 no compila en Android); `flutter_local_notifications` ^19 requiere desugaring.

## 6. Entregas y versiones
| Entrega | Versión | Contenido |
| --- | --- | --- |
| E0 | v0.0.1–v0.0.5 | Factibilidad: Google Cloud, conexión multicuenta (Android vía página web) |
| E1 | v0.0.6–v0.0.7 | Panel: firma fija, tokens seguros, barra por tipo, apodo/color, orden, alerta de % |
| E2 | v0.0.8 | Indexador, explorador con tamaño por carpeta, búsqueda global |
| E3 (MVP) | v0.0.9 | Analizador + exportar CSV |
| E4 | v0.0.10 | Web con tarjeta para instalar la app; Mi Panel |
| E5 | v0.1.0 | Acciones: papelera, restaurar, vaciar, mover, copiar/mover entre cuentas |
| E6 | v0.1.1 | Carpetas: copiar/mover entre cuentas, duplicar, renombrar, crear |
| E7 | v0.1.2 | Barra lateral |
| E8 | v0.1.3 | Instalador de Windows |
| E9 | v0.1.4 | Limpieza de duplicados |
| E10 | v0.1.5 | Selección múltiple y lotes; vaciar todas las papeleras |
| E11 | v0.1.6 | Índice incremental |
| E13 | v0.1.7 | Sin conexión |
| E12 | v0.1.8 | Exportar a Sheets, aviso de cuota, `NUCLEO.md` |
| E14 | v0.1.9 | Balanceador de espacio |
| E16 | v0.1.10 | Mover sin duplicar (pasar la propiedad entre cuentas personales) |
| E15 | v0.1.11 | Notificaciones con la app cerrada (Android) |
| E17 | v0.1.12 | Historial y deshacer |
| E18 | v0.1.13 | Auditoría de compartidos |
| E19 | v0.1.14 | Gmail pesado |
| E20 | v0.1.15 | Reglas automáticas |
| E21 | v0.1.16 | Evolución del uso |
| E22 | v0.1.17 | Espejo / respaldo |
| E23 | v0.2.0 | Mi Drive total |
| E24 | v0.2.1 | Subir archivos (cuenta con más lugar) |
| E25 | v0.2.2 | Discos virtuales |
| E26 | v0.2.3 | Unidad de Windows (rclone) |
| E27 | v0.3.0–v0.3.3 | Equipo ↔ Drive: niveles Exacto/Idéntico/Parecido, copiar rutas y links, abrir carpetas, compartidos conmigo opcionales con dueño |
| E27 (mejora) | v0.3.4–v0.3.5 | Equipo ↔ Drive: buscador, filtros (tipo, cuenta, carpeta, tamaño, copias) y orden; abrir la carpeta eligiendo el explorador (con "Recordar"); sin Files de Google |

Plan visual: Whiteboard "Multi G-DRIVE Admin Explorer&Analyzer — MVP y Entregables".
Guía de Google Cloud: doc "Guía Google Cloud — Multi G-DRIVE Admin (E0)".

## 7. Decisiones y límites conocidos
- Los archivos "compartidos conmigo" no ocupan espacio propio y no están bajo control del usuario: en Equipo ↔ Drive van ocultos por defecto.
- Google Fotos no se puede analizar (Google no expone la biblioteca a otras apps) → app aparte **FotosCompare**.
- Los Documentos de Google no tienen huella (MD5) ni ocupan cuota.
- Un archivo no se reparte entre cuentas (Mi Drive total / discos).
- Límite de 10 sesiones de Google por navegador: tras conectar una cuenta se puede cerrar su sesión en el navegador.
- La marca "sin conexión" de la app oficial de Drive no es legible: la app tiene su propia sección Sin conexión.
- Android no tiene una forma estándar de abrir una carpeta en un explorador. La app arma su propio selector "Abrir la carpeta con…":
  primero las apps que declaran abrir carpetas (`resource/folder`, `inode/directory`, `vnd.android.document/directory`, `file://`),
  luego exploradores conocidos (Solid Explorer, MiXplorer…) a los que se les pasa la carpeta, y como "alternativa"
  su visor genérico. Se descartan las apps que aceptan cualquier archivo (`*/*`), que eran las que abrían el archivo en vez de la carpeta.
  Probado (v0.3.4): Solid Explorer y MiXplorer abren la carpeta. Files de Google no acepta abrir una carpeta (va a su inicio):
  se quitó de la lista (v0.3.5); en su lugar queda "Archivos del sistema (Android)" (DocumentsUI), que sí la abre.
  La ruta siempre queda copiada para pegarla si el explorador abre en otro lado. Elección recordada: clave `mgd_explorador_carpetas`.
- Sin probar aún con cuentas reales: la mayoría de las funciones desde E5 (solo se verificó la compilación).

## 8. Pendientes / ideas
- Pruebas reales y correcciones (mandar capturas).
- Probar "Archivos del sistema (Android)" en "Abrir su carpeta" (v0.3.5).
- Notificaciones con la app cerrada en Windows (tarea programada).
- Copiar carpetas en "Mover a un disco" para Workspace (hoy usa pasar la propiedad).
- Reproductor: repo `luchorcompartidos/reproductor`, sobre el núcleo (`NUCLEO.md`).
