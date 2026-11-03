#!/usr/bin/env bash
# Prueba las migraciones, los datos de ejemplo y las reglas en un PostgreSQL local.
# Uso: herramientas/probar_bd.sh   (requiere psql y un servidor PostgreSQL 15+ local)
set -euo pipefail
RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
DB=${DB:-confeccion_prueba}
export PGOPTIONS="-c client_min_messages=warning"
PSQL=(psql -X -q -v ON_ERROR_STOP=1 ${PGURL:+"$PGURL"})
"${PSQL[@]}" -d postgres -c "drop database if exists $DB" -c "create database $DB" >/dev/null
run() { "${PSQL[@]}" -d "$DB" -f "$1" >/dev/null && echo "  ✓ $(basename "$1")"; }
echo "Simulación de Supabase"; run "$RAIZ/supabase/tests/00_simular_supabase.sql"
echo "Migraciones"; for f in "$RAIZ"/supabase/migrations/*.sql; do run "$f"; done
run "$RAIZ/supabase/tests/01_permisos_por_defecto.sql"
echo "Datos de ejemplo"; run "$RAIZ/supabase/seed.sql"
echo "Pruebas"
for f in "$RAIZ"/supabase/tests/[1-9][0-9]_*.sql; do
  "${PSQL[@]}" -d "$DB" -v raiz="$RAIZ" -o /dev/null -f "$f" 2>&1 | sed 's/^psql:.*NOTICE:  /    /' 
done
echo "Listo."
