#!/usr/bin/env bash
# Home AI lab helper. Run ./lab.sh help to see the commands.
# Works with the bash that ships with macOS (3.2), Linux, and WSL on Windows.
set -euo pipefail

cd "$(dirname "$0")"

PROJECT=home-ai-lab
OPTIONAL_PARTS="qdrant portainer"
# Ollama models aren't backed up: they're large and can always be pulled again.
BACKUP_VOLUMES="open-webui qdrant portainer"
ASSUME_YES=0

say()  { printf '%s\n' "$*"; }
warn() { printf 'Warning: %s\n' "$*" >&2; }
die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }

# ask "Question?" y|n  -> succeeds on yes. --yes answers yes; no terminal takes the default.
ask() {
  local prompt=$1 default=$2 reply
  [ "$ASSUME_YES" = 1 ] && return 0
  if [ ! -t 0 ]; then [ "$default" = y ]; return; fi
  if [ "$default" = y ]; then prompt="$prompt [Y/n] "; else prompt="$prompt [y/N] "; fi
  read -r -p "$prompt" reply || true
  case ${reply:-$default} in [Yy]*) return 0 ;; *) return 1 ;; esac
}

# ---- .env helpers -----------------------------------------------------------

env_get() {
  [ -f .env ] || return 0
  awk -v k="$1" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2) } END { print v }' .env
}

env_set() {
  local tmp
  tmp=$(mktemp)
  awk -v k="$1" -v v="$2" '
    index($0, k "=") == 1 { if (!done) print k "=" v; done = 1; next }
    { print }
    END { if (!done) print k "=" v }' .env > "$tmp"
  cat "$tmp" > .env # rewrite in place so .env keeps its private permissions
  rm -f "$tmp"
}

profiles() { env_get COMPOSE_PROFILES | tr ',' ' '; }

has_profile() {
  case " $(profiles) " in *" $1 "*) return 0 ;; esac
  return 1
}

# set_profiles "part part ..." -> writes them to .env in a stable order
set_profiles() {
  local out="" p
  for p in ollama $OPTIONAL_PARTS; do
    case " $* " in *" $p "*) out="${out:+$out,}$p" ;; esac
  done
  env_set COMPOSE_PROFILES "$out"
}

native_ollama() {
  case $(env_get COMPOSE_FILE) in *compose.native-ollama.yml*) return 0 ;; esac
  return 1
}

# ---- system checks ----------------------------------------------------------

need_docker() {
  command -v docker >/dev/null 2>&1 ||
    die "Docker isn't installed. Get Docker Desktop from https://www.docker.com/products/docker-desktop/"
  docker info >/dev/null 2>&1 ||
    die "Docker isn't running. Open Docker Desktop, wait until it says it's running, then try again."
  docker compose version >/dev/null 2>&1 ||
    die "Docker Compose v2 is missing. Update Docker Desktop."
}

need_env() {
  [ -f .env ] || die "No .env yet. Run ./lab.sh setup first."
}

dc() { docker compose "$@"; }

# Runs the ollama command line, wherever Ollama lives.
ollama_cli() {
  if native_ollama; then
    if ! command -v ollama >/dev/null 2>&1; then
      warn "The Ollama Mac app isn't installed. Get it from https://ollama.com/download and open it once."
      return 1
    fi
    ollama "$@"
  elif [ -t 0 ] && [ -t 1 ]; then
    dc exec ollama ollama "$@"
  else
    dc exec -T ollama ollama "$@"
  fi
}

ram_gb() {
  local kb=0
  case $(uname -s) in
    Darwin) kb=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 )) ;;
    Linux) kb=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo 2>/dev/null || echo 0) ;;
  esac
  echo $(( kb / 1024 / 1024 ))
}

# A good first model for this machine's memory. See the README for alternatives.
recommend_model() {
  local gb
  gb=$(ram_gb)
  if [ "$gb" -ge 36 ]; then echo gemma4:26b
  elif [ "$gb" -ge 24 ]; then echo qwen3.5:9b
  elif [ "$gb" -ge 12 ]; then echo qwen3.5:4b
  else echo qwen3.5:2b
  fi
}

random_hex() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    od -An -tx1 -N32 /dev/urandom | tr -d ' \n'
  fi
}

print_urls() {
  say "  Chat (Open WebUI)    http://localhost:3000"
  if has_profile qdrant; then say "  Qdrant dashboard     http://localhost:6333/dashboard"; fi
  if has_profile portainer; then say "  Portainer            https://localhost:9443"; fi
}

first_run_notes() {
  case $1 in
    qdrant)
      say "Dashboard: http://localhost:6333/dashboard (collections appear once something writes to it)." ;;
    portainer)
      local code=000 token="" _
      for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        code=$(curl -sk -o /dev/null -w '%{http_code}' https://localhost:9443/api/users/admin/check 2>/dev/null || true)
        [ "$code" != 000 ] && break
        sleep 1
      done
      # 204 means the admin user already exists, so there's nothing to set up.
      if [ "$code" = 204 ]; then
        say "Portainer is at https://localhost:9443"
        return 0
      fi
      # Portainer prints a fresh token on every start until the admin user exists.
      token=$(dc logs portainer 2>/dev/null | grep -o 'setup_token=[0-9a-f]*' | tail -1 | cut -d= -f2 || true)
      if [ -n "$token" ]; then
        say "Open https://localhost:9443 within 5 minutes and create the admin user."
        say "Portainer will ask for this one-time setup token:"
        say ""
        say "  $token"
        say ""
        say "Your browser will warn about the certificate. That's expected for a local tool: continue anyway."
        say "Missed the 5 minutes? Run ./lab.sh restart portainer to get a fresh window and token."
      else
        say "Portainer is at https://localhost:9443"
      fi ;;
  esac
}

# ---- commands ---------------------------------------------------------------

cmd_setup() {
  need_docker

  if [ -f .env ]; then
    say "Found your existing .env. Keeping its keys."
  else
    cp .env.example .env
    chmod 600 .env
    say "Created .env"
  fi

  [ -n "$(env_get WEBUI_SECRET_KEY)" ] || env_set WEBUI_SECRET_KEY "$(random_hex)"

  local files="docker-compose.yml" where="Docker, CPU only" docker_ollama=1
  case $(uname -s) in
    Darwin)
      say ""
      say "On a Mac, Ollama is much faster as the native Mac app because it can use the Apple GPU."
      say "Inside Docker it only gets the CPU."
      if ask "Use the Ollama Mac app? (recommended)" y; then
        docker_ollama=0
        files="$files:compose.native-ollama.yml"
        where="Ollama Mac app"
        # Switching from Docker Ollama: free up port 11434 for the app.
        dc rm --stop --force ollama >/dev/null 2>&1 || true
        if ! command -v ollama >/dev/null 2>&1; then
          warn "Ollama isn't installed yet. Download it from https://ollama.com/download and open it once before ./lab.sh start."
        fi
      fi ;;
    Linux)
      if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
        files="$files:compose.nvidia.yml"
        where="Docker, NVIDIA GPU (needs the NVIDIA Container Toolkit)"
      elif [ -e /dev/kfd ]; then
        files="$files:compose.amd.yml"
        where="Docker, AMD GPU (ROCm)"
      fi ;;
  esac
  env_set COMPOSE_FILE "$files"
  env_set COMPOSE_PATH_SEPARATOR ":"

  # Keep any optional parts already turned on; set ollama from the choice above.
  local keep="" p
  for p in $(profiles); do [ "$p" = ollama ] || keep="$keep $p"; done
  keep=${keep# }
  if [ "$docker_ollama" = 1 ]; then set_profiles "ollama $keep"; else set_profiles "$keep"; fi

  say ""
  say "Setup done."
  say "  Ollama runs in:  $where"
  say "  Optional parts:  ${keep:-none yet (add them later with ./lab.sh add)}"
  say ""
  say "Next:"
  say "  ./lab.sh start"
  say "  ./lab.sh pull $(recommend_model)    (a good first model for $(ram_gb) GB of memory)"
  say "  Then open http://localhost:3000 and create your account. The first account becomes the admin."
}

cmd_start() {
  need_docker
  need_env
  if native_ollama && ! curl -fsS -m 3 http://localhost:11434/api/version >/dev/null 2>&1; then
    warn "Can't reach the Ollama Mac app. Open Ollama from Applications (a llama icon appears in the menu bar)."
  fi
  say "Starting the lab. The first start downloads a few GB of images, so give it a few minutes."
  if ! dc up -d --wait --wait-timeout 600; then
    die "The lab didn't start cleanly (see the messages above). ./lab.sh logs shows more."
  fi
  say ""
  say "Your lab is running:"
  print_urls
  local count
  count=$(ollama_cli list 2>/dev/null | tail -n +2 | grep -c . || true)
  if [ "${count:-0}" = 0 ]; then
    say ""
    say "No models yet. Pull one with: ./lab.sh pull $(recommend_model)"
  fi
}

cmd_stop() {
  need_env
  dc stop
}

cmd_restart() {
  need_env
  dc restart "$@"
  case " $* " in *" portainer "*) first_run_notes portainer ;; esac
}

cmd_status() {
  need_env
  dc ps --format 'table {{.Service}}\t{{.Status}}'
  say ""
  print_urls
  say ""
  say "Models:"
  ollama_cli list 2>/dev/null || say "  (Ollama isn't reachable right now)"
}

cmd_add() {
  need_docker
  need_env
  local part=${1:-}
  case " $OPTIONAL_PARTS " in
    *" $part "*) ;;
    *) die "Usage: ./lab.sh add qdrant|portainer" ;;
  esac
  set_profiles "$(profiles) $part"
  dc up -d --wait --wait-timeout 300 "$part"
  say ""
  say "Added $part."
  first_run_notes "$part"
}

cmd_remove() {
  need_env
  local part=${1:-} keep="" p
  case " $OPTIONAL_PARTS " in
    *" $part "*) ;;
    *) die "Usage: ./lab.sh remove qdrant|portainer" ;;
  esac
  dc rm --stop --force "$part"
  for p in $(profiles); do [ "$p" = "$part" ] || keep="$keep $p"; done
  set_profiles "$keep"
  say "Removed $part. Its data is kept; ./lab.sh add $part brings it back as it was."
}

cmd_pull() {
  [ $# -ge 1 ] || die "Usage: ./lab.sh pull <model>, for example: ./lab.sh pull $(recommend_model)"
  need_env
  ollama_cli pull "$1"
}

cmd_models() {
  need_env
  ollama_cli list
}

cmd_logs() {
  need_env
  dc logs --follow --tail 100 "$@"
}

cmd_backup() {
  need_docker
  need_env
  local dest v saved="" failed=""
  dest="backups/$(date +%Y-%m-%d_%H%M%S)"
  mkdir -p "$dest"
  chmod 700 "$dest"
  cp .env "$dest/env"
  chmod 600 "$dest/env"

  say "Pausing the lab for a few seconds so the databases are copied cleanly..."
  dc stop
  for v in $BACKUP_VOLUMES; do
    docker volume inspect "${PROJECT}_$v" >/dev/null 2>&1 || continue
    if docker run --rm -v "${PROJECT}_$v:/data:ro" -v "$PWD/$dest:/backup" alpine:3.22 \
        tar czf "/backup/$v.tgz" -C /data .; then
      saved="$saved $v"
    else
      failed="$failed $v"
    fi
  done
  dc up -d

  [ -z "$failed" ] || die "Couldn't back up:$failed"
  say "Saved$saved and your .env to $dest"
}

cmd_restore() {
  local src=${1:-} v
  [ -n "$src" ] && [ -d "$src" ] || die "Usage: ./lab.sh restore backups/<folder>"
  src=$(cd "$src" && pwd)
  need_docker

  say "This replaces the lab's current chats, settings and keys with the copy in:"
  say "  $src"
  ask "Continue?" n || die "Cancelled. Nothing was changed."

  if [ -f "$src/env" ]; then
    if [ -f .env ]; then cp .env ".env.bak.$(date +%Y%m%d%H%M%S)"; fi
    cp "$src/env" .env
    chmod 600 .env
  fi
  need_env

  dc down
  for v in $BACKUP_VOLUMES; do
    [ -f "$src/$v.tgz" ] || continue
    if ! docker volume inspect "${PROJECT}_$v" >/dev/null 2>&1; then
      docker volume create --label "com.docker.compose.project=$PROJECT" \
        --label "com.docker.compose.volume=$v" "${PROJECT}_$v" >/dev/null
    fi
    docker run --rm -v "${PROJECT}_$v:/data" -v "$src:/backup:ro" alpine:3.22 \
      sh -c 'find /data -mindepth 1 -delete && tar xzf "/backup/$1.tgz" -C /data' sh "$v"
    say "Restored $v"
  done
  dc up -d
  say "Restore finished."
}

cmd_update() {
  need_docker
  need_env
  say "Backing up first, so you can roll back if an update misbehaves."
  cmd_backup
  dc pull
  dc up -d --wait --wait-timeout 600
  say "Updated. Running the versions pinned in docker-compose.yml (or your .env overrides)."
}

cmd_help() {
  cat <<'EOF'
Home AI lab

  ./lab.sh setup              First-time setup (safe to run again to change options)
  ./lab.sh start              Start the lab and print its addresses
  ./lab.sh stop               Stop everything (your data stays)
  ./lab.sh restart [part]     Restart everything, or one part
  ./lab.sh status             What's running, where to open it, which models you have

  ./lab.sh pull <model>       Download a model, e.g. ./lab.sh pull qwen3.5:4b
  ./lab.sh models             List downloaded models

  ./lab.sh add <part>         Turn on qdrant or portainer
  ./lab.sh remove <part>      Turn one off again (its data is kept)

  ./lab.sh logs [part]        Follow the logs (Ctrl+C to stop watching)
  ./lab.sh backup             Save chats, settings and .env to backups/
  ./lab.sh restore <folder>   Put a backup back
  ./lab.sh update             Back up, then pull and restart on the pinned versions

Add -y to answer yes to every question.
EOF
}

main() {
  local args=() a
  for a in "$@"; do
    case $a in
      -y|--yes) ASSUME_YES=1 ;;
      *) args+=("$a") ;;
    esac
  done
  set -- ${args[@]+"${args[@]}"}

  local cmd=${1:-help}
  [ $# -eq 0 ] || shift
  case $cmd in
    setup) cmd_setup ;;
    start|up) cmd_start ;;
    stop|down) cmd_stop ;;
    restart) cmd_restart "$@" ;;
    status|ps) cmd_status ;;
    add) cmd_add "$@" ;;
    remove) cmd_remove "$@" ;;
    pull) cmd_pull "$@" ;;
    models|list) cmd_models ;;
    logs) cmd_logs "$@" ;;
    backup) cmd_backup ;;
    restore) cmd_restore "$@" ;;
    update) cmd_update ;;
    help|-h|--help) cmd_help ;;
    *) cmd_help; exit 1 ;;
  esac
}

main "$@"
