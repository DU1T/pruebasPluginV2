# Cambios en el plugin Swift — Revisión de estabilidad y precisión

**Proyecto:** UWBPlugin
**Área:** `UWBplugin/` (framework nativo consumido por Unity)
**Base:** auditoría del commit `9f7e360` (puntos A1–A5, B1–B7, C) + bugs adicionales
encontrados durante la implementación.

---

## 1. Resumen

Revisión completa del pipeline de posicionamiento. Dos objetivos:

1. **Estabilidad**: ninguna ruta llamada desde Unity puede crashear el proceso ni
   dejar estado corrupto (fatalError eliminados, carreras de datos cerradas, ciclo de
   retención roto, NaN en cuarentena).
2. **Precisión**: se eliminó la mayor fuente de error (acelerómetro crudo con gravedad
   dentro del Kalman) y se añadieron ventana de frescura, compuerta de outliers,
   proyección de altura, reset del filtro por mapa y rotación de conexiones.

La trilateración nueva es el solver 2D por mínimos cuadrados de la app espejo
(linealización + ecuaciones normales 2×2 con guarda de colinealidad y residual RMS),
que reemplaza a `tirlaterate_3D`, `multilateration` y el solver LAPACK.

---

## 2. Estabilidad

| Punto | Cambio |
|---|---|
| A1 — fatalError | `setAnchorMap` y `start` devuelven `Int32` (0 éxito / negativos error); `MapReader` devuelve `nil`; `Math.swift` (LAPACK + fatalError) eliminado. Ver nota ABI abajo. |
| A2 — carreras de datos | Todo el estado mutable vive en la cola serial UWB. La salida se publica como `PositionSnapshot` bajo `NSLock`; el cambio de mapa (`applyNewAnchorMap`) se encola igual que ya se hacía con `setDistanceFilter`. |
| A3 — ciclo de retención | `UWBManagerDelegate: AnyObject` y `weak var delegate` en `UWBManager`. `start()` con pipeline activo hace teardown y reinicia (nunca apila dos). |
| A4 — NaN | `trilaterate2D` devuelve `nil` con anclas colineales o resultado no finito (se conserva el último fix); el Kalman rechaza mediciones no finitas. La división por `afeb` desapareció con `tirlaterate_3D`. |
| A5 — notificaciones falsas | `triggerUIRefresh` ya no postea `didEnterBackground`/`willEnterForeground`/`didBecomeActive` sintéticas (las recibía todo SDK del proceso); ahora fuerza `setNeedsLayout`/`layoutIfNeeded` de la jerarquía de vistas. |

**Nota ABI:** pasar de `void` a `Int32` en `setAnchorMap`/`start` es seguro para los
`DllImport` C# existentes declarados `void` (el valor de retorno queda en registro y se
ignora). El C# nuevo puede declararlos `int` y comprobar el código.

## 3. Precisión

| Punto | Cambio |
|---|---|
| B1 — acelerómetro | Eliminado del pipeline (archivos borrados). La aceleración cruda venía en el marco del dispositivo, con gravedad, sin rotar al mapa, y además con dos bugs propios (ver §5). El Kalman queda como modelo de velocidad constante con `predict(dt)` en la ruta UWB. |
| B2 — distancias inclinadas | `setUserHeight(h)` proyecta cada distancia al plano del piso: `d_h = √(d² − (z_ancla − h)²)`. Default: desactivada (compatible con mapas de anclas registradas a z=0). |
| B3 — datos viejos | `stalenessWindow = 1.0 s`: solo anclas con medida reciente entran al fix. `connectionTimeout = 10 s` queda solo para desconectar, y los expirados se excluyen del tick actual (antes participaban una última vez). |
| B4 — medidas inválidas | `distance <= 0` o no finita se descarta (antes `abs()` las disfrazaba). Compuerta por ancla: un salto físicamente imposible (> 4 m/s·Δt + 0.5 m) queda pendiente y solo se acepta si la siguiente medida lo confirma. |
| B5 — Kalman sin reset | Ya no es singleton: instancia propiedad de `PositionCoordinator`, con `reset()` en cambio de mapa y bandera `isInitialized` (el primer fix inicializa el estado directamente, sin centinela `== .zero`). Tras un hueco > 2 s sin fixes se reinicializa en vez de extrapolar. |
| B6 — R y Q | `R = diag(0.1²)` (UWB ±0.1 m LoS) y `Q` del modelo de aceleración aleatoria `σa²·[[dt⁴/4, dt³/2],[dt³/2, dt²]]` por eje, con `σa = 0.8 m/s²`. Ambos son parámetros del init de `KalmanFilter`. |
| B7 — política de conexión | `connectionLimit = 6` (antes 100). Al llegar al límite, los descubiertos quedan como candidatos; si hay candidatos frescos y el ancla conectada más lejana supera el umbral de rotación (el del filtro de distancia, o 10 m), se libera para que el slot lo tome el candidato. |

## 4. Limpieza (C)

- `pickTopThreeAnchors`, `multInitializeMatrixVector` (con su fila de ceros del pivote),
  `gaussJordan`, `matrixMultiplication`, `transpose` y `solveQuadratic`: eliminados.
- `didDisconnect` del SDK ahora se propaga al coordinador (antes solo logueaba →
  `connectedDevices` quedaba desincronizado cuando la desconexión la iniciaba el beacon).
- `getCoords` ya no usa `JSONSerialization` (formato directo) y se añadió
  `getPositionData` con punteros de salida + calidad del fix (residual, nº de anclas,
  edad en ms) para polling por frame sin asignaciones.
- Mapeo de ejes plugin ↔ Unity documentado en el README.
- Typo `connectionTimout` corregido; `mapURL`/`refreshRate` muertos eliminados.

## 5. Bugs corregidos que no estaban en la auditoría

1. **`updateG(delta_time:)` usaba `0.5·dt` en la fila de posición** en lugar de
   `0.5·dt²`: la aceleración empujaba la posición ~10× de más a 10 Hz.
2. **`updateF(delta_time:)` construía `F` transpuesta**: el init sin etiqueta de
   `simd_double4x4` recibe *columnas*, no filas, así que el término `dt` acoplaba
   posición→velocidad (`vx += dt·x`): la velocidad estimada crecía con la *posición*.
   La reescritura usa `simd_double4x4(rows:)` explícito.
3. **`lastTime` no se actualizaba en el early-return** del acelerómetro → el primer
   `predict` tras el primer fix usaba un Δt acumulado enorme.
4. Ambos mueren con el acelerómetro, pero se documentan porque explican gran parte del
   comportamiento errático observado frente a la app espejo.

## 6. Cambios de comportamiento visibles desde Unity

- `getCoords` **conserva el último fix** durante cortes (< 3 anclas frescas) en lugar
  de volver a null; la frescura se consulta con `getPositionData` (`fixAgeMs`).
  Devuelve null solo antes del primer fix (o tras `stop`/cambio de mapa).
- `setAnchorMap` con JSON inválido conserva el mapa anterior y devuelve `-2` (antes:
  crash).
- Máximo 6 beacons conectados a la vez (rotación automática hacia los más cercanos).
- Nueva función `setUserHeight(double)`: activarla (1.2–1.4 m) cuando las anclas estén
  montadas en altura y el mapa registre su `z` real.

## 7. Pendientes / siguientes pasos

- Ajustar `measurementStd` / `processAccelStd` con logs reales del venue (B6 fino).
- `UWBTestApp/` conserva las copias antiguas de estas clases: portar la revisión si se
  quiere seguir usando como banco de pruebas.
- Si algún día se necesita predicción entre updates UWB: `CMDeviceMotion`
  (`userAcceleration` rotada por `attitude` al marco del mapa), nunca el acelerómetro
  crudo.
