# hermes-bootstrap

Script que aplica los tweaks que sacamos en este experimento sobre un Hermes Agent recién instalado, para que el setup quede como el de mi máquina actual.

## Qué hace el script (10 pasos, idempotente)

1. **Backup** de `config.yaml`, `SOUL.md`, `USER.md`, `MEMORY.md` antes de tocar nada
2. Pin del **modelo default** a `gemini:gemini-2.5-pro` (`provider: custom` → WallasAPI en `localhost:8001`) y **fuerza terminal tool a backend `local`** (sin docker / modal fallback — evita el bug donde el sandbox reporta fechas de 2024 cuando el host está en 2026)
3. **Memory provider = holographic** (plugin shipped con Hermes, local SQLite + FTS5, sin cloud, sin API key extra)
4. **Web backend = tavily** (necesita `TAVILY_API_KEY` — free tier 1000/mes en https://tavily.com)
5. Remueve **toolset huérfano `- hermes`** del `platform_toolsets.cli` (era versión antigua, dispara warnings)
6. Escribe **SOUL.md con 8 reglas** que aprendimos a base de probar:
   - 1-4: usar fact_store / USER.md para identidad, nunca inventar
   - 5: siempre producir texto post-tool (evita loops de retry por respuesta vacía)
   - 6: usar resultados de tools, no dar disclaimers de "no tengo acceso a tiempo real"
   - 7: para hora/fecha usar `date` en terminal (no `timedatectl`, que requiere systemd); fallback a time.is via web_search
   - 8: nunca escribir sintaxis de tool calls como texto en la respuesta al usuario
7. Escribe **MEMORY.md con notas operacionales** del setup (WallasAPI, comandos útiles, qué hacer si el modelo falla)
8. Crea **USER.md template** si está vacío (con placeholders `[TU NOMBRE]` para personalizar)
9. **Parchea el plugin Tavily** del propio Hermes — bug real upstream: ignoraba el campo `answer` de Tavily (la respuesta sintetizada por su LLM, que es lo único confiable). Sin el parche, el modelo cliente solo veía snippets crudos y confundía sunset con hora actual
10. Instala **numpy** en el venv de Hermes (opcional, para HRR features del plugin holographic)

## Cómo usar en una máquina nueva

```bash
# 1. Instalar Hermes oficial primero (Linux/WSL2/macOS):
curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash
source ~/.bashrc

# 2. Correr Hermes una vez para que genere ~/.hermes/config.yaml inicial:
hermes        # contestá lo mínimo del wizard, salí con /exit

# 3. Copiar este script a la máquina (scp / cp / lo que sea) y ejecutar:
chmod +x hermes-bootstrap.sh
./hermes-bootstrap.sh

# 4. Editar USER.md con tus datos reales:
nano ~/.hermes/memories/USER.md

# 5. Conseguir Tavily key y agregarla al .env:
# Signup gratis en https://app.tavily.com/home → copiar key → ...
echo "TAVILY_API_KEY=tvly-tu-key" >> ~/.hermes/.env

# 6. WallasAPI tiene que estar corriendo en localhost:8001:
wallasapi status     # si no está, wallasapi start

# 7. Listo:
hermes
```

## Variables de entorno (opcional)

Para customizar antes de correr:

```bash
HERMES_HOME=/otra/ruta/hermes ./hermes-bootstrap.sh
WALLAS_BASE_URL=http://otrahost:8001/v1 ./hermes-bootstrap.sh
HERMES_DEFAULT_MODEL=groq:meta-llama/llama-4-scout-17b-16e-instruct ./hermes-bootstrap.sh
```

## Modelos sugeridos por orden de fiabilidad (para `HERMES_DEFAULT_MODEL`)

Todos free, vía WallasAPI. De más fiable a más rápido:

| Modelo | Velocidad | Sigue reglas SOUL.md | Cuándo elegirlo |
|---|---|---|---|
| `gemini:gemini-2.5-pro` | 5-15s | ✓ alto | Default — máxima fiabilidad |
| `nvidia:mistralai/mistral-medium-3.5-128b` | 3-8s | ✓ medio-alto | Si Gemini Pro tiene rate limit |
| `nvidia:mistralai/mistral-nemotron` | 2-5s | medio (mezcla idiomas a veces, fabrica al sintetizar) | Velocidad sobre exactitud |
| `groq:meta-llama/llama-4-scout-17b-16e-instruct` | 1-2s | medio | Más rápido pero descuidado |
| `agentico` | variable | ruleta | Si querés rotación automática del tier |

## Rollback

El script imprime al final el path del backup. Para revertir:

```bash
BACKUP=~/.hermes/bootstrap-backup-YYYYMMDD_HHMMSS
cp $BACKUP/config.yaml ~/.hermes/
cp $BACKUP/SOUL.md ~/.hermes/
cp $BACKUP/memories/* ~/.hermes/memories/
cp $BACKUP/tavily_provider.py.orig ~/.hermes/hermes-agent/plugins/web/tavily/provider.py  # si existe
```

## Patch del Tavily plugin — ¿lo mando como PR upstream?

Sí debería. El cambio es objetivo:
- Tavily expone un campo `answer` sintetizado por LLM, mucho más exacto que los snippets crudos
- El plugin actual lo descarta y solo pasa los snippets al modelo
- Modelos chicos confunden snippets de "sunset 17:47" con "hora actual = 17:47"

Si querés mandar el PR a `NousResearch/hermes-agent`, el diff vive en `hermes-bootstrap.sh` (pasos 9 — `include_answer: True` en el request y prepend del `answer` en el normalizer). El backup `.orig` en el dir de backup te sirve para hacer el diff: `diff -u backup/tavily_provider.py.orig ~/.hermes/hermes-agent/plugins/web/tavily/provider.py`.
