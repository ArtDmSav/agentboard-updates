#!/usr/bin/env bash
# «Доска» (AgentBoard): сервер одной командой. На чистом сервере Ubuntu 24.04 или Debian 12, от root:
#
#   curl -fsSL https://raw.githubusercontent.com/ArtDmSav/agentboard-updates/main/install.sh | bash
#
# С флагами — через «bash -s --», например свой домен и агент:
#
#   curl -fsSL https://raw.githubusercontent.com/ArtDmSav/agentboard-updates/main/install.sh \
#     | bash -s -- --domain board.example.com --with-agent
#
# Флаги — `agentboard-install.py install --help` (docs/SERVER_TASK.md, раздел 37); --dry-run показывает план и ничего
# не меняет. Повторный запуск безопасен: делается только недостающее, а в конце — новый код сопряжения.
#
# Что делает этот файл (загрузчик), и только это:
#   1. проверяет, что это root и Ubuntu 24.04 / Debian 12;
#   2. ставит python3, python3-venv, curl и сертификаты, если их нет (apt);
#   3. скачивает последний выпуск из канала ArtDmSav/agentboard-updates (GitHub Releases) и проверяет его: SHA-256
#      manifest.json — по channel.json, размер и SHA-256 архива — по manifest.json;
#   4. берёт из архива установщик этого же выпуска (updater/installer/agentboard-install.py) и запускает
#      `agentboard-install.py install --from-dir <скачанный выпуск> <ваши флаги>`: он проверяет выпуск ещё раз
#      сам (а когда выпуски станут подписанными — и подписи) и ставит всё остальное.
# Сам код установки живёт в выпуске, а не здесь: этот файл меняется, только если меняется формат канала. Доверие —
# то же, что к выпускам: репозиторий канала на GitHub по HTTPS.
#
# Источник — updater/installer/install.sh репозитория «Доски»; в корень канала (ветка main) его кладёт владелец
# (README канала, «Установка»). Весь файл — одна функция, вызванная в последней строке: оборванная загрузка
# ничего не запустит.
set -euo pipefail

main() {
  local base="https://github.com/ArtDmSav/agentboard-updates" channel="" from_dir="" dry_run=0
  local -a pass=() global=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --releases) base="${2:?--releases: нужен адрес}"; global+=(--releases "$2"); shift 2 ;;
      --channel) channel="${2:?--channel: нужен адрес}"; global+=(--channel "$2"); shift 2 ;;
      --from-dir) from_dir="${2:?--from-dir: нужна папка}"; shift 2 ;;
      --dry-run) dry_run=1; pass+=("$1"); shift ;;
      -h|--help) usage; return 0 ;;
      *) pass+=("$1"); shift ;;
    esac
  done
  base="${base%/}"
  [ -n "$channel" ] || channel="$base/releases/latest/download/channel.json"

  say "«Доска»: установка сервера одной командой$([ "$dry_run" = 1 ] && echo ' — пробный запуск, ничего не меняется')"
  if [ "$(id -u)" != 0 ] && [ "$dry_run" != 1 ]; then
    die "запустите от root: sudo -i, затем команду ещё раз (или … | sudo bash)"
  fi
  [ -r "$OS_RELEASE" ] || die "нет $OS_RELEASE: не понять, что это за система"
  local os_id os_version os_name
  os_id="$(os_field ID)"
  os_version="$(os_field VERSION_ID)"
  os_name="$(os_field PRETTY_NAME)"
  os_name="${os_name:-$os_id $os_version}"
  case "$os_id:$os_version" in
    ubuntu:24.04|debian:12) say "  система: $os_name" ;;
    *) die "система «$os_name» не поддерживается: нужна Ubuntu 24.04 или Debian 12 (лучше — чистый сервер)" ;;
  esac
  case "$(uname -m)" in
    x86_64|aarch64) ;;
    *) say "  ! процессор $(uname -m): проверено только на x86_64 и aarch64" ;;
  esac

  local -a need=()
  command -v python3 >/dev/null 2>&1 || need+=(python3)
  python3 -c 'import ensurepip, venv' >/dev/null 2>&1 || need+=(python3-venv)
  command -v curl >/dev/null 2>&1 || need+=(curl)
  [ -e /etc/ssl/certs/ca-certificates.crt ] || need+=(ca-certificates)
  if [ "${#need[@]}" -gt 0 ]; then
    if [ "$dry_run" = 1 ]; then
      say "  будет поставлено: ${need[*]} (apt-get install)"
      if ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
        die "без python3 и curl пробный запуск дальше не пройти: запустите без --dry-run" \
          "(или apt-get install -y python3 curl)"
      fi
    else
      say "  ставлю: ${need[*]}"
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -q >/dev/null || die "apt-get update не прошёл: нет сети или зеркала apt недоступны"
      apt-get install -y -q --no-install-recommends "${need[@]}" >/dev/null \
        || die "apt-get install ${need[*]} не прошёл"
    fi
  fi
  python3 -c 'import sys; sys.exit(sys.version_info < (3, 11))' \
    || die "Python $(python3 -V 2>&1) — нужен 3.11 или новее"

  local work release
  # The folder is removed when the script ends, whatever the way: the trap runs after main has returned, so it names
  # the folder itself, not the local variable.
  work="$(mktemp -d /tmp/agentboard-install.XXXXXX)"
  # shellcheck disable=SC2064  # expanded now, on purpose
  trap "rm -rf -- '$work'" EXIT
  release="$work/release"
  mkdir -m 0700 "$release"
  if [ -n "$from_dir" ]; then
    [ -d "$from_dir" ] || die "--from-dir $from_dir: нет такой папки"
    local file
    for file in "$from_dir"/channel.json "$from_dir"/manifest.json "$from_dir"/*.sig \
                "$from_dir"/agentboard-server-*.tar.gz; do
      if [ -f "$file" ] && [ ! -L "$file" ]; then cp "$file" "$release/"; fi
    done
    [ -f "$release/channel.json" ] && [ -f "$release/manifest.json" ] \
      || die "в $from_dir нет channel.json и manifest.json"
    say "  выпуск — из папки $from_dir"
  else
    say "  канал выпусков: $channel"
    fetch "$channel" "$release/channel.json" 65536 || die "не скачать $channel — нет связи с GitHub?"
    fetch "$channel.sig" "$release/channel.json.sig" 1024 2>/dev/null || rm -f "$release/channel.json.sig"
  fi

  # Канал → тег и SHA-256 манифеста последнего выпуска.
  local facts tag version manifest_sha
  facts="$(python3 -I - "$release/channel.json" <<'PY'
import json, re, sys
try:
    ch = json.load(open(sys.argv[1], encoding="utf-8"))
    row = ch["releases"][0]
    assert ch["latest"] == row["version"]
    assert re.fullmatch(r"[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}", row["version"])
    assert re.fullmatch(r"server-v" + re.escape(row["version"]) + r"(-rc[0-9]{1,3})?", row["tag"])
    assert re.fullmatch(r"[0-9a-f]{64}", row["manifest_sha256"])
except Exception:
    sys.exit(1)
print(row["tag"], row["version"], row["manifest_sha256"])
PY
)" || die "channel.json не по форме: это не канал выпусков «Доски»"
  read -r tag version manifest_sha <<<"$facts"
  if [ -z "$from_dir" ]; then
    fetch "$base/releases/download/$tag/manifest.json" "$release/manifest.json" 65536 \
      || die "не скачать manifest.json выпуска $version"
    fetch "$base/releases/download/$tag/manifest.json.sig" "$release/manifest.json.sig" 1024 2>/dev/null \
      || rm -f "$release/manifest.json.sig"
  fi
  [ "$(sha256 "$release/manifest.json")" = "$manifest_sha" ] \
    || die "SHA-256 manifest.json выпуска $version не совпал с каналом: ничего не ставлю"

  # Манифест → архив: имя, адрес, размер, SHA-256.
  local name url size artifact_sha
  facts="$(python3 -I - "$release/manifest.json" "$version" <<'PY'
import json, re, sys
try:
    m = json.load(open(sys.argv[1], encoding="utf-8"))
    a = m["artifact"]
    assert m["product"] == "agentboard-server" and m["version"] == sys.argv[2]
    assert a["name"] == f"agentboard-server-{sys.argv[2]}.tar.gz"
    assert re.fullmatch(r"https://[A-Za-z0-9./_-]+", a["url"]) and a["url"].endswith("/" + a["name"])
    assert type(a["size"]) is int and 0 < a["size"] <= 100_000_000
    assert re.fullmatch(r"[0-9a-f]{64}", a["sha256"])
except Exception:
    sys.exit(1)
print(a["name"], a["url"], a["size"], a["sha256"])
PY
)" || die "manifest.json выпуска $version не по форме"
  read -r name url size artifact_sha <<<"$facts"
  if [ -z "$from_dir" ]; then
    say "  выпуск $version: скачиваю $name"
    fetch "$url" "$release/$name" "$size" || die "не скачать $url"
  fi
  [ -f "$release/$name" ] || die "нет архива $name"
  [ "$(wc -c <"$release/$name" | tr -d ' ')" = "$size" ] || die "размер $name не совпал с манифестом: ничего не ставлю"
  [ "$(sha256 "$release/$name")" = "$artifact_sha" ] || die "SHA-256 $name не совпал с манифестом: ничего не ставлю"
  say "  выпуск $version проверен: SHA-256 манифеста и архива сходятся"

  local installer="agentboard-server-$version/updater/installer/agentboard-install.py"
  tar -xzf "$release/$name" -C "$work" "$installer" 2>/dev/null \
    || die "в выпуске $version нет установщика ($installer)"
  python3 -I "$work/$installer" install --help >/dev/null 2>&1 \
    || die "установщик выпуска $version не умеет установку одной командой: нужен выпуск 1.19.0 или новее"

  local code=0
  if (exec </dev/tty) 2>/dev/null; then
    python3 -I "$work/$installer" "${global[@]}" install --from-dir "$release" "${pass[@]}" </dev/tty || code=$?
  else
    python3 -I "$work/$installer" "${global[@]}" install --from-dir "$release" "${pass[@]}" </dev/null || code=$?
  fi
  return "$code"
}

usage() {
  printf '%s\n' \
    "«Доска»: установка сервера одной командой (Ubuntu 24.04 / Debian 12, от root)." \
    "  curl -fsSL https://raw.githubusercontent.com/ArtDmSav/agentboard-updates/main/install.sh | bash" \
    "  … | bash -s -- --domain board.example.com    свой домен (иначе — <IP>.sslip.io)" \
    "  … | bash -s -- --with-agent                   ещё Claude Code и сессии «Агентов»" \
    "  … | bash -s -- --dry-run                      только показать план" \
    "Остальные флаги — у установщика выпуска (agentboard-install.py install --help); docs/SERVER_TASK.md, раздел 37."
}

say() { printf '%s\n' "$*"; }

die() {
  printf '\nошибка: %s\n' "$*" >&2
  exit 1
}

sha256() { sha256sum "$1" | cut -d' ' -f1; }

# os_field NAME: a field of /etc/os-release (sourced in a subshell, as the file is meant to be read).
os_field() {
  # shellcheck disable=SC1090  # the server's own file
  (. "$OS_RELEASE" && eval "printf '%s' \"\${$1:-}\"")
}

# Tests put another system's file here (updater/tests/test_bootstrap.py); on a server it is always /etc/os-release.
OS_RELEASE="${AGENTBOARD_OS_RELEASE:-/etc/os-release}"

# fetch URL FILE MAX_BYTES: только HTTPS, повторы, не больше MAX_BYTES.
fetch() {
  curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 \
    --max-filesize "$3" -o "$2" "$1"
}

main "$@"
