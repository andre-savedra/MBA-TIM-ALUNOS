# =====================================================================
#  TIM_2026 - Aula 1 - Passo 1 (Windows): criar o broker MQTT na Azure
#  Uso:  .\1-criar-broker.ps1 equipe01
#  Ajustes de regiao, tamanho da VM e rede: arquivo config.env
# =====================================================================
param(
  [string]$Equipe = "equipe01",
  [string]$Regiao = "",
  [string]$Origem = "",
  [string]$TamanhoVm = "",
  [string]$Grupo  = ""
)
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
function Linha { "----------------------------------------------------------" }

# --- configuracao ----------------------------------------------------
$cfg = @{
  REGIAO = "brazilsouth"; REGIOES_ALTERNATIVAS = ""
  TAMANHO_VM = "Standard_B1s"; TAMANHOS_ALTERNATIVOS = ""
  ORIGEM = "Internet"; ABRIR_1883 = "true"; PREFIXO_GRUPO = "mqtt-lab-rg"
}
if (Test-Path "config.env") {
  Get-Content "config.env" | ForEach-Object {
    if ($_ -match '^\s*([A-Z_0-9]+)\s*=\s*(.*?)\s*$' -and $cfg.ContainsKey($Matches[1])) {
      $cfg[$Matches[1]] = $Matches[2].Trim('"')
    }
  }
} else { "[aviso] config.env nao encontrado; usando os valores padrao." }

if ($Regiao -ne "")    { $cfg.REGIAO = $Regiao }
if ($Origem -ne "")    { $cfg.ORIGEM = $Origem }
if ($TamanhoVm -ne "") { $cfg.TAMANHO_VM = $TamanhoVm }
if ($Grupo -eq "")     { $Grupo = "$($cfg.PREFIXO_GRUPO)-$Equipe" }
$ArqCred = "credenciais-$Equipe.txt"

if ($Equipe -notmatch '^[a-zA-Z0-9_-]+$') { throw "Equipe invalida: use letras, numeros, _ ou -" }

# --- guarda de custo -------------------------------------------------
$Economicos = @("Standard_B1ls","Standard_B1s","Standard_B1ms","Standard_B2ts_v2","Standard_B2ls_v2","Standard_B2s")
if ($Economicos -notcontains $cfg.TAMANHO_VM) {
  Linha
  " ATENCAO: $($cfg.TAMANHO_VM) nao esta na lista de tamanhos economicos."
  " Tamanhos sugeridos para o broker: $($Economicos -join ', ')"
  " Uma VM maior pode custar varias vezes mais por hora ligada."
  $ok = Read-Host " Digite CONTINUAR para usar $($cfg.TAMANHO_VM) mesmo assim"
  if ($ok -ne "CONTINUAR") { throw "Cancelado. Ajuste TAMANHO_VM no config.env." }
}

Linha
"  TIM_2026 - criando broker MQTT na Azure"
"  Equipe .........: $Equipe"
"  Grupo recursos .: $Grupo"
"  Regiao preferida: $($cfg.REGIAO)"
"  Tamanho da VM ..: $($cfg.TAMANHO_VM)"
"  Origem liberada : $($cfg.ORIGEM)"
Linha

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
  throw "Azure CLI nao encontrada. Instale em https://learn.microsoft.com/cli/azure/install-azure-cli"
}
az account show 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { "[1/6] Abrindo o login do Azure..."; az login --only-show-errors | Out-Null }
else { "[1/6] Login do Azure ja ativo." }
"      Assinatura: $(az account show --query name -o tsv)"

# --- senhas ----------------------------------------------------------
function Gerar([int]$n) {
  $c = [char[]]('abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789')
  -join (1..$n | ForEach-Object { $c | Get-Random })
}
$SenhaMqtt = ""; $SenhaVm = ""
if (Test-Path $ArqCred) {
  $map = @{}; Get-Content $ArqCred | ForEach-Object { if ($_ -match '^([A-Z_]+)=(.*)$') { $map[$Matches[1]] = $Matches[2] } }
  $SenhaMqtt = $map['SENHA_MQTT']; $SenhaVm = $map['SENHA_ADMIN_VM']
}
if ($SenhaMqtt -and $SenhaVm) { "[2/6] Reaproveitando senhas de $ArqCred (execucao repetida)." }
else {
  "[2/6] Gerando senhas exclusivas deste laboratorio."
  $SenhaMqtt = Gerar 20
  $SenhaVm = "Tim2026!" + (Gerar 16)
}

# --- listas de tentativa ---------------------------------------------
function Lista($a, $b) {
  (@($a) + ($b -split ',')) | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" } | Select-Object -Unique
}
$Regioes  = Lista $cfg.REGIAO $cfg.REGIOES_ALTERNATIVAS
$Tamanhos = Lista $cfg.TAMANHO_VM $cfg.TAMANHOS_ALTERNATIVOS

function SkuLiberado($reg, $tam) {
  $r = az vm list-skus -l $reg --size $tam --resource-type virtualMachines `
        --query "[?name=='$tam'] | [0].restrictions" -o json --only-show-errors 2>$null
  if (-not $r -or $r -eq "null") { return $false }
  if ($r -match '"Location"' -or $r -match 'NotAvailableForSubscription') { return $false }
  return $true
}
function CotaOk($reg) {
  $a = az vm list-usage -l $reg --query "[?contains(localName,'Total Regional vCPUs')] | [0].currentValue" -o tsv --only-show-errors 2>$null
  $l = az vm list-usage -l $reg --query "[?contains(localName,'Total Regional vCPUs')] | [0].limit" -o tsv --only-show-errors 2>$null
  if (-not ($a -match '^\d+$') -or -not ($l -match '^\d+$')) { return $true }
  return (([int]$l - [int]$a) -ge 2)
}
function FalhaDeCapacidade($txt) {
  return ($txt -match 'SkuNotAvailable|NotAvailableForSubscription|AllocationFailed|ZonalAllocationFailed|OverconstrainedAllocation|InsufficientCapacity|QuotaExceeded|OperationNotAllowed|ExceedingQuota|out of capacity|currently unavailable')
}

"[3/6] Escolhendo regiao e tamanho com capacidade disponivel..."
$RegEscolhida = ""; $TamEscolhido = ""
foreach ($reg in $Regioes) {
  if (-not (CotaOk $reg)) { "      ${reg}: cota regional de vCPUs esgotada nesta assinatura; proxima regiao."; continue }
  foreach ($tam in $Tamanhos) {
    if (SkuLiberado $reg $tam) { $RegEscolhida = $reg; $TamEscolhido = $tam; "      disponivel: $tam em $reg"; break }
    "      $tam nao disponivel em $reg"
  }
  if ($RegEscolhida -ne "") { break }
}
if ($RegEscolhida -eq "") {
  Linha
  " Nenhuma combinacao de regiao e tamanho esta disponivel para esta assinatura."
  " Isso costuma acontecer quando muitas pessoas criam VMs na mesma regiao ao"
  " mesmo tempo, ou quando a cota da assinatura ja esta tomada."
  ""
  " O que fazer:"
  "  1. Edite config.env e acrescente outras regioes em REGIOES_ALTERNATIVAS."
  "     Lista de regioes:   az account list-locations -o table"
  "  2. Confira a cota:     az vm list-usage -l $($cfg.REGIAO) -o table"
  "  3. Veja se o tamanho e oferecido na regiao:"
  "     az vm list-skus -l $($cfg.REGIAO) --size $($cfg.TAMANHO_VM) --resource-type virtualMachines -o table"
  "  4. Se a turma inteira estiver criando agora, espalhe as equipes por regioes diferentes."
  Linha
  throw "Sem capacidade nas regioes configuradas."
}

"[4/6] Criando o grupo de recursos em $RegEscolhida..."
az group create -n $Grupo -l $RegEscolhida --only-show-errors -o none
if ($LASTEXITCODE -ne 0) { throw "Falha ao criar o grupo de recursos. Confira permissoes da assinatura." }

"[5/6] Implantando VM + Mosquitto (leva de 3 a 6 minutos)..."
$implantou = $false; $tentados = @(); $ultimoErro = ""
foreach ($reg in (@($RegEscolhida) + $Regioes | Select-Object -Unique)) {
  foreach ($tam in (@($TamEscolhido) + $Tamanhos | Select-Object -Unique)) {
    if ($tentados -contains "$reg/$tam") { continue }
    $tentados += "$reg/$tam"
    Write-Host "      tentando $tam em $reg... " -NoNewline
    $saida = az deployment group create -g $Grupo -n "tim2026-mqtt" -f main.bicep `
      -p senhaMqtt=$SenhaMqtt senhaAdminVm=$SenhaVm origemPermitida=$($cfg.ORIGEM) `
         tamanhoVm=$tam local=$reg abrirPorta1883=$($cfg.ABRIR_1883) `
      --only-show-errors -o none 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0) {
      "ok"; $implantou = $true; $RegEscolhida = $reg; $TamEscolhido = $tam; break
    }
    "falhou"; $ultimoErro = $saida
    if (FalhaDeCapacidade $saida) {
      "      -> a Azure recusou por falta de capacidade ou cota em $reg."
      "         Isso e comum quando muita gente cria VM na mesma regiao."
      continue
    }
    ""
    ($saida -split "`n" | Select-Object -First 20) | ForEach-Object { "      $_" }
    throw "Falha na implantacao por um motivo que nao e capacidade. Mensagem acima."
  }
  if ($implantou) { break }
}
if (-not $implantou) {
  Linha
  " Todas as combinacoes de regiao e tamanho foram recusadas por capacidade ou cota."
  " Ultima mensagem da Azure:"
  ($ultimoErro -split "`n" | Select-Object -First 20) | ForEach-Object { "   $_" }
  ""
  " O que fazer: acrescente regioes em REGIOES_ALTERNATIVAS no config.env,"
  " tente mais tarde, ou distribua as equipes por regioes diferentes."
  " Regioes disponiveis: az account list-locations -o table"
  Linha
  throw "Sem capacidade para criar a VM agora."
}
if ($TamEscolhido -ne $cfg.TAMANHO_VM) { "      [aviso] tamanho usado: $TamEscolhido (o preferido nao estava disponivel)" }
if ($RegEscolhida -ne $cfg.REGIAO)     { "      [aviso] regiao usada: $RegEscolhida (a preferida nao tinha capacidade)" }

function Ler($n) { az deployment group show -g $Grupo -n "tim2026-mqtt" --query "properties.outputs.$n.value" -o tsv --only-show-errors }
$NomeVm = Ler "nomeDaVm"; $Ip = Ler "ipPublicoDaVm"; $Dns = Ler "enderecoDns"
$Ws = Ler "urlWebSocketNodeRed"; $UsrMqtt = Ler "usuarioMqttCriado"
if (-not $NomeVm -or -not $Ws) { throw "A implantacao terminou, mas as saidas nao foram lidas. Rode: az deployment group show -g $Grupo -n tim2026-mqtt --query properties.outputs" }

"[6/6] Aguardando o Mosquitto terminar a configuracao na VM..."
$pronto = $false
foreach ($i in 1..12) {
  $r = az vm run-command invoke -g $Grupo -n $NomeVm --command-id RunShellScript `
        --scripts "grep -c TIM2026_SETUP_OK /var/log/tim2026-setup.log 2>/dev/null || echo 0" `
        --query 'value[0].message' -o tsv 2>$null
  if ($r -match '[1-9]') { $pronto = $true; break }
  "      tentativa $i/12 - ainda instalando..."
  Start-Sleep -Seconds 25
}

@"
# TIM_2026 - credenciais do laboratorio MQTT - equipe $Equipe
# NAO versionar e NAO compartilhar. Senhas temporarias, apenas para a aula.
GRUPO_RECURSOS=$Grupo
REGIAO_USADA=$RegEscolhida
TAMANHO_VM_USADO=$TamEscolhido
NOME_VM=$NomeVm
IP_PUBLICO=$Ip
DNS=$Dns
URL_WEBSOCKET_NODE_RED=$Ws
USUARIO_MQTT=$UsrMqtt
SENHA_MQTT=$SenhaMqtt
SENHA_ADMIN_VM=$SenhaVm
TOPICO=senai/tim2026/$Equipe/medicoes
"@ | Set-Content -Encoding UTF8 $ArqCred

Linha
if ($pronto) { "  BROKER PRONTO" } else { "  VM CRIADA - configuracao ainda nao confirmou. Rode: .\2-verificar-broker.ps1 $Equipe" }
Linha
"  Configure o no 'mqtt out' do Node-RED assim:"
""
"    Server ......: $Ws"
"    TLS .........: desmarcado"
"    Protocolo ...: MQTT 3.1.1"
"    Usuario .....: $UsrMqtt"
"    Senha .......: $SenhaMqtt"
"    Topic .......: (vazio - vem do msg.topic)"
"    QoS .........: 1      Retain: desmarcado"
""
"  No .env do Node-RED:  MQTT_TEAM=$Equipe"
"  Topico publicado...:  senai/tim2026/$Equipe/medicoes"
"  VM .................: $TamEscolhido em $RegEscolhida"
""
"  Credenciais salvas em: $ArqCred"
"  Monitorar mensagens..: abra monitor.html no navegador"
"  Conferir pela Azure..: .\2-verificar-broker.ps1 $Equipe"
"  Apagar tudo no fim...: .\3-apagar-tudo.ps1 $Equipe"
Linha
