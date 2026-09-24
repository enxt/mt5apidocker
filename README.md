# MetaTrader 5 en Docker + API HTTP

Un contenedor que ejecuta el terminal MetaTrader 5 bajo Wine y expone una API
HTTP (FastAPI) para controlarlo: cuenta, símbolos, cotizaciones, históricos,
órdenes, posiciones y un WebSocket con cotizaciones en tiempo real. El terminal
también se puede ver y manejar desde el navegador (noVNC).

## Estructura

```text
├── Dockerfile              # imagen: Debian 13 + Wine 11 + Python Windows + MT5
├── docker-compose.yml
├── .env.example            # copiar a .env
├── config/                 # tu servers.dat (no se sube a git ni a la imagen)
├── docker/                 # scripts del contenedor
│   ├── install-mt5.sh      #   descarga e instala MT5 (solo en el build)
│   ├── configure_terminal.py  # genera startup.ini (login) y ajusta common.ini
│   ├── entrypoint.sh
│   ├── run-mt5.sh          #   mantiene vivo el terminal
│   ├── run-server.sh       #   arranca la API cuando el terminal está en marcha
│   ├── dismiss-liveupdate.sh  # cierra la ventana de actualización del terminal
│   ├── supervisord.conf
│   └── requirements.txt    #   versiones fijadas para el Python de Wine
├── api/                    # la API (FastAPI) y sus tests
└── .github/workflows/docker.yml
```

## Puesta en marcha

Requisitos: Docker con soporte **linux/amd64 nativo** (Linux x86-64 o Windows
con Docker Desktop/WSL2). En Mac con Apple Silicon no funciona de forma fiable:
MT5 es un programa Windows x86-64 y no hay alternativa ARM.

```bash
cp .env.example .env        # y rellenar MT5_LOGIN, MT5_PASSWORD, MT5_SERVER, API_KEY_SEED
cp <tu servers.dat> config/   # ver «Servidor del broker» más abajo
docker compose up -d --build
docker compose logs -f
```

- Terminal en el navegador: <http://localhost:6901> (contraseña `VNC_PASSWORD`)
- API y documentación interactiva: <http://localhost:8000/docs>

El primer build tarda (descarga Wine, Python y MT5). El arranque del contenedor
lleva 1-2 minutos hasta que la API responde en `/health`.

Para usar la imagen publicada por GitHub Actions en lugar de compilarla, pon
`MT5_IMAGE=ghcr.io/<usuario>/mt5api:latest` en `.env` y usa
`docker compose pull && docker compose up -d`.

## Servidor del broker (`config/servers.dat`)

La imagen se construye con el instalador genérico de MetaQuotes, para que sea
la misma para todo el mundo y no revele con qué broker opera nadie. Ese
terminal solo conoce los servidores de MetaQuotes, y si `MT5_SERVER` es de
otro broker **ni siquiera intenta el login** (su log no dice nada).

La lista de servidores de tu broker se aporta al arrancar, como las
credenciales del `.env`: copia tu `servers.dat` en la carpeta `config/` del
proyecto. Se monta en el contenedor y se copia al terminal en cada arranque.
Está excluida de git y de la imagen.

Para obtenerlo, en cualquier MT5 de Windows desde el que ya hayas entrado en
tu cuenta (o tras buscar tu broker en *File → Open an Account*):

1. *File → Open Data Folder*.
2. Copia `Config\servers.dat` a `config/servers.dat` de este proyecto.
3. `docker compose up -d` (o `docker compose restart` si ya estaba en marcha).

En el log del contenedor debe aparecer `servers.dat imported from /config/servers.dat`.
Si falta, aparece un aviso `WARNING: no /config/servers.dat`.

## Cómo funciona

**Build** (capas ordenadas de menos a más cambiante):

1. Paquetes: Wine 11 (winehq-stable, versión fijada en `WINE_VERSION`), TigerVNC, noVNC, supervisor.
   A las DLLs de Wine se les quitan los símbolos de depuración (1,4 GB → 0,5 GB;
   `--build-arg STRIP_WINE=0` lo desactiva).
2. Prefijo de Wine y Python 3.9 para Windows.
3. Dependencias Python dentro de ese Python.
4. MetaTrader 5, con `install-mt5.sh`, en una etapa aparte con el Wine 10 de
   Debian (el instalador se cuelga con Wine 11); a la imagen final solo se
   copia la carpeta del terminal. Si la descarga o la instalación
   fallan, **el build falla** (antes generaba una imagen sin terminal). La
   build de MT5 instalada queda en `/opt/mt5-version`.
5. Scripts y código de la API.

**Arranque** (`entrypoint.sh` → supervisord):

```
configure_terminal.py   escribe startup.ini con cuenta/servidor y activa algo trading
x11                     Xtigervnc: servidor X + VNC en :5900
novnc                   websockify + noVNC en :6901
openbox                 gestor de ventanas
mt5                     wine terminal64.exe /portable /config:startup.ini
liveupdate              cierra la ventana de LiveUpdate (Restart/Later) cuando aparece
server                  espera al terminal y lanza la API (wine python -m app) en :8000
```

El login lo hace el propio terminal con el mecanismo oficial de MetaQuotes
(`/config:` con `[Common] Login/Password/Server`); ya no se teclea nada por VNC.
Si aun así no hubiera iniciado sesión, la API reintenta `mt5.initialize()`
pasándole las credenciales.

## Variables de entorno

| Variable | Descripción | Por defecto |
| :--- | :--- | :--- |
| `MT5_LOGIN` | Número de cuenta | `0` (sin login) |
| `MT5_PASSWORD` | Contraseña de la cuenta | - |
| `MT5_SERVER` | Servidor del broker (p. ej. `Deriv-Demo`) | - |
| `MT5_MAX_BARS` | Barras de histórico por gráfico | `1000000` |
| `API_KEY_SEED` | Semilla de la API key; vacío desactiva la autenticación | - |
| `LOG_LEVEL` | Nivel de log de la API | `INFO` |
| `VNC_PASSWORD` | Contraseña VNC (máx. 8 caracteres); vacío = sin contraseña | - |
| `VNC_GEOMETRY` | Resolución del escritorio | `1280x800` |
| `MT5_IMAGE` | Imagen a usar en compose | `mt5api:local` |

## Endpoints de la API

Todos los endpoints (salvo auth, health y docs) requieren la cabecera `X-API-Key`. La clave es `sha256(API_KEY_SEED)` y se imprime en el log del contenedor al arrancar; también se obtiene con `POST /api/v1/auth/login`.

### Terminal & Account
| Method | Endpoint | Description |
| :--- | :--- | :--- |
| GET | `/api/v1/terminal/info` | Terminal info (build, connected, trade_allowed) |
| GET | `/api/v1/terminal/account/info` | Account info (balance, equity, margin) |
| GET | `/api/v1/terminal/version` | MT5 version |
| POST | `/api/v1/terminal/disconnect` | Disconnect from terminal |
| GET | `/api/v1/terminal/ping` | Broker ping latency |

### Symbols & Market Data
| Method | Endpoint | Description |
| :--- | :--- | :--- |
| GET | `/api/v1/symbols/` | List all symbols |
| GET | `/api/v1/symbols/{symbol}` | Symbol info |
| POST | `/api/v1/symbols/select/{symbol}` | Add symbol to Market Watch |
| GET | `/api/v1/symbols/ticks/{symbol}` | Current bid/ask tick |
| GET | `/api/v1/symbols/rates/from` | OHLC bars from datetime + count |
| GET | `/api/v1/symbols/rates/pos` | OHLC bars from position + count |
| GET | `/api/v1/symbols/rates/range` | OHLC bars for date range |
| GET | `/api/v1/symbols/ticks/{symbol}/from` | Tick data from datetime + count |
| GET | `/api/v1/symbols/ticks/{symbol}/range` | Tick data for date range |
| POST | `/api/v1/symbols/book/{symbol}/subscribe` | Subscribe to Level 2 depth |
| POST | `/api/v1/symbols/book/{symbol}/unsubscribe` | Unsubscribe from depth |
| GET | `/api/v1/symbols/book/{symbol}` | Get current depth snapshot |

### Trading
| Method | Endpoint | Description |
| :--- | :--- | :--- |
| POST | `/api/v1/trading/order` | Place market order (BUY/SELL) |
| POST | `/api/v1/trading/modify-sl-tp` | Modify SL/TP on open position |
| GET | `/api/v1/trading/order_check/{symbol}` | Check if symbol is tradeable |

### Orders (Pending)
| Method | Endpoint | Description |
| :--- | :--- | :--- |
| GET | `/api/v1/orders/` | List pending orders |
| GET | `/api/v1/orders/total` | Count pending orders |
| POST | `/api/v1/orders/pending` | Place pending order (BUY_LIMIT, SELL_STOP, etc.) with optional expiration |
| PUT | `/api/v1/orders/{ticket}` | Modify pending order (price, SL, TP, expiration) |
| DELETE | `/api/v1/orders/{ticket}` | Cancel pending order |
| GET | `/api/v1/orders/calc/margin` | Calculate required margin |
| GET | `/api/v1/orders/calc/profit` | Calculate potential profit/loss |

### Positions
| Method | Endpoint | Description |
| :--- | :--- | :--- |
| GET | `/api/v1/positions/` | List open positions |
| GET | `/api/v1/positions/by_symbol/{symbol}` | Positions by symbol |
| POST | `/api/v1/positions/close` | Close position (full or partial via `volume` param) |
| POST | `/api/v1/positions/close_all` | Close all positions |
| POST | `/api/v1/positions/modify` | Move a stop or target, **by ticket** |

> [!NOTE]
> `GET /api/v1/positions/?magic=...` filters to positions carrying that magic
> number, which is how a bot finds its own trades and leaves everything else
> alone. A magic of `0` is a real value — it is what a hand-placed trade
> carries — and is filtered for, not treated as "no filter".
>
> `POST /positions/modify` takes the MT5 ticket. The older
> `/trading/modify-sl-tp` takes a `trade_id` from this service's own database
> and so cannot touch a position it did not record; it remains for callers
> already using it.

### Streaming

| Protocol | Endpoint | Description |
| :--- | :--- | :--- |
| WS | `/api/v1/stream` | Quotes, positions and account, pushed as they change |

From the same machine: `ws://localhost:8000/api/v1/stream`.

Query parameters, all optional except the key: `api_key`, `symbols` (comma
separated), `magic` to filter positions to one bot's trades, and `interval` for
the quote loop in seconds.

```bash
wscat -c "ws://localhost:8000/api/v1/stream?api_key=KEY&symbols=XAUUSD,BTCUSD&magic=777701"
```

```jsonc
<- {"type": "ready",  "symbols": ["BTCUSD", "XAUUSD"], "interval": 0.25}
<- {"type": "tick",   "symbol": "XAUUSD", "bid": 4400.0, "ask": 4400.5, ...}
<- {"type": "positions", "positions": [ ... ]}
<- {"type": "account",   "equity": 10002.5, "balance": 10000.0, ...}

-> {"action": "subscribe",   "symbols": ["EURUSD"]}
-> {"action": "unsubscribe", "symbols": ["BTCUSD"]}
-> {"action": "ping"}
```

**Why it exists.** REST is the wrong shape for a price feed: a client learns
things at the rate it asks rather than the rate they change, is blind between
polls, and spends most round trips discovering nothing has moved.

MT5 has no push API — `symbol_info_tick` is a question, not a subscription — so
this still polls. What changes is that *one* loop inside the process already
holding the terminal connection does it, and **only differences are sent**. A
quiet symbol costs nothing; a busy one arrives as fast as it moves. Positions
and the account are polled on a slower loop and sent when the set changes,
which is what makes a server-side stop-out visible: it produces no message
anywhere, the position simply stops being there.

Floating profit is deliberately excluded from the change comparison. It moves
on every tick, and including it would turn the slow loop into a second quote
feed.

Authentication takes the same key as the REST routes, from the `X-API-Key`
header or the `api_key` query parameter — the query form because browsers
cannot set headers on a WebSocket handshake.

### History
| Method | Endpoint | Description |
| :--- | :--- | :--- |
| GET | `/api/v1/history/deals` | Trade deal history |
| GET | `/api/v1/history/orders` | Order history |
| GET | `/api/v1/history/order_by_ticket/{ticket}` | Single order by ticket |

> [!TIP]
> Full interactive docs with request/response schemas are available at `/docs` (Swagger UI) once the API is running.

## GitHub Actions

`.github/workflows/docker.yml`:

- **push a `main`** o ejecución manual: tests unitarios → build → smoke test
  (arranca el contenedor y espera a `/health`) → publica en
  `ghcr.io/<usuario>/mt5api` con las etiquetas `latest`,
  `mt5-<build>` y `sha-<commit>`.
- **cada lunes**: vuelve a construir descargando MT5 de nuevo y **solo publica
  si la build de MT5 es nueva** (si ya existe la etiqueta `mt5-<build>`, no
  hace nada).
- **pull request**: build y tests, sin publicar.
- La ejecución manual tiene la opción `refresh_mt5` para forzar la descarga.

La capa de MT5 se cachea por semana ISO, así que los push de una misma semana
reutilizan el terminal ya descargado.

## Tests

```bash
cd api
pip install -r requirements.txt      # Python 3.11
python -m pytest tests/unit -q       # sin contenedor, sin Wine, sin broker
python -m pytest tests -q            # integración; necesita el contenedor en marcha
```

`tests/unit` ejecuta la aplicación real contra un módulo `MetaTrader5` falso
(`tests/unit/fake_mt5.py`), estricto donde el real lo es.
