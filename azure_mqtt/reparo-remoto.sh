#!/usr/bin/env bash
# Executado DENTRO da VM por az vm run-command (passo 4).
# Idempotente: corrige a causa conhecida, reinstala o que faltar e relata.
set -uo pipefail
echo "== TIM_2026 reparo do broker =="

DROPIN=/etc/systemd/system/mosquitto.service.d/10-porta80.conf

# 1) Causa conhecida: CapabilityBoundingSet no drop-in retirava CAP_SETUID/
#    CAP_SETGID. O Mosquitto inicia como root e precisa delas para trocar
#    para o usuario mosquitto; sem elas o servico morre na partida.
if grep -q 'CapabilityBoundingSet' "$DROPIN" 2>/dev/null; then
  echo "[1] drop-in com CapabilityBoundingSet encontrado -> removendo a linha"
  install -d -m 755 "$(dirname "$DROPIN")"
  printf '[Service]\nAmbientCapabilities=CAP_NET_BIND_SERVICE\n' > "$DROPIN"
else
  echo "[1] drop-in ja esta correto"
fi

# 2) Pacote presente?
if ! command -v mosquitto >/dev/null 2>&1; then
  echo "[2] mosquitto ausente -> instalando"
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq mosquitto mosquitto-clients
else
  echo "[2] pacote presente: $(mosquitto -h 2>&1 | head -1)"
fi

# 3) Diretorios exigidos pelo Mosquitto 2.x
install -d -m 740 -o mosquitto -g mosquitto /var/log/mosquitto /run/mosquitto /var/lib/mosquitto
echo "[3] diretorios garantidos"

# 3b) Causa conhecida: opcoes repetidas. O /etc/mosquitto/mosquitto.conf do
#     Ubuntu ja define persistence, persistence_location e log_dest; repetir
#     qualquer uma faz o Mosquitto 2.x abortar com "Duplicate ... value".
#     A config do laboratorio e reescrita no formato minimo, preservando a
#     porta do listener WebSocket em uso (80 nativa ou 8080 do fallback).
CONF=/etc/mosquitto/conf.d/tim2026.conf
PORTA_WS=80
grep -q '^listener 8080 ' "$CONF" 2>/dev/null && PORTA_WS=8080
if [ -f "$CONF" ]; then
  cp -p "$CONF" "$CONF.antes-reparo" 2>/dev/null || true
fi
cat > "$CONF" <<CONFEOF
listener 1883 0.0.0.0
protocol mqtt

listener $PORTA_WS 0.0.0.0
protocol websockets

allow_anonymous false
password_file /etc/mosquitto/passwd
acl_file /etc/mosquitto/acl

connection_messages true
CONFEOF
chmod 644 "$CONF"
echo "[3b] config reescrita no formato minimo (websocket na $PORTA_WS)"

# 3c) Qualquer outro arquivo em conf.d que repita as mesmas opcoes.
for extra in /etc/mosquitto/conf.d/*.conf; do
  [ "$extra" = "$CONF" ] && continue
  [ -f "$extra" ] || continue
  if grep -qE '^[[:space:]]*(persistence|persistence_location|log_dest)[[:space:]]' "$extra"; then
    echo "[3c] removendo opcoes repetidas de $extra"
    sed -i -E '/^[[:space:]]*(persistence|persistence_location|log_dest)[[:space:]]/d' "$extra"
  fi
done

# 4) Senha e ACL
if [ ! -s /root/mqtt_pass ]; then
  echo "[4] FALTA /root/mqtt_pass - nao e possivel recriar a senha aqui."
else
  SENHA="$(tr -d '\r\n' < /root/mqtt_pass)"
  if [ ! -s /etc/mosquitto/passwd ]; then
    echo "[4] recriando /etc/mosquitto/passwd"
    mosquitto_passwd -b -c /etc/mosquitto/passwd turma "$SENHA"
  else
    echo "[4] arquivo de senhas presente"
  fi
  [ -s /etc/mosquitto/acl ] || printf 'user turma\ntopic readwrite senai/tim2026/#\n' > /etc/mosquitto/acl
  chown root:mosquitto /etc/mosquitto/passwd /etc/mosquitto/acl
  chmod 640 /etc/mosquitto/passwd /etc/mosquitto/acl
fi

# 5) Reiniciar
systemctl daemon-reload
systemctl enable mosquitto >/dev/null 2>&1
systemctl restart mosquitto
sleep 4
echo "[5] servico: $(systemctl is-active mosquitto)"

# 6) Porta 80: garantia por fallback
if ! ss -ltn | grep -qE ':80[[:space:]]'; then
  if grep -q '^listener 80 ' /etc/mosquitto/conf.d/tim2026.conf 2>/dev/null; then
    echo "[6] porta 80 nao subiu -> fallback 8080 + redirecionamento"
    sed -i 's/^listener 80 0.0.0.0$/listener 8080 0.0.0.0/' /etc/mosquitto/conf.d/tim2026.conf
    systemctl restart mosquitto; sleep 3
  fi
  iptables -t nat -C PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 8080 2>/dev/null \
    || iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 8080
fi
echo "[6] portas: $(ss -ltn | grep -oE ':(80|1883|8080) ' | tr -d ': ' | tr '\n' ' ')"

# 7) Prova local
if [ -s /root/mqtt_pass ]; then
  SENHA="$(tr -d '\r\n' < /root/mqtt_pass)"
  if mosquitto_pub -h 127.0.0.1 -p 1883 -u turma -P "$SENHA" \
       -t 'senai/tim2026/infra/reparo' -q 1 -m '{"origem":"reparo"}' 2>&1; then
    echo "[7] publicacao local OK"
  else
    echo "[7] publicacao local FALHOU"
  fi
fi

# 8) Veredito
if systemctl is-active --quiet mosquitto; then
  echo "RESULTADO: BROKER ATIVO"
  echo TIM2026_SETUP_OK >> /var/log/tim2026-setup.log
else
  echo "RESULTADO: BROKER AINDA FALHANDO"
  echo "--- validacao da configuracao ---"
  # A mensagem mais util vem do proprio broker lendo a config.
  timeout 5 mosquitto -c /etc/mosquitto/mosquitto.conf -v 2>&1 | grep -iE 'error|warning' | head -10
  echo "--- arquivos em conf.d ---"
  ls -1 /etc/mosquitto/conf.d/ 2>/dev/null
  echo "--- journal ---"
  journalctl -u mosquitto -n 15 --no-pager
  echo "--- unit efetivo ---"
  systemctl cat mosquitto --no-pager | grep -vE '^\s*#|^$' | tail -20
fi
