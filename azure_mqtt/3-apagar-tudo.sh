#!/usr/bin/env bash
# =====================================================================
#  TIM_2026 - Aula 1 - Passo 3: apagar todos os recursos da Azure
#  Uso:  ./3-apagar-tudo.sh [equipe]
#  Apaga o grupo de recursos inteiro (VM, disco, IP, rede, NSG).
# =====================================================================
set -euo pipefail
cd "$(dirname "$0")"
EQUIPE="${1:-equipe01}"
ARQ_CRED="credenciais-$EQUIPE.txt"
GRUPO="${GRUPO:-}"
if [ -z "$GRUPO" ] && [ -f "$ARQ_CRED" ]; then
  GRUPO="$(grep -m1 '^GRUPO_RECURSOS=' "$ARQ_CRED" | cut -d= -f2-)"
fi
if [ -z "$GRUPO" ]; then
  PREFIXO="$( (grep -m1 '^PREFIXO_GRUPO=' config.env 2>/dev/null || true) | cut -d= -f2- | tr -d '[:space:]' )"
  GRUPO="${PREFIXO:-mqtt-lab-rg}-$EQUIPE"
fi

echo "Serao apagados TODOS os recursos do grupo: $GRUPO"
az group show -n "$GRUPO" --query "{nome:name,regiao:location}" -o tsv 2>/dev/null || { echo "Grupo nao existe. Nada a fazer."; exit 0; }
echo
az resource list -g "$GRUPO" --query "[].{tipo:type,nome:name}" -o table 2>/dev/null || true
echo
printf 'Digite APAGAR para confirmar: '
read -r RESP
[ "$RESP" = "APAGAR" ] || { echo "Cancelado."; exit 0; }

az group delete -n "$GRUPO" --yes --no-wait --only-show-errors
echo "Exclusao iniciada em segundo plano."
echo "Confira em alguns minutos com: az group exists -n $GRUPO"
echo "Cobranca cessa quando a exclusao concluir."
