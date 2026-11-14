# Laboratório MQTT na Azure — automação do Apêndice MQTT e do Apêndice B

Provisiona, com **um comando**, o broker Mosquitto na Azure já configurado como pedem o
`Apêndice MQTT — Node-RED → Mosquitto na Azure` e o `Apêndice B — MQTT sobre WebSocket na porta 80`
do `roteiro_pratica1_alternativo.md`.

O que o aluno **não** precisa mais fazer: criar VM pelo portal, abrir regra de NSG, entrar por SSH,
instalar Mosquitto, editar `public.conf`, rodar `mosquitto_passwd`, escrever a ACL, reiniciar o serviço.
Tudo isso acontece sozinho na primeira inicialização da VM.

## Particularidades da rede do SENAI já tratadas

| Bloqueio na escola | Como este pacote resolve |
|---|---|
| Saída TCP 1883 bloqueada | O broker nasce com **listener WebSocket na porta 80** (`ws://<host>:80/mqtt`), que é o endereço entregue ao aluno. O listener 1883 continua existindo, mas só para conferência interna. |
| SSH (porta 22) bloqueado | **Nenhuma porta 22 é aberta.** A administração e os testes usam `az vm run-command`, que trafega por HTTPS. Não há chave SSH para gerar, guardar ou distribuir. |
| Porta 80 privilegiada no Ubuntu | O Mosquitto 2.x abandona privilégios e pode falhar no bind da porta 80. O script instala a capacidade `CAP_NET_BIND_SERVICE` e, se ainda assim a porta não subir, **cai automaticamente** para um listener em 8080 com redirecionamento 80 → 8080. Para o aluno o endereço continua `:80`. |

## Arquivos

| Arquivo | Para quê |
|---|---|
| `config.env` | **Único arquivo a editar:** região, regiões alternativas, tamanho da VM, origem autorizada e prefixo do grupo. Lido pelos scripts nas três plataformas. |
| `main.bicep` | Infraestrutura como código: NSG, VNet, IP público com DNS, NIC, VM Ubuntu 24.04 e o cloud-init que instala e configura o Mosquitto. |
| `1-CRIAR-BROKER.cmd` | **Windows: duplo clique.** Pergunta a equipe e executa o passo 1 contornando a política de execução do Windows, sem alterar nada na máquina. Há equivalentes para os passos 2 e 3. |
| `1-criar-broker.sh` / `.ps1` | Cria tudo e imprime, no fim, exatamente os campos do nó `mqtt out`. |
| `2-verificar-broker.sh` / `.ps1` | Mostra serviço, portas em escuta e **escuta o tópico ao vivo**, sem SSH. |
| `3-apagar-tudo.sh` / `.ps1` | Apaga o grupo de recursos inteiro no fim da aula. |
| `4-reparar-broker.sh` / `.ps1` / `.cmd` | Conserta um broker que não subiu, **sem recriar a VM**: corrige as causas conhecidas, reinstala o que faltar e relata o estado. |
| `reparo-remoto.sh` | Script executado dentro da VM pelo passo 4. Não precisa ser aberto. |
| `monitor.html` | Assinante MQTT no navegador, pelo mesmo WebSocket 80. É a prova de que a mensagem atravessou a rede da escola. |
| `credenciais-<equipe>.txt` | Gerado na execução. Contém IP, URL, usuário e senhas. Não versionar (já está no `.gitignore`). |

## Pré-requisito único: Azure CLI

- Windows: `winget install Microsoft.AzureCLI`
- macOS: `brew install azure-cli`
- Linux: `curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash`

Não é preciso instalar Bicep à parte: a Azure CLI o baixa na primeira execução.

## Configuração — `config.env`

É o único arquivo que o professor costuma editar. Sem aspas nos valores.

| Chave | Para quê |
|---|---|
| `REGIAO` | Região preferida. Ver as disponíveis: `az account list-locations -o table`. |
| `REGIOES_ALTERNATIVAS` | Lista separada por vírgula, tentada em ordem quando a preferida está sem capacidade ou cota. |
| `TAMANHO_VM` | Tamanho da VM. Padrão `Standard_B1s`. |
| `TAMANHOS_ALTERNATIVOS` | Tamanhos tentados em ordem se o preferido faltar na região. |
| `ORIGEM` | Origem autorizada nas regras de entrada. `Internet` ou um CIDR como `200.1.2.3/32`. |
| `ABRIR_1883` | `true`/`false`. A prática usa WebSocket na 80; isso é só para redes sem bloqueio. |
| `PREFIXO_GRUPO` | Prefixo do grupo de recursos; o nome final fica `<prefixo>-<equipe>`. |

Variável de ambiente tem prioridade sobre o arquivo, útil para um caso isolado sem editar nada:

```sh
REGIAO=eastus2 ORIGEM=200.1.2.3/32 ./1-criar-broker.sh equipe01
```

### Custo da VM

O broker é leve e o padrão é o menor tamanho razoável. Referência com a VM ligada 24 h —
confirme no calculador oficial para a sua assinatura:

| Tamanho | Recursos | Ordem de grandeza / mês |
|---|---|---|
| `Standard_B1ls` | 1 vCPU · 0,5 GB | ~US$ 4 |
| `Standard_B1s` (padrão) | 1 vCPU · 1 GB | ~US$ 8 |
| `Standard_B2ts_v2` | 2 vCPU · 1 GB | ~US$ 9 |

Os scripts **recusam** qualquer tamanho fora da lista de econômicos e só prosseguem se alguém digitar
`CONTINUAR`, para que uma troca distraída no `config.env` não consuma a assinatura da turma. O custo
só cessa de fato com o passo 3: parar a VM mantém disco e IP sendo cobrados.

### Quando a região não tem capacidade

É o erro mais comum em turma, porque todos criam ao mesmo tempo na mesma região. Os scripts tratam
isso em três camadas, sem intervenção:

1. **Antes de criar**, perguntam à Azure se o tamanho é oferecido e liberado na região
   (`az vm list-skus`) e se ainda há cota regional de vCPUs (`az vm list-usage`).
2. **Durante a implantação**, reconhecem as falhas de capacidade — `SkuNotAvailable`,
   `AllocationFailed`, `ZonalAllocationFailed`, `QuotaExceeded`, `OverconstrainedAllocation` e
   afins — e passam sozinhos para a próxima combinação de região e tamanho.
3. **Se tudo falhar**, dizem exatamente o que ajustar, com os comandos de diagnóstico prontos.
   Erros que *não* são de capacidade (senha fora da política, permissão, template) interrompem na
   hora em vez de ficar tentando outras regiões.

A região e o tamanho efetivamente usados aparecem no fim da execução e ficam registrados em
`credenciais-<equipe>.txt`, nos campos `REGIAO_USADA` e `TAMANHO_VM_USADO`.

Dica de sala: se a turma é grande, distribua as equipes por regiões diferentes no `config.env` antes
da aula, em vez de deixar todos disputarem a mesma.

## Passo 1 — criar o broker

**Windows (máquina da escola) — duplo clique:** abra a pasta `azure_mqtt` e dê duplo clique em
**`1-CRIAR-BROKER.cmd`**. Ele pergunta o identificador da equipe e faz o resto. Não é preciso abrir
terminal nem mexer na política de execução do PowerShell: o atalho já a contorna apenas para esta
execução.

Se preferir o terminal:

```powershell
cd Aula1\azure_mqtt
powershell -ExecutionPolicy Bypass -File .\1-criar-broker.ps1 equipe01
```

**macOS/Linux:**

```sh
cd Aula1/azure_mqtt
chmod +x *.sh
./1-criar-broker.sh equipe01
```

O script abre o login do Azure no navegador, cria o grupo `mqtt-lab-rg-equipe01`, implanta a VM,
espera o broker ficar pronto e imprime o quadro de configuração. Leva de 4 a 8 minutos.
Rodar de novo com a mesma equipe é seguro: reaproveita as senhas e apenas reconcilia os recursos.

Cada equipe usa seu próprio identificador (`equipe01`, `equipe02`, …): grupo de recursos, VM e
tópico ficam separados.

### Restringir a origem (recomendado pelo roteiro)

Por padrão as regras aceitam qualquer origem, protegidas por usuário, senha e ACL. Com o IP público
de saída da escola em mãos, coloque-o em `ORIGEM` no `config.env` — vale para toda a turma de uma vez:

```
ORIGEM=200.1.2.3/32
```

## Passo 2 — configurar o Node-RED

O script imprime os valores; eles também ficam em `credenciais-<equipe>.txt`.

No nó **mqtt out** (`Azure MQTT — medições`):

| Campo | Valor |
|---|---|
| Server | `ws://<dns-da-vm>:80/mqtt` ← campo `URL_WEBSOCKET_NODE_RED` |
| Port | deixe como vier; a porta está na URL |
| TLS | desmarcado |
| Protocolo | MQTT 3.1.1 |
| Client ID | vazio |
| Security → usuário | `turma` |
| Security → senha | campo `SENHA_MQTT` |
| Topic | **vazio** (vem do `msg.topic`) |
| QoS / Retain | `1` / desmarcado |

No `.env` do simulador: `MQTT_TEAM=equipe01`, e reinicie o runtime (`npm run nodered`).
O tópico publicado fica `senai/tim2026/equipe01/medicoes`.

## Passo 3 — comprovar a entrega

Dois caminhos independentes, nenhum deles exigindo SSH.

**No navegador (o que comprova o trajeto pela rede da escola):** abra `monitor.html` com duplo clique,
cole a URL e a senha do arquivo de credenciais e clique em Conectar. Dispare **Coletar todos agora**
no Node-RED. A tela conta eventos distintos por `event_id` e marca repetições do QoS 1 — é a contagem
que o roteiro pede (12 no cenário normal, 11 na lacuna, 12 no duplicado).

**Pela Azure, assinando dentro da VM:** duplo clique em `2-VERIFICAR-BROKER.cmd` no Windows, ou:

```sh
./2-verificar-broker.sh equipe01 30
```

Ele imprime o estado do serviço, as portas em escuta e fica 30 segundos assinando `senai/tim2026/#`.
Dispare a coleta no Node-RED enquanto a escuta estiver aberta: *retain* está em `false`, então
assinante que chega depois não recebe histórico.

## Se o broker não subir — reparo sem recriar a VM

Sintoma: `Connection refused` ao usar `mosquitto_sub` dentro da VM, e o `monitor.html` não conecta.
Isso significa que o Mosquitto não está rodando — não é problema de rede, NSG ou senha.

```sh
./4-reparar-broker.sh equipe01
```

No Windows, duplo clique em `4-REPARAR-BROKER.cmd`. O reparo roda por HTTPS, sem SSH, e é seguro de
repetir. Ele verifica, nesta ordem: o drop-in do systemd, a presença do pacote, os diretórios que o
Mosquitto 2.x exige (`/var/log/mosquitto`, `/run/mosquitto`, `/var/lib/mosquitto`), os arquivos de
senha e ACL, e então reinicia e publica uma mensagem de teste. No fim imprime `BROKER ATIVO` ou o
trecho do journal com o motivo real da falha.

> Notas históricas, para quem for ler o código. Duas armadilhas reais, nesta ordem:
>
> 1. **Opções repetidas na configuração.** O `/etc/mosquitto/mosquitto.conf` do Ubuntu já define
>    `persistence`, `persistence_location` e `log_dest`. A config do laboratório também as declarava,
>    e o Mosquitto 2.x trata isso como **erro fatal** — `Duplicate persistence_location value in
>    configuration` — e se recusa a iniciar. Era esta a causa do `Connection refused`. A config em
>    `conf.d/` hoje declara apenas o que é específico do laboratório: listeners, autenticação e ACL.
> 2. **`CapabilityBoundingSet` no drop-in do systemd.** Posto para "liberar" a porta 80, ele
>    *restringe* o conjunto de capacidades. O unit do Ubuntu inicia o Mosquitto como **root**, que
>    abandona privilégios por conta própria — a porta 80 nunca precisou disso —, e sem
>    `CAP_SETUID`/`CAP_SETGID` o broker não conseguiria trocar de usuário. Era um problema latente,
>    não a causa observada. Hoje o drop-in tem apenas `AmbientCapabilities`.
>
> O passo 4 corrige as duas em VMs criadas com as versões antigas, e imprime a validação da
> configuração feita pelo próprio broker quando a falha for outra.

## Encerramento — apagar tudo no fim da aula

Duplo clique em `3-APAGAR-TUDO.cmd` no Windows, ou:

```sh
./3-apagar-tudo.sh equipe01
```

Pede a confirmação `APAGAR` e remove o grupo inteiro — VM, disco, IP e rede. Parar a VM não encerra a
cobrança de disco e IP; apagar o grupo encerra.

## Diagnóstico

| Sintoma | O que fazer |
|---|---|
| `Nó em connecting` no Node-RED | Confirme que o campo Server tem `ws://` e `/mqtt`. Rode o passo 2: se as portas estão em escuta, o problema está na saída da escola — teste o `monitor.html` na mesma máquina. |
| `Not authorized` | Senha copiada do arquivo errado de equipe, ou `Topic` preenchido com algo fora de `senai/tim2026/#` (a ACL só libera esse prefixo). |
| Script para em "ainda instalando" até a 12ª tentativa | A VM subiu, o cloud-init não concluiu. Espere um minuto e rode o passo 2; o rodapé mostra as últimas linhas de `/var/log/tim2026-setup.log`. |
| `az: command not found` | Azure CLI não instalada — veja os pré-requisitos. No Windows, feche e reabra o terminal depois de instalar. |
| Windows: *"não pode ser carregado porque a execução de scripts foi desabilitada"* | Use o atalho `1-CRIAR-BROKER.cmd` (duplo clique), que já contorna isso sem alterar a configuração da máquina. |
| `Connection refused` na porta 1883 dentro da VM | O broker não está rodando. Rode `./4-reparar-broker.sh <equipe>`. |
| Script para sem mensagem nenhuma | Não deve mais acontecer: há uma rede de segurança que relata qualquer falha inesperada. Se ocorrer, reexecute o mesmo comando — ele é seguro de repetir. |
| Erro de cota ou capacidade na região | Tratado sozinho: o script tenta as `REGIOES_ALTERNATIVAS` e os `TAMANHOS_ALTERNATIVOS` do `config.env`. Se esgotar, ele imprime os comandos de diagnóstico. |
| Navegador bloqueia o WebSocket | Abra `monitor.html` como arquivo local (`file://`), não servido por HTTPS: página HTTPS não abre conexão `ws://`. Proxy da escola pode barrar o cabeçalho `Upgrade`; nesse caso registre a pendência e use o passo 2. |
| Node-RED não muda de tópico | `.env` só é lido na partida do processo; Deploy sozinho não recarrega o ambiente. |

## Nota de segurança para a turma

Perfil didático, dados sintéticos: o tráfego na porta 80 **não é criptografado** e a senha é temporária
e exclusiva da aula. Para dados reais, o roteiro continua valendo — `wss`/TLS na 443 ou 8883 com
certificado confiável, usuário por cliente, ACLs individuais, persistência e backup. Não entregue
`credenciais-*.txt`, `.env` nem `flows_cred.json` junto com os fluxos exportados.
