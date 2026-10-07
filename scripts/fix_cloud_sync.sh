#!/usr/bin/env bash
# Corrige a configuração pública do Supabase e recompila o APK do carro.
# Requer Bash, Python 3 e Flutter. Não instala o APK nem acessa o Supabase.
set -euo pipefail
set +x # Nunca exiba a chave em traces deste script.

usage() {
  cat <<'USAGE'
Uso: scripts/fix_cloud_sync.sh [CHAVE_PUBLICA] [--no-update-car-env] [--configure-only]

A chave também pode vir de SUPABASE_PUBLISHABLE_KEY ou SUPABASE_ANON_KEY.
O argumento tem prioridade. Somente sb_publishable_* ou JWT com role=anon.
SUPABASE_URL pode substituir o projeto padrão:
  https://wdfsjhhtgqnrvpfjkcjp.supabase.co

Por padrão, atualiza android/local.properties e car_env.json, preserva outras
configurações, limpa o build e executa:
  flutter build apk --release --target-platform android-arm64 \
    --build-name=VERSAO-debug --dart-define-from-file=car_env.json
Entrega: Eaglemetry_v01_test.apk para a versão 0.1.0 do pubspec.yaml.
O sufixo -debug bloqueia auto-update local; o APK usa Flutter release/AOT.

--no-update-car-env  Preserva car_env.json; exige configuração correspondente.
--configure-only     Atualiza/valida os arquivos sem limpar ou compilar.
--help               Mostra este uso.
FLUTTER_BIN          Caminho opcional do executável Flutter.

Exemplo sem gravar a chave no histórico (Bash):
  read -r -s -p 'Chave pública Supabase: ' SUPABASE_PUBLISHABLE_KEY; echo
  export SUPABASE_PUBLISHABLE_KEY
  scripts/fix_cloud_sync.sh
  unset SUPABASE_PUBLISHABLE_KEY

A validação é local e não confirma que a chave está ativa no servidor.
Chaves secret/service_role são recusadas. Não use credenciais privadas.
USAGE
}
die() { printf 'Erro: %s\n' "$*" >&2; exit 1; }
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPDATE_ENV=1
CONFIGURE_ONLY=0
KEY="${SUPABASE_PUBLISHABLE_KEY:-${SUPABASE_ANON_KEY:-}}"
HAVE_KEY=0
for arg in "$@"; do
  case "$arg" in
    --help|-h) usage; exit 0 ;;
    --no-update-car-env) UPDATE_ENV=0 ;;
    --configure-only) CONFIGURE_ONLY=1 ;;
    --*) die "Opção desconhecida. Use --help." ;;
    *) [[ "$HAVE_KEY" == 0 ]] || die 'Informe somente uma chave.'
       KEY="$arg"; HAVE_KEY=1 ;;
  esac
done
command -v python3 >/dev/null || die 'Python 3 não encontrado.'
FLUTTER_BIN="${FLUTTER_BIN:-flutter}"
if [[ "$CONFIGURE_ONLY" == 0 ]]; then
  command -v "$FLUTTER_BIN" >/dev/null || die 'Flutter não encontrado; use FLUTTER_BIN.'
fi
# Transfere a chave ao validador pelo ambiente, nunca pela linha de comando.
export FIX_SYNC_PUBLIC_KEY="$KEY"
export FIX_SYNC_URL="${SUPABASE_URL:-https://wdfsjhhtgqnrvpfjkcjp.supabase.co}"
python3 - "$ROOT_DIR" "$UPDATE_ENV" <<'PY'
import base64
import json
import os
from pathlib import Path
import re
import sys
import tempfile
from urllib.parse import urlsplit


def fail(message):
    sys.exit('Erro: ' + message)


root = Path(sys.argv[1])
key = os.environ['FIX_SYNC_PUBLIC_KEY']
url = os.environ['FIX_SYNC_URL'].rstrip('/')
parts = urlsplit(url)
if (parts.scheme != 'https' or not parts.hostname or parts.username or parts.password
        or parts.query or parts.fragment or parts.path or not re.fullmatch(r'https://[A-Za-z0-9.-]+(?::[0-9]+)?', url)):
    fail('SUPABASE_URL deve ser uma origem HTTPS válida, sem caminho ou credenciais.')
if not key or key != key.strip():
    fail('A chave pública está vazia ou contém espaços nas extremidades.')
if not re.fullmatch(r'sb_publishable_[A-Za-z0-9_-]{20,}', key):
    if not re.fullmatch(r'[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+', key):
        fail('Use uma chave sb_publishable_* ou um JWT anon legado.')
    try:
        header, payload, signature = key.split('.')
        decode = lambda value: json.loads(base64.urlsafe_b64decode(value + '=' * (-len(value) % 4)))
        claims = decode(payload)
        metadata = decode(header)
        if claims.get('role') != 'anon' or metadata.get('alg') != 'HS256':
            fail('Somente JWT público com role=anon e algoritmo HS256 é aceito.')
        if claims.get('ref') and parts.hostname.endswith('.supabase.co') and claims['ref'] != parts.hostname.split('.')[0]:
            fail('O JWT pertence a outro projeto Supabase.')
        if len(base64.urlsafe_b64decode(signature + '=' * (-len(signature) % 4))) != 32:
            fail('A assinatura do JWT tem formato inválido.')
    except (ValueError, TypeError, AttributeError):
        fail('JWT inválido. Não foi possível ler seus campos.')

local = root / 'android/local.properties'
env_file = root / 'car_env.json'
# Valida todos os arquivos antes de escrever. Não altera campos privados existentes.
try:
    env = json.loads(env_file.read_text()) if env_file.exists() else {}
except (ValueError, OSError):
    fail('car_env.json não contém JSON válido ou não pode ser lido.')
if not isinstance(env, dict):
    fail('car_env.json deve conter um objeto JSON.')
public = {'SUPABASE_URL': url, 'SUPABASE_PUBLISHABLE_KEY': key, 'SUPABASE_ANON_KEY': key}
if sys.argv[2] == '0':
    if any(env.get(k) != v for k, v in public.items()) or str(env.get('CLOUD_SYNC_ENABLED', 'true')).lower() != 'true':
        fail('car_env.json não corresponde à configuração solicitada; permita sua atualização.')
else:
    env.update(public)
    env['CLOUD_SYNC_ENABLED'] = True

values = {'SUPABASE_URL': url, 'SUPABASE_ANON_KEY': key,
          'SUPABASE_FUNCTIONS_URL': url + '/functions/v1', 'CLOUD_SYNC_ENABLED': 'true'}
lines = local.read_text().splitlines(keepends=True) if local.exists() else []
output = []
seen = set()
continuation = False
for line in lines:
    # Preserva propriedades alheias. Remove também valores continuados das chaves alvo.
    if continuation:
        continuation = len(line.rstrip('\r\n')) - len(line.rstrip('\r\n').rstrip('\\'))
        continuation = bool(continuation % 2)
        continue
    match = re.match(r'^\s*([^#!\s=:]+)(?:\s*[=:]|\s|$)', line)
    name = match.group(1) if match else None
    if name in values:
        continuation = bool((len(line.rstrip('\r\n')) - len(line.rstrip('\r\n').rstrip('\\'))) % 2)
        if name not in seen:
            output.append(name + '=' + values[name] + '\n')
            seen.add(name)
    else:
        output.append(line)
if output and not output[-1].endswith(('\n', '\r')):
    output[-1] += '\n'
output.extend(k + '=' + v + '\n' for k, v in values.items() if k not in seen)


def write_atomic(path, content):
    if path.is_symlink():
        fail('Arquivo de configuração não pode ser link simbólico.')
    if path.exists() and path.read_text() == content:
        return
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix='.' + path.name)
    try:
        with os.fdopen(fd, 'w') as stream:
            stream.write(content)
        if path.exists():
            os.chmod(temporary, path.stat().st_mode & 0o777)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)

if local.is_symlink() or env_file.is_symlink():
    fail('Arquivos de configuração não podem ser links simbólicos.')
write_atomic(local, ''.join(output))
if sys.argv[2] != '0':
    write_atomic(env_file, json.dumps(env, indent=2, ensure_ascii=False) + '\n')
print('Configuração pública validada e atualizada, sem duplicar chaves.')
PY
unset FIX_SYNC_PUBLIC_KEY FIX_SYNC_URL KEY
[[ "$CONFIGURE_ONLY" == 0 ]] || exit 0
cd "$ROOT_DIR"
# Nome de entrega combinado: 0.1.0 -> v01; 0.1.2 -> v01_2.
# O número de build (+NNN) não altera o nome da versão pública.
APK_NAME="$(python3 - <<'PYVERSION'
from pathlib import Path
import re
text = Path('pubspec.yaml').read_text()
match = re.search(r'^version:\s*(\d+)\.(\d+)\.(\d+)(?:\+[0-9]+)?\s*(?:#.*)?$', text, re.MULTILINE)
if not match:
    raise SystemExit('Erro: versão numérica inválida no pubspec.yaml.')
major, minor, patch = match.groups()
tag = major + minor + ('_' + patch if int(patch) else '')
print('Eaglemetry_v' + tag + '_test.apk')
PYVERSION
)"
# Limpa saídas nativas e Flutter que podem conter BuildConfig antigo.
BUILD_NAME="$(sed -n 's/^version: \([^+ ]*\).*/\1/p' pubspec.yaml)-debug"
"$FLUTTER_BIN" clean
"$FLUTTER_BIN" pub get
"$FLUTTER_BIN" build apk --release --target-platform android-arm64 \
  --build-name="$BUILD_NAME" --dart-define-from-file=car_env.json
APK="$ROOT_DIR/build/app/outputs/flutter-apk/app-release.apk"
[[ -f "$APK" ]] || die 'Build terminou sem o APK esperado.'
DELIVERY_APK="$ROOT_DIR/build/app/outputs/flutter-apk/$APK_NAME"
cp "$APK" "$DELIVERY_APK"
printf 'APK gerado: %s\n' "$DELIVERY_APK"
