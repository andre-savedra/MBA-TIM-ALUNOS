// =====================================================================
//  TIM_2026 - Aula 1 - Laboratorio MQTT na Azure
//  Cria: NSG + IP publico + VNet + NIC + VM Ubuntu 24.04 com Mosquitto
//  ja configurado em DOIS listeners:
//     - TCP 1883            (MQTT nativo, uso interno / conferencia)
//     - WebSocket porta 80  (publicacao do Node-RED do SENAI)
//  Nao abre a porta 22: a administracao e feita por HTTPS
//  (az vm run-command), porque a rede da escola bloqueia SSH.
// =====================================================================

@description('Regiao do Azure. Padrao: a regiao do grupo de recursos.')
param local string = resourceGroup().location

@description('Prefixo dos nomes dos recursos.')
param prefixo string = 'mqtt-lab'

@description('Tamanho da VM. B1s e suficiente para o laboratorio.')
param tamanhoVm string = 'Standard_B1s'

@description('Usuario administrador do Linux.')
param usuarioAdminVm string = 'azureuser'

@description('Senha do administrador do Linux. Nao ha porta SSH aberta; serve apenas como credencial exigida pelo Azure.')
@secure()
@minLength(12)
param senhaAdminVm string

@description('Usuario MQTT usado pela turma.')
param usuarioMqtt string = 'turma'

@description('Senha do usuario MQTT. Use apenas letras e numeros.')
@secure()
@minLength(8)
param senhaMqtt string

@description('Origem autorizada nas regras de entrada. Use o IP publico de saida do SENAI em CIDR (ex.: 200.1.2.3/32). "Internet" libera para qualquer origem, protegido apenas por usuario e senha.')
param origemPermitida string = 'Internet'

@description('Abrir tambem a porta 1883 (MQTT/TCP) para a origem autorizada. A pratica do SENAI nao depende disso: o Node-RED usa WebSocket na porta 80.')
param abrirPorta1883 bool = true

@description('Abrir a porta 22 (SSH) para a origem autorizada. Mantenha false: a escola bloqueia SSH e a administracao e feita por az vm run-command.')
param abrirSsh bool = false

@description('Rotulo DNS do IP publico. Precisa ser unico na regiao.')
param rotuloDns string = toLower('${prefixo}-${uniqueString(resourceGroup().id)}')

var nomeVm = '${prefixo}-broker'
var nomeVnet = '${prefixo}-vnet'
var nomeSubnet = 'default'
var nomeNsg = '${prefixo}-nsg'
var nomeIp = '${prefixo}-ip'
var nomeNic = '${prefixo}-nic'
var topicoBase = 'senai/tim2026'

// ---------------------------------------------------------------------
//  cloud-init: instala e configura o Mosquitto na primeira inicializacao
// ---------------------------------------------------------------------
var cloudInitModelo = '''#cloud-config
package_update: true
packages:
  - mosquitto
  - mosquitto-clients
write_files:
  - path: /etc/mosquitto/conf.d/tim2026.conf
    permissions: '0644'
    owner: root:root
    content: |
      # Laboratorio TIM_2026 - dados sinteticos, sem TLS.
      # Listener MQTT nativo: conferencia dentro da VM e redes liberadas.
      listener 1883 0.0.0.0
      protocol mqtt

      # Listener MQTT sobre WebSocket: caminho usado pelo Node-RED do SENAI,
      # porque a rede da escola bloqueia a porta 1883 de saida.
      listener 80 0.0.0.0
      protocol websockets

      # Autenticacao e ACL valem para os dois listeners.
      allow_anonymous false
      password_file /etc/mosquitto/passwd
      acl_file /etc/mosquitto/acl

      # Registra conexoes e desconexoes no log, usado pelo passo 2.
      connection_messages true

      # NAO declarar persistence, persistence_location nem log_dest aqui:
      # o /etc/mosquitto/mosquitto.conf do Ubuntu ja as define, e o
      # Mosquitto 2.x aborta com "Duplicate <opcao> value in configuration".
  - path: /etc/mosquitto/acl
    permissions: '0640'
    owner: root:root
    content: |
      user __USUARIO_MQTT__
      topic readwrite __TOPICO_BASE__/#
  - path: /root/mqtt_pass
    permissions: '0600'
    owner: root:root
    content: '__SENHA_MQTT__'
  - path: /etc/systemd/system/mosquitto.service.d/10-porta80.conf
    permissions: '0644'
    owner: root:root
    content: |
      # O unit do Ubuntu inicia o Mosquitto como root, que abandona
      # privilegios sozinho; a porta 80 ja funciona assim. Esta capacidade
      # e apenas garantia caso um unit futuro passe a usar User=mosquitto.
      # NAO acrescentar CapabilityBoundingSet aqui: isso retiraria
      # CAP_SETUID/CAP_SETGID e o broker nao conseguiria mais trocar de
      # usuario, falhando na partida.
      [Service]
      AmbientCapabilities=CAP_NET_BIND_SERVICE
  - path: /etc/systemd/system/tim2026-setup.service
    permissions: '0644'
    owner: root:root
    content: |
      # Reaplica a configuracao do laboratorio apos cada reinicializacao da VM.
      [Unit]
      Description=Configuracao do broker MQTT do laboratorio TIM_2026
      After=network-online.target
      Wants=network-online.target
      [Service]
      Type=oneshot
      ExecStart=/opt/tim2026/setup.sh
      RemainAfterExit=yes
      [Install]
      WantedBy=multi-user.target
  - path: /opt/tim2026/setup.sh
    permissions: '0750'
    owner: root:root
    content: |
      #!/usr/bin/env bash
      # Configuracao do broker do laboratorio TIM_2026.
      # Idempotente: pode ser executado novamente por az vm run-command.
      set -uo pipefail
      LOG=/var/log/tim2026-setup.log
      exec >>"$LOG" 2>&1
      echo "=== setup $(date -Is) ==="
      USUARIO='__USUARIO_MQTT__'
      TOPICO='__TOPICO_BASE__'
      SENHA="$(tr -d '\r\n' < /root/mqtt_pass)"
      printf '%s' "$SENHA" > /root/mqtt_pass
      chmod 600 /root/mqtt_pass
      for i in $(seq 1 30); do
        command -v mosquitto_passwd >/dev/null 2>&1 && break
        echo "aguardando pacote mosquitto ($i)"; sleep 10
      done
      mosquitto_passwd -b -c /etc/mosquitto/passwd "$USUARIO" "$SENHA"
      chown root:mosquitto /etc/mosquitto/passwd /etc/mosquitto/acl
      chmod 640 /etc/mosquitto/passwd /etc/mosquitto/acl
      # Saneamento de VMs criadas com a versao anterior deste arquivo, que
      # continha CapabilityBoundingSet e impedia o broker de iniciar.
      if grep -q 'CapabilityBoundingSet' /etc/systemd/system/mosquitto.service.d/10-porta80.conf 2>/dev/null; then
        echo "corrigindo drop-in systemd herdado (CapabilityBoundingSet)"
        sed -i '/CapabilityBoundingSet/d' /etc/systemd/system/mosquitto.service.d/10-porta80.conf
      fi
      # O Mosquitto 2.x exige estes diretorios e falha na partida sem eles.
      install -d -m 740 -o mosquitto -g mosquitto /var/log/mosquitto /run/mosquitto /var/lib/mosquitto
      systemctl daemon-reload
      systemctl enable mosquitto
      systemctl enable tim2026-setup.service >/dev/null 2>&1
      systemctl restart mosquitto
      sleep 4
      echo "--- estado do servico ---"
      systemctl is-active mosquitto
      # Garantia do caminho WebSocket: se a porta 80 nao subir, o listener
      # passa para 8080 e o kernel redireciona 80 -> 8080. Para o Node-RED
      # e para o navegador o endereco continua sendo ws://<host>:80/mqtt.
      if ! ss -ltn | grep -qE ':80[[:space:]]'; then
        echo "porta 80 nao subiu; aplicando fallback 8080 + redirecionamento"
        sed -i 's/^listener 80 0.0.0.0$/listener 8080 0.0.0.0/' /etc/mosquitto/conf.d/tim2026.conf
        systemctl restart mosquitto
        sleep 3
        iptables -t nat -C PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 8080 2>/dev/null \
          || iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 8080
        echo "fallback aplicado: ws na 8080 com redirecionamento da 80"
      fi
      echo "--- portas em escuta ---"
      ss -ltn | grep -E ':(80|1883|8080)[[:space:]]' || echo "ATENCAO: nenhuma porta MQTT em escuta"
      echo "--- redirecionamento NAT ---"
      iptables -t nat -S PREROUTING | grep 'dport 80' || echo "sem redirecionamento (porta 80 nativa)"
      echo "--- teste local de publicacao ---"
      mosquitto_pub -h 127.0.0.1 -p 1883 -u "$USUARIO" -P "$SENHA" \
        -t "$TOPICO/infra/pronto" -q 1 \
        -m '{"origem":"cloud-init","status":"broker pronto"}' && echo "publicacao local OK"
      if systemctl is-active --quiet mosquitto; then
        echo TIM2026_SETUP_OK
      else
        echo TIM2026_SETUP_FALHOU
        echo "--- journal ---"
        journalctl -u mosquitto -n 40 --no-pager
        echo "--- teste de sintaxe da configuracao ---"
        mosquitto -c /etc/mosquitto/mosquitto.conf -v 2>&1 | head -20 &
        sleep 2; kill %1 2>/dev/null
        echo "--- drop-ins ativos ---"
        systemctl cat mosquitto --no-pager | tail -30
      fi
runcmd:
  - bash /opt/tim2026/setup.sh
'''

var cloudInit = replace(replace(replace(cloudInitModelo, '__SENHA_MQTT__', senhaMqtt), '__USUARIO_MQTT__', usuarioMqtt), '__TOPICO_BASE__', topicoBase)

// ---------------------------------------------------------------------
//  Rede
// ---------------------------------------------------------------------
resource nsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: nomeNsg
  location: local
  properties: {
    securityRules: concat(
      [
        {
          name: 'Allow-MQTT-WebSocket-80'
          properties: {
            description: 'MQTT sobre WebSocket - caminho usado pelo Node-RED do SENAI'
            priority: 1000
            direction: 'Inbound'
            access: 'Allow'
            protocol: 'Tcp'
            sourceAddressPrefix: origemPermitida
            sourcePortRange: '*'
            destinationAddressPrefix: '*'
            destinationPortRange: '80'
          }
        }
      ],
      abrirPorta1883 ? [
        {
          name: 'Allow-MQTT-TCP-1883'
          properties: {
            description: 'MQTT nativo - opcional, costuma ser bloqueado na saida da escola'
            priority: 1010
            direction: 'Inbound'
            access: 'Allow'
            protocol: 'Tcp'
            sourceAddressPrefix: origemPermitida
            sourcePortRange: '*'
            destinationAddressPrefix: '*'
            destinationPortRange: '1883'
          }
        }
      ] : [],
      abrirSsh ? [
        {
          name: 'Allow-SSH-22'
          properties: {
            description: 'SSH - desativado por padrao; use az vm run-command'
            priority: 1020
            direction: 'Inbound'
            access: 'Allow'
            protocol: 'Tcp'
            sourceAddressPrefix: origemPermitida
            sourcePortRange: '*'
            destinationAddressPrefix: '*'
            destinationPortRange: '22'
          }
        }
      ] : []
    )
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: nomeVnet
  location: local
  properties: {
    addressSpace: { addressPrefixes: [ '10.20.0.0/16' ] }
    subnets: [
      {
        name: nomeSubnet
        properties: {
          addressPrefix: '10.20.1.0/24'
          networkSecurityGroup: { id: nsg.id }
        }
      }
    ]
  }
}

resource ipPublico 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: nomeIp
  location: local
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: { domainNameLabel: rotuloDns }
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: nomeNic
  location: local
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: { id: '${vnet.id}/subnets/${nomeSubnet}' }
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: { id: ipPublico.id }
        }
      }
    ]
    networkSecurityGroup: { id: nsg.id }
  }
}

// ---------------------------------------------------------------------
//  VM
// ---------------------------------------------------------------------
resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: nomeVm
  location: local
  properties: {
    hardwareProfile: { vmSize: tamanhoVm }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: 'server'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'StandardSSD_LRS' }
        deleteOption: 'Delete'
      }
    }
    osProfile: {
      computerName: nomeVm
      adminUsername: usuarioAdminVm
      adminPassword: senhaAdminVm
      customData: base64(cloudInit)
      linuxConfiguration: {
        disablePasswordAuthentication: false
        provisionVMAgent: true
        patchSettings: { patchMode: 'ImageDefault' }
      }
    }
    networkProfile: {
      networkInterfaces: [
        { id: nic.id, properties: { deleteOption: 'Delete' } }
      ]
    }
  }
}

// ---------------------------------------------------------------------
//  Saidas usadas pelos scripts e pelos alunos
// ---------------------------------------------------------------------
output nomeDaVm string = nomeVm
output ipPublicoDaVm string = ipPublico.properties.ipAddress
output enderecoDns string = ipPublico.properties.dnsSettings.fqdn
output urlWebSocketNodeRed string = 'ws://${ipPublico.properties.dnsSettings.fqdn}:80/mqtt'
output usuarioMqttCriado string = usuarioMqtt
output topicoBaseDaTurma string = '${topicoBase}/<equipe>/medicoes'
output origemAutorizada string = origemPermitida
