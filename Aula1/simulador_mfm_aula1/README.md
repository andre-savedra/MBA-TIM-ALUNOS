# Aula 1 — pacote dos alunos

**Simulador Exchange + Swagger + Node-RED inicialmente vazio.** Não contém fluxo resolvido, Functions de resposta nem painel pronto.

## Preparar e iniciar

Requisito: Node.js 22 ou 24 LTS com npm. Abra o terminal nesta pasta (onde está package.json).

```sh
npm ci
```

Copie `.env.example` para `.env`, mantendo os valores fictícios. No Windows, não salvar como `.env.txt`. A instalação exige Internet/cache; depois, a execução e o Swagger são locais.

Terminal 1:
```sh
npm start
```
Terminal 2, nesta mesma pasta:
```sh
npm run nodered
```

- Controle: <http://127.0.0.1:3000>
- Swagger: <http://127.0.0.1:3000/docs>
- Node red: <http://127.0.0.1:1880>
- `/pratica1-alt` dashboard.


1 - 
```javascript
// Publica somente o contrato interno; nunca headers ou token HTTP.
const p = msg.payload;
const valido = p && p.origin === "SIMULADOR_MFM" && p.mode === "simulado"
  && typeof p.sensor_id === "string" && Number.isFinite(p.value)
  && Number.isFinite(Date.parse(p.measured_at));
if (!valido) { node.warn("MQTT: medicao fora do contrato didatico; nada publicado"); return null; }
const team = String(env.get("MQTT_TEAM") || "professor").trim();
if (!/^[a-zA-Z0-9_-]+$/.test(team)) { node.error("MQTT_TEAM: use letras, numeros, _ ou -"); return null; }
const record = {
  schema_version: "1.0", asset_id: p.asset_id, sensor_id: p.sensor_id,
  variable: p.variable, unit: p.unit, value: p.value,
  measured_at: p.measured_at, ingested_at: p.ingested_at || new Date().toISOString(),
  origin: p.origin, mode: p.mode, quality: p.quality || "formato_valido"
};
record.event_id = JSON.stringify([record.origin, record.asset_id, record.sensor_id, record.variable, record.measured_at]);
node.status({ fill: "green", shape: "dot", text: team + " | " + record.value + " " + record.unit });
return { topic: "senai/tim2026/" + team + "/medicoes", payload: JSON.stringify(record), qos: 1, retain: false };
```

## M5. Testar dentro da VM antes do Node-RED

Abrir dois terminais na VM. Em cada um, obter a senha sem escrevê-la no histórico do shell:

```sh
read -s -p 'Senha MQTT do laboratório: ' MQTT_LAB_PASSWORD
printf '\n'
```

Terminal A, manter assinando:

```sh
mosquitto_sub -h 127.0.0.1 -p 1883 -u turma -P "turma" -t 'senai/tim2026/#' -q 1 -v
```

Terminal B:

```sh
mosquitto_pub -h 127.0.0.1 -p 1883 -u turma -P "turma" -t 'senai/tim2026/teste' -q 1 -m '{"origem":"teste-local","value":35.5}'
unset MQTT_LAB_PASSWORD
```