# UWBplugin — Posicionamiento indoor UWB para Unity (iOS)

Framework nativo iOS que estima la posición 2D del teléfono a partir de distancias UWB
a beacons Estimote de posición conocida (trilateración por mínimos cuadrados + filtro
de Kalman de velocidad constante), expuesto a Unity mediante funciones `@_cdecl`.

## Build Instructions

```commandline
xcodebuild -scheme UWBplugin -configuration Release -sdk iphoneos CONFIGURATION_BUILD_DIR=./Products -destination generic/platform=iOS
```

## API C (desde Unity)

Todas las funciones que devuelven `Int32` usan `0` como éxito y códigos negativos como
error. Ninguna ruta del bridge puede abortar el proceso: un JSON inválido devuelve un
código de error, nunca un crash.

| Función | Firma C# | Descripción |
|---|---|---|
| `setAnchorMap` | `int setAnchorMap(string json)` | Carga el mapa de anclas (JSON). `0` ok, `-1` string null, `-2` JSON inválido (se conserva el mapa anterior). Si el pipeline está activo, lo resetea sobre el nuevo mapa. |
| `start` | `int start()` | Inicia el pipeline. `0` ok, `-1` sin mapa. Si ya está corriendo, reinicia (nunca apila dos pipelines). |
| `stop` | `void stop()` | Desconecta sensores, detiene el escaneo y libera todo. |
| `getCoords` | `IntPtr getCoords()` | JSON `{"x":…,"y":…}` con la última posición filtrada. Tras el primer fix conserva la última posición válida durante cortes (usar `getPositionData` para saber la frescura). Liberar con `freeCString`. |
| `getPositionData` | `int getPositionData(out double x, out double y, out double residual, out int activeAnchors, out double fixAgeMs)` | Igual que `getCoords` pero sin asignar JSON (apto para polling por frame) y con calidad del fix: residual RMS de la trilateración (m), número de anclas usadas y edad del fix (ms). Devuelve `1` si hay fix, `0` si no. |
| `freeCString` | `void freeCString(IntPtr ptr)` | Libera el string de `getCoords`. |
| `setDistanceFilter` | `void setDistanceFilter(int enabled, double maxDistance)` | Excluye del cálculo los sensores que midan más de `maxDistance` m (histéresis de re-inclusión al 85%). No desconecta sesiones. |
| `setUserHeight` | `void setUserHeight(double height)` | Altura del teléfono (m) para proyectar distancias inclinadas al plano del piso: `d_h = √(d² − (z_ancla − h)²)`. Usar 1.2–1.4 con anclas en techo. `<= 0` desactiva la proyección (default). |
| `triggerUIRefresh` | `void triggerUIRefresh()` | Workaround de refresco de UI. Ya no publica notificaciones falsas de ciclo de vida; fuerza layout de la jerarquía de vistas. |

`setDistanceFilter` y `setUserHeight` pueden llamarse antes o después de `start()`; la
configuración se retiene y se aplica al pipeline activo.

### Uso de la calidad del fix

`residual` alto (> ~0.5 m) o `fixAgeMs` creciendo indican un fix poco confiable
(obstáculos, multipath, pocas anclas frescas): Unity decide ahí si congelar la cámara,
ocultar el avatar, etc. El plugin nunca borra la última posición; solo deja de
actualizarla.

## Formato del mapa de anclas

```json
{
  "31787018dfdd4c2fb241f563081da8d2": { "x": 0.0, "y": 0.0, "z": 2.5 },
  "b288b83142c74bf0ab28178d93532e32": { "x": 4.0, "y": 0.0, "z": 2.5 }
}
```

Claves: `publicIdentifier` del beacon (el mismo que muestra Estimote Cloud).
Coordenadas en **metros**. `z` es la altura del ancla sobre el piso; solo se usa si la
proyección está activa (`setUserHeight > 0`). Si registras las anclas con `z = 0`,
deja la proyección desactivada.

## Mapeo de ejes plugin ↔ Unity

El plugin trabaja en un plano 2D de piso: `x` e `y` en metros sobre el plano del mapa
(el mismo sistema en que se registraron las anclas). Unity usa X/Z como plano
horizontal con Y hacia arriba, así que la conversión canónica es:

```
Unity.X = plugin.x
Unity.Z = plugin.y
Unity.Y = altura que defina la app (el plugin no estima altura)
```

Mantén esta transposición en **un solo punto** del lado C# (p. ej. `UWBLocator`);
cualquier rotación/offset del mapa respecto a la escena debe aplicarse ahí también.

## Parámetros de tuning

| Parámetro | Dónde | Default | Significado |
|---|---|---|---|
| `measurementStd` | `KalmanFilter.init` | 0.1 m | Ruido de medición UWB (R = σ²). Subir en entornos con mucho multipath. |
| `processAccelStd` | `KalmanFilter.init` | 0.8 m/s² | Aceleración aleatoria del modelo (Q). Subir si el filtro "arrastra" al caminar rápido; bajar si tiembla. |
| `stalenessWindow` | `PositionCoordinator` | 1.0 s | Solo anclas con medida más reciente que esto entran a la trilateración. |
| `connectionTimeout` | `ViewModel` | 10 s | Sin updates durante este tiempo → desconexión del sensor. |
| `connectionLimit` | `ViewModel` | 6 | Conexiones UWB simultáneas (iOS limita las sesiones de Nearby Interaction; se rota hacia anclas más cercanas). |
| `maxRadialSpeed` / `gateSlack` | `PositionCoordinator` | 4 m/s / 0.5 m | Compuerta de outliers por ancla: saltos mayores requieren confirmación en la siguiente medida. |

## Arquitectura

```
Unity (C#) → @_cdecl (Main.swift) → ViewModel → PositionCoordinator → UWBManager → EstimoteUWB SDK
```

Todo el estado mutable vive en una `OperationQueue` serial; lo único que cruza hilos es
el snapshot de posición publicado, protegido con lock (leído por `getCoords` /
`getPositionData` desde el hilo de Unity).

Ver `UWBplugin/SWIFT_PLUGIN_CHANGES.md` (filtro de distancia) y
`UWBplugin/CAMBIOS_ESTABILIDAD_PRECISION.md` (revisión de estabilidad y precisión)
para el detalle de los cambios.
