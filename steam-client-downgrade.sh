#!/usr/bin/env bash
#
# steam-client-downgrade.sh
#
# Downgrade / rollback do CLIENTE Steam (o software), em Linux.
#
# O cliente Steam se atualiza sozinho via "bootstrap", baixando o manifesto
# mais recente do CDN da Valve. O CDN nao guarda historico, entao este script
# usa a copia arquivada no Internet Archive (item "steam_steamcmd_packages"),
# que contem cada versao publicada do cliente com seus arquivos e manifesto.
#
# O metodo (guia "Steam Client Downgrades & Survival Kit"):
#   1) backup do diretorio de pacotes e do launcher;
#   2) baixa o launcher da versao antiga e valida o SHA2 contra o manifesto;
#   3) roda o bootstrap com -overridepackageurl apontando para o arquivo,
#      de modo que ele mesmo instale o pacote antigo;
#   4) cria steam.cfg com BootStrapperInhibitAll=enable para travar o
#      auto-update;
#   5) "undo" desfaz tudo voltando ao cliente mais recente.
#
# Uso:
#   ./steam-client-downgrade.sh status
#   ./steam-client-downgrade.sh list
#   ./steam-client-downgrade.sh downgrade [VERSAO]   # padrao: 1 versao atras
#   ./steam-client-downgrade.sh undo
#   ./steam-client-downgrade.sh restore-backup
#   ./steam-client-downgrade.sh cleanup
#
# Opcoes:
#   -y, --yes            nao pedir confirmacao
#   -n, --dry-run        apenas mostrar o plano (nao altera nada)
#       --steam-path DIR caminho do Steam (padrao: deteccao automatica)
#       --backup-dir DIR onde guardar o backup
#       --no-restart      nao reiniciar o Steam no final
#

set -euo pipefail

readonly SCRIPT_VERSION="1.0.0"

# ---------------------------------------------------------------- configuracao
readonly ARCHIVE_ITEM="steam_steamcmd_packages"
readonly ARCHIVE_BASE="https://archive.org/download/${ARCHIVE_ITEM}/steam_client_ubuntu12"
readonly ARCHIVE_META="https://archive.org/metadata/${ARCHIVE_ITEM}"
readonly STEAM_CDN="https://client-update.steamstatic.com"
readonly PKG_UBUNTU12="steam_client_ubuntu12"
readonly PKG_STEAMRT64="steam_client_steamrt64"

STEAM_ROOT=""            # diretorio raiz da instalacao do Steam
BACKUP_DIR=""            # diretorio do backup
TARGET_VERSION=""        # versao alvo do downgrade
DO_DRYRUN=0
ASSUME_YES=0
NO_RESTART=0
STATE_DIR="${HOME}/.steam-client-downgrade"
WORK_DIR=""

cleanup_work() {
  [ -n "${WORK_DIR:-}" ] && [ -d "$WORK_DIR" ] && rm -rf "$WORK_DIR"
  return 0
}
trap cleanup_work EXIT

# ------------------------------------------------------------------- log/UI
if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_B=$'\033[1m'; C_DIM=$'\033[2m'
  C_OK=$'\033[1;32m'; C_WARN=$'\033[1;33m'; C_ERR=$'\033[1;31m'; C_INF=$'\033[1;36m'
else
  C_RESET=""; C_B=""; C_DIM=""; C_OK=""; C_WARN=""; C_ERR=""; C_INF=""
fi

log()  { printf '%s[downgrade]%s %s\n' "$C_INF" "$C_RESET" "$*"; }
step() { printf '\n%s==>%s %s%s%s\n' "$C_INF" "$C_RESET" "$C_B" "$*" "$C_RESET"; }
ok()   { printf '%s[  ok  ]%s %s\n' "$C_OK" "$C_RESET" "$*"; }
warn() { printf '%s[ aviso]%s %s\n' "$C_WARN" "$C_RESET" "$*" >&2; }
err()  { printf '%s[ erro ]%s %s\n' "$C_ERR" "$C_RESET" "$*" >&2; }
die()  { err "$*"; exit 1; }
dim()  { printf '%s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }

confirm() {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  [ "$DO_DRYRUN" -eq 1 ] && return 0
  local resp=""
  printf '%s%s%s [s/N] ' "$C_WARN" "$*" "$C_RESET" >/dev/tty
  read -r resp </dev/tty || resp=""
  case "$resp" in
    [sSyY]*) return 0 ;;
    *) return 1 ;;
  esac
}

have() { command -v "$1" >/dev/null 2>&1; }

require_tools() {
  local missing=()
  for t in curl python3 unzip sha256sum; do
    have "$t" || missing+=("$t")
  done
  [ ${#missing[@]} -eq 0 ] || die "ferramentas ausentes: ${missing[*]}"
}

# --------------------------------------------------------------- utilidades
sha256_of() { sha256sum "$1" | cut -d' ' -f1; }

# versao instalada, lida do manifesto do pacote principal
installed_version() {
  local root="$1" m v pkg
  for pkg in "$PKG_UBUNTU12" "$PKG_STEAMRT64"; do
    m="$root/package/${pkg}.manifest"
    [ -f "$m" ] || continue
    v=$(grep -m1 -oE '"version"[[:space:]]+"[0-9]+"' "$m" | grep -oE '[0-9]+' || true)
    [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  done
  return 1
}

# versao de um pacote especifico: package_version <root> <pacote>
package_version() {
  local m="$1/package/$2.manifest"
  [ -f "$m" ] || return 1
  grep -m1 -oE '"version"[[:space:]]+"[0-9]+"' "$m" | grep -oE '[0-9]+' || true
}

# versao que o cliente realmente em execucao reportou (log do console)
running_client_version() {
  local logf="$HOME/.steam/steam/logs/console_log.txt"
  [ -f "$logf" ] || return 1
  grep -a "Client version:" "$logf" 2>/dev/null | tail -1 | sed -E 's/.*Client version: ([0-9]+).*/\1/' || true
}

# versao mais recente publicada pela Valve (CDN)
remote_version() {
  curl -s --max-time 30 "${STEAM_CDN}/${PKG_UBUNTU12}" 2>/dev/null \
    | grep -m1 -oE '"version"[[:space:]]+"[0-9]+"' | grep -oE '[0-9]+' || true
}

# curl para o archive.org, que as vezes entrega a ~10 KB/s: em vez de um
# --max-time curto (que cortava o download no meio), so desiste se a conexao
# praticamente parar (<2 KB/s por 60s), e tenta de novo em erro transitorio.
archive_curl() {
  curl -fsSL --connect-timeout 20 --speed-limit 2048 --speed-time 60 \
       --max-time 1800 --retry 3 --retry-delay 5 "$@"
}

# versoes do cliente arquivadas no Internet Archive (mais antiga -> mais nova)
archive_versions() {
  log "consultando o Internet Archive (pode demorar se o archive.org estiver lento)..." >&2
  local json
  if ! json=$(archive_curl "$ARCHIVE_META"); then
    err "falha ao baixar a lista de versoes do archive.org (veja o erro do curl acima)"
    return 1
  fi
  python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
except Exception as e:
    print("resposta invalida do archive.org: %s" % e, file=sys.stderr)
    sys.exit(1)
vs=set()
for f in d.get("files",[]):
    p=f.get("name","").split("/")
    if len(p)>=3 and p[0]==sys.argv[1] and p[1].isdigit():
        vs.add(p[1])
print("\n".join(sorted(vs,key=int)))
' "$PKG_UBUNTU12" <<< "$json"
}

# le um bloco do manifesto VDF: manifest_get <arquivo> <bloco> <campo>
manifest_get() {
  python3 - "$1" "$2" "$3" <<'PY'
import re,sys
path,block,field=sys.argv[1],sys.argv[2],sys.argv[3]
try:
    t=open(path,encoding="utf-8",errors="replace").read()
except OSError:
    sys.exit(1)
m=re.search(r'"%s"\s*\{(.*?)\n\t\}' % re.escape(block), t, re.S)
if not m:
    sys.exit(1)
f=re.search(r'"%s"\s+"([^"]+)"' % field, m.group(1))
print(f.group(1) if f else "")
PY
}

manifest_version() {
  grep -m1 -oE '"version"[[:space:]]+"[0-9]+"' "$1" | grep -oE '[0-9]+' || true
}

# ------------------------------------------------------------------- Steam
detect_steam_root() {
  local root="" pid
  pid=$(steam_pid 2>/dev/null || true)
  if [ -n "$pid" ] && [ -r "/proc/$pid/cmdline" ]; then
    local bin
    bin=$(tr '\0' '\n' < "/proc/$pid/cmdline" | head -1)
    [ -n "$bin" ] && root=$(dirname "$(dirname "$bin")")
  fi
  if [ -z "$root" ]; then
    for c in "$HOME/.local/share/Steam" "$HOME/.steam/steam" "$HOME/.steam/debian-installation" \
             "$HOME/.steam/root" "$HOME/.var/app/com.valvesoftware.Steam/data/Steam"; do
      [ -x "$c/ubuntu12_32/steam" ] && { root="$c"; break; }
    done
  fi
  [ -n "$root" ] || return 1
  [ -d "$root/package" ] || return 1
  printf '%s' "$root"
}

# pid do cliente Steam em execucao (o nome do processo e "steam", mas o caminho
# completo e o que garante que nao pegamos outro processo com o mesmo nome)
steam_pid() {
  local pid cmd
  for pid in $(pgrep -x steam 2>/dev/null || true); do
    cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)
    case "$cmd" in
      *ubuntu12_32/steam*) printf '%s' "$pid"; return 0 ;;
    esac
  done
  return 1
}

steam_running() { steam_pid >/dev/null 2>&1; }

stop_steam() {
  steam_running || { clean_stale_locks; return 0; }
  log "parando o Steam..."
  "$STEAM_ROOT/ubuntu12_32/steam" -shutdown >/dev/null 2>&1 || true
  local i
  for i in $(seq 1 30); do
    steam_running || { ok "Steam encerrado."; clean_stale_locks; return 0; }
    sleep 1
  done
  warn "Steam nao encerrou pelo -shutdown; forcando."
  local pid
  pid=$(steam_pid 2>/dev/null || true)
  [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null || true
  pkill -x steamwebhelper >/dev/null 2>&1 || true
  sleep 3
  pid=$(steam_pid 2>/dev/null || true)
  if [ -n "$pid" ]; then
    kill -KILL "$pid" 2>/dev/null || true
    sleep 2
  fi
  steam_running && die "nao foi possivel encerrar o Steam (rode o script sem o Steam aberto)."
  ok "Steam encerrado."
  clean_stale_locks
}

# o launcher aborta com "Steam is already running" quando sobrou um .pid obsoleto
# ou o socket do pipe: limpa os dois para o bootstrap poder rodar de verdade.
clean_stale_locks() {
  local pidfile="$HOME/.steam/steam.pid" p
  if [ -f "$pidfile" ]; then
    p=$(cat "$pidfile" 2>/dev/null || true)
    if [ -n "$p" ] && ps -p "$p" >/dev/null 2>&1; then
      warn "processo $p ainda vivo; nao removo o pid file."
      return 0
    fi
    rm -f "$pidfile" && ok "pid file obsoleto removido ($pidfile)."
  fi
  [ -p "$HOME/.steam/steam.pipe" ] && { rm -f "$HOME/.steam/steam.pipe"; ok "socket obsoleto removido."; }
  return 0
}

start_steam() {
  [ "$NO_RESTART" -eq 1 ] && { dim "reinicio do Steam pulado (--no-restart)."; return 0; }
  steam_running && { dim "Steam ja esta rodando."; return 0; }
  local cmd=""
  if [ -x /usr/bin/steam ]; then
    cmd="/usr/bin/steam"
  elif [ -x "$HOME/.local/share/SLSsteam/path/steam" ]; then
    cmd="$HOME/.local/share/SLSsteam/path/steam"
  else
    cmd="$STEAM_ROOT/ubuntu12_32/steam"
  fi
  log "iniciando o Steam ($cmd)..."
  setsid nohup "$cmd" >/dev/null 2>&1 &
  sleep 12
  steam_running && ok "Steam iniciado." || warn "Steam nao apareceu no processo; verifique manualmente."
}

# ------------------------------------------------------------------- backup
make_backup() {
  local dest="$1"
  log "criando backup em $dest"
  mkdir -p "$dest"
  cp -a "$STEAM_ROOT/package" "$dest/package" 2>/dev/null || true
  [ -x "$STEAM_ROOT/ubuntu12_32/steam" ] && cp -a "$STEAM_ROOT/ubuntu12_32/steam" "$dest/steam"
  [ -d "$STEAM_ROOT/ubuntu12_64" ] && cp -a "$STEAM_ROOT/ubuntu12_64" "$dest/ubuntu12_64"
  [ -f "$STEAM_ROOT/steam.sh" ] && cp -a "$STEAM_ROOT/steam.sh" "$dest/steam.sh"
  [ -f "$STEAM_ROOT/steam.cfg" ] && cp -a "$STEAM_ROOT/steam.cfg" "$dest/steam.cfg"
  mkdir -p "$STATE_DIR"
  printf '%s\n' "$dest" > "$STATE_DIR/last_backup"
  ok "backup salvo em $dest"
}

last_backup_dir() {
  if [ -n "$BACKUP_DIR" ]; then printf '%s' "$BACKUP_DIR"; return 0; fi
  if [ -f "$STATE_DIR/last_backup" ]; then
    local b; b=$(cat "$STATE_DIR/last_backup")
    [ -d "$b" ] && { printf '%s' "$b"; return 0; }
  fi
  local b
  b=$(ls -1dt "$HOME"/steam-client-backup-* 2>/dev/null | head -1 || true)
  [ -n "$b" ] && [ -d "$b" ] && { printf '%s' "$b"; return 0; }
  return 1
}

# ------------------------------------------------------------------ comandos
cmd_start() {
  step "Iniciando o Steam"
  start_steam
}

cmd_status() {
  step "Status do cliente Steam"
  local cur remote ub rt running
  cur=$(installed_version "$STEAM_ROOT" || echo "?")
  remote=$(remote_version || echo "?")
  ub=$(package_version "$STEAM_ROOT" "$PKG_UBUNTU12" || echo "?")
  rt=$(package_version "$STEAM_ROOT" "$PKG_STEAMRT64" || echo "?")
  running=$(running_client_version || echo "?")
  printf '  raiz do Steam   : %s\n' "$STEAM_ROOT"
  printf '  versao atual    : %s\n' "$cur"
  printf '  versao no CDN   : %s\n' "$remote"
  printf '  pacote ubuntu12 : %s\n' "$ub"
  printf '  pacote steamrt64: %s\n' "$rt"
  printf '  cliente rodando : %s\n' "$running"
  if [ -f "$STEAM_ROOT/steam.cfg" ] && grep -q "BootStrapperInhibitAll=enable" "$STEAM_ROOT/steam.cfg"; then
    printf '  auto-update     : BLOQUEADO (steam.cfg)\n'
  else
    printf '  auto-update     : liberado\n'
  fi
  if b=$(last_backup_dir 2>/dev/null); then
    printf '  backup          : %s\n' "$b"
  else
    printf '  backup          : (nenhum)\n'
  fi
  printf '  em execucao     : %s\n' "$(steam_running && echo sim || echo nao)"
}

cmd_list() {
  step "Versoes do cliente arquivadas no Internet Archive"
  local cur; cur=$(installed_version "$STEAM_ROOT" || echo "0")
  local versions; versions=$(archive_versions) || die "nao foi possivel listar o arquivo."
  [ -n "$versions" ] || die "o arquivo nao tem versoes de ${PKG_UBUNTU12}."
  local target; target=$(latest_below "$cur" "$versions")
  while read -r v; do
    [ -z "$v" ] && continue
    local mark="   "
    [ "$v" = "$cur" ] && mark=" ->"
    [ "$v" = "$target" ] && mark=" <-"
    printf '  %s %s' "$mark" "$v"
    [ "$v" = "$cur" ] && printf '   (instalada)'
    [ "$v" = "$target" ] && printf '   (1 versao atras: alvo do downgrade)'
    printf '\n'
  done <<< "$versions"
}

pick_target_version() {
  local current="$1" requested="${2:-}"
  if [ -n "$requested" ]; then
    printf '%s' "$requested"; return 0
  fi
  local versions; versions=$(archive_versions) || die "nao foi possivel consultar o arquivo."
  [ -n "$versions" ] || die "o arquivo nao tem versoes de ${PKG_UBUNTU12}."
  local best; best=$(latest_below "$current" "$versions")
  [ -n "$best" ] || die "nao ha versao arquivada anterior a $current."
  printf '%s' "$best"
}

# maior versao da lista (uma por linha) que seja menor que <atual>; vazio se nenhuma
latest_below() {
  local current="$1" versions="$2" best="" v
  while read -r v; do
    [ -z "$v" ] && continue
    if [ "$v" -lt "$current" ] && { [ -z "$best" ] || [ "$v" -gt "$best" ]; }; then
      best="$v"
    fi
  done <<< "$versions"
  printf '%s' "$best"
}

cmd_downgrade() {
  step "Downgrade do cliente Steam"
  local current; current=$(installed_version "$STEAM_ROOT") || die "nao foi possivel ler a versao instalada."
  log "versao instalada: $current"

  TARGET_VERSION=$(pick_target_version "$current" "${1:-}")
  log "versao alvo    : $TARGET_VERSION"

  local remote; remote=$(remote_version || echo "")
  if [ "$TARGET_VERSION" = "$current" ]; then
    ok "ja esta na versao desejada ($current). nada a fazer."
    return 0
  fi

  local base="${ARCHIVE_BASE}/${TARGET_VERSION}"
  local work; work=$(mktemp -d /tmp/steam-downgrade.XXXXXX)
  WORK_DIR="$work"

  step "1/5 baixando o manifesto e o launcher da versao $TARGET_VERSION"
  local mf="$work/manifest"
  archive_curl -o "$mf" "${base}/${PKG_UBUNTU12}" \
    || die "falha ao baixar o manifesto em ${base}/${PKG_UBUNTU12}"
  local mver; mver=$(manifest_version "$mf")
  [ "$mver" = "$TARGET_VERSION" ] || die "manifesto inesperado: $mver (esperado $TARGET_VERSION)"

  local lfile lsha
  lfile=$(manifest_get "$mf" "steam_ubuntu12" "file")
  lsha=$(manifest_get "$mf" "steam_ubuntu12" "sha2")
  [ -n "$lfile" ] && [ -n "$lsha" ] || die "manifesto sem a entrada do launcher (steam_ubuntu12)."

  log "baixando $lfile"
  archive_curl -o "$work/launcher.zip" "${base}/${lfile}" \
    || die "falha ao baixar o launcher."
  local got; got=$(sha256_of "$work/launcher.zip")
  [ "$got" = "$lsha" ] || die "SHA2 do launcher diverge (esperado $lsha, obtido $got)."
  ok "launcher baixado e verificado (SHA2 ok)."

  if [ "$DO_DRYRUN" -eq 1 ]; then
    step "dry-run: o que seria feito"
    dim "  1. backup em ${BACKUP_DIR:-$HOME/steam-client-backup-<data>}"
    dim "  2. substitui $STEAM_ROOT/ubuntu12_32/steam pelo launcher $TARGET_VERSION"
    dim "  3. roda: steam -forcesteamupdate -forcepackagedownload -overridepackageurl $base -exitsteam"
    dim "  4. cria $STEAM_ROOT/steam.cfg com BootStrapperInhibitAll=enable"
    dim "  5. reinicia o Steam"
    ok "dry-run concluido, nada foi alterado."
    return 0
  fi

  step "2/5 backup do estado atual"
  if [ -z "$BACKUP_DIR" ]; then
    BACKUP_DIR="$HOME/steam-client-backup-$(date +%Y%m%d-%H%M%S)"
  fi
  make_backup "$BACKUP_DIR"

  step "3/5 instalando o launcher antigo e deixando o bootstrap instalar o pacote antigo"
  stop_steam
  clean_stale_locks
  unzip -o -q "$work/launcher.zip" -d "$work/old" || die "falha ao extrair o launcher."
  [ -f "$work/old/ubuntu12_32/steam" ] || die "launcher nao encontrado dentro do zip."
  install -m 755 "$work/old/ubuntu12_32/steam" "$STEAM_ROOT/ubuntu12_32/steam"
  [ -f "$work/old/steam.sh" ] && install -m 755 "$work/old/steam.sh" "$STEAM_ROOT/steam.sh"
  ok "launcher da versao $TARGET_VERSION instalado."

  log "executando o bootstrap (pode levar alguns minutos)..."
  ( cd "$STEAM_ROOT" && "$STEAM_ROOT/ubuntu12_32/steam" \
      -forcesteamupdate -forcepackagedownload \
      -overridepackageurl "$base" -exitsteam ) >"$work/bootstrap.log" 2>&1 || true

  step "4/5 verificando o resultado"
  local now; now=$(installed_version "$STEAM_ROOT" || echo "")
  if [ "$now" != "$TARGET_VERSION" ]; then
    warn "a versao instalada ainda e $now (esperado $TARGET_VERSION)."
    warn "log do bootstrap: $work/bootstrap.log"
    warn "use './steam-client-downgrade.sh restore-backup' para voltar ao estado anterior."
    return 1
  fi
  ok "cliente agora na versao $TARGET_VERSION."

  step "5/5 bloqueando auto-update"
  if [ ! -f "$STEAM_ROOT/steam.cfg" ]; then
    printf 'BootStrapperInhibitAll=enable\n' > "$STEAM_ROOT/steam.cfg"
    ok "criado $STEAM_ROOT/steam.cfg (BootStrapperInhibitAll=enable)."
  else
    grep -q "BootStrapperInhibitAll=enable" "$STEAM_ROOT/steam.cfg" \
      || printf 'BootStrapperInhibitAll=enable\n' >> "$STEAM_ROOT/steam.cfg"
    ok "auto-update bloqueado em $STEAM_ROOT/steam.cfg."
  fi

  mkdir -p "$STATE_DIR"
  printf '%s\n' "$TARGET_VERSION" > "$STATE_DIR/target_version"
  printf '%s\n' "$current"    > "$STATE_DIR/previous_version"

  start_steam
  sleep 3
  local running; running=$(running_client_version || echo "")
  if [ -n "$running" ] && [ "$running" = "$TARGET_VERSION" ]; then
    ok "cliente em execucao reportando a versao $running."
  elif [ -n "$running" ]; then
    warn "cliente em execucao reportando $running (esperado $TARGET_VERSION)."
  fi
  printf '\n%s%sDowngrade concluido.%s cliente na versao %s (era %s).\n' \
    "$C_OK" "$C_B" "$C_RESET" "$TARGET_VERSION" "$current"
  printf '%sPara voltar ao mais recente: %s./steam-client-downgrade.sh undo%s\n' "$C_DIM" "$C_RESET" "$C_RESET"
}

cmd_undo() {
  step "Desfazendo o downgrade (voltando ao cliente mais recente)"
  local remote; remote=$(remote_version || echo "")
  [ -n "$remote" ] || die "nao consegui consultar a versao no CDN (sem rede?)"

  local cur_ub cur_rt
  cur_ub=$(package_version "$STEAM_ROOT" "$PKG_UBUNTU12" || echo "")
  cur_rt=$(package_version "$STEAM_ROOT" "$PKG_STEAMRT64" || echo "")
  log "pacote $PKG_UBUNTU12 : ${cur_ub:-?} (CDN: $remote)"
  log "pacote $PKG_STEAMRT64 : ${cur_rt:-?} (CDN: $remote)"

  if [ "$cur_ub" = "$remote" ] && [ "$cur_rt" = "$remote" ]; then
    ok "os dois pacotes ja estao na versao mais recente ($remote)."
    unlock_autoupdate
    return 0
  fi

  if [ "$DO_DRYRUN" -eq 1 ]; then
    dim "  1. para o Steam e limpa locks obsoletos (steam.pid / steam.pipe)"
    dim "  2. fase A: usa o launcher da versao instalada para atualizar o pacote ubuntu12 no CDN"
    dim "  3. fase B: usa o launcher novo para reinstalar o pacote steamrt64 (arquivos do cliente)"
    dim "  4. remove BootStrapperInhibitAll de steam.cfg e reinicia o Steam"
    ok "dry-run concluido, nada foi alterado."
    return 0
  fi

  stop_steam
  clean_stale_locks

  step "1/4 fase A - atualizando o pacote $PKG_UBUNTU12 no CDN"
  if [ "$cur_ub" != "$remote" ] && [ -n "$cur_ub" ]; then
    # o launcher que gerencia o pacote ubuntu12 e o do proprio pacote instalado;
    # o launcher novo (que so conhece o steamrt64) nunca atualizaria o ubuntu12.
    local work; work=$(mktemp -d /tmp/steam-undo.XXXXXX); WORK_DIR="$work"
    local base="${ARCHIVE_BASE}/${cur_ub}" mf lfile lsha
    if archive_curl -o "$work/manifest" "${base}/${PKG_UBUNTU12}" 2>/dev/null; then
      lfile=$(manifest_get "$work/manifest" "steam_ubuntu12" "file")
      lsha=$(manifest_get "$work/manifest" "steam_ubuntu12" "sha2")
      if [ -n "$lfile" ] && archive_curl -o "$work/launcher.zip" "${base}/${lfile}" 2>/dev/null; then
        if [ -z "$lsha" ] || [ "$(sha256_of "$work/launcher.zip")" = "$lsha" ]; then
          unzip -o -q "$work/launcher.zip" -d "$work/old" 2>/dev/null || true
          if [ -f "$work/old/ubuntu12_32/steam" ]; then
            install -m 755 "$work/old/ubuntu12_32/steam" "$STEAM_ROOT/ubuntu12_32/steam"
            ok "launcher da versao $cur_ub instalado (ele atualiza o pacote ubuntu12)."
          fi
        fi
      fi
    fi
    run_bootstrap "$work/bootstrapA.log"
  else
    log "pacote ubuntu12 ja esta na versao do CDN."
  fi

  step "2/4 fase B - reinstalando o pacote $PKG_STEAMRT64 (arquivos do cliente)"
  local attempt
  for attempt in 1 2 3; do
    run_bootstrap "/tmp/steam-undo-B$attempt.log"
    cur_ub=$(package_version "$STEAM_ROOT" "$PKG_UBUNTU12" || echo "")
    cur_rt=$(package_version "$STEAM_ROOT" "$PKG_STEAMRT64" || echo "")
    log "passada $attempt -> ubuntu12: ${cur_ub:-?} | steamrt64: ${cur_rt:-?}"
    if [ "$cur_ub" = "$remote" ] && [ "$cur_rt" = "$remote" ]; then break; fi
  done

  step "3/4 liberando o auto-update e verificando"
  unlock_autoupdate

  start_steam
  sleep 3
  local running; running=$(running_client_version || echo "")
  if [ -n "$running" ]; then
    if [ "$running" = "$remote" ]; then
      ok "cliente em execucao na versao $running (igual a do CDN)."
    else
      warn "cliente em execucao na versao $running | CDN: $remote"
    fi
  else
    warn "nao consegui ler a versao do cliente em execucao."
  fi

  printf '\n%s%sUndo concluido.%s pacotes: ubuntu12=%s steamrt64=%s (CDN: %s).\n' \
    "$C_OK" "$C_B" "$C_RESET" "${cur_ub:-?}" "${cur_rt:-?}" "$remote"
}

# executa o bootstrap do launcher atual
run_bootstrap() {
  local logfile="${1:-/tmp/steam-bootstrap.log}"
  ( cd "$STEAM_ROOT" && "$STEAM_ROOT/ubuntu12_32/steam" \
      -forcesteamupdate -forcepackagedownload -exitsteam ) >"$logfile" 2>&1 || true
  if grep -q "Steam is already running" "$logfile" 2>/dev/null; then
    warn "o launcher achou o Steam como 'ja rodando' (lock obsoleto); limpando e tentando de novo."
    clean_stale_locks
    ( cd "$STEAM_ROOT" && "$STEAM_ROOT/ubuntu12_32/steam" \
        -forcesteamupdate -forcepackagedownload -exitsteam ) >"$logfile" 2>&1 || true
  fi
  return 0
}

# remove o bloqueio de auto-update (BootStrapperInhibitAll) do steam.cfg
unlock_autoupdate() {
  local cfg="$STEAM_ROOT/steam.cfg"
  [ -f "$cfg" ] || return 0
  if grep -q "BootStrapperInhibitAll=enable" "$cfg"; then
    grep -v "BootStrapperInhibitAll=enable" "$cfg" > "$cfg.tmp" 2>/dev/null || true
    mv "$cfg.tmp" "$cfg"
    [ -s "$cfg" ] || rm -f "$cfg"
    ok "auto-update liberado (removido BootStrapperInhibitAll de steam.cfg)."
  fi
  return 0
}

cmd_restore_backup() {
  step "Restaurando o backup"
  local backup; backup=$(last_backup_dir 2>/dev/null || true)
  [ -n "$backup" ] || die "nenhum backup encontrado."
  log "backup: $backup"
  if ! confirm "Restaurar o backup e sobrescrever o estado atual do cliente?"; then
    warn "cancelado."; return 0
  fi
  stop_steam
  [ -d "$backup/package" ] && { rm -rf "$STEAM_ROOT/package"; cp -a "$backup/package" "$STEAM_ROOT/package"; }
  [ -f "$backup/steam" ] && install -m 755 "$backup/steam" "$STEAM_ROOT/ubuntu12_32/steam"
  [ -d "$backup/ubuntu12_64" ] && { rm -rf "$STEAM_ROOT/ubuntu12_64"; cp -a "$backup/ubuntu12_64" "$STEAM_ROOT/ubuntu12_64"; }
  if [ -f "$backup/steam.cfg" ]; then
    cp -a "$backup/steam.cfg" "$STEAM_ROOT/steam.cfg"
  else
    rm -f "$STEAM_ROOT/steam.cfg"
  fi
  ok "backup restaurado."
  local v; v=$(installed_version "$STEAM_ROOT" || echo "?")
  log "versao instalada: $v"
  start_steam
}

cmd_cleanup() {
  step "Limpando backups"
  local dirs
  dirs=$(ls -1d "$HOME"/steam-client-backup-* 2>/dev/null || true)
  if [ -z "$dirs" ]; then
    ok "nenhum backup para remover."
    return 0
  fi
  printf '%s\n' "$dirs" | sed 's/^/  /'
  if ! confirm "Remover todos esses backups?"; then
    warn "cancelado."; return 0
  fi
  rm -rf $dirs
  rm -rf "$STATE_DIR"
  ok "backups removidos."
}

usage() {
  cat <<EOF
${C_B}steam-client-downgrade.sh${C_RESET} v${SCRIPT_VERSION} - downgrade/rollback do cliente Steam (Linux)

${C_B}USO${C_RESET}
  $0 status                 situacao atual (versao, auto-update, backup)
  $0 start                  apenas inicia o Steam
  $0 list                   versoes do cliente disponiveis no arquivo
  $0 downgrade [VERSAO]     rebaixa o cliente (padrao: 1 versao atras)
  $0 undo                   volta para o cliente mais recente
  $0 restore-backup         restaura o backup salvo (offline)
  $0 cleanup                remove os backups salvos

${C_B}OPCOES${C_RESET}
  -y, --yes                 nao pedir confirmacao
  -n, --dry-run             so mostrar o plano, sem alterar nada
      --steam-path DIR      caminho da instalacao do Steam
      --backup-dir DIR      onde salvar o backup
      --no-restart          nao reiniciar o Steam ao final
  -h, --help                esta ajuda

${C_B}EXEMPLOS${C_RESET}
  $0 status
  $0 downgrade --dry-run
  $0 downgrade
  $0 downgrade 1791918634
  $0 undo -y
EOF
}

# ------------------------------------------------------------------- main
main() {
  local cmd=""
  local ARG1=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -y|--yes)      ASSUME_YES=1 ;;
      -n|--dry-run)  DO_DRYRUN=1 ;;
      --no-restart)  NO_RESTART=1 ;;
      --steam-path)  STEAM_ROOT="${2:-}"; shift ;;
      --backup-dir)  BACKUP_DIR="${2:-}"; shift ;;
      -h|--help)     usage; exit 0 ;;
      -*)            die "opcao desconhecida: $1" ;;
      *)
        if [ -z "$cmd" ]; then cmd="$1"; else ARG1="$1"; fi
        ;;
    esac
    shift
  done

  require_tools
  if [ -z "$STEAM_ROOT" ]; then
    STEAM_ROOT=$(detect_steam_root) || die "nao encontrei a instalacao do Steam (use --steam-path)."
  fi
  [ -d "$STEAM_ROOT" ] || die "caminho do Steam invalido: $STEAM_ROOT"
  mkdir -p "$STATE_DIR"

  case "$cmd" in
    status)         cmd_status ;;
    start)          cmd_start ;;
    list)           cmd_list ;;
    downgrade)      cmd_downgrade "${ARG1:-}" ;;
    undo)           cmd_undo ;;
    restore-backup) cmd_restore_backup ;;
    cleanup)        cmd_cleanup ;;
    "")             usage ;;
    *)              die "comando desconhecido: $cmd (use --help)" ;;
  esac
}

main "$@"
