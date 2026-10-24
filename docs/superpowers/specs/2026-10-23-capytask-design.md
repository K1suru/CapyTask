# CapyTask — Documento de Diseño y Especificación Técnica 🍊

**Fecha:** 23 de octubre de 2026  
**Proyecto:** CapyTask (Monitor de Sistema y Mascota Flotante para macOS)  
**Estado:** Propuesta de Diseño para Aprobación  

---

## 1. Visión del Proyecto

**CapyTask** es un monitor de recursos del sistema para macOS inspirado en la claridad del Administrador de Tareas de Windows, pero con una identidad visual tierna (*cute*) protagonizada por un capibara. Combina métricas reales y precisas del kernel de macOS con un compañero de escritorio flotante (*desktop companion*) que reacciona emocionalmente en tiempo real a la carga del equipo.

### Objetivos Clave
1. **Consumos reales y exactos**: Lecturas veraces de CPU, Memoria RAM (activa, inactiva, cableada, comprimida), Almacenamiento y lista completa de procesos mediante APIs nativas de Darwin / Mach kernel.
2. **Eficiencia extrema**: Diseñado en Swift nativo para mantener un impacto insignificante (<30 MB de RAM y <0.5% de CPU en segundo plano).
3. **Doble visualización**: Pestaña de *Resumen Visual* (gráficos de anillo, top consumidores y capibara animado en su onsen) y pestaña de *Procesos* (tabla detallada con búsqueda, ordenamiento y botón para finalizar tareas).
4. **Mascota flotante interactiva**: Capibara flotante en pantalla, libremente arrastrable, con sutil sombra, sin bordes molestos, activable/desactivable a voluntad y con reacciones dinámicas al estrés del sistema.
5. **Vida en segundo plano**: Integración en la barra de menú superior de macOS (Menu Bar) para operación continua y silenciosa.

---

## 2. Arquitectura de Software

```
┌─────────────────────────────────────────────────────────────┐
│                       CapyTask App                          │
│                                                             │
│   ┌──────────────────────┐       ┌──────────────────────┐   │
│   │   Menu Bar Agent     │       │ CapyPetController    │   │
│   │ (NSStatusItem / Pop) │       │ (NSPanel Flotante)   │   │
│   └──────────┬───────────┘       └──────────┬───────────┘   │
│              │                              │               │
│              ▼                              ▼               │
│   ┌─────────────────────────────────────────────────────┐   │
│   │             CapyTask MainWindow (SwiftUI)           │   │
│   │  - Tab 1: Resumen Visual (Anillos, Top Apps, Onsen) │   │
│   │  - Tab 2: Procesos (Tabla estilo Task Manager)      │   │
│   └──────────────────────────┬──────────────────────────┘   │
│                              │                              │
│                              ▼                              │
│   ┌─────────────────────────────────────────────────────┐   │
│   │            SystemMonitorEngine (Observable)         │   │
│   │      Timer Adaptativo: 1.0s (Focus) / 2.5s (Idle)   │   │
│   └──────────┬──────────────────────────────┬───────────┘   │
└──────────────┼──────────────────────────────┼───────────────┘
               ▼                              ▼
┌──────────────────────────────┐ ┌──────────────────────────────┐
│       Darwin / Mach APIs     │ │        libproc / Sysctl      │
│ - host_processor_info        │ │ - proc_listpids              │
│ - mach_host_self             │ │ - proc_pidinfo (taskinfo)    │
│ - host_statistics64          │ │ - proc_pidpath / NSRunningApp│
└──────────────────────────────┘ └──────────────────────────────┘
```

### 2.1 Tecnologías
- **Lenguaje:** Swift 6.4 (compilación nativa arm64 / Apple Silicon y x86_64).
- **Framework de UI:** SwiftUI combinado con AppKit (`NSPanel`, `NSStatusItem`, `NSWorkspace`).
- **APIs de Métricas del Sistema:**
  - `mach_host_self()` y `host_processor_info()` para cálculo diferencial exacto de ticks de CPU (User, System, Idle, Nice).
  - `host_statistics64()` con `HOST_VM_INFO64` para medición real de memoria física (Wired, Active, Inactive, Compressed, Free).
  - `libproc` (`proc_listpids`, `proc_pidinfo`, `proc_taskinfo`) para métricas por proceso individual sin spawnear subprocesos shell pesados.
  - `NSWorkspace` para extraer nombres amigables de aplicaciones e iconos oficiales de macOS (.icns / bundle icons).

---

## 3. Componentes del Sistema

### 3.1 `SystemMonitorEngine` (Motor Central de Métricas)
- **Patrón:** Singleton `@Observable` compartido por toda la app.
- **Frecuencia Adaptativa:**
  - **1.0 segundo:** Si la ventana principal de CapyTask está abierta y en foco.
  - **2.5 segundos:** Si solo la mascota flotante o el menú superior están activos, minimizando el impacto en la batería.
- **Métricas globales calculadas:**
  - `cpuUsage`: Porcentaje global (0% a 100%).
  - `cpuCores`: Carga individual por núcleo (Performance Cores y Efficiency Cores).
  - `memoryStats`: Memoria Usada vs Memoria Libre (en GB y %), desglosada en App Memory, Wired y Compressed.
  - `diskStats`: Espacio ocupado y libre del disco principal.
  - `stressLevel`: Valor normalizado entre 0.0 y 1.0 calculado como `max(cpuUsage, memoryUsagePercentage)`.

### 3.2 `ProcessSampler` (Muestreador de Procesos)
- Lee la tabla de procesos del kernel directamente mediante C Darwin APIs.
- Extrae para cada proceso:
  - `pid`: ID de proceso.
  - `name`: Nombre de la aplicación o ejecutable.
  - `icon`: Icono nativo de la app vía `NSWorkspace`.
  - `cpuPercent`: Porcentaje de CPU calculado sobre el delta entre dos muestras consecutivas.
  - `memoryBytes`: Memoria residente real (`pti_resident_size`).
  - `isUserApp`: Booleano que diferencia si el proceso pertenece a una aplicación en `/Applications` o es un daemon interno de macOS (`launchd`, `kernel_task`, etc.).

### 3.3 `CapyPetController` & `CapyPetOverlayView` (Mascota Flotante)
- **Ventana:** Subclase personalizada de `NSPanel`:
  - `styleMask = [.borderless, .nonactivatingPanel]`
  - `level = .floating` (se mantiene sobre el resto de ventanas sin robar el foco de teclado).
  - `backgroundColor = .clear`, `isOpaque = false`, `hasShadow = true`.
  - Arrastrable libremente por la pantalla mediante eventos de mouse (`mouseDragged`).
  - Persistencia de posición en `UserDefaults` (recuerda dónde la dejaste, con validación de pantalla activa para monitores desconectados).
- **Interactividad:**
  - **Hover:** Al pasar el cursor por encima, aparece una pequeña burbujita redondeada con el porcentaje actual (ej: `CPU: 18% · RAM: 42%`).
  - **Doble clic:** Abre o trae al frente la ventana principal de CapyTask.
  - **Clic derecho:** Despliega un menú contextual rápido:
    - 👁️ *Ocultar Mascota*
    - 🔒 *Fijar en esta posición (desactivar arrastre accidental)*
    - 📊 *Abrir Monitor Completo*
    - ⚙️ *Ajustes de CapyTask*
    - ❌ *Cerrar CapyTask*
- **Estados Emocionales del Capibara (Bucles Animados en Tiempo Real):**
  | Estado | Rango de Carga | Animación y Acción (Seamless Loop 2-3s) | Fuente de Asset |
  |---|---|---|---|
  | **Normal / Relajado** | < 40% | Sentado plácidamente, respiración rítmica, parpadeo tierno y orejitas relajadas | `capy_anim_normal` (Google Flow / PNG Sequence) |
  | **Preocupado** | 40% - 75% | Orejitas alertas en movimiento, mirando nerviosamente a los lados, gotita de sudor en la frente | `capy_anim_worried` (Google Flow / PNG Sequence) |
  | **Estresado / Sobrecarga** | > 75% | Postura tensa, orejitas hacia atrás, ojos apretados o achinados (> <), mejillas sonrojadas por el calor y respiración agitada contenida (estrés sutil sin exageraciones) | `capy_anim_stressed` (Google Flow / PNG Sequence) |

- **Pipeline de Generación y Transparencia:**
  - Los clips se generan en **Google Flow** con relación de aspecto cuadrada (1:1), duración de 2 a 3 segundos en bucle continuo (*seamless loop*) y sobre fondo de pantalla verde pura croma (`#00FF00`).
  - Un script en el proyecto (`scripts/process_capy_clips.sh`) aplica chroma key automático con `ffmpeg`/Python para remover el fondo verde y exportar secuencias de fotogramas PNG transparentes de alta resolución.
  - SwiftUI reproduce los fotogramas en tiempo real con un componente optimizado (`CapySpriteView`), manteniendo un consumo nulo de CPU y permitiendo que el capibara flote transparente sobre el escritorio de macOS.


---

## 4. Diseño de la Ventana Principal (`CapyTaskMainWindow`)

La ventana principal tiene dimensiones cómodas (~680 x 520 px), esquinas redondeadas con estilo macOS moderno y paleta de colores cálida inspirada en CapyCoin.

### 4.1 Barra de Herramientas Superior
- **Logo y Título:** Ícono de capibara + texto "CapyTask".
- **Selector de Pestañas (Segmented Picker):**
  - 📊 **Resumen Visual**
  - 📋 **Procesos**
- **Interruptor de Mascota:** Toggle cute tipo switch: *"Mascota en Pantalla: ON / OFF"*.

### 4.2 Pestaña 1: "Resumen Visual"
1. **Tarjeta de Rendimiento Circular (Donut Charts):**
   - Anillo concéntrico principal: CPU (naranja mandarina).
   - Anillo secundario: Memoria RAM (verde menta suave).
   - Anillo exterior: Disco (azul agua onsen).
   - En el centro: Avatar grande del Capibara en su tina con microanimación de respiración/flotación y texto de estado (ej: *"Todo tranquilo, 24% de esfuerzo"*).
2. **Tarjeta de "Top Apps Devoradoras":**
   - Podio de las 5 aplicaciones que más recursos están consumiendo en ese instante.
   - Cada fila muestra: Ícono oficial de la app, Nombre, Barra de progreso y % de CPU / MB de RAM.
3. **Métricas Rápidas:**
   - RAM Total instalada vs Libre.
   - Núcleos de CPU activos y velocidad de muestreo.

### 4.3 Pestaña 2: "Procesos"
1. **Barra de Control:**
   - Campo de búsqueda en vivo con ícono de lupa ("Buscar por app o proceso...").
   - Filtro: Botones de selección rápida `[Solo Mis Apps]` vs `[Todos los Procesos]`.
   - Contador de procesos activos (ej. `72 apps de usuario / 340 procesos totales`).
2. **Tabla de Procesos Interactiva:**
   - Columnas ordenables (clic en cabecera para ordenar ascendente/descendente):
     - **Aplicación / Proceso:** Ícono nativo + Nombre + PID.
     - **CPU (%):** Porcentaje con barra visual sutil en color naranja.
     - **Memoria:** Consumo en MB o GB con indicador de peso.
     - **Tipo:** Etiqueta distintiva `App` (en verde pastel) o `Sistema` (en gris).
3. **Acción de Finalización:**
   - Botón rojo suave **"Finalizar Tarea"** (Kill Process).
   - Al seleccionarse un proceso y presionar el botón, se despliega una pequeña alerta amigable de confirmación para evitar cierres accidentales.
   - Envía señal `SIGTERM`, y si no responde en 3 segundos, `SIGKILL`.

---

## 5. Menú Superior (Menu Bar Item)

- Vive en la barra de menú con un ícono miniatura de capibara (`NSStatusItem`).
- Al hacer clic, abre un menú emergente rápido con:
  - Mini estado de consumo en una línea: `CPU: 14% · RAM: 8.2 GB`.
  - Toggle rápido: `[✓] Mostrar Mascota en Pantalla`.
  - Botón: `Abrir CapyTask...` (`⌘O`).
  - Botón: `Preferencias...` (`⌘,`).
  - Separador y `Salir de CapyTask` (`⌘Q`).

---

## 6. Recursos Visuales y Estilo

### 6.1 Assets
Importados directamente de la carpeta de diseño de `CapyCoin`:
- `capy_onsen_relaxed.png`
- `capy_onsen_cautious.png`
- `capy_onsen_worried.png`
- `capy_onsen_panic.png`
- `capy_sleeping.png`
- `capy_logo.png`

### 6.2 Paleta de Colores
- **Capy Brown:** `#7A4B29` (acentos y textos principales).
- **Mandarina Orange:** `#FF8C42` (indicador de CPU y alertas).
- **Bamboo Green:** `#88A764` (indicador de RAM saludable y tags de apps).
- **Onsen Blue:** `#5B92E5` (gráficas de disco y agua).
- **Warm Cream Background:** `#FDFBF7` (modo claro) / `#23211F` (modo oscuro nativo de macOS).

---

## 7. Estructura del Código y Construcción

El proyecto se estructurará como un paquete estándar de Swift (`Package.swift`) para ser compilable desde la línea de comandos con el SDK nativo de macOS:

```
Monitor/
├── Package.swift
├── Sources/
│   └── CapyTask/
│       ├── App/
│       │   ├── CapyTaskApp.swift          // Punto de entrada & App Lifecycle
│       │   ├── MenuBarController.swift    // Control de NSStatusItem
│       │   └── AppState.swift             // Estado global y configuración
│       ├── Core/
│       │   ├── SystemMonitorEngine.swift  // Hilo de muestreo y temporizador
│       │   ├── CPUReader.swift            // Mach host processor info
│       │   ├── MemoryReader.swift         // Mach host VM statistics
│       │   └── ProcessManager.swift       // Darwin libproc enumerator & kill
│       ├── Pet/
│       │   ├── CapyPetWindow.swift        // NSPanel transparente y flotante
│       │   ├── CapyPetController.swift    // Lógica de arrastre y estados
│       │   └── CapyPetView.swift          // Vista SwiftUI de la mascota y badge
│       ├── UI/
│       │   ├── MainWindowView.swift       // Ventana principal con pestañas
│       │   ├── VisualSummaryTab.swift     // Pestaña 1: Anillos y Onsen
│       │   ├── ProcessListTab.swift       // Pestaña 2: Tabla de tareas
│       │   └── Theme.swift                // Colores, tipografía y estilos
│       └── Resources/
│           ├── Assets.xcassets/           // PNGs de Capibara (512x512)
│           └── Info.plist                 // Configuración del bundle de macOS
├── scripts/
│   ├── build_app.sh                       // Compila y crea CapyTask.app
│   └── install.sh                         // Instala en /Applications
└── docs/
    └── superpowers/specs/
        └── 2026-10-23-capytask-design.md
```

---

## 8. Verificación y Criterios de Aceptación

1. **Lectura Real de Recursos:**
   - La CPU y la RAM coinciden con los valores reportados por `top -l 1` y *Monitor de Actividad* de macOS.
2. **Eficiencia:**
   - La app consumirá menos de 35 MB de RAM y menos de 0.5% de CPU cuando la ventana esté cerrada y solo la mascota esté activa.
3. **Comportamiento de la Mascota:**
   - Flota sobre todas las demás aplicaciones.
   - Es arrastrable con suavidad y conserva su posición al reabrir la app o reiniciar.
   - Cambia su expresión a relajado, atento, preocupado o pánico según la carga del sistema.
4. **Control de Procesos:**
   - Se puede buscar cualquier aplicación abierta y forzar su cierre de forma segura previa confirmación.
