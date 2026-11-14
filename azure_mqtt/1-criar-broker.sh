#!/usr/bin/env bash
# =====================================================================
#  TIM_2026 - Aula 1 - Passo 1: criar o broker MQTT na Azure
#  Uso:   ./1-criar-broker.sh [equipe]
#  Ajustes de regiao, tamanho da VM e rede: arquivo config.env
#  Requisitos: Azure CLI (az) e uma assinatura autorizada.
# =====================================================================
set -euo pipefail
cd "$(dirname "$0")"

EQUIPE="${1:-equipe01}"

linha() { printf '%s\n' "----------------------------------------------------------"; }
TRATADO=0
erro()  { TRATADO=1; printf '\n[ERRO] %s\n' "$1" >&2; exit 1; }
trap 'c=$?; if [ "$c" -ne 0 ] && [ "$TRATADO" -eq 0 ]; then
  printf "\n[ERRO] o script parou de forma inesperada (codigo %s) no passo acima.\n" "$c" >&2
  printf "       Reexecute o mesmo comando: ele e seguro de repetir.\n" >&2
fi' EXIT

# --- configuracao ----------------------------------------------------
# Precedencia: variavel de ambiente > config.env > padrao do script.
ENV_REGIAO="${REGIAO:-}"; ENV_ORIGEM="${ORIGEM:-}"; ENV_TAMANHO="${TAMANHO_VM:-}"
# Leitura segura do config.env: so chaves conhecidas, sem executar o arquivo.
REGIAO=brazilsouth; REGIOES_ALTERNATIVAS=""
TAMANHO_VM=Standard_B1s; TAMANHOS_ALTERNATIVOS=""
ORIGEM=Internet; ABRIR_1883=true; PREFIXO_GRUPO=mqtt-lab-rg
if [ -f config.env ]; then
  while IFS= read -r L || [ -n "$L" ]; do
    case "$L" in ''|'#'*) continue;; esac
    K="${L%%=*}"; V="${L#*=}"
    K="$(printf '%s' "$K" | tr -d '[:space:]')"
    V="$(printf '%s' "$V" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^"//;s/"$//')"
    case "$K" in
      REGIAO|REGIOES_ALTERNATIVAS|TAMANHO_VM|TAMANHOS_ALTERNATIVOS|ORIGEM|ABRIR_1883|PREFIXO_GRUPO)
        eval "$K=\$V" ;;
    esac
  done < config.env
else
  echo "[aviso] config.env nao encontrado; usando os valores padrao."
fi
[ -n "$ENV_REGIAO" ]  && REGIAO="$ENV_REGIAO"
[ -n "$ENV_ORIGEM" ]  && ORIGEM="$ENV_ORIGEM"
[ -n "$ENV_TAMANHO" ] && TAMANHO_VM="$ENV_TAMANHO"

GRUPO="${GRUPO:-$PREFIXO_GRUPO-$EQUIPE}"
ARQ_CRED="credenciais-$EQUIPE.txt"

# --- guarda de custo -------------------------------------------------
# Lista de tamanhos economicos aceitos. Qualquer outro exige confirmacao.
ECONOMICOS="Standard_B1ls Standard_B1s Standard_B1ms Standard_B2ts_v2 Standard_B2ls_v2 Standard_B2s"
economico() { case " $ECONOMICOS " in *" $1 "*) return 0;; *) return 1;; esac; }
if ! economico "$TAMANHO_VM"; then
  linha
  echo " ATENCAO: $TAMANHO_VM nao esta na lista de tamanhos economicos."
  echo " Tamanhos sugeridos para o broker: $ECONOMICOS"
  echo " Uma VM maior pode custar varias vezes mais por hora ligada."
  printf ' Digite CONTINUAR para usar %s mesmo assim: ' "$TAMANHO_VM"
  read -r OKC
  [ "$OKC" = "CONTINUAR" ] || erro "Cancelado. Ajuste TAMANHO_VM no config.env."
fi

if ! printf '%s' "$EQUIPE" | grep -qE '^[a-zA-Z0-9_-]+$'; then
  erro "Identificador de equipe invalido: use apenas letras, numeros, _ ou -"
fi

linha
echo " TIM_2026 - criando broker MQTT na Azure"
echo " Equipe .........: $EQUIPE"
echo " Grupo recursos .: $GRUPO"
echo " Regiao preferida: $REGIAO"
echo " Tamanho da VM ..: $TAMANHO_VM"
echo " Origem liberada : $ORIGEM"
linha

command -v az >/dev/null 2>&1 || erro "Azure CLI nao encontrada. Instale em https://learn.microsoft.com/cli/azure/install-azure-cli"

if ! az account show >/dev/null 2>&1; then
  echo "[1/6] Abrindo o login do Azure no navegador..."
  az login --only-show-errors >/dev/null || erro "Login no Azure nao concluido."
else
  echo "[1/6] Login do Azure ja ativo."
fi
echo "      Assinatura: $(az account show --query name -o tsv)"

# --- senhas ----------------------------------------------------------
gerar() {
  local n="$1" bruto=""
  if command -v openssl >/dev/null 2>&1; then
    bruto="$(openssl rand -base64 $((n * 4)) 2>/dev/null | LC_ALL=C tr -dc 'A-Za-z0-9')"
  fi
  if [ "${#bruto}" -lt "$n" ]; then
    bruto="$(dd if=/dev/urandom bs=1024 count=8 2>/dev/null | LC_ALL=C tr -dc 'A-Za-z0-9')"
  fi
  [ "${#bruto}" -ge "$n" ] || erro "Nao foi possivel gerar senha aleatoria nesta maquina."
  printf '%s' "${bruto:0:$n}"
}
SENHA_MQTT=""; SENHA_VM=""
if [ -f "$ARQ_CRED" ]; then
  SENHA_MQTT="$( (grep -m1 '^SENHA_MQTT=' "$ARQ_CRED" || true) | cut -d= -f2- )"
  SENHA_VM="$( (grep -m1 '^SENHA_ADMIN_VM=' "$ARQ_CRED" || true) | cut -d= -f2- )"
fi
if [ -n "$SENHA_MQTT" ] && [ -n "$SENHA_VM" ]; then
  echo "[2/6] Reaproveitando senhas de $ARQ_CRED (execucao repetida)."
else
  echo "[2/6] Gerando senhas exclusivas deste laboratorio."
  SENHA_MQTT="$(gerar 20)"
  SENHA_VM="Tim2026!$(gerar 16)"
fi
[ -n "$SENHA_MQTT" ] && [ -n "$SENHA_VM" ] || erro "Nao foi possivel definir as senhas."

# --- listas de tentativa ---------------------------------------------
lista() { printf '%s' "$1" | tr ',' ' ' | tr -s ' '; }
REGIOES="$(lista "$REGIAO $REGIOES_ALTERNATIVAS")"
TAMANHOS="$(lista "$TAMANHO_VM $TAMANHOS_ALTERNATIVOS")"

# Pergunta a propria Azure se o tamanho e oferecido e liberado na regiao.
sku_liberado() {
  local reg="$1" tam="$2" r
  r="$(az vm list-skus -l "$reg" --size "$tam" --resource-type virtualMachines \
        --query "[?name=='$tam'] | [0].restrictions" -o json --only-show-errors 2>/dev/null || true)"
  [ -n "$r" ] && [ "$r" != "null" ] || return 1     # nao oferecido na regiao
  case "$r" in *'"Location"'*|*'NotAvailableForSubscription'*) return 1;; esac
  return 0
}

# Cota regional de vCPUs. Nao bloqueia se nao for possivel ler.
cota_ok() {
  local reg="$1" atual limite
  atual="$(az vm list-usage -l "$reg" --query "[?contains(localName,'Total Regional vCPUs')] | [0].currentValue" -o tsv --only-show-errors 2>/dev/null || true)"
  limite="$(az vm list-usage -l "$reg" --query "[?contains(localName,'Total Regional vCPUs')] | [0].limit" -o tsv --only-show-errors 2>/dev/null || true)"
  case "$atual$limite" in ''|*[!0-9]*) return 0;; esac
  [ "$((limite - atual))" -ge 2 ]
}

# Reconhece as falhas tipicas de falta de capacidade ou cota na regiao.
falha_de_capacidade() {
  grep -qiE 'SkuNotAvailable|NotAvailableForSubscription|AllocationFailed|ZonalAllocationFailed|OverconstrainedAllocation|InsufficientCapacity|QuotaExceeded|OperationNotAllowed|ExceedingQuota|out of capacity|currently unavailable' "$1"
}

echo "[3/6] Escolhendo regiao e tamanho com capacidade disponivel..."
REG_ESCOLHIDA=""; TAM_ESCOLHIDO=""
for reg in $REGIOES; do
  if ! cota_ok "$reg"; then
    echo "      $reg: cota regional de vCPUs esgotada nesta assinatura; proxima regiao."
    continue
  fi
  for tam in $TAMANHOS; do
    if sku_liberado "$reg" "$tam"; then
      REG_ESCOLHIDA="$reg"; TAM_ESCOLHIDO="$tam"
      echo "      disponivel: $tam em $reg"
      break
    fi
    echo "      $tam nao disponivel em $reg"
  done
  [ -n "$REG_ESCOLHIDA" ] && break
done
if [ -z "$REG_ESCOLHIDA" ]; then
  linha
  echo " Nenhuma combinacao de regiao e tamanho esta disponivel para esta assinatura."
  echo " Isso costuma acontecer quando muitas pessoas criam VMs na mesma regiao"
  echo " ao mesmo tempo, ou quando a cota da assinatura ja esta tomada."
  echo
  echo " O que fazer:"
  echo "  1. Edite config.env e acrescente outras regioes em REGIOES_ALTERNATIVAS."
  echo "     Lista de regioes:   az account list-locations -o table"
  echo "  2. Confira a cota:     az vm list-usage -l $REGIAO -o table"
  echo "  3. Veja se o tamanho e oferecido na regiao:"
  echo "     az vm list-skus -l $REGIAO --size $TAMANHO_VM --resource-type virtualMachines -o table"
  echo "  4. Se a turma inteira estiver criando agora, espalhe as equipes por"
  echo "     regioes diferentes no config.env."
  linha
  erro "Sem capacidade nas regioes configuradas."
fi

echo "[4/6] Criando o grupo de recursos em $REG_ESCOLHIDA..."
az group create -n "$GRUPO" -l "$REG_ESCOLHIDA" --only-show-errors -o none \
  || erro "Falha ao criar o grupo de recursos. Confira permissoes da assinatura."

# --- implantacao, com troca automatica em caso de falta de capacidade --
echo "[5/6] Implantando VM + Mosquitto (leva de 3 a 6 minutos)..."
LOG_ERR="$(mktemp 2>/dev/null || echo /tmp/tim2026-deploy.err)"
IMPLANTOU=0
TENTADOS=""
for reg in $REG_ESCOLHIDA $REGIOES; do
  for tam in $TAM_ESCOLHIDO $TAMANHOS; do
    case " $TENTADOS " in *" $reg/$tam "*) continue;; esac
    TENTADOS="$TENTADOS $reg/$tam"
    printf '      tentando %s em %s... ' "$tam" "$reg"
    if az deployment group create \
        -g "$GRUPO" -n "tim2026-mqtt" -f main.bicep \
        -p senhaMqtt="$SENHA_MQTT" senhaAdminVm="$SENHA_VM" \
           origemPermitida="$ORIGEM" tamanhoVm="$tam" local="$reg" \
           abrirPorta1883="$ABRIR_1883" \
        --only-show-errors -o none 2>"$LOG_ERR"; then
      echo "ok"
      IMPLANTOU=1; REG_ESCOLHIDA="$reg"; TAM_ESCOLHIDO="$tam"
      break
    fi
    echo "falhou"
    if falha_de_capacidade "$LOG_ERR"; then
      echo "      -> a Azure recusou por falta de capacidade ou cota em $reg."
      echo "         Isso e comum quando muita gente cria VM na mesma regiao."
      continue
    fi
    # Qualquer outro erro nao se resolve trocando de regiao.
    echo
    sed 's/^/      /' "$LOG_ERR" | head -20
    erro "Falha na implantacao por um motivo que nao e capacidade. Mensagem acima."
  done
  [ "$IMPLANTOU" -eq 1 ] && break
done
if [ "$IMPLANTOU" -ne 1 ]; then
  linha
  echo " Todas as combinacoes de regiao e tamanho foram recusadas por capacidade ou cota."
  echo " Ultima mensagem da Azure:"
  sed 's/^/   /' "$LOG_ERR" | head -20
  echo
  echo " O que fazer: acrescente regioes em REGIOES_ALTERNATIVAS no config.env,"
  echo " tente mais tarde, ou distribua as equipes por regioes diferentes."
  echo " Regioes disponiveis: az account list-locations -o table"
  linha
  erro "Sem capacidade para criar a VM agora."
fi
[ "$TAM_ESCOLHIDO" = "$TAMANHO_VM" ] || echo "      [aviso] tamanho usado: $TAM_ESCOLHIDO (o preferido nao estava disponivel)"
[ "$REG_ESCOLHIDA" = "$REGIAO" ] || echo "      [aviso] regiao usada: $REG_ESCOLHIDA (a preferida nao tinha capacidade)"

ler() {
  az deployment group show -g "$GRUPO" -n "tim2026-mqtt" \
    --query "properties.outputs.$1.value" -o tsv --only-show-errors
}
NOME_VM="$(ler nomeDaVm)"; IP="$(ler ipPublicoDaVm)"; DNS="$(ler enderecoDns)"
WS="$(ler urlWebSocketNodeRed)"; USUARIO_MQTT="$(ler usuarioMqttCriado)"
[ -n "$NOME_VM" ] && [ -n "$WS" ] || erro "A implantacao terminou, mas as saidas nao foram lidas. Rode: az deployment group show -g $GRUPO -n tim2026-mqtt --query properties.outputs"

echo "[6/6] Aguardando o Mosquitto terminar a configuracao na VM..."
PRONTO="nao"
for i in $(seq 1 12); do
  RES="$(az vm run-command invoke -g "$GRUPO" -n "$NOME_VM" \
          --command-id RunShellScript \
          --scripts "grep -c TIM2026_SETUP_OK /var/log/tim2026-setup.log 2>/dev/null || echo 0" \
          --query 'value[0].message' -o tsv 2>/dev/null || true)"
  if printf '%s' "$RES" | grep -qE '(^|[^0-9])[1-9][0-9]*([^0-9]|$)'; then PRONTO="sim"; break; fi
  printf '      tentativa %s/12 - ainda instalando...\n' "$i"
  sleep 25
done

cat > "$ARQ_CRED" <<CRED
# TIM_2026 - credenciais do laboratorio MQTT - equipe $EQUIPE
# NAO versionar e NAO compartilhar. Senhas temporarias, apenas para a aula.
GRUPO_RECURSOS=$GRUPO
REGIAO_USADA=$REG_ESCOLHIDA
TAMANHO_VM_USADO=$TAM_ESCOLHIDO
NOME_VM=$NOME_VM
IP_PUBLICO=$IP
DNS=$DNS
URL_WEBSOCKET_NODE_RED=$WS
USUARIO_MQTT=$USUARIO_MQTT
SENHA_MQTT=$SENHA_MQTT
SENHA_ADMIN_VM=$SENHA_VM
TOPICO=senai/tim2026/$EQUIPE/medicoes
CRED
chmod 600 "$ARQ_CRED"

linha
if [ "$PRONTO" = "sim" ]; then
  echo " BROKER PRONTO"
else
  echo " VM CRIADA - a configuracao do broker ainda nao confirmou."
  echo " Aguarde 1 minuto e rode: ./2-verificar-broker.sh $EQUIPE"
fi
linha
echo " Configure o no 'mqtt out' do Node-RED assim:"
echo
echo "   Server ......: $WS"
echo "   TLS .........: desmarcado"
echo "   Protocolo ...: MQTT 3.1.1"
echo "   Usuario .....: $USUARIO_MQTT"
echo "   Senha .......: $SENHA_MQTT"
echo "   Topic .......: (vazio - vem do msg.topic)"
echo "   QoS .........: 1      Retain: desmarcado"
echo
echo " No .env do Node-RED:  MQTT_TEAM=$EQUIPE"
echo " Topico publicado...:  senai/tim2026/$EQUIPE/medicoes"
echo " VM .................: $TAM_ESCOLHIDO em $REG_ESCOLHIDA"
echo
echo " Credenciais salvas em: $ARQ_CRED"
echo " Monitorar mensagens..: abra monitor.html no navegador"
echo " Conferir pela Azure..: ./2-verificar-broker.sh $EQUIPE"
echo " Apagar tudo no fim...: ./3-apagar-tudo.sh $EQUIPE"
linha
