#!/usr/bin/env bash
# =====================================================================
#  TIM_2026 - Aula 1 - Passo 2: conferir o broker e ouvir as mensagens
#  Uso:  ./2-verificar-broker.sh [equipe] [segundos]
#  Tudo via HTTPS (az vm run-command): nao usa SSH nem a porta 1883.
# =====================================================================
set -euo pipefail
cd "$(dirname "$0")"

EQUIPE="${1:-equipe01}"
SEGUNDOS="${2:-30}"
ARQ_CRED="credenciais-$EQUIPE.txt"
if [ ! -f "$ARQ_CRED" ]; then
  echo "[ERRO] $ARQ_CRED nao encontrado."
  DISP="$( (ls credenciais-*.txt 2>/dev/null || true) | sed 's/^credenciais-//;s/\.txt$//' | tr '\n' ' ' )"
  if [ -n "$DISP" ]; then
    echo "       Equipes ja criadas nesta pasta: $DISP"
    echo "       Use: ./2-verificar-broker.sh <equipe>"
  else
    echo "       Nenhum broker criado ainda. Rode: ./1-criar-broker.sh $EQUIPE"
  fi
  exit 1
fi
# shellcheck disable=SC1090
set -a; . "./$ARQ_CRED"; set +a

linha() { printf '%s\n' "----------------------------------------------------------"; }
rodar() { az vm run-command invoke -g "$GRUPO_RECURSOS" -n "$NOME_VM" --command-id RunShellScript \
            --scripts "$1" --query 'value[0].message' -o tsv 2>/dev/null | sed '/^\[stdout\]$/d;/^\[stderr\]$/d'; }

linha; echo " Estado do broker - equipe $EQUIPE"; linha
ESTADO="$(rodar 'echo "servico: $(systemctl is-active mosquitto)"; echo "--- portas em escuta ---"; ss -ltn | grep -E ":(80|1883|8080)[[:space:]]" || echo "portas MQTT NAO estao em escuta"; echo "--- ultimas linhas do setup ---"; tail -n 8 /var/log/tim2026-setup.log 2>/dev/null; if ! systemctl is-active --quiet mosquitto; then echo "--- motivo da falha ---"; journalctl -u mosquitto -n 15 --no-pager; fi')"
printf '%s\n' "$ESTADO"
if printf '%s' "$ESTADO" | grep -q 'servico: active'; then
  :
else
  linha
  echo " O broker NAO esta ativo. Rode o reparo, que corrige as causas conhecidas"
  echo " sem recriar a VM:"
  echo "   ./4-reparar-broker.sh $EQUIPE"
  linha
  exit 1
fi

linha; echo " Ouvindo senai/tim2026/# por ${SEGUNDOS}s"
echo " Dispare agora 'Coletar todos agora' no Node-RED."; linha
rodar "timeout ${SEGUNDOS} mosquitto_sub -h 127.0.0.1 -p 1883 -u '$USUARIO_MQTT' -P \"\$(cat /root/mqtt_pass)\" -t 'senai/tim2026/#' -q 1 -v; echo '--- fim da escuta ---'"

linha; echo " Clientes conectados (log do broker)"; linha
rodar "grep -E 'New client connected|disconnect' /var/log/mosquitto/mosquitto.log 2>/dev/null | tail -n 10 || echo 'sem registros'"
linha
echo " Se nada apareceu: confira no Node-RED se o no esta 'connected',"
echo " se o Topic esta vazio e se a sessao de medicoes foi limpa."
linha
