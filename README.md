# Multi G-DRIVE Admin Explorer&Analyzer

Administra desde un solo lugar el almacenamiento de varias cuentas de Google Drive.
Un solo código Flutter → **APK** (Android), **.exe** (Windows) y **web** (limitada) en GitHub Pages.

## E0 · v0.0.1 — Prueba de factibilidad
- Conectar N cuentas de Google (solo lectura de metadatos).
- Ver la cuota de cada cuenta (Drive, Papelera, Gmail y Fotos) y el total.

## Configuración (una vez)
1. Google Cloud: seguir la guía de E0.
2. Repo → *Settings → Secrets and variables → Actions* → Secret: `DESKTOP_CLIENT_SECRET`
   (los IDs de cliente no son secretos y están en `lib/config.dart`).
3. Repo → *Settings → Pages* → Source: **GitHub Actions**.

## Versiones
Commit con `[patch]`, `[minor]` o `[major]` → Release con APK y .exe.
Sin marca → web publicada + APK/.exe de prueba en *Artifacts* (sin Release).

## Descargas
- Web: https://luchorcompartidos.github.io/multigdrive/
- APK y .exe (zip portable): sección *Releases*.
