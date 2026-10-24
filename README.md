# CapyTask 🍊

🌐 **Disponible en español e inglés · Available in Spanish and English** — [English below](#english)

Monitor de recursos para macOS con la claridad del Administrador de Tareas de Windows y un capibara animado que reacciona a la carga de tu Mac: tranquilo, preocupado o estresado.

- **Métricas reales** del kernel (Mach/libproc): CPU por núcleo, memoria física (activa, inactiva, wired, comprimida y libre), disco y procesos.
- **Resumen Visual**: anillos de CPU, RAM y disco con el capibara en el centro, *Top Apps Devoradoras* con sus iconos (agrupa los "Helper" con su app), memoria desglosada, carga por núcleo (P/E) e historial.
- **Procesos**: tabla ordenable (Nombre, PID, CPU %, Memoria MB, Tipo) con búsqueda, filtro *Solo Mis Apps / Todos* y **Finalizar Tarea** (SIGTERM y, si a los 3 s sigue vivo, SIGKILL) con confirmación.
- **Mascota flotante**: sticker sin bordes, siempre visible, arrastrable y con la posición recordada. Está quieta y **se anima al pasar el cursor**, con una burbuja de CPU/RAM. Doble clic abre el monitor; clic derecho, el menú rápido.
- **Barra de menú**: consumo en una línea, mostrar/ocultar mascota, abrir CapyTask y preferencias.
- **Idioma**: español o inglés desde *Ajustes › General › Idioma*. Se aplica al instante (ventana, mascota, menús y formatos de número). Por defecto usa el idioma del sistema.

| Estado | Carga | Animación |
|---|---|---|
| Relajado | < 40 % | `assets_processed/frames/normal` |
| Preocupado | 40 – 75 % | `assets_processed/frames/worried` |
| Estresado | > 75 % | `assets_processed/frames/stressed` |

## Descargar

Descarga `CapyTask-1.0.0.zip` desde [Releases](https://github.com/K1suru/CapyTask/releases/latest), descomprímelo y arrastra **CapyTask.app** a *Aplicaciones*. Es universal (Apple Silicon e Intel) y requiere macOS 14 o posterior.

La app no está firmada con un certificado de Apple Developer, así que la primera vez macOS la bloqueará. Para abrirla:

- Clic derecho sobre **CapyTask.app** › **Abrir** › **Abrir**, o
- *Ajustes del Sistema › Privacidad y seguridad* › **Abrir igualmente**, o
- en Terminal: `xattr -dr com.apple.quarantine /Applications/CapyTask.app`

## Requisitos

- macOS 14 o posterior (probado en macOS 27, Apple A18 Pro).
- Para compilar: Swift 6 — basta con las *Command Line Tools*; Xcode no es necesario.

## Compilar y ejecutar

```bash
scripts/build_app.sh          # crea build/CapyTask.app (universal arm64 + x86_64, firmada ad-hoc)
open build/CapyTask.app
```

Para instalarla en `/Applications` (o `~/Applications` si no hay permisos):

```bash
scripts/install.sh
```

Durante el desarrollo:

```bash
swift run CapyTask --open-window   # sin empaquetar; los fotogramas se leen de assets_processed/
scripts/test.sh                    # tests de lógica, sprites y lecturas reales del sistema
```

`scripts/test.sh` es `swift test` indicando la ruta del plugin de Swift Testing: con solo las Command Line Tools, SwiftPM a veces la omite y falla con *"plugin for module 'TestingMacros' not found"*.

### Modos de diagnóstico

```bash
build/CapyTask.app/Contents/MacOS/CapyTask --benchmark          # CPU y memoria de CapyTask por escenario
build/CapyTask.app/Contents/MacOS/CapyTask --snapshot /tmp/capy # PNG de cada vista + comprobaciones
```

## Arquitectura

```
Sources/CapyTask/
├── App/    CapyTaskApp (ciclo de vida y menú), AppState (preferencias), MenuBarController,
│           WindowControllers (ventana principal y ajustes), SnapshotRunner (diagnóstico)
├── Core/   SystemMonitorEngine (motor @Observable + actor de muestreo), CPUReader, MemoryReader,
│           ProcessManager (libproc, ps y finalizar procesos), CapyMood, Models, Sysctl
├── Pet/    CapySpriteView (reproductor de fotogramas), CapyPetWindow (NSPanel),
│           CapyPetController (posición, menú, hover), CapyPetView (interacción y burbuja)
├── UI/     MainWindowView, VisualSummaryTab, ProcessListTab, SettingsView, Theme, Components
└── Resources/  Info.plist y capy_logo.png (icono de la app y de la barra de menú)
```

- Las lecturas se hacen en un `actor` fuera del hilo principal; la UI solo recibe instantáneas.
- **Muestreo adaptativo**: 1 s con la ventana enfocada, 2,5 s con la mascota o el menú, 5 s si no se ve nada y 10 s con la pantalla dormida. La lista de procesos solo se lee mientras la ventana está visible.
- **Animación del capibara** (`CapySpriteView`): lee `metadata.json` y reproduce los 64 fotogramas a ~16 fps (62,5 ms) con una animación discreta de `contents` que ejecuta el WindowServer, sin coste de CPU para la app. Los fotogramas se decodifican en `IOSurface`s al tamaño real en pantalla y se comparten entre vistas. En reposo solo se guarda el primer fotograma; los 64 se cargan al pasar el cursor (~0,15 s) y se sueltan 10 s después.
- `scripts/build_app.sh` copia `assets_processed/metadata.json` y `frames/` a `CapyTask.app/Contents/Resources/Sprites` (los GIF no se incluyen).

## Rendimiento medido (build release, `--benchmark`)

| Escenario | CPU | Memoria |
|---|---|---|
| Solo mascota en reposo (ventana cerrada) | ~0,02 % estable | ~16 MB |
| Mascota animándose (cursor encima) | ~0 % en la app | ~31 MB |
| Ventana · Resumen Visual | ~1,3 % | ~35 MB |
| Ventana · Procesos (refresco cada 1 s) | ~4,5 % | ~51 MB |

Tras cerrar la ventana la CPU vuelve a ~0 % (tras unos segundos de limpieza); la memoria baja a ~44 MB, no del todo, por la fragmentación de malloc. Un arranque solo con la mascota se queda en ~16 MB.

## Decisiones respecto a la especificación

- **Animación solo con el cursor encima**, a petición: el capibara muestra el primer fotograma de su estado y se anima al hacer hover (también en la ventana principal y en Ajustes). Respeta *Reducir movimiento*.
- **Fotogramas en `IOSurface`.** Con `CGImage` cada fotograma existía dos veces (copia de la app + copia de Core Animation) y la mascota pasaba de 44 MB; con superficies compartidas se guarda una sola copia.
- **Tres estados**, como en la especificación actualizada: desaparecen el estado "durmiendo" y las imágenes estáticas del onsen.
- **Estrés de memoria basado en la presión del kernel.** macOS llena la RAM a propósito: un Mac de 8 GB ronda el 75 % "usado" estando tranquilo. El ánimo usa `max(CPU suavizada, estrés de memoria)`: la memoria solo preocupa al capibara con presión *Elevada* y lo estresa con presión *Crítica*. La UI muestra la RAM usada como Monitor de Actividad.
- **Procesos del sistema.** macOS no deja leer la CPU/memoria de procesos de otros usuarios (root, `_windowserver`…) sin privilegios. Para ellos se usa `/bin/ps` (setuid, incluido en macOS) cada ≥2 s y solo con la ventana visible; para los tuyos, libproc con `phys_footprint` (la columna *Memoria* de Monitor de Actividad y de `top`).
- **% de CPU por proceso** como en Monitor de Actividad y `top`: 100 % = un núcleo completo.
- **Sin `Assets.xcassets`**: compilar catálogos de assets requiere Xcode (`actool`). El icono `.icns` se genera con `sips` + `iconutil` a partir de `capy_logo.png`.
- **`@ViewState` en vez de `@State`**: en el SDK de macOS 27, `@State` es una macro cuyo plugin solo trae Xcode; el alias apunta al property wrapper clásico para compilar con las Command Line Tools.
- La ventana abre a 720 × 560 (mínimo 680 × 520) para que quepan las tarjetas sin apretarse.

---

## English

**CapyTask** is a macOS resource monitor with the clarity of the Windows Task Manager and an animated capybara that reacts to your Mac's load: relaxed, worried or stressed. **The whole app is available in Spanish and English** — switch any time in *Settings › General › Language* (it follows your system language by default).

- **Real kernel metrics** (Mach/libproc): per-core CPU, physical memory (active, inactive, wired, compressed, free), disk and processes — they match `top` and Activity Monitor.
- **Visual Summary**: CPU, RAM and disk rings with the capybara in the middle, *Hungriest Apps* with their icons, memory breakdown, per-core load and history.
- **Processes**: sortable table (Name, PID, CPU %, Memory MB, Type) with live search, *My Apps Only / All Processes* filter and **End Task** (SIGTERM, then SIGKILL after 3 s) with confirmation.
- **Floating pet**: borderless sticker that floats over every window, draggable, remembers its position, animates on hover and shows a CPU/RAM bubble. Double-click opens the monitor; right-click opens a quick menu.
- **Menu bar** item with live usage, pet toggle and settings.
- **Lightweight**: ~16 MB and ~0.02 % CPU in the background with the pet on screen.

### Download

Get `CapyTask-1.0.0.zip` from [Releases](https://github.com/K1suru/CapyTask/releases/latest), unzip it and drag **CapyTask.app** to *Applications*. Universal binary (Apple Silicon and Intel), macOS 14 or later.

The app is not signed with an Apple Developer certificate, so macOS blocks it the first time. To open it: right-click **CapyTask.app** › **Open** › **Open**, or use *System Settings › Privacy & Security* › **Open Anyway**, or run `xattr -dr com.apple.quarantine /Applications/CapyTask.app`.

### Build from source

```bash
scripts/build_app.sh   # builds build/CapyTask.app (universal, ad-hoc signed); only Command Line Tools needed
scripts/test.sh        # runs the test suite
```
