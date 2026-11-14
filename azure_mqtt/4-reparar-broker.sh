#!/usr/bin/env bash
# =====================================================================
#  TIM_2026 - Aula 1 - Passo 4: reparar o broker de uma VM existente
#  Uso:  ./4-reparar-broker.sh [equipe]
#  Nao recria a VM. Roda por HTTPS (az vm run-command), sem SSH.
# =====================================================================
set -euo pipefail
cd "$(dirname "$0")"
EQUIPE="${1:-equipe01}"
ARQ_CRED="credenciais-$EQUIPE.txt"
linha() { printf '%s\n' "----------------------------------------------------------"; }

[ -f "$ARQ_CRED" ] || { echo "[ERRO] $ARQ_CRED nao encontrado."; exit 1; }
[ -f reparo-remoto.sh ] || { echo "[ERRO] reparo-remoto.sh nao encontrado nesta pasta."; exit 1; }
set -a; . "./$ARQ_CRED"; set +a
command -v az >/dev/null 2>&1 || { echo "[ERRO] Azure CLI nao encontrada."; exit 1; }

linha
echo " Reparando o broker da equipe $EQUIPE"
echo " VM: $NOME_VM   grupo: $GRUPO_RECURSOS"
echo " Isso leva cerca de 1 minuto."
linha
SAIDA=""
# Forma preferida: a Azure CLI le o script do arquivo.
if SAIDA="$(az vm run-command invoke -g "$GRUPO_RECURSOS" -n "$NOME_VM" \
      --command-id RunShellScript --scripts @reparo-remoto.sh \
      --query 'value[0].message' -o tsv 2>/dev/null)" && [ -n "$SAIDA" ]; then
  :
else
  # Reserva: envia o conteudo do script como argumento unico.
  SAIDA="$(az vm run-command invoke -g "$GRUPO_RECURSOS" -n "$NOME_VM" \
      --command-id RunShellScript --scripts "$(cat reparo-remoto.sh)" \
      --query 'value[0].message' -o tsv)" \
    || { echo "[ERRO] Nao foi possivel executar o reparo na VM. A VM esta ligada? Confira: az vm get-instance-view -g $GRUPO_RECURSOS -n $NOME_VM --query instanceView.statuses"; exit 1; }
fi
printf '%s\n' "$SAIDA" | sed '/^\[stdout\]$/d;/^\[stderr\]$/d'
linha
echo " Se o resultado foi BROKER ATIVO, teste agora:"
echo "   ./2-verificar-broker.sh $EQUIPE 30"
echo "   ou abra monitor.html com a URL $URL_WEBSOCKET_NODE_RED"
linha
