# scripts/reprise.ps1 - reprise apres la coupure du PC
# 1. Remet de l'ordre : le 20/11, kubectl pointait sur ton AUTRE cluster (tp3) au lieu de tp2.
#    On retire de tp3 uniquement ce que le TP2 y a installe ce jour-la, puis on arrete tp3
#    (pour liberer la memoire du PC). Rien d'autre n'est touche dans tp3.
# 2. Relance la fin de l'etape 3 puis les etapes 4 et 5 sur le BON cluster (tp2).
# Lancement : powershell -ExecutionPolicy Bypass -File .\scripts\reprise.ps1

$debut = Get-Date
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root
. "$Root\tools\capture.ps1"
if (-not (Start-DockerDesktop)) {
    Write-Host "ERREUR : Docker Desktop ne demarre pas. Ouvre-le a la main, attends qu'il soit vert, puis relance ce script." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "=== 1/3 Nettoyage du cluster tp3 (installations faites par erreur le 20/11) ===" -ForegroundColor Cyan
$clusters = (kind get clusters 2>$null) -join " "
if ($clusters -match "\btp3\b") {
    cmd /c "docker start tp3-control-plane >NUL 2>&1"
    for ($i = 0; $i -lt 24; $i++) {
        cmd /c "kubectl --context kind-tp3 get nodes >NUL 2>&1"
        if ($LASTEXITCODE -eq 0) { break }
        Start-Sleep -Seconds 5
    }
    $releases = @(
        @{ Name = "alloy"; Ns = "monitoring" }, @{ Name = "tempo"; Ns = "monitoring" },
        @{ Name = "loki"; Ns = "monitoring" }, @{ Name = "kps"; Ns = "monitoring" },
        @{ Name = "argocd"; Ns = "argocd" }
    )
    foreach ($r in $releases) {
        $hist = $null
        try { $hist = helm history $r.Name -n $r.Ns --kube-context kind-tp3 -o json 2>$null | ConvertFrom-Json } catch {}
        if (-not $hist) { continue }
        $first = "$(@($hist)[0].updated)"
        # On ne retire que ce qui a ete installe le 20/11 (par le TP2), jamais une installation plus ancienne
        if ($first -like "2026-11-20*") {
            cmd /c "helm uninstall $($r.Name) -n $($r.Ns) --kube-context kind-tp3 >NUL 2>&1"
            Write-Host "  tp3 : $($r.Name) retire (installe par erreur le 20/11)" -ForegroundColor DarkGray
        } else {
            Write-Host "  tp3 : $($r.Name) existait avant le 20/11 -> conserve" -ForegroundColor DarkGray
        }
    }
    cmd /c "kubectl --context kind-tp3 delete secret grafana-admin slack-webhook -n monitoring --ignore-not-found >NUL 2>&1"
    cmd /c "kubectl --context kind-tp3 delete namespace tp-app --ignore-not-found --wait=false >NUL 2>&1"
    cmd /c "docker stop tp3-control-plane >NUL 2>&1"
    Write-Host "  tp3 nettoye et arrete. Pour le relancer plus tard : docker start tp3-control-plane" -ForegroundColor Green
} else {
    Write-Host "  pas de cluster tp3 : rien a nettoyer"
}

Write-Host ""
Write-Host "=== 2/3 Fin de l'etape 3 (ArgoCD) sur le cluster tp2 ===" -ForegroundColor Cyan
powershell -ExecutionPolicy Bypass -File "$PSScriptRoot\etape-03b-argocd.ps1"

Write-Host ""
Write-Host "=== 3/3 Etapes 4 et 5 sur le cluster tp2 ===" -ForegroundColor Cyan
powershell -ExecutionPolicy Bypass -File "$PSScriptRoot\etape-04-05.ps1"

Write-Host ""
Write-Host ("TOUT EST TERMINE en {0:N0} minutes. Dis a Claude 'fini'." -f ((Get-Date) - $debut).TotalMinutes) -ForegroundColor Green
