# =====================================================================
#  TIM_2026 - Aula 1 - Passo 4 (Windows): reparar o broker existente
#  Uso:  .\4-reparar-broker.ps1 equipe01
# =====================================================================
param([string]$Equipe = "equipe01")
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
$ArqCred = "credenciais-$Equipe.txt"
if (-not (Test-Path $ArqCred)) { throw "$ArqCred nao encontrado." }
if (-not (Test-Path "reparo-remoto.sh")) { throw "reparo-remoto.sh nao encontrado nesta pasta." }
$m = @{}; Get-Content $ArqCred | ForEach-Object { if ($_ -match '^([A-Z_]+)=(.*)$') { $m[$Matches[1]] = $Matches[2] } }

"----------------------------------------------------------"
" Reparando o broker da equipe $Equipe"
" VM: $($m['NOME_VM'])   grupo: $($m['GRUPO_RECURSOS'])"
" Isso leva cerca de 1 minuto."
"----------------------------------------------------------"
$saida = az vm run-command invoke -g $m['GRUPO_RECURSOS'] -n $m['NOME_VM'] `
  --command-id RunShellScript --scripts "@reparo-remoto.sh" `
  --query 'value[0].message' -o tsv 2>$null
if (-not $saida) {
  $conteudo = (Get-Content "reparo-remoto.sh" -Raw)
  $saida = az vm run-command invoke -g $m['GRUPO_RECURSOS'] -n $m['NOME_VM'] `
    --command-id RunShellScript --scripts $conteudo `
    --query 'value[0].message' -o tsv
}
if (-not $saida) { throw "Nao foi possivel executar o reparo na VM. A VM esta ligada?" }
$saida -split "`n" | Where-Object { $_ -notmatch '^\[std(out|err)\]$' }
"----------------------------------------------------------"
" Se o resultado foi BROKER ATIVO, teste agora:"
"   .\2-verificar-broker.ps1 $Equipe 30"
"   ou abra monitor.html com a URL $($m['URL_WEBSOCKET_NODE_RED'])"
"----------------------------------------------------------"
