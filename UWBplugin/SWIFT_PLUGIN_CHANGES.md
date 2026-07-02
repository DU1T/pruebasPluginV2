# Cambios en el plugin Swift — Filtro de distancia UWB

**Proyecto:** UWBPlugin
**Área:** `UWBplugin/` (framework nativo consumido por Unity)
**Relacionado con:** `UWBTestApp/` (app de prueba SwiftUI, usada como referencia)

---

## 1. Resumen

Se implementó un **filtro de distancia** en el plugin nativo: permite excluir sensores
UWB del cálculo de posición cuando superan una distancia máxima configurable, sin
desconectarlos físicamente.

El filtro ya existía en `UWBTestApp` (app de prueba con UI). Este cambio lo **porta al
plugin real** (`UWBplugin/`), que es el que Unity consume, adaptándolo a un contexto sin
UI y con acceso vía polling (`getCoords()`) en lugar de bindings reactivos.

---

## 2. Contexto de arquitectura

El proyecto tiene dos implementaciones paralelas dentro de `UWBPlugin-main/`:

| Carpeta | Qué es | Rol del filtro |
|---|---|---|
| `UWBTestApp/` | App iOS SwiftUI de prueba | Implementación original, con UI (`@Observable AppState`, throttle 8Hz, etc.) |
| `UWBplugin/` | Framework nativo real, **sin UI** | Implementación portada, consumida por Unity vía polling |

Flujo del plugin (el que le interesa a quien continúe el proyecto):

```
Unity (C#, UWBLocator) → @_cdecl (Main.swift) → ViewModel → PositionCoordinator → UWBManager (Estimote SDK)
```

`PositionCoordinator` corre en una `OperationQueue` serial
(`maxConcurrentOperationCount = 1`, referida como `UWBQueue`), para evitar condiciones de
carrera entre las mediciones que llegan del SDK de Estimote y los cambios de
configuración que llegan desde Unity.

---

## 3. Principio de diseño del filtro (leer antes de tocar el código)

**El filtro nunca desconecta sensores por distancia.**

Una versión anterior desconectaba y reconectaba sensores según el umbral. Esto causaba
ciclos de connect/disconnect a ~10Hz, porque las mediciones UWB son ruidosas cerca del
límite (un sensor a 5.05m puede oscilar entre 4.9m y 5.1m constantemente).

El diseño actual:

- Mantiene **todas** las sesiones UWB activas siempre.
- Filtra **a nivel de datos**: los sensores fuera de rango se excluyen del cálculo de
  trilateración, pero siguen midiendo y reportando distancia.
- Usa **histéresis** para evitar oscilación en el límite del umbral.

### Histéresis

Con `hysteresisRatio = 0.85` y un umbral de 5m:

- Se **excluye** un sensor al superar 5.0m.
- Se **re-incluye** solo al bajar a 4.25m (85% del umbral).
- Entre 4.25m y 5.0m hay una **zona muerta**: el sensor mantiene el estado que tenía,
  sin cambiar.

```
5.1m → excluido | 4.9m → sigue excluido | 4.2m → re-incluido
                          ↑ zona muerta, no cambia de estado
```

Sin esto, un sensor justo en el borde del umbral generaría inclusiones/exclusiones
varias veces por segundo, y por lo tanto saltos en la trilateración.

> **Nota:** el timeout de 10s que desconecta un sensor que dejó de reportar por completo
> es un mecanismo **independiente** del filtro de distancia y no se modificó.

---

## 4. Cambios por archivo

### `UWBplugin/Coordinators/PositionCoordinator.swift`

**Propiedades nuevas:**

```swift
var outOfRangeDevices: Set<String> = []
var distanceFilterEnabled: Bool = false
var maxConnectionDistance: Double = 5.0
private let hysteresisRatio: Double = 0.85
```

**Lógica añadida dentro de `didUpdatePosition(deviceId:distance:)`:**

- Paso de histéresis: decide si el `deviceId` entra o sale de `outOfRangeDevices`,
  siguiendo la regla de la sección 3.
- La trilateración pasa a usar solo los anchors en rango:

  ```swift
  let activeAnchors = anchors.filter { !outOfRangeDevices.contains($0.key) }
  ```

  Si `activeAnchors.count < 3`, el resultado es `filteredPos = nil` (no hay suficientes
  sensores para triangular).
- Los sensores que expiran por timeout también se remueven de `outOfRangeDevices`, para
  que no queden "colgados" ahí indefinidamente.

**Método nuevo:**

```swift
func setDistanceFilter(enabled: Bool, maxDistance: Double)
```

- Se **encola en la `UWBQueue`**, para serializarse correctamente con
  `didUpdatePosition` y evitar data races entre el hilo que recibe mediciones del SDK y
  el hilo que aplica el cambio de configuración.
- Al desactivar el filtro (`enabled = false`), limpia `outOfRangeDevices` por completo
  (todos los sensores vuelven a estar disponibles para trilateración).

**Qué NO se portó desde `UWBTestApp`** (por ser exclusivo de la UI SwiftUI):

- Throttle de 8Hz (`uiUpdateInterval`)
- `AppState` / bindings observables
- `pendingExpiredIds`
- `outOfRangeSnapshot`

El plugin no empuja actualizaciones a una UI; Unity las **consulta por polling**, así
que estos mecanismos no aplican aquí.

---

### `UWBplugin/Main.swift`

**Globals nuevos:**

```swift
var distanceFilterEnabled: Bool = false
var maxConnectionDistance: Double = 5.0
```

Permiten persistir la configuración del filtro si Unity la setea **antes** de llamar a
`start()`, y que sobreviva a ciclos de `start()`/`stop()` (el `PositionCoordinator` se
recrea en cada `start()`).

**Función exportada nueva:**

```swift
@_cdecl("setDistanceFilter")
public func setDistanceFilter(_ enabled: Int32, _ maxDistance: Double)
```

- **Por qué `Int32` y no `Bool`:** el marshaling de `Bool` a través del límite C es
  ambiguo (puede representarse en 1 byte o 4 según la plataforma/compilador). `Int32`
  mapea de forma inequívoca a `int` de C, así que se usa `0`/`1` en vez de `Bool`.
- `Double` sí mapea 1:1 con `double` de C, sin ambigüedad, por eso no tiene el mismo
  tratamiento.

**En `start()`:** al crear el `PositionCoordinator`, se le aplica inmediatamente la
configuración persistida en los globals (`distanceFilterEnabled`,
`maxConnectionDistance`).

---

## 5. Parámetros configurables

| Constante | Archivo | Valor actual | Descripción |
|---|---|---|---|
| `hysteresisRatio` | `PositionCoordinator.swift` | `0.85` | Factor de re-inclusión (85% del umbral) |
| `maxConnectionDistance` | `Main.swift` / `PositionCoordinator.swift` | `5.0` m (default) | Umbral de exclusión, configurable desde Unity |
| `distanceFilterEnabled` | `Main.swift` / `PositionCoordinator.swift` | `false` (default) | Activa/desactiva el filtro |

---

## 6. Qué NO hace el filtro

- No desconecta el sensor del SDK de Estimote — la sesión UWB permanece activa siempre.
- No bloquea reconexiones — no hay cooldown adicional para sensores que vuelven a estar
  en rango.
- No afecta el timeout de 10s — un sensor fuera de rango puede expirar igual si deja de
  enviar datos por completo.

---

## 7. Para quien continúe el proyecto

- El punto de entrada para depurar el filtro es `didUpdatePosition(deviceId:distance:)`
  en `PositionCoordinator.swift` — ahí está toda la lógica de histéresis y filtrado.
- Si el filtro parece "no responder" desde Unity, revisar primero que
  `setDistanceFilter` se esté llamando **después** de que el framework esté cargado, y
  que los valores lleguen como `0`/`1` (no `true`/`false`) en el lado nativo.
- `UWBTestApp/` sigue siendo útil como banco de pruebas del comportamiento del
  filtro (activar/desactivar, mover el slider, ver los sensores cambiar de color) antes
  de validar en Unity, aunque su código no se ejecuta en producción.
