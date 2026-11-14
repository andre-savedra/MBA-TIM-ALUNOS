@echo off
rem Atalho de duplo clique - TIM_2026. Contorna a politica de execucao do
rem Windows, que bloqueia .ps1 por padrao, sem alterar nada na maquina.
setlocal
cd /d "%~dp0"
title TIM_2026 - reparar o broker MQTT existente
echo ==========================================================
echo  TIM_2026 - reparar o broker MQTT existente
echo ==========================================================
echo.
set "EQUIPE=%~1"
if "%EQUIPE%"=="" set /p EQUIPE=Identificador da equipe (ex.: equipe01): 
if "%EQUIPE%"=="" set "EQUIPE=equipe01"
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File ".\4-reparar-broker.ps1" -Equipe "%EQUIPE%"
echo.
echo ----------------------------------------------------------
echo Terminado. Anote os dados acima ou abra o arquivo
echo credenciais-%EQUIPE%.txt nesta mesma pasta.
pause
endlocal
