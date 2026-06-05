#!/usr/bin/env bash
# hermes-bootstrap.sh — aplica los tweaks de configuración personal sobre un Hermes recién instalado.
#
# Asume:
#   - Hermes ya instalado (hermes-agent vive en $HERMES_HOME/hermes-agent/)
#   - Que WallasAPI corre en localhost:8001 (cambiar BASE_URL si está en otro lado)
#
# Lo que hace (idempotente — seguro re-ejecutar):
#   1. Backup de config.yaml, SOUL.md, USER.md, MEMORY.md
#   2. Pin de modelo a nvidia:mistralai/ministral-14b-instruct-2512 (vía WallasAPI)
#   3. Memory provider = holographic (local SQLite, sin cloud)
#   4. Web backend = tavily (requiere TAVILY_API_KEY en .env)
#   5. Remueve toolset huérfano "hermes" del platform_toolsets.cli
#   6. Pone SOUL.md con las 10 reglas que aprendimos
#   7. Pone MEMORY.md con notas operacionales
#   8. Crea USER.md template si está vacío (vos lo personalizás)
#   9. Parchea plugin Tavily para usar Tavily.answer (bug real del upstream)
#  10. Instala numpy en el venv de Hermes (opcional, HRR features de holographic)
#  11. Instala wrapper `hermes-up` en ~/.local/bin (actualiza Hermes y re-aplica
#      parches en una sola operación — usalo SIEMPRE en lugar de `hermes update`)
#
# Después del script:
#   - Editá ~/.hermes/memories/USER.md con tus datos reales
#   - Agregá TAVILY_API_KEY=tvly-... a ~/.hermes/.env
#   - Asegurate que WallasAPI esté corriendo (wallasapi start)
#   - hermes
#
# Para actualizar Hermes a futuras versiones:
#   hermes-up      # NO uses `hermes update` directo, te borra los parches

set -u  # no set -e — queremos seguir aunque algún paso ya esté aplicado

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
WALLAS_BASE_URL="${WALLAS_BASE_URL:-http://localhost:8001/v1}"
DEFAULT_MODEL="${HERMES_DEFAULT_MODEL:-nvidia:mistralai/ministral-14b-instruct-2512}"

# ---------------------------------------------------------------- preconditions
if [[ ! -d "$HERMES_HOME" ]]; then
  echo "[ERROR] Hermes no está en $HERMES_HOME — instalalo primero con el one-liner oficial:" >&2
  echo "        curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash" >&2
  exit 1
fi
if [[ ! -d "$HERMES_HOME/hermes-agent" ]]; then
  echo "[ERROR] $HERMES_HOME/hermes-agent/ no existe — install incompleto?" >&2
  exit 1
fi
if [[ ! -f "$HERMES_HOME/config.yaml" ]]; then
  echo "[ERROR] $HERMES_HOME/config.yaml no existe — corré 'hermes' al menos una vez para generarlo" >&2
  exit 1
fi

# ---------------------------------------------------------------- 1. backup
TS="$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR="$HERMES_HOME/bootstrap-backup-$TS"
mkdir -p "$BACKUP_DIR"
for f in config.yaml SOUL.md memories/USER.md memories/MEMORY.md; do
  if [[ -f "$HERMES_HOME/$f" ]]; then
    install -D "$HERMES_HOME/$f" "$BACKUP_DIR/$f"
  fi
done
echo "[1/10] Backup en $BACKUP_DIR"

# ---------------------------------------------------------------- 2. model pin
sed -i "s|^  default:.*|  default: $DEFAULT_MODEL|" "$HERMES_HOME/config.yaml"
sed -i 's|^  provider:.*|  provider: custom|' "$HERMES_HOME/config.yaml"
sed -i "s|^  base_url:.*|  base_url: $WALLAS_BASE_URL|" "$HERMES_HOME/config.yaml"
# Hermes a veces deja api_key vacío — anything-local funciona si WallasAPI no tiene PROXY_API_KEY
if ! grep -q "^  api_key:" "$HERMES_HOME/config.yaml"; then
  sed -i '/^  base_url:/a\  api_key: anything-local' "$HERMES_HOME/config.yaml"
fi
# Terminal tool: forzar shell host (backend=local), sin docker ni modal fallback.
# Bugs observados:
#  - Con docker_image o modal_mode=auto setteados, Hermes a veces spawnea un
#    sandbox con reloj congelado y reporta fechas de 2024 cuando el host está
#    en 2026. Vaciar docker_image + modal_mode=never lo evita.
#  - persistent_shell=true cachea una shell con env del primer spawn (TZ raro,
#    etc). Resultado: 'date' devuelve hora UTC+1 o similar en lugar del TZ
#    del sistema. Cambiando a persistent_shell=false cada comando agarra
#    /etc/timezone correctamente.
sed -i "/^terminal:/,/^[^ ]/ s|^  backend:.*|  backend: local|" "$HERMES_HOME/config.yaml"
sed -i 's|^  modal_mode:.*|  modal_mode: never|' "$HERMES_HOME/config.yaml"
sed -i 's|^  docker_image:.*|  docker_image: ""|' "$HERMES_HOME/config.yaml"
sed -i 's|^  persistent_shell:.*|  persistent_shell: false|' "$HERMES_HOME/config.yaml"
# Bashrc: asegurar TZ=America/Lima (cambiá por tu TZ si vives en otra zona).
# Hermes auto-sourcea bashrc en cada nueva shell — esto garantiza que `date`
# devuelva la zona local sin depender de que el modelo recuerde el prefijo TZ=...
if ! grep -q "^export TZ=" "$HOME/.bashrc" 2>/dev/null; then
  echo "export TZ=America/Lima" >> "$HOME/.bashrc"
fi
echo "[2/10] Modelo pinned a $DEFAULT_MODEL via $WALLAS_BASE_URL; terminal local + persistent_shell off; TZ exportado en bashrc"

# ---------------------------------------------------------------- 3. memory provider
# holographic = plugin shipped con Hermes, local SQLite + FTS5, sin cloud
sed -i "/^memory:/,/^[^ ]/ s|^  provider: ''|  provider: holographic|" "$HERMES_HOME/config.yaml"
sed -i "/^memory:/,/^[^ ]/ s|^  provider: \"\"|  provider: holographic|" "$HERMES_HOME/config.yaml"
echo "[3/10] Memory provider = holographic (local SQLite, sin cloud)"

# ---------------------------------------------------------------- 4. web backend
sed -i 's|^  backend: ddgs|  backend: tavily|' "$HERMES_HOME/config.yaml"
echo "[4/10] Web backend = tavily (necesita TAVILY_API_KEY en .env)"

# ---------------------------------------------------------------- 5. orphan toolset
sed -i '/^      - hermes$/d' "$HERMES_HOME/config.yaml"
echo "[5/10] Toolset huérfano '- hermes' removido"

# ---------------------------------------------------------------- 6. SOUL.md
cat > "$HERMES_HOME/SOUL.md" << 'SOULEOF'
# Hermes Agent Persona

Eres Hermes, asistente personal directo y honesto del usuario (definido en USER.md).
Hablas en español por default — el usuario escribe en español casi siempre.

## Reglas de oro — NUNCA romper

1. **Si el usuario pregunta algo sobre sí mismo** (nombre, cumpleaños, color favorito,
   proyecto, ubicación, preferencias) — primero MIRA USER.md (ya está inyectado
   en este prompt). Si no está ahí, invoca el tool fact_store con
   action=probe y entity=user. **NUNCA inventes** datos personales. Si no sabes,
   decí 'no tengo esa información'.

2. **Si el usuario dice 'recuerda que...' / 'guarda que...' / 'no olvides...'** —
   invoca el tool fact_store con action=add, content=el hecho, category=user_pref
   y mostrá el fact_id que devuelve. NUNCA respondas 'ya lo guardé' sin haber
   invocado el tool — el usuario verifica.

3. **Si el usuario pide 'verifica' / 'muéstrame qué guardaste' / 'usa las tools'** —
   invoca fact_store con action=list, o probe entity=user. Mostrá el resultado raw.

4. **Cuando dudes entre los tools memory y fact_store**: usá fact_store. El tool
   memory built-in está vacío en este install; toda la memoria real vive en
   holographic via fact_store.

5. **Después de invocar CUALQUIER tool, SIEMPRE producí una respuesta textual
   al usuario**, aunque el tool devuelva vacío. Si fact_store devuelve [] o
   sin resultados, decí explícitamente 'No tengo registro de X en mi memoria'.
   NUNCA termines tu turno en silencio después de un tool call — el usuario
   queda esperando y la sesión se traba en reintentos.

6. **USA LOS RESULTADOS DE LOS TOOLS.** Cuando web_search te devuelve datos sobre
   clima, hora, noticias, precios, etc — esos datos SON tu información en tiempo
   real. NUNCA respondas 'no tengo acceso a información en tiempo real' después
   de que un tool te dio resultados. Tu trabajo es resumir lo que el tool te dio.
   Si Tavily devolvió 'Lima 20 grados nublado', decí exactamente eso, no
   sugerencias de AccuWeather.

7. **Para preguntas de HORA, FECHA o ZONA HORARIA específicas**:
   PRIMER intento: tool terminal con: TZ=America/Lima date '+%Y-%m-%d %H:%M:%S %Z'
   (cambiá America/Lima por la zona del usuario). Es exacto al segundo.
   NO uses 'timedatectl' — requiere systemd y falla en WSL.
   Si terminal devuelve una fecha que claramente está mal (años desfasados,
   timezone raro), FALLBACK: web_search con query 'sitio:time.is/es/Lima' o
   equivalente para la zona del usuario. NO inventes.

8. **NUNCA escribas sintaxis de tool calls como texto en tu respuesta al usuario.**
   Las tools se invocan estructuradamente (function calling) y el usuario solo
   ve el resultado. Si escribís literalmente 'web_search(query=...)' o
   'fact_store(action=add, ...)' como parte de tu respuesta, está mal — el
   usuario lo lee como bug. INVOCÁ la tool y respondé en lenguaje natural sobre
   el resultado. Tu monologue interior (chain of thought) NO debe filtrarse al
   chat — mantenelo dentro de las invocaciones reales.

9. **Routing de "guardá esto" — elegí el destino correcto.** Hermes tiene
   TRES sistemas de memoria. Decisión basada en señales del usuario:

   - **USER.md** (`memory` tool con target=user) — identidad y preferencias
     ESTABLES del usuario. Se carga en cada turn (límite 1375 chars, no
     desperdiciar). Usar cuando el usuario diga:
     "soy X" / "trabajo en Y" / "mi stack es Z" / "anotá en mi perfil" /
     "prefiero respuestas en español" / "no me expliques cosas básicas".

   - **MEMORY.md** (`memory` tool con target=memory) — reglas/decisiones
     OPERACIONALES vivas del proyecto. Se carga en cada turn (límite 2200
     chars). Usar cuando el usuario diga:
     "regla del proyecto" / "decidimos que" / "anotá en memory" /
     "workaround temporal" / "URL/comando que uso seguido".

   - **fact_store** (plugin holographic, SQLite, sin tope) — TODO LO DEMÁS.
     Hechos dinámicos, granulares, voluminosos. Se consulta on-demand, no
     contamina el system prompt. Default cuando dudes. Usar para:
     clientes, transacciones, deadlines, campañas, snippets de research,
     hechos sobre personas/lugares/productos.

   **Regla de oro: si el usuario no especifica destino, andá a fact_store**
   (es lo más barato en contexto). Si dudás entre MEMORY.md y fact_store,
   andá a fact_store. USER.md solo cuando claramente es sobre la identidad
   estable del usuario.

   Después de guardar, decí EXPLÍCITAMENTE dónde quedó:
   "Guardado en tu perfil (USER.md)" / "Anotado en MEMORY.md" /
   "Registrado en fact_store con id #N". Nunca digas solo "listo, guardado"
   sin decir dónde.

10. **Delegation + persistencia — los subagentes son efímeros.** Los
    subagentes (delegate_task) NO heredan USER.md / MEMORY.md y NO pueden
    escribir a fact_store ni a memory.md (skip_memory=True, tool memory
    bloqueado, plugin holographic no inyectado). Lo único que sobrevive
    es el resultado textual que el subagente devuelve al padre. Por
    defecto ese resultado solo vive en tu contexto y se pierde al
    terminar la sesión.

    Cuando recibás el output de un subagente que contenga hallazgos
    útiles (research, decisiones, datos de clientes/proyectos), DESPUÉS
    de presentárselo al usuario invocá fact_store(action='upsert') para
    persistir los 3-5 puntos más valiosos con una categoría descriptiva
    ("meta_ads_research", "competitor_analysis", etc).

    Avisale al usuario QUÉ guardaste explícitamente ("Guardé en fact_store
    estos 4 hallazgos: ...") para que pueda corregirte si elegiste mal.
    Si el usuario no quiere persistir nada, te lo va a decir; pero el
    default es persistir, porque el costo de perder research es alto.

    Cuando le delegues tareas al subagente, en el goal mismo incluí los
    datos relevantes del usuario que necesita ("el usuario es [Nombre],
    trabaja en proyecto [X], prefiere [Y]") — el subagente no los va a
    poder consultar por su cuenta.

## Tono

Concreto. Sin floritura ni '¡claro!' innecesarios. Si el usuario es breve, vos también.
SOULEOF
echo "[6/10] SOUL.md con 10 reglas escritas"

# ---------------------------------------------------------------- 7. MEMORY.md
cat > "$HERMES_HOME/memories/MEMORY.md" << 'MEMEOF'
Setup activo: WallasAPI corre en localhost:8001 dentro de WSL (provider=custom en config Hermes). Comandos útiles: wallasapi status, wallasapi update, wallasapi logs.
§
Memory provider activo: holographic (plugin local SQLite, NO cloud). Tools disponibles: fact_store (add/probe/search/list/remove/contradict) y fact_feedback (helpful/unhelpful).
§
Notas operacionales sobre WallasAPI: el tier 'agentico' filtra a strong tool callers gratis. Si el modelo no llama tools fiablemente, cambiar model.default a gemini:gemini-2.5-pro (más lento ~5-15s pero respeta tool results).
§
Cosas que no funcionan en este install: Ollama local daemon está down (los modelos ollama:* fallan con Connection refused). Para usarlos hay que arrancar Ollama en Windows o dentro de WSL.
MEMEOF
echo "[7/10] MEMORY.md con notas operacionales"

# ---------------------------------------------------------------- 8. USER.md
# Solo crear template si está vacío — no clobereamos un USER.md que ya tenga datos.
USER_MD="$HERMES_HOME/memories/USER.md"
if [[ ! -s "$USER_MD" ]] || ! grep -q "Nombre:" "$USER_MD"; then
  cat > "$USER_MD" << 'USEREOF'
Nombre: [TU NOMBRE COMPLETO AQUÍ]
§
Cumpleaños: [DD de MES]
§
Ubicación: [Ciudad, País]
§
Color favorito: [color]
§
Proyecto principal: [nombre del proyecto y descripción de una línea]
§
Setup: [SO + WSL si aplica] + Hermes con model.default = gemini:gemini-2.5-pro apuntando a WallasAPI en localhost:8001. Memory provider: holographic (SQLite local en ~/.hermes/memory_store.db).
USEREOF
  echo "[8/10] USER.md template creado — EDITALO con tus datos reales antes de usar Hermes"
else
  echo "[8/10] USER.md ya tiene datos — no se toca"
fi

# ---------------------------------------------------------------- 9. Tavily plugin patch
# Bug upstream: el plugin Tavily ignora el campo 'answer' que es la respuesta
# sintetizada por su LLM. Sin ese fix, el modelo cliente recibe solo snippets
# crudos y confunde sunset/sunrise con hora actual, ciudades homónimas, etc.
TAVILY_FILE="$HERMES_HOME/hermes-agent/plugins/web/tavily/provider.py"
if [[ -f "$TAVILY_FILE" ]]; then
  if grep -q '"include_answer": True' "$TAVILY_FILE"; then
    echo "[9/10] Plugin Tavily ya parchado (skip)"
  else
    # Backup del archivo original antes de parchar
    cp -p "$TAVILY_FILE" "$BACKUP_DIR/tavily_provider.py.orig"
    # Agregar include_answer + search_depth al request
    sed -i 's|"include_images": False,|"include_images": False,\n                    "include_answer": True,\n                    "search_depth": "advanced",|' "$TAVILY_FILE"
    # Modificar normalize para usar el campo answer
    python3 - "$TAVILY_FILE" << 'PYPATCH'
import sys, re
p = sys.argv[1]
src = open(p).read()
old = '''def _normalize_tavily_search_results(response: Dict[str, Any]) -> Dict[str, Any]:
    """Map Tavily ``/search`` response to ``{success, data: {web: [...]}}``."""
    web_results = []
    for i, result in enumerate(response.get("results", [])):
        web_results.append(
            {
                "title": result.get("title", ""),
                "url": result.get("url", ""),
                "description": result.get("content", ""),
                "position": i + 1,
            }
        )
    return {"success": True, "data": {"web": web_results}}'''
new = '''def _normalize_tavily_search_results(response: Dict[str, Any]) -> Dict[str, Any]:
    """Map Tavily ``/search`` response. Prepends synthesized answer as first result."""
    web_results = []
    answer = (response.get("answer") or "").strip()
    if answer:
        web_results.append({
            "title": "Tavily synthesized answer",
            "url": "tavily://answer",
            "description": answer,
            "position": 0,
        })
    for i, result in enumerate(response.get("results", [])):
        web_results.append({
            "title": result.get("title", ""),
            "url": result.get("url", ""),
            "description": result.get("content", ""),
            "position": len(web_results),
        })
    return {"success": True, "data": {"web": web_results}}'''
if old in src:
    open(p, "w").write(src.replace(old, new))
    print("  normalizer patched")
else:
    print("  normalizer already patched or upstream changed shape — leaving as is")
PYPATCH
    echo "[9/10] Plugin Tavily parchado (backup: $BACKUP_DIR/tavily_provider.py.orig)"
  fi
else
  echo "[9/10] Plugin Tavily no encontrado en $TAVILY_FILE — skip"
fi

# ---------------------------------------------------------------- 10. numpy
# Optional pero recomendado para HRR (Holographic Reduced Representations)
# del plugin holographic. Sin numpy degrada a FTS5 puro.
VENV_PY="$HERMES_HOME/hermes-agent/venv/bin/python"
if [[ -x "$VENV_PY" ]]; then
  if "$VENV_PY" -c "import numpy" >/dev/null 2>&1; then
    echo "[10/10] numpy ya instalado en venv (skip)"
  else
    if command -v uv >/dev/null 2>&1; then
      uv pip install numpy --python "$VENV_PY" >/dev/null 2>&1 && echo "[10/10] numpy instalado via uv" || echo "[10/10] numpy install falló — manual: uv pip install numpy --python $VENV_PY"
    else
      "$VENV_PY" -m pip install numpy >/dev/null 2>&1 && echo "[10/10] numpy instalado via pip" || echo "[10/10] numpy install falló (instalalo a mano si querés HRR)"
    fi
  fi
fi

# ---------------------------------------------------------------- 10b. API_SERVER_KEY
# Hermes Gateway (v0.14+) se niega a arrancar el api_server platform si
# API_SERVER_KEY no está seteado, incluso para binds loopback-only en
# 127.0.0.1. Generamos una key local random si no existe; la dejamos en
# .env (no en config.yaml) para mantenerla fuera de git.
ENV_FILE="$HERMES_HOME/.env"
if [[ -f "$ENV_FILE" ]] && grep -q "^API_SERVER_KEY=" "$ENV_FILE" 2>/dev/null; then
  echo "[10b/11] API_SERVER_KEY ya presente en .env (skip)"
else
  if command -v openssl >/dev/null 2>&1; then
    GEN_KEY=$(openssl rand -hex 32)
  else
    GEN_KEY=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
  fi
  {
    echo ""
    echo "# API key del gateway (loopback only) — generada por hermes-bootstrap.sh"
    echo "API_SERVER_KEY=$GEN_KEY"
  } >> "$ENV_FILE"
  echo "[10b/11] API_SERVER_KEY generada y agregada a $ENV_FILE"
fi

# ---------------------------------------------------------------- 11. hermes-up wrapper
# Cuando el usuario corra `hermes update`, el git pull de Hermes pisa el patch
# del plugin Tavily. El wrapper `hermes-up` corre `hermes update` y después
# re-ejecuta este mismo bootstrap para restaurar todos los parches en una
# sola operación. Resuelve la ruta absoluta del script para que el symlink
# en ~/.local/bin pueda llamarlo después.
BOOTSTRAP_PATH="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/$(basename "${BASH_SOURCE[0]}")"
USER_BIN="$HOME/.local/bin"
mkdir -p "$USER_BIN"
cat > "$USER_BIN/hermes-up" <<HERMUP
#!/usr/bin/env bash
# hermes-up — actualiza Hermes y re-aplica los parches locales.
# Generado por hermes-bootstrap.sh (no editar a mano, se sobrescribe en cada
# corrida del bootstrap).
set -e
echo "[1/3] Actualizando Hermes core (hermes update)..."
hermes update --skip-restart 2>/dev/null || hermes update
echo "[2/3] Re-aplicando parches locales (bootstrap)..."
"$BOOTSTRAP_PATH"
echo "[3/3] Listo. Reiniciá Hermes con: hermes"
HERMUP
chmod +x "$USER_BIN/hermes-up"
# Asegurar que ~/.local/bin esté en el PATH (vía ~/.bashrc).
if ! grep -Fq '$HOME/.local/bin' "$HOME/.bashrc" 2>/dev/null; then
  echo '' >> "$HOME/.bashrc"
  echo '# Added by hermes-bootstrap.sh' >> "$HOME/.bashrc"
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
fi
echo "[11/11] Wrapper hermes-up instalado en $USER_BIN/hermes-up"

# ----------------------------------------------------------------- next steps
cat <<NEXT

╔══════════════════════════════════════════════════════════════════╗
║                   BOOTSTRAP COMPLETO                             ║
╚══════════════════════════════════════════════════════════════════╝

Tu Hermes ya tiene aplicados los parches que aprendimos. Backup en:
  $BACKUP_DIR

Próximos pasos antes de usar:

  1. Editá USER.md con tus datos reales:
       nano $HERMES_HOME/memories/USER.md

  2. Conseguí tu Tavily API key (1000 búsquedas/mes free, sin tarjeta):
       https://app.tavily.com/home
       echo "TAVILY_API_KEY=tvly-..." >> $HERMES_HOME/.env

  3. Asegurate que WallasAPI esté corriendo:
       wallasapi status
       wallasapi start    # si no está

  4. Arrancá Hermes:
       hermes

Para actualizar Hermes a futuras versiones (re-aplica parches automáticamente):
  hermes-up      # NUNCA uses 'hermes update' directo, te borra los parches

Lo que ya funciona out-of-the-box después de los pasos arriba:
  ✓ Memoria persistente local (holographic SQLite, sin cloud)
  ✓ fact_store tools (probe/add/list/search)
  ✓ Web search vía Tavily con respuesta sintetizada (fix del bug upstream)
  ✓ Reglas que evitan alucinaciones de identidad y silencios post-tool
  ✓ Default model = Ministral 14B (verificado como mejor tool caller del free tier)
  ✓ Wrapper hermes-up que sobrevive a los updates del core

Para revertir todos los cambios:
  cp $BACKUP_DIR/config.yaml $HERMES_HOME/
  cp $BACKUP_DIR/SOUL.md $HERMES_HOME/
  cp $BACKUP_DIR/memories/* $HERMES_HOME/memories/
  cp $BACKUP_DIR/tavily_provider.py.orig $TAVILY_FILE  # si existe
  rm $USER_BIN/hermes-up

NEXT
