# scripts/etape-03b-argocd.ps1
# Etape 3 (partie B) : PR bloquee par Trivy, installation d'ArgoCD, deploiement GitOps,
# rejet d'un deploiement par OPA Gatekeeper via ArgoCD, puis retour a l'etat sain.
# Lancement : powershell -ExecutionPolicy Bypass -File .\scripts\etape-03b-argocd.ps1

$ErrorActionPreference = "Continue"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root
. "$Root\tools\capture.ps1"
New-Item -ItemType Directory -Force "$Root\docs\logs" | Out-Null
Start-Transcript -Path "$Root\docs\logs\etape-03b.log" -Force | Out-Null
function Stop-WithError([string]$Message) {
    Write-Host ""; Write-Host "ERREUR : $Message" -ForegroundColor Red
    Stop-Transcript | Out-Null; exit 1
}
$Repo = "https://github.com/YasmineZerai/tp2-devops-sre"
$ArgoUi = "http://localhost:30443"

function Get-AppStatus {
    $s = kubectl get application catalog-api -n argocd -o jsonpath="{.status.sync.status}|{.status.health.status}|{.status.operationState.phase}|{.status.sync.revision}" 2>$null
    if (-not $s) { return @{ Sync = ""; Health = ""; Phase = ""; Rev = "" } }
    $p = $s -split "\|"
    return @{ Sync = $p[0]; Health = $p[1]; Phase = $p[2]; Rev = $p[3] }
}
function Request-Refresh {
    cmd /c "kubectl annotate application catalog-api -n argocd argocd.argoproj.io/refresh=normal --overwrite >NUL 2>&1"
}

cmd /c "git checkout -q main 2>&1" | Out-Null
cmd /c "git fetch -q origin 2>&1" | Out-Null

# ---------------------------------------------------------------------------
# 0. Cluster disponible ?
# ---------------------------------------------------------------------------
cmd /c "kubectl get nodes >NUL 2>&1"
if ($LASTEXITCODE -ne 0) {
    Write-Host "Cluster indisponible : redemarrage du noeud Kind..." -ForegroundColor Yellow
    cmd /c "docker start tp2-control-plane >NUL 2>&1"
    Start-Sleep -Seconds 40
    cmd /c "kubectl get nodes >NUL 2>&1"
    if ($LASTEXITCODE -ne 0) { Stop-WithError "Le cluster Kind ne repond pas. Verifie que Docker Desktop est lance." }
}

# ---------------------------------------------------------------------------
# 1. PR #2 : image bloquee par Trivy (vulnerabilite CRITICAL)
# ---------------------------------------------------------------------------
$prSha = (git rev-parse origin/feature/trivy-vulnerable).Trim()
Show-Section "Etape 3 - PR #2 : la porte Trivy bloque une image vulnerable"
Write-Host "Commit de la PR : $prSha"
$prRun = Wait-GitHubRun -Sha $prSha -Event "pull_request" -TimeoutMinutes 20
if ($prRun) {
    Write-Host ""
    Write-Host "Resultat : $($prRun.conclusion)" -ForegroundColor $(if ($prRun.conclusion -eq "failure") { "Red" } else { "Yellow" })
    Show-RunJobs $prRun
    Write-Host ""
    Write-Host "=> Trivy a detecte des vulnerabilites CRITICAL : l'image n'est ni poussee ni deployee." -ForegroundColor Red
    Save-Capture "E3_16_pr_trivy_echec_terminal"
    $jobs = Invoke-RestMethod -Uri "https://api.github.com/repos/YasmineZerai/tp2-devops-sre/actions/runs/$($prRun.id)/jobs" -Headers @{ "User-Agent" = "tp2-script" }
    $build = $jobs.jobs | Where-Object { $_.name -like "Build*" } | Select-Object -First 1
    $stepGate = ($build.steps | Where-Object { $_.name -like "*porte bloquante*" } | Select-Object -First 1).number
    Save-BrowserCapture -Name "E3_17_pr_trivy_critical_log" -Url "$($build.html_url)#step:$($stepGate):1" -WaitSeconds 18
    Save-BrowserCapture -Name "E3_18_pr_trivy_checks_github" -Url "$Repo/pull/2#:~:text=Some%20checks%20were%20not%20successful" -WaitSeconds 18
} else {
    Write-Host "Workflow de la PR #2 introuvable : captures Trivy ignorees." -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# 2. Image publique sur GHCR ?
# ---------------------------------------------------------------------------
$deployTag = ((git show origin/deploy:helm/catalog-api/values.yaml | Select-String -Pattern '^\s+tag:').Line -replace '.*tag:\s*"?([^"]+)"?.*', '$1').Trim()
Write-Host ""
Write-Host "Version a deployer (branche deploy) : $deployTag" -ForegroundColor Cyan
try {
    $tok = (Invoke-RestMethod -Uri "https://ghcr.io/token?scope=repository:yasminezerai/catalog-api:pull").token
    $null = Invoke-WebRequest -UseBasicParsing -Method Head -Uri "https://ghcr.io/v2/yasminezerai/catalog-api/manifests/$deployTag" -Headers @{
        Authorization = "Bearer $tok"
        Accept = "application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json"
    }
    Write-Host "Image ghcr.io/yasminezerai/catalog-api:$deployTag accessible publiquement." -ForegroundColor Green
} catch {
    Stop-WithError "L'image n'est pas publique sur GHCR (ou introuvable). Dis-le a Claude."
}

# ---------------------------------------------------------------------------
# 3. Installation d'ArgoCD
# ---------------------------------------------------------------------------
Show-Section "Etape 3 - Installation d'ArgoCD (Helm)"
Invoke-Cmd "helm repo add argo https://argoproj.github.io/argo-helm --force-update"
Invoke-Cmd "helm repo update argo"
Invoke-Cmd "helm upgrade --install argocd argo/argo-cd --namespace argocd --create-namespace -f argocd/values-argocd.yaml --wait --timeout 10m"
if ($LASTEXITCODE -ne 0) { Stop-WithError "L'installation d'ArgoCD a echoue." }
Save-Capture "E3_19_installation_argocd"

Show-Section "Etape 3 - ArgoCD est operationnel"
Invoke-Cmd "kubectl get pods -n argocd"
Invoke-Cmd "kubectl get svc argocd-server -n argocd"
Save-Capture "E3_20_pods_argocd"

# ---------------------------------------------------------------------------
# 4. Application GitOps
# ---------------------------------------------------------------------------
Show-Section "Etape 3 - Application ArgoCD (source : branche deploy du depot Git)"
Write-Host ""
Write-Host "PS> Get-Content argocd\application.yaml" -ForegroundColor Yellow
Get-Content argocd\application.yaml | Out-Host
Invoke-Cmd "kubectl apply -f argocd/application.yaml"
Save-Capture "E3_21_application_argocd_yaml"

Show-Section "Etape 3 - Synchronisation automatique par ArgoCD"
$ok = $false
for ($i = 0; $i -lt 36; $i++) {
    $st = Get-AppStatus
    Write-Host ("  [{0}] sync={1} health={2} operation={3}" -f (Get-Date -Format HH:mm:ss), $st.Sync, $st.Health, $st.Phase)
    if ($st.Sync -eq "Synced" -and $st.Health -eq "Healthy") { $ok = $true; break }
    Start-Sleep -Seconds 10
}
Write-Host ""
Invoke-Cmd "kubectl get applications -n argocd"
Invoke-Cmd "kubectl get deploy,pods,svc -n tp-app -o wide"
if (-not $ok) { Write-Host "L'application n'est pas Synced/Healthy : dis-le a Claude." -ForegroundColor Red }
Save-Capture "E3_22_application_synced_healthy"

Show-Section "Etape 3 - Le microservice deploye repond (NodePort 30080)"
Invoke-Cmd "kubectl get deploy catalog-api -n tp-app -o jsonpath={.spec.template.spec.containers[0].image}"
Write-Host ""
Invoke-Cmd "curl.exe -s http://localhost:30080/health"
Write-Host ""
Invoke-Cmd "curl.exe -s http://localhost:30080/products/1"
Save-Capture "E3_23_service_deploye_repond"

Save-BrowserCapture -Name "E3_24_argocd_ui_applications" -Url "$ArgoUi/applications" -WaitSeconds 15
Save-BrowserCapture -Name "E3_25_argocd_ui_arbre_ressources" -Url "$ArgoUi/applications/argocd/catalog-api?view=tree" -WaitSeconds 15

# ---------------------------------------------------------------------------
# 5. Rejet par Gatekeeper d'un deploiement ArgoCD non conforme (tag latest)
# ---------------------------------------------------------------------------
Show-Section "Etape 3 - Test : on pousse l'image ':latest' sur la branche deploy"
$wt = Join-Path $env:TEMP "tp2-deploy-wt"
cmd /c "git worktree remove --force ""$wt"" >NUL 2>&1"
cmd /c "git worktree prune >NUL 2>&1"
Invoke-Cmd "git worktree add -B deploy ""$wt"" origin/deploy"
$vf = Join-Path $wt "helm\catalog-api\values.yaml"
(Get-Content $vf) -replace '^(\s+tag:).*', '$1 "latest"' | Set-Content $vf -Encoding ascii
Push-Location $wt
Write-Host ""
Write-Host "PS> git diff" -ForegroundColor Yellow
git --no-pager diff | Out-Host
Invoke-Cmd "git commit -q -am ""test: image latest (doit etre refusee par Gatekeeper)"""
Invoke-Cmd "git push origin deploy"
Pop-Location
Request-Refresh
Save-Capture "E3_26_push_tag_latest_deploy"

Show-Section "Etape 3 - ArgoCD tente le deploiement : refus de l'API Server (Gatekeeper)"
$denied = $false
for ($i = 0; $i -lt 30; $i++) {
    $st = Get-AppStatus
    $msg = kubectl get application catalog-api -n argocd -o jsonpath="{.status.operationState.message}" 2>$null
    Write-Host ("  [{0}] sync={1} health={2} operation={3}" -f (Get-Date -Format HH:mm:ss), $st.Sync, $st.Health, $st.Phase)
    if ($msg -match "denied|gatekeeper|latest") { $denied = $true; break }
    Start-Sleep -Seconds 10
    if ($i % 3 -eq 2) { Request-Refresh }
}
Write-Host ""
Write-Host "Message d'erreur d'ArgoCD (operationState.message) :" -ForegroundColor Red
kubectl get application catalog-api -n argocd -o jsonpath="{.status.operationState.message}" | Out-Host
Write-Host ""
Write-Host ""
Write-Host "Le service continue de tourner avec la derniere version conforme :" -ForegroundColor Green
Invoke-Cmd "kubectl get deploy catalog-api -n tp-app -o jsonpath={.spec.template.spec.containers[0].image}"
Write-Host ""
Invoke-Cmd "curl.exe -s http://localhost:30080/health"
if (-not $denied) { Write-Host "Le refus Gatekeeper n'a pas ete observe : dis-le a Claude." -ForegroundColor Yellow }
Save-Capture "E3_27_argocd_sync_refuse_gatekeeper"
Save-BrowserCapture -Name "E3_28_argocd_ui_sync_failed" -Url "$ArgoUi/applications/argocd/catalog-api?view=tree&operation=true" -WaitSeconds 15
Save-BrowserCapture -Name "E3_29_argocd_ui_liste_sync_failed" -Url "$ArgoUi/applications" -WaitSeconds 12

# ---------------------------------------------------------------------------
# 6. Retour a l'etat sain (git revert) : GitOps = rollback par Git
# ---------------------------------------------------------------------------
Show-Section "Etape 3 - Rollback GitOps : git revert sur la branche deploy"
Push-Location $wt
Invoke-Cmd "git revert --no-edit HEAD"
Invoke-Cmd "git push origin deploy"
Invoke-Cmd "git --no-pager log --oneline -4"
Pop-Location
Request-Refresh
$ok = $false
for ($i = 0; $i -lt 30; $i++) {
    $st = Get-AppStatus
    Write-Host ("  [{0}] sync={1} health={2} operation={3}" -f (Get-Date -Format HH:mm:ss), $st.Sync, $st.Health, $st.Phase)
    if ($st.Sync -eq "Synced" -and $st.Health -eq "Healthy" -and $st.Phase -eq "Succeeded") { $ok = $true; break }
    Start-Sleep -Seconds 10
    if ($i % 3 -eq 2) { Request-Refresh }
}
Invoke-Cmd "kubectl get applications -n argocd"
Save-Capture "E3_30_rollback_git_revert_synced"
Save-BrowserCapture -Name "E3_31_argocd_ui_retour_healthy" -Url "$ArgoUi/applications/argocd/catalog-api?view=tree" -WaitSeconds 15

cmd /c "git worktree remove --force ""$wt"" >NUL 2>&1"
Stop-Transcript | Out-Null
Write-Host ""
Write-Host "Etape 3 terminee. Dis a Claude 'fini'." -ForegroundColor Green
