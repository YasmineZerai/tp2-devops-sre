# scripts/etape-finale.ps1 - enchaine la fin de l'etape 3 (ArgoCD) puis les etapes 4 et 5
# Lancement : powershell -ExecutionPolicy Bypass -File .\scripts\etape-finale.ps1
$debut = Get-Date
powershell -ExecutionPolicy Bypass -File "$PSScriptRoot\etape-03b-argocd.ps1"
powershell -ExecutionPolicy Bypass -File "$PSScriptRoot\etape-04-05.ps1"
Write-Host ""
Write-Host ("TOUT EST TERMINE en {0:N0} minutes. Dis a Claude 'fini'." -f ((Get-Date) - $debut).TotalMinutes) -ForegroundColor Green
