# Confección: gestión y trazabilidad de producción

App para una planta de confección en Medellín. Reemplaza el control de piso de SAMMU y agrega
materiales, corte, costos e inventarios.

- **App Android** (tablets Lenovo y celulares de planta): trabaja **sin conexión** y sincroniza sola.
- **Panel web** (oficina, responsive) y, desde la Fase 8, **tableros de TV**.
- **Servidor**: Supabase (PostgreSQL, Auth, RLS, Storage, Realtime) + **PowerSync** para la sincronización.

> Estado: **Fase 6 (primera parte) terminada** (tablet del módulo, recorrido de paquetes y juegos). Ver [`docs/fase-6/FASE_6.md`](docs/fase-6/FASE_6.md),
> [`docs/fase-5/FASE_5.md`](docs/fase-5/FASE_5.md),
> [`docs/fase-4/FASE_4.md`](docs/fase-4/FASE_4.md),
> [`docs/fase-3/FASE_3.md`](docs/fase-3/FASE_3.md),
> [`docs/fase-2/FASE_2.md`](docs/fase-2/FASE_2.md),
> [`docs/fase-1/FASE_1.md`](docs/fase-1/FASE_1.md) y la propuesta aprobada en [`docs/fase-0/`](docs/fase-0/).

## Estructura

```
app/                 Flutter (un solo código para Android y web)
  lib/main_planta.dart   entrada de la app Android
  lib/main_web.dart      entrada del panel web
  lib/core/              tema, formato colombiano, sesión, sincronización, base local
  lib/features/          un módulo por área (asistencia, personal, configuración…)
  test/                  pruebas (formato, bandeja sin conexión, e2e)
supabase/
  migrations/            esquema, reglas, RLS, funciones (SQL)
  seed.sql               datos de EJEMPLO (todo lo marcado EJEMPLO es ficticio)
  tests/                 pruebas de reglas de negocio en PostgreSQL
sync/sync-rules.yaml     qué baja a cada tablet (PowerSync Sync Streams)
herramientas/            scripts: crear usuarios de ejemplo, probar la base
docs/                    propuesta, esquema, guías
```

## 0. Sin instalar nada: compilación en GitHub

Cada vez que se sube código a <https://github.com/grupocdssas-png/confeccion-app>, GitHub corre las pruebas y genera el
**APK de las tablets** y el **panel web**: pestaña **Actions** → la última ejecución verde → sección **Artifacts**
(`apk-tablets`, `panel-web`). Para que apunten a su Supabase y PowerSync, una sola vez en *Settings → Secrets and variables →
Actions* cree `SUPABASE_URL`, `SUPABASE_ANON_KEY` y `POWERSYNC_URL` (son públicas; las claves secretas nunca van ahí).

## 1. Instalar en su computador (VS Code, opcional)

1. Instale **Flutter** (canal estable actual; el proyecto usa Dart 3.13 o superior): <https://docs.flutter.dev/get-started/install>.
   Para el APK necesita además **Android Studio** (trae el SDK de Android).
2. Instale **VS Code** con las extensiones *Flutter* y *Dart*.
3. Instale **Node.js 18+** (para los scripts) y, si quiere el servidor local, **Docker Desktop**.
4. Abra la carpeta del proyecto en VS Code y en la terminal:

```bash
cd app
```

```bash
flutter pub get
```

```bash
dart run build_runner build --delete-conflicting-outputs
```

## 2. Configurar Supabase (nube)

1. Cree un proyecto en <https://supabase.com> (región más cercana: São Paulo, `sa-east-1`).
2. Instale la CLI y enlace el proyecto (desde la raíz del repositorio):

```bash
npx supabase login
```

```bash
npx supabase link --project-ref SU_PROJECT_REF
```

3. Cree las tablas, reglas y permisos (aplica todo `supabase/migrations`):

```bash
npx supabase db push
```

4. Cargue los datos de ejemplo (la cadena de conexión está en *Project Settings → Database*):

```bash
psql "SU_CADENA_DE_CONEXION" -f supabase/seed.sql
```

5. Cree los usuarios de ejemplo (gerencia, jefe de producción, bodega y dos tablets). La
   `service_role key` está en *Project Settings → API*; es **secreta**: úsela solo en su computador.

```bash
SUPABASE_URL=https://SU_PROJECT_REF.supabase.co SUPABASE_SERVICE_ROLE_KEY=su_clave_secreta node herramientas/crear_usuarios_demo.mjs
```

El script imprime la contraseña de los usuarios de ejemplo. Crea: `gerencia@ejemplo.co`, `jefe.produccion@ejemplo.co`,
`bodega@ejemplo.co`, `costos@ejemplo.co` (aprueba ajustes y fichas), `diseno@ejemplo.co`, `compras@ejemplo.co`, `comercial@ejemplo.co` y las cuentas técnicas `tablet-ent@planta.local`,
`tablet-mod1@planta.local` y `celular-bodega@planta.local`. Se puede volver a correr sin problema.

## 3. Configurar PowerSync (nube)

1. Cree una cuenta en <https://powersync.com> y una instancia nueva conectada a su proyecto de Supabase
   (asistente "Connect to Supabase": pide la cadena de conexión de la base).
2. En la base de Supabase cree el usuario de replicación que pide el asistente (el asistente muestra el SQL
   exacto; la publicación `powersync` ya la crean nuestras migraciones).
3. En **Client Auth** active *Use Supabase Auth* (PowerSync toma las llaves JWKS de su proyecto).
4. En **Sync Streams** pegue el contenido de [`sync/sync-rules.yaml`](sync/sync-rules.yaml) y despliegue.
5. Copie la URL de la instancia (`https://xxxx.powersync.journeyapps.com`).

## 4. Archivo de configuración de la app

Copie `app/config/ejemplo.json` como `app/config/dev.json` y llene:

| Clave | Dónde se encuentra |
|---|---|
| `SUPABASE_URL` | Supabase → Project Settings → API |
| `SUPABASE_ANON_KEY` | Supabase → API → clave pública (*anon* o *publishable*). Es pública, puede ir en la app. |
| `POWERSYNC_URL` | URL de su instancia de PowerSync |

`dev.json` no se sube al repositorio (está en `.gitignore`). Las claves secretas (service_role, Alegra,
WhatsApp) **nunca** van en la app: viven solo en los secretos de Supabase.

## 5. Ejecutar

Panel web en Chrome:

```bash
flutter run -d chrome -t lib/main_web.dart --dart-define-from-file=config/dev.json
```

App de planta en una tablet conectada por USB (active *Depuración USB* en la tablet):

```bash
flutter run -t lib/main_planta.dart --dart-define-from-file=config/dev.json
```

En VS Code también puede usar *Run and Debug* con las configuraciones de `.vscode/launch.json`.

## 6. Compilar el APK para las tablets

```bash
flutter build apk --release -t lib/main_planta.dart --dart-define-from-file=config/dev.json
```

El archivo queda en `app/build/app/outputs/flutter-apk/app-release.apk`. Cópielo a la tablet e instálelo
(permita "instalar apps de origen desconocido"). La primera vez:

1. Abra la app → **Vincular tablet** → ingrese la cuenta técnica de esa estación (ej. `tablet-ent@planta.local`).
2. Espere "Descargando los datos de la estación…" (necesita internet solo esa vez).
3. Desde ahí funciona con o sin conexión.

**Modo kiosco:** la app ya abre en pantalla completa y vertical. Para impedir que el operario salga de la app,
active *Fijar pantalla* (Ajustes → Seguridad → Fijar app) en cada tablet, o use la gestión de dispositivos
de Lenovo/Google si la tienen.

> Firma del APK para producción: antes de instalar en todas las tablets hay que crear una llave de firma
> propia (lo hacemos juntos cuando pasemos a producción).

## 7. Desplegar el panel web

```bash
flutter build web --release -t lib/main_web.dart --no-web-resources-cdn --dart-define-from-file=config/dev.json -o build/web_oficina
```

Suba la carpeta `app/build/web_oficina` a cualquier hosting estático (Netlify, Vercel, Cloudflare Pages,
Firebase Hosting). `--no-web-resources-cdn` incluye el motor gráfico dentro de la app: la web y la TV siguen
abriendo aunque se caiga internet.

## 8. Pruebas

Pruebas de la app (formato colombiano, sincronización sin conexión sobre SQLite real y cálculo de corte con los casos de `test_vectores/`):

```bash
cd app && flutter test
```

Reglas de negocio en PostgreSQL (requiere un PostgreSQL 15+ local; no toca su proyecto de Supabase):

```bash
herramientas/probar_bd.sh
```

Prueba de punta a punta con Supabase y PowerSync locales (Docker):

```bash
npx supabase start
```

```bash
psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -c "create database powersync_storage"
```

```bash
docker run -d --name powersync_local --network supabase_network_confeccion -p 8080:8080 -v "$PWD/sync/local:/config" -e POWERSYNC_CONFIG_PATH=/config/powersync.yaml journeyapps/powersync-service:latest start -r unified
```

```bash
SUPABASE_URL=http://127.0.0.1:54321 SUPABASE_SERVICE_ROLE_KEY=clave_de_supabase_status CLAVE_DEMO=Planta-2026 node herramientas/crear_usuarios_demo.mjs
```

```bash
cd app && E2E=1 SUPABASE_ANON_KEY=anon_de_supabase_status SUPABASE_SERVICE_ROLE_KEY=clave_de_supabase_status flutter test test/e2e
```

(`npx supabase status` muestra las claves locales. Copie `sync/sync-rules.yaml` a `sync/local/` si lo cambia.)

## Impresoras Zebra

- **Tablets y celulares:** la Zebra necesita **IP fija** en el wifi de la planta. Regístrela en *Configuración → Impresoras y
  etiquetas* y asígnela a la estación. La app envía por el puerto 9100 aunque no haya internet.
- **PC de oficina:** instale **Zebra Browser Print** (gratuito, del sitio de Zebra) con la impresora por USB o red. Si no está,
  la web genera un PDF al tamaño real (100 × 50 mm).
- Material: térmico directo para paquetes y juegos; transferencia térmica o sintética para rollos, ubicaciones y máquinas.

## Formato y convenciones

- Interfaz en español, moneda COP (`$ 1.750.905`), números `1.234,56`, hora de Bogotá (UTC−5).
- Tipografía IBM Plex Sans / Mono incluida en la app (funciona sin internet).
- Los registros de planta son **eventos**: nunca se editan ni se borran; se anulan con un evento nuevo.
- Guía corta por rol: [`docs/GUIA_POR_ROL.md`](docs/GUIA_POR_ROL.md).
