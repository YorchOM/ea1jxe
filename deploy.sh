#!/usr/bin/env bash
# Despliega ea1jxe en serviyorch (ssh ea1jxe). Solo sube lo COMMITEADO en la rama main.
#
#   ./deploy.sh                    despliega
#   ./deploy.sh --ver              solo enseña qué cambiaría; no sube nada a GitHub ni al servidor
#   ./deploy.sh --preguntar        enseña qué cambiaría y pide confirmación (lo usa deploy.bat)
#   ./deploy.sh --build            además reconstruye la imagen del contenedor (si cambió el Dockerfile)
#   ./deploy.sh --borrar-sobrantes además quita del servidor lo que ya no está en el repo (con copia)
#   ./deploy.sh --forzar           pisa también ficheros editados a mano en el servidor tras su último commit
#
# Generado desde la plantilla común de despliegue de serviyorch: si cambias la lógica, cámbiala en
# todos los repos a la vez. Lo propio de este proyecto está en el bloque de configuración.
set -euo pipefail
export LC_ALL=C   # mismo orden al ordenar aquí y en el servidor

# ---------------------------------------------------------------- configuración de este proyecto
MODO=archivo              # archivo: git archive al docroot | pull: el servidor es un clon git
RAMA=main
SITIO=ea1jxe            # carpeta en /home/yorch/sites
SUBDIR=''          # subcarpeta del repo que se sirve ('' = el repo entero)
COMPOSE=ea1jxe        # carpeta en ~/docker/serviyorch/sites (para --build; '' = no aplica)
URL=https://ea1jxe.es                # se comprueba al terminar
# Lo del repo que NO se sirve (pathspecs de git, separados por espacios). deploy.sh, deploy.bat y
# STATUS.md nunca se suben.
EXCLUIR=''
# Lo que vive solo en el servidor y no se toca nunca (regex sobre la ruta relativa).
CONSERVAR='^(uploads/|.*cache.*\.json$)'
# Órdenes que corren en el servidor después de subir, desde la carpeta del sitio.
DESPUES=''
# -----------------------------------------------------------------------------------------------

HOST=ea1jxe
DESTINO=/home/yorch/sites/$SITIO
COPIAS=/home/yorch/backups/deploy

VER=0; PREGUNTAR=0; BUILD=0; BORRAR=0; FORZAR=0
for a in "$@"; do
  case "$a" in
    --ver) VER=1 ;;
    --preguntar) PREGUNTAR=1 ;;
    --build) BUILD=1 ;;
    --borrar-sobrantes) BORRAR=1 ;;
    --forzar) FORZAR=1 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "Opción desconocida: $a"; exit 2 ;;
  esac
done

cd "$(dirname "$0")"
die() { echo "ERROR: $*" >&2; exit 1; }
# md5sum escribe "hash  fichero" (Linux) o "hash *fichero" (Git Bash): se deja todo en la primera forma.
norm5() { sed -E 's/^\\?([0-9a-f]{32}) [ *]/\1  /' | sort -k2; }
listar() { local n; n=$(grep -c . "$1" || true); sed -n '1,40p' "$1" | sed 's/^/    /'; [ "$n" -gt 40 ] && echo "    … y $((n-40)) más"; return 0; }

# --- 1. Repo local: rama correcta y alineado con GitHub
rama=$(git branch --show-current)
[ "$rama" = "$RAMA" ] || die "estás en la rama '$rama'; este proyecto se despliega desde '$RAMA'."
sucio=$(git status --porcelain --untracked-files=no)
if [ -n "$sucio" ]; then
  echo "Aviso: hay cambios sin commitear. NO se suben (solo va lo commiteado):"
  echo "$sucio" | sed 's/^/    /'
fi
git fetch -q origin "$RAMA" || die "no puedo hablar con GitHub (git fetch)."
detras=$(git rev-list --count "HEAD..origin/$RAMA")
[ "$detras" -eq 0 ] || die "GitHub tiene $detras commit(s) que no tienes en local: haz git pull primero."
delante=$(git rev-list --count "origin/$RAMA..HEAD")
COMMIT=$(git rev-parse --short HEAD)
echo "== $SITIO · $COMMIT $(git log -1 --format=%s | cut -c1-70)"
[ "$delante" -gt 0 ] && echo "   $delante commit(s) aún no están en GitHub; se suben al desplegar."

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# --- 2. Qué cambiaría
if [ "$MODO" = pull ]; then
  SRV=$(ssh -o BatchMode=yes "$HOST" "git -C $DESTINO rev-parse HEAD") || die "no encuentro el clon en $DESTINO."
  ssh -o BatchMode=yes "$HOST" "git -C $DESTINO status --porcelain --untracked-files=no" > "$TMP/srv-sucio"
  if [ -s "$TMP/srv-sucio" ]; then
    echo "En el servidor hay ficheros modificados a mano (git pull se negaría):"; listar "$TMP/srv-sucio"
    die "resuélvelo antes en $HOST:$DESTINO."
  fi
  if ! git cat-file -e "$SRV^{commit}" 2>/dev/null; then
    die "el servidor está en un commit ($SRV) que no tienes en local."
  fi
  git log --oneline "$SRV..HEAD" > "$TMP/commits"
  if [ ! -s "$TMP/commits" ]; then echo "Ya está al día: el servidor está en $(git rev-parse --short "$SRV")."; [ "$BUILD" -eq 1 ] || exit 0
  else echo "Se aplican $(wc -l < "$TMP/commits") commit(s):"; listar "$TMP/commits"; fi
else
  ref=HEAD; [ -n "$SUBDIR" ] && ref="HEAD:$SUBDIR"
  # autocrlf=false: al servidor (Linux) siempre en LF, sea cual sea la configuración de Windows.
  # Ni el propio script ni el STATUS.md van al docroot.
  excl=(':(exclude)deploy.sh' ':(exclude)deploy.bat' ':(exclude)STATUS.md'); for e in $EXCLUIR; do excl+=(":(exclude)$e"); done
  git -c core.autocrlf=false archive --format=tar "$ref" -- . "${excl[@]}" > "$TMP/c.tar"
  mkdir "$TMP/x"; tar -xf "$TMP/c.tar" -C "$TMP/x"
  ( cd "$TMP/x" && find . -type f | sed 's|^\./||' | sort > "$TMP/lista" && tr '\n' '\0' < "$TMP/lista" | xargs -0 md5sum ) \
    | norm5 > "$TMP/local.md5"
  ssh -o BatchMode=yes "$HOST" "cd $DESTINO && xargs -d '\n' md5sum 2>/dev/null; true" < "$TMP/lista" \
    | norm5 > "$TMP/srv.md5"
  awk 'NR==FNR{s[substr($0,35)]=$1;next} {f=substr($0,35); if(!(f in s)) print "nuevo  " f; else if(s[f]!=$1) print "cambia " f}' \
    "$TMP/srv.md5" "$TMP/local.md5" > "$TMP/difs"
  ssh -o BatchMode=yes "$HOST" "cd $DESTINO && find . -type f | sed 's|^\./||'" | sort > "$TMP/srv-todos"
  comm -23 "$TMP/srv-todos" "$TMP/lista" | { if [ -n "$CONSERVAR" ]; then grep -Ev "$CONSERVAR" || true; else cat; fi; } > "$TMP/sobran"
  # Los que solo difieren en el fin de línea (CRLF de despliegues viejos) se cuentan aparte.
  sed -n 's/^cambia //p' "$TMP/difs" > "$TMP/cambian"
  if [ -s "$TMP/cambian" ]; then
    eolmd5='while IFS= read -r f; do printf "%s  %s\n" "$(tr -d "\r" < "$f" | md5sum | cut -c1-32)" "$f"; done'
    ( cd "$TMP/x" && bash -c "$eolmd5" < "$TMP/cambian" ) | sort > "$TMP/l-eol"
    ssh -o BatchMode=yes "$HOST" "cd $DESTINO && bash -c $(printf %q "$eolmd5")" < "$TMP/cambian" | sort > "$TMP/s-eol"
    comm -12 "$TMP/l-eol" "$TMP/s-eol" | cut -c35- > "$TMP/solo-eol"
  else : > "$TMP/solo-eol"; fi
  grep -vxF -f <(sed 's/^/cambia /' "$TMP/solo-eol") "$TMP/difs" > "$TMP/reales" || true
  if [ -s "$TMP/reales" ]; then echo "Cambian $(wc -l < "$TMP/reales") fichero(s):"; listar "$TMP/reales"
  else echo "Ningún fichero del repo tiene contenido distinto en el servidor."; fi
  # Protección: un fichero del servidor editado DESPUÉS de su último commit tiene cambios hechos
  # a mano allí (arreglos en caliente) que el repo no tiene. Pisarlo los perdería.
  sed -n 's/^cambia //p' "$TMP/reales" > "$TMP/reales-cambia"
  : > "$TMP/editados"
  if [ -s "$TMP/reales-cambia" ]; then
    ssh -o BatchMode=yes "$HOST" "cd $DESTINO && xargs -d '\n' stat -c '%Y %n'" < "$TMP/reales-cambia" > "$TMP/srv-mtime"
    while read -r t f; do
      c=$(git log -1 --format=%ct HEAD -- "${SUBDIR:+$SUBDIR/}$f")
      [ -n "$c" ] && [ "$t" -gt $((c + 120)) ] && echo "$f  (servidor $(date -d "@$t" '+%d-%m-%Y %H:%M'), último commit $(date -d "@$c" '+%d-%m-%Y %H:%M'))" >> "$TMP/editados"
    done < "$TMP/srv-mtime"
  fi
  if [ -s "$TMP/editados" ]; then
    echo "OJO: editados en el servidor después de su último commit (el repo no tiene esos cambios):"; listar "$TMP/editados"
    if [ "$FORZAR" -eq 0 ] && [ "$VER" -eq 0 ]; then
      die "no los piso. Trae esos cambios al repo y commitéalos, o repite con --forzar si de verdad sobran."
    fi
  fi
  [ -s "$TMP/solo-eol" ] && echo "Y $(wc -l < "$TMP/solo-eol") más solo cambian el fin de línea (CRLF → LF); se suben igual."
  if [ -s "$TMP/sobran" ]; then
    echo "En el servidor y ya no en el repo ($(wc -l < "$TMP/sobran")):"; listar "$TMP/sobran"
    [ "$BORRAR" -eq 1 ] && echo "   → se borran (con copia)." || echo "   → se dejan. Usa --borrar-sobrantes para quitarlos."
  fi
  if [ ! -s "$TMP/difs" ] && { [ "$BORRAR" -eq 0 ] || [ ! -s "$TMP/sobran" ]; } && [ "$BUILD" -eq 0 ]; then
    echo "Ya está al día."; exit 0
  fi
fi

[ "$VER" -eq 1 ] && { echo "(--ver: no se ha subido nada)"; exit 0; }
if [ "$PREGUNTAR" -eq 1 ]; then
  read -r -p "¿Desplegar $SITIO? (s/n) " r; [ "$r" = s ] || [ "$r" = S ] || { echo "Cancelado."; exit 0; }
fi

# --- 3. GitHub primero: lo que corre en el servidor tiene que estar en GitHub
[ "$delante" -gt 0 ] && { git push -q origin "$RAMA" || die "git push ha fallado; no despliego."; }

# --- 4. Subir
TS=$(date +%Y%m%d-%H%M%S)
if [ "$MODO" = pull ]; then
  ssh -o BatchMode=yes "$HOST" "git -C $DESTINO pull --ff-only -q" || die "git pull ha fallado en el servidor."
  DESHACER="ssh $HOST 'git -C $DESTINO reset --hard $(git rev-parse --short "$SRV")'"
else
  # Copia de lo que se va a pisar o borrar, para poder volver atrás.
  { sed 's/^[a-z]* *//' "$TMP/difs" | grep -v '^$' || true; [ "$BORRAR" -eq 1 ] && cat "$TMP/sobran"; true; } > "$TMP/pisar"
  COPIA="$COPIAS/$SITIO-$TS.tgz"
  ssh -o BatchMode=yes "$HOST" "mkdir -p $COPIAS && cd $DESTINO && xargs -d '\n' sh -c 'for f; do [ -e \"\$f\" ] && printf \"%s\n\" \"\$f\"; done' _ | tar czf $COPIA -T - && chmod 600 $COPIA" < "$TMP/pisar"
  ssh -o BatchMode=yes "$HOST" "tar -x -C $DESTINO" < "$TMP/c.tar" || die "no se ha podido descomprimir en el servidor (¿permisos?). Copia previa: $COPIA"
  if [ "$BORRAR" -eq 1 ] && [ -s "$TMP/sobran" ]; then
    ssh -o BatchMode=yes "$HOST" "cd $DESTINO && xargs -d '\n' rm -f" < "$TMP/sobran"
  fi
  ssh -o BatchMode=yes "$HOST" "echo '$COMMIT $TS' > $COPIAS/$SITIO.ultimo; ls -1t $COPIAS/$SITIO-*.tgz 2>/dev/null | tail -n +11 | xargs -r rm -f"
  DESHACER="ssh $HOST 'tar xzf $COPIA -C $DESTINO'"
fi

# --- 5. Después de subir
if [ -n "$DESPUES" ]; then
  echo "-- tras subir:"
  ssh -o BatchMode=yes "$HOST" "cd $DESTINO && set -e
$DESPUES" || die "ha fallado un paso posterior al despliegue (el código ya está subido)."
fi
if [ "$BUILD" -eq 1 ]; then
  [ -n "$COMPOSE" ] || die "--build: este proyecto no tiene compose propio en serviyorch."
  echo "-- reconstruyendo la imagen…"
  ssh -o BatchMode=yes "$HOST" "cd /home/yorch/docker/serviyorch/sites/$COMPOSE && docker compose up -d --build 2>&1 | tail -3"
fi

# --- 6. Comprobar
if [ -n "$URL" ]; then
  code=$(curl -s -o /dev/null -w '%{http_code}' -L --max-time 30 "$URL" || echo 000)
  [ "$code" = 200 ] && echo "OK  $URL responde 200." || echo "OJO $URL responde $code."
fi
echo "Desplegado $COMMIT en $SITIO."
echo "Para deshacer: $DESHACER"
