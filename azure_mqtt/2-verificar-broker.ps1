# =====================================================================
#  TIM_2026 - Aula 1 - Passo 2 (Windows): conferir o broker
#  Uso:  .\2-verificar-broker.ps1 equipe01 30
# =====================================================================
param([string]$Equipe = "equipe01", [int]$Segundos = 30)
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
$ArqCred = "credenciais-$Equipe.txt"
if (-not (Test-Path $ArqCred)) { throw "$ArqCred nao encontrado. Rode .\1-criar-broker.ps1 $Equipe" }
$m = @{}; Get-Content $ArqCred | ForEach-Object { if ($_ -match '^([A-Z_]+)=(.*)$') { $m[$Matches[1]] = $Matches[2] } }
function Rodar($s) {
  az vm run-command invoke -g $m['GRUPO_RECURSOS'] -n $m['NOME_VM'] --command-id RunShellScript `
    --scripts $s --query 'value[0].message' -o tsv 2>$null
}
"----------------------------------------------------------"
" Estado do broker - equipe $Equipe"
"----------------------------------------------------------"
Rodar 'echo "servico: $(systemctl is-active mosquitto)"; echo "--- portas ---"; ss -ltn | grep -E ":(80|1883)[[:space:]]" || echo "portas 80/1883 NAO estao em escuta"; echo "--- setup ---"; tail -n 8 /var/log/tim2026-setup.log 2>/dev/null'
"----------------------------------------------------------"
" Ouvindo senai/tim2026/# por $Segundos s. Dispare a coleta no Node-RED."
"----------------------------------------------------------"
Rodar "timeout $Segundos mosquitto_sub -h 127.0.0.1 -p 1883 -u '$($m['USUARIO_MQTT'])' -P `"`$(cat /root/mqtt_pass)`" -t 'senai/tim2026/#' -q 1 -v; echo '--- fim da escuta ---'"
"----------------------------------------------------------"
