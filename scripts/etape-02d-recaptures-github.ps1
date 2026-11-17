# scripts/etape-02d-recaptures-github.ps1
# Refait la capture du blocage de merge de la PR #1 (Edge doit etre connecte a GitHub)
# Lancement : powershell -ExecutionPolicy Bypass -File .\scripts\etape-02d-recaptures-github.ps1

$ErrorActionPreference = "Continue"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root
. "$Root\tools\capture.ps1"
$Repo = "https://github.com/YasmineZerai/tp2-devops-sre"

Write-Host "Recapture du blocage de merge (PR #1)..." -ForegroundColor Cyan
# "#:~:text=" : fragment de texte, Edge fait defiler la page jusqu'a la section "Merge info"
Save-BrowserCapture -Name "E2_26_pr_github_merge_bloque" -Url "$Repo/pull/1#:~:text=Some%20checks%20were%20not%20successful" -WaitSeconds 18
Write-Host ""
Write-Host "Recapture terminee. Dis a Claude 'fini'." -ForegroundColor Green
