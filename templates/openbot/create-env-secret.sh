#!/usr/bin/env bash
# Cria o Secret OPCIONAL openbot/openbot-env com chaves de provedores para o OpenBot (variáveis de
# ambiente do pod). O OpenBot funciona sem ele: a maioria dos provedores entra pelo próprio CLI
# (Claude Code, Codex...). Use só para provedores que pedem chave, como o Grok (XAI_API_KEY).
#
# Os valores vêm de um arquivo no SEU computador, no formato NOME=valor (uma por linha; linhas vazias e
# começando com # são ignoradas), passam por stdin e nunca são impressos. Rode do seu computador:
#   KUBECTL="ssh ubuntu@100.95.76.83 sudo k3s kubectl" bash templates/openbot/create-env-secret.sh < openbot.env
# (no fish, igual: a variável na frente do comando funciona). Apague o openbot.env depois.
#
# Nomes aceitos: XAI_API_KEY, CURSOR_API_KEY, CLINE_API_KEY, MISTRAL_API_KEY, OPENBOT_AUTH_API_URL,
# OPENBOT_DISPLAY_SIZE. ATENÇÃO: todos os agentes do OpenBot conseguem ler essas variáveis.
#
# Se o Secret já existir, aborta sem alterar nada. Depois de criar, reinicie o pod para ele ler o Secret:
#   ssh ubuntu@100.95.76.83 'sudo k3s kubectl -n openbot rollout restart deploy/openbot'
# Desfazer: ssh ubuntu@100.95.76.83 'sudo k3s kubectl -n openbot delete secret openbot-env' e reinicie o pod.
# Variáveis: KUBECTL (padrão: "sudo k3s kubectl").
set -euo pipefail

KUBECTL=${KUBECTL:-"sudo k3s kubectl"}
NOMES='XAI_API_KEY|CURSOR_API_KEY|CLINE_API_KEY|MISTRAL_API_KEY|OPENBOT_AUTH_API_URL|OPENBOT_DISPLAY_SIZE'

if [ -t 0 ]; then
  echo "passe o arquivo NOME=valor por stdin (… < openbot.env)" >&2
  exit 1
fi

linhas=""
numero=0
while IFS= read -r linha || [ -n "$linha" ]; do
  numero=$((numero + 1))
  linha=${linha%$'\r'}
  case "$linha" in '' | '#'*) continue ;; esac
  if ! [[ "$linha" =~ ^($NOMES)=[^[:space:]].*$ ]]; then
    # Mostra só o número da linha e o nome, nunca o valor (uma linha sem "=" pode ser uma chave colada).
    if [[ "$linha" == *=* && "${linha%%=*}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      echo "linha $numero inválida (nome '${linha%%=*}' não aceito ou valor vazio); nada foi alterado" >&2
    else
      echo "linha $numero inválida (esperado NOME=valor); nada foi alterado" >&2
    fi
    exit 1
  fi
  linhas+="$linha"$'\n'
done

if [ -z "$linhas" ]; then
  echo "nenhuma variável recebida; nada foi alterado" >&2
  exit 1
fi

if $KUBECTL -n openbot get secret openbot-env </dev/null >/dev/null 2>&1; then
  echo "o Secret openbot-env já existe; nada foi alterado" >&2
  exit 1
fi

$KUBECTL create namespace openbot --dry-run=client -o yaml </dev/null | $KUBECTL apply -f - >/dev/null
printf '%s' "$linhas" | $KUBECTL -n openbot create secret generic openbot-env --from-env-file=/dev/stdin >/dev/null

echo "Secret criado: openbot/openbot-env ($(printf '%s' "$linhas" | grep -c .) variável(is)). Reinicie o pod para aplicar."
