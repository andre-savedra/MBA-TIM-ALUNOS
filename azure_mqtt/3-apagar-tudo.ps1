# =====================================================================
#  TIM_2026 - Aula 1 - Passo 3 (Windows): apagar todos os recursos
#  Uso:  .\3-apagar-tudo.ps1 equipe01
# =====================================================================
param([string]$Equipe = "equipe01", [string]$Grupo = "")
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
$ArqCred = "credenciais-$Equipe.txt"
if ($Grupo -eq "" -and (Test-Path $ArqCred)) {
  Get-Content $ArqCred | ForEach-Object { if ($_ -match '^GRUPO_RECURSOS=(.*)$') { $Grupo = $Matches[1] } }
}
if ($Grupo -eq "") {
  $pref = "mqtt-lab-rg"
  if (Test-Path "config.env") {
    Get-Content "config.env" | ForEach-Object { if ($_ -match '^\s*PREFIXO_GRUPO\s*=\s*(.*?)\s*$') { $pref = $Matches[1] } }
  }
  $Grupo = "$pref-$Equipe"
}
"Serao apagados TODOS os recursos do grupo: $Grupo"
az group show -n $Grupo -o none 2>$null
if ($LASTEXITCODE -ne 0) { "Grupo nao existe. Nada a fazer."; exit 0 }
az resource list -g $Grupo --query "[].{tipo:type,nome:name}" -o table
$r = Read-Host "Digite APAGAR para confirmar"
if ($r -ne "APAGAR") { "Cancelado."; exit 0 }
az group delete -n $Grupo --yes --no-wait --only-show-errors
"Exclusao iniciada em segundo plano. Cobranca cessa quando concluir."
