# Manual de Modding — Breath of Fire IV Recomp (PC y Android)

Esta guía explica paso a paso cómo crear, probar, empaquetar e instalar **mods de código**, **packs de texturas HD**, **reemplazos de archivos de disco** y **mods nativos** para **Breath of Fire IV Recomp** (tanto en **Android** como en **PC**).

---

## 1. Dónde se guardan los mods

Todos los mods viven dentro de la carpeta `mods/` junto a tus archivos del juego:

- **PC (Linux / Windows / macOS):** junto al ejecutable `bof4` (en el directorio de trabajo donde está `bof4.ini`):
  ```text
  mods/<nombre_del_mod>/
  ```
- **Android:**
  ```text
  /Android/data/com.bof4recomp.app/files/mods/<nombre_del_mod>/
  ```
  > **Consejo para Android 11+:** No necesitas un explorador de archivos con permisos especiales. Puedes empaquetar tu mod en un archivo **`.zip`** e instalarlo con un toque usando el botón **Import Mod (.zip)** en la pantalla inicial (o abrir el **Menú → MODS → Mod Importer (.zip)** dentro del juego).

Las carpetas cuyo nombre empiece por `.` o `_`, así como `mods/dumped_textures/`, son ignoradas automáticamente por el cargador de mods.

---

## 2. Estructura de un mod

Cada mod es una carpeta dentro de `mods/`. Todos los archivos son opcionales — incluye únicamente lo que tu mod necesite:

```text
mods/mi_mod_epico/
├── mod.ini                  # Metadatos, prioridad y estado (activado/desactivado)
├── code.txt                 # Parches de código MIPS, RAM, overlays y GameShark
├── patches/                 # (Opcional) Archivos adicionales .txt / .patch / .cht
│   ├── combate.txt
│   └── balance.txt
├── textures/                # (Opcional) Texturas PNG personalizadas (1x, 2x, 4x HD)
│   ├── 4f8a1c029b7e11d0_ryu_capa.png
│   ├── vram_320_0_64x64.png
│   └── 320_0_0_480_0_0_64x64.png
├── disc/                    # (Opcional) Reemplazo de archivos del CD-ROM ISO9660
│   └── DATA/ARC001.EMI
└── native/                  # (Opcional) Código nativo recompilado personalizado
    ├── bof4_arm64.native    # Para Android ARM64
    └── bof4.native          # Para PC / arquitectura genérica
```

---

## 3. El archivo `mod.ini`

`mod.ini` describe tu mod y define su orden de carga. Si lo omites, el mod se carga automáticamente con el nombre de su carpeta y prioridad `100`.

```ini
[mod]
name = Mi Mod de Balance y Texturas HD
author = TuNombre
version = 1.0.0
description = Mejora los sprites principales y ajusta la curva de dificultad.
priority = 100
enabled = true
```

### Orden de prioridad (`priority`)
- Los mods se cargan en **orden ascendente de `priority`** (`10` antes que `100`, `100` antes que `200`).
- Si dos mods modifican la misma dirección de memoria, textura o archivo del disco, **gana el mod con mayor `priority`** (el que se carga al final).
- Puedes activar o desactivar cualquier mod **en tiempo real** desde el menú del juego (`MENU → MODS`), y el cargador actualizará automáticamente `enabled = true/false` en `mod.ini`.

---

## 4. Cómo hacer mods que modifican el código (`code.txt` y `patches/*.txt`)

El motor de parches escribe en la RAM de PlayStation (2 MB: `0x80000000`–`0x801FFFFF`) a través del bus del emulador (`cpu.w8/w16/w32`). Esto activa automáticamente `cpu.ram_touch`: si tu mod parchea instrucciones MIPS dentro de funciones recompiladas estáticamente, **esas páginas se invalidan automáticamente** para que el código MIPS modificado se ejecute de forma segura tanto en modo intérprete como en modo recompilado.

### 4.1 Sintaxis completa de parches

Los comentarios pueden empezar por `#`, `//` o `;`.

| Comando | Descripción | Ejemplo |
| --- | --- | --- |
| `write8 <dir> <val>` | Escribe 1 byte (`0x00`–`0xFF`) cada vblank | `write8 0x800A1234 0x63` |
| `write16 <dir> <val>` | Escribe 2 bytes little-endian (`0x0000`–`0xFFFF`) | `write16 0x800A1234 0x03E7` |
| `write32 <dir> <val>` | Escribe 4 bytes (ideal para instrucciones MIPS) | `write32 0x80034560 0x24020063` |
| `nop <dir>` | Reemplaza la instrucción MIPS de 32 bits por `NOP` (`0x00000000`) | `nop 0x80034564` |
| `bytes <dir> <b0> <b1> ...` | Escribe una secuencia arbitraria de bytes hexadecimales | `bytes 0x80090000 48 6F 6C 61 00` |
| `once <comando>` | Aplica el parche **una sola vez** al cargar el mod | `once write32 0x80015000 0x00000000` |
| `if32 <dir> == <val> -> <cmd>` | **Seguro para overlays:** solo parchea si en `<dir>` está el opcode exacto `<val>` | `if32 0x80120040 == 0x27BDFFE0 -> write32 0x80120044 0x24020001` |
| `if32 <dir> != <val> -> <cmd>` | Aplica `<cmd>` si el valor de 32 bits en `<dir>` es distinto a `<val>` | `if32 0x80120040 != 0x00000000 -> nop 0x80120048` |
| `if16 <dir> == <val> -> <cmd>` | Condición de 16 bits igual | `if16 0x800C0010 == 0x0001 -> write16 0x800C0020 0x03E7` |
| `if16 <dir> != <val> -> <cmd>` | Condición de 16 bits distinto | `if16 0x800C0010 != 0x0000 -> write8 0x800C0024 0xFF` |

### 4.2 Compatibilidad con códigos GameShark / Action Replay de PS1

Puedes pegar códigos clásicos de PlayStation 1 directamente en `code.txt`:

- `80XXXXXX YYYY` → Escribe `YYYY` (16 bits) en `0x80XXXXXX`
- `30XXXXXX 00YY` → Escribe `YY` (8 bits) en `0x80XXXXXX`
- `D0XXXXXX YYYY` → Condición: ejecuta la línea siguiente solo si `[0x80XXXXXX] == YYYY`
- `D1XXXXXX YYYY` → Condición: ejecuta la línea siguiente solo si `[0x80XXXXXX] != YYYY`

Ejemplo:
```text
# Código condicional GameShark (solo aplica cuando el indicador está activo)
D011A400 0001
8011A402 03E7
```

### 4.3 Cómo parchear overlays dinámicos de Breath of Fire IV sin corromper otros módulos

Breath of Fire IV carga distintos **overlays** (combate, exploración, menú de campamento, minijuegos) en las mismas direcciones de RAM (por ejemplo `0x80100000+`). Si escribes un parche incondicional en una dirección de overlay, corromperás los demás módulos cuando se carguen ahí.

**Solución:** usa siempre `if32` verificando una instrucción firma única de ese overlay (el prólogo o una instrucción vecina que NO sobrescribas):

```text
# Parche seguro para el overlay de combate:
# Comprueba la instrucción firma en 0x80112000 antes de parchear 0x80112018.
if32 0x80112000 == 0x27BDFFD8 -> write32 0x80112018 0x24020002
if32 0x80112000 == 0x27BDFFD8 -> nop 0x8011201C
```

Cada vblank (60 veces por segundo), el cargador comprueba la firma:
- Cuando el juego carga el overlay de combate → el parche se aplica automáticamente al instante.
- Cuando el juego cambia al mapa de exploración → la firma ya no coincide y tu parche no toca nada.

### 4.4 Ejemplo de ensamblador MIPS R3000A (PS1)

Las instrucciones de PlayStation 1 son MIPS I (little-endian, 32 bits por instrucción). Recuerda el **branch delay slot** (la instrucción inmediatamente después de un `j`, `jal`, `jr`, `beq` o `bne` también se ejecuta).

Instrucciones útiles frecuentes:
- `0x00000000` → `nop`
- `0x03E00008` → `jr $ra` (retornar de función; recuerda poner `nop` en el delay slot siguiente)
- `0x2402XXXX` → `addiu $v0, $zero, 0xXXXX` (cargar constante de retorno en `$v0`, p. ej. `0x24020063` = devolver `99`)
- `0x08XXXXXX` → `j target` donde `XXXXXX = (target & 0x0FFFFFFF) >> 2` (saltar a una *code cave* en RAM libre)
- `0x0CXXXXXX` → `jal target` (llamar a una subrutina personalizada en tu *code cave*)

Ejemplo de **code cave** en `code.txt`:
```text
# Subrutina personalizada en RAM libre (0x801F8000):
# Duplica $v0 (sll $v0, $v0, 1) y retorna
once write32 0x801F8000 0x00021040  # sll $v0, $v0, 1
once write32 0x801F8004 0x03E00008  # jr  $ra
once write32 0x801F8008 0x00000000  # nop (delay slot)

# Gancho seguro que llama a nuestra subrutina desde una función del juego:
if32 0x80045000 == 0x27BDFFE8 -> write32 0x80045020 0x0C07E000  # jal 0x801F8000
```

> **Consejo:** Puedes usar Ghidra, `mipsel-linux-gnu-as` o herramientas de ensamblado MIPS online para obtener los opcodes de 32 bits exactos.

### 4.5 Mods avanzados de código nativo (`native/`)

Si modificas directamente el código fuente recompilado de `port/src/rec/` o `port/src/qol/` y compilas tu propio blob nativo (`bof4_arm64.native` o `bof4.native`), colócalo en `mods/<tu_mod>/native/`. El cargador lo detecta antes de arrancar `psx.run` y lo carga en lugar del binario por defecto (el mod activado con mayor `priority` tiene preferencia).

---

## 5. Cómo crear packs de texturas personalizadas (1x y HD 2x/4x)

El renderizador incluye un **sistema nativo de volcado (dumping) y reemplazo de texturas PNG** que funciona tanto a resolución 1x como con texturas de alta definición **2x, 4x o cualquier resolución hasta 2048×2048** (RGBA con transparencia).

### 5.1 Flujo recomendado (el método más fácil: volcar → editar → cargar)

1. **Abre el menú en el juego** tocando el botón **`MENU`** en la parte superior de la pantalla (o pulsando `L3 + R3` en mando / `F1` en PC).
2. Ve a la pestaña **`MODS`** y activa **`Dump Textures → ON`**.
3. Juega normalmente las escenas, menús o personajes cuyas texturas quieras modificar.
4. El motor guardará automáticamente cada sprite/textura única en formato PNG dentro de:
   ```text
   mods/dumped_textures/<HASH_16_HEX>_<tx>_<ty>_<cx>_<cy>_<u>_<v>_<w>x<h>.png
   ```
   Por ejemplo:
   ```text
   mods/dumped_textures/4f8a1c029b7e11d0_320_0_0_480_0_0_64x64.png
   ```
5. Desactiva **`Dump Textures → OFF`** cuando ya tengas las texturas capturadas.
6. Edita esos archivos PNG en GIMP, Photoshop, Aseprite, Krita o reescálalos con IA (2x/4x — por ejemplo de `64x64` a `256x256`).
   - **Importante:** Mantén el **hash de 16 dígitos hexadecimales** al inicio del nombre del archivo (por ejemplo `4f8a1c029b7e11d0_ryu_hd.png` o `4f8a1c029b7e11d0.png`).
   - Usa canal alfa (transparencia PNG normal) para las zonas transparentes.
7. Copia tus PNG editados dentro de:
   ```text
   mods/mi_pack_hd/textures/
   ```
   (Puedes organizarlos en subcarpetas dentro de `textures/`, por ejemplo `textures/personajes/`, `textures/ui/`, `textures/enemigos/` — el cargador busca de forma recursiva).
8. En el juego, abre **`MENU → MODS → Reload All Mods`** — ¡verás tus texturas nuevas **al instante sin reiniciar el juego**!

### 5.2 Los 3 formatos de nombre soportados en `textures/`

| Formato de nombre | Cuándo usarlo | Cómo funciona |
| --- | --- | --- |
| `<16hex>.png` o `<16hex>_etiqueta.png` | **Recomendado para sprites, retratos, UI y packs HD** | Compara por hash FNV-1a de los píxeles originales de PS1. Funciona incluso si el juego mueve la textura a otra posición de VRAM. Soporta **cualquier resolución HD** (ej. 2x, 4x) y usa filtrado bilineal suave automáticamente. |
| `<tx>_<ty>_<cx>_<cy>_<u>_<v>_<w>x<h>.png` | Reemplazo exacto por coordenadas de página de textura (`tx, ty`), paleta CLUT (`cx, cy`) y recorte UV (`u, v, w, h`) | Útil cuando quieres reemplazar un recorte específico independientemente de su contenido. Soporta HD. |
| `vram_<x>_<y>_<w>x<h>.png` | Reemplazo directo de bloques subidos a la VRAM de 15 bits de PS1 (fondos, pantallas de título, texturas 3D) | Intercepta la subida `GP0(A0h)` a la región `(x, y, w, h)` de la VRAM de 1024×512. |

> **Consejo para texturas HD:** En **`MENU → VIDEO`**, asegúrate de tener **Resolution en `2x` o `4x`** para apreciar todo el detalle nítido de tus texturas HD de alta resolución!

---

## 6. Cómo reemplazar archivos del disco (`disc/`)

Si modificas diálogos, mapas, música, modelos o archivos internos del CD-ROM de PlayStation 1 sin tener que reconstruir toda la imagen `.bin/.cue`:

1. Coloca el archivo modificado dentro de `mods/<tu_mod>/disc/` respetando exactamente la ruta dentro del disco ISO9660 (p. ej. `mods/traduccion/disc/DATA/ARC001.EMI`).
2. Al iniciar o recargar mods, el cargador busca automáticamente el LBA original en el disco mediante `disc.find()` e intercepta las lecturas del CD-ROM en caliente mediante `spu.sector_hook`.
3. Tu archivo de reemplazo no puede superar el tamaño en sectores del archivo original del disco (si es menor, el espacio sobrante se rellena con ceros).

---

## 7. Cómo empaquetar e instalar un mod en Android (`.zip`)

Para compartir tu mod o instalarlo cómodamente en Android:

1. Crea un archivo `.zip` que contenga la carpeta de tu mod:
   ```text
   mi_mod_hd.zip
   └── mi_mod_hd/
       ├── mod.ini
       ├── code.txt
       └── textures/
           └── 4f8a1c029b7e11d0_ryu_hd.png
   ```
   *(También funciona si `mod.ini`, `code.txt` y `textures/` están directamente en la raíz del `.zip`: el importador creará automáticamente la carpeta con el nombre del `.zip`).*
2. En Android, abre el botón **Import Mod (.zip)** en la pantalla de inicio (si ya estabas dentro del juego, abre **`MENU → MODS → Mod Importer (.zip)`** y vuelve a abrir la app).
3. Selecciona tu archivo `.zip`. Se descomprimirá automáticamente dentro de `mods/` y aparecerá listo en **`MENU → MODS`**.

---

## 8. Configuración relacionada en `bof4.ini`

El menú integrado (`MENU`) guarda automáticamente tus cambios en `bof4.ini`, pero también puedes editarlo a mano:

```ini
[window]
detail = 2              # 1 (320x240), 2 (640x480), 4 (1280x960)
fps_limit = 60          # 30, 60, 90, 120 o 0 (sin límite)
backend = opengl        # auto, opengl (OpenGL ES en Android / OpenGL en PC) o vulkan
anti_wobble = true      # Corrección subpíxel PGXP (elimina el temblor de polígonos 3D)
filter = linear         # linear (suave, evita temblor de píxeles) o nearest (píxeles nítidos)
smooth_textures = true  # Filtrado anti-shimmer de texels en 2x/4x

[audio]
smooth_fix = true       # Remuestreo adaptativo + rampa suave sin chasquidos
latency_ms = 140        # Tamaño de búfer en ms (40–400; 120–180 recomendado en Android)
volume = 1.0            # Volumen maestro (0.0 a 1.0)

[mods]
enabled = true          # Activa o desactiva el cargador de mods
textures = true         # Activa o desactiva reemplazos de texturas PNG
dump_textures = false   # Activa el volcado de texturas a mods/dumped_textures/
```

---

## 9. Solución de problemas

- **Mi mod no aparece en `MENU → MODS`:**
  - Comprueba que esté dentro de `mods/<nombre>/` (no directamente suelto en `mods/`).
  - Verifica que el nombre de la carpeta no empiece por `.` o `_` ni se llame `dumped_textures`.
  - Pulsa **`Reload All Mods`** dentro del menú.
- **Mi parche de código no surte efecto:**
  - Si modificas un overlay (combate/mapa), verifica que la dirección y la firma en `if32` coincidan con tu región del disco (**SLUS-01324**, versión US).
  - Revisa la consola o `bof4_boot.log` para confirmar cuántos parches se cargaron (`mods: loaded X active mod(s): Y code patch(es)...`).
- **Mi textura PNG no se reemplaza:**
  - Comprueba que sea un archivo `.png` válido (RGB o RGBA, hasta 2048×2048).
  - Asegúrate de que **`Mods Enabled`** y **`Texture Packs`** estén en **`ON`** en `MENU → MODS`.
  - Verifica que los primeros 16 caracteres hexadecimales del nombre coincidan con el archivo generado por **`Dump Textures`**.
