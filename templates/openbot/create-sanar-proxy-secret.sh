#!/usr/bin/env bash
# Cria o Secret openbot/sanar-proxy, usado pelo sanar-proxy (LiteLLM entre o OpenBot e o Sanar Router):
#   SANAR_API_KEY       a chave do Sanar Router, lida do stdin (uma linha, só o valor)
#   LITELLM_MASTER_KEY  a chave que o OpenBot usa para falar com o proxy; gerada aqui (aleatória)
# Nenhum dos dois valores é impresso.
#
# Rode do SEU computador, ANTES do push que ativa o proxy (sem o Secret, o pod fica em
# CreateContainerConfigError). Exemplo, lendo a chave de um arquivo .env:
#   grep '^SANAR_API_KEY=' <arquivo .env com a chave> | cut -d= -f2- | \
#     KUBECTL="ssh ubuntu@100.95.76.83 sudo k3s kubectl" bash templates/openbot/create-sanar-proxy-secret.sh
#
# Depois, copie a LITELLM_MASTER_KEY para a área de transferência (sem exibi-la) e cole-a como chave do
# provedor no OpenBot (veja docs/aplicacoes/openbot.md):
#   ssh ubuntu@100.95.76.83 "sudo k3s kubectl -n openbot get secret sanar-proxy -o jsonpath='{.data.LITELLM_MASTER_KEY}'" | base64 -d | wl-copy
#
# Se o Secret já existir, aborta sem alterar nada. Para trocar a chave do router: apague o Secret, rode de
# novo, reinicie o proxy (rollout restart deploy/sanar-proxy) e cole a nova LITELLM_MASTER_KEY no OpenBot.
# Desfazer: ssh ubuntu@100.95.76.83 'sudo k3s kubectl -n openbot delete secret sanar-proxy'
# Variáveis: KUBECTL (padrão: "sudo k3s kubectl").
set -euo pipefail

KUBECTL=${KUBECTL:-"sudo k3s kubectl"}

if [ -t 0 ]; then
  echo "passe a chave do Sanar Router por stdin (… | bash create-sanar-proxy-secret.sh)" >&2
  exit 1
fi

IFS= read -r chave || true
chave=${chave%$'\r'}
chave=${chave#\"}; chave=${chave%\"}
chave=${chave#\'}; chave=${chave%\'}
# Uma chave de API: sem espaços nem aspas, de tamanho razoável. Nunca mostra o valor.
if ! [[ "$chave" =~ ^[A-Za-z0-9._~+/=-]{16,512}$ ]]; then
  echo "a chave recebida não parece uma chave de API (vazia, com espaços ou caracteres inesperados); nada foi alterado" >&2
  exit 1
fi

if $KUBECTL -n openbot get secret sanar-proxy </dev/null >/dev/null 2>&1; then
  echo "o Secret sanar-proxy já existe; nada foi alterado" >&2
  exit 1
fi

$KUBECTL create namespace openbot --dry-run=client -o yaml </dev/null | $KUBECTL apply -f - >/dev/null
printf 'SANAR_API_KEY=%s\nLITELLM_MASTER_KEY=sk-%s\n' "$chave" "$(openssl rand -hex 24)" |
  $KUBECTL -n openbot create secret generic sanar-proxy --from-env-file=/dev/stdin >/dev/null

echo "Secret criado: openbot/sanar-proxy (SANAR_API_KEY e LITELLM_MASTER_KEY)"
