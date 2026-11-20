# scripts/etape-04-05.ps1
# Etape 4 : instrumentation OpenTelemetry + Prometheus / Grafana / Loki / Tempo / Alloy
# Etape 5 : SLI/SLO, PrometheusRule (burn rate), dashboard RED, test k6, incident + alertes
# Lancement : powershell -ExecutionPolicy Bypass -File .\scripts\etape-04-05.ps1

$ErrorActionPreference = "Continue"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root
. "$Root\tools\capture.ps1"
New-Item -ItemType Directory -Force "$Root\docs\logs", "$Root\docs\k6", "$Root\.secrets" | Out-Null
Start-Transcript -Path "$Root\docs\logs\etape-04-05.log" -Force | Out-Null

$Repo = "https://github.com/YasmineZerai/tp2-devops-sre"
$Prom = "http://localhost:30900"
$Graf = "http://localhost:30300"
$AM = "http://localhost:30903"
$ArgoUi = "http://localhost:30443"
$py = "$Root\.venv\Scripts\python.exe"
$problems = New-Object System.Collections.Generic.List[string]
function Note-Problem([string]$m) { $problems.Add($m); Write-Host "PROBLEME : $m" -ForegroundColor Red }

function Get-AppStatus {
    $s = kubectl get application catalog-api -n argocd -o jsonpath="{.status.sync.status}|{.status.health.status}|{.status.operationState.phase}|{.status.sync.revision}" 2>$null
    if (-not $s) { return @{ Sync = ""; Health = ""; Phase = ""; Rev = "" } }
    $p = $s -split "\|"
    return @{ Sync = $p[0]; Health = $p[1]; Phase = $p[2]; Rev = $p[3] }
}
function Request-Refresh { cmd /c "kubectl annotate application catalog-api -n argocd argocd.argoproj.io/refresh=normal --overwrite >NUL 2>&1" }
function Wait-AppAtRevision([string]$rev, [int]$maxTries = 40) {
    for ($i = 0; $i -lt $maxTries; $i++) {
        $st = Get-AppStatus
        Write-Host ("  [{0}] revision={1} sync={2} health={3} operation={4}" -f (Get-Date -Format HH:mm:ss), ($st.Rev + "       ").Substring(0, 7), $st.Sync, $st.Health, $st.Phase)
        if ($st.Rev -eq $rev -and $st.Sync -eq "Synced" -and $st.Health -eq "Healthy") { return $true }
        if ($i % 3 -eq 2) { Request-Refresh }
        Start-Sleep -Seconds 10
    }
    return $false
}
function Prom-Query([string]$q) {
    try {
        $r = Invoke-RestMethod -Uri "$Prom/api/v1/query?query=$([uri]::EscapeDataString($q))"
        if ($r.data.result.Count -gt 0) { return [double]$r.data.result[0].value[1] }
    } catch {}
    return $null
}
function Install-Chart([string]$name, [string[]]$charts, [string]$values) {
    foreach ($c in $charts) {
        Invoke-Cmd "helm upgrade --install $name $c --namespace monitoring -f $values --wait --timeout 12m"
        if ($LASTEXITCODE -eq 0) { return $true }
        Write-Host "  -> echec avec $c, essai suivant..." -ForegroundColor Yellow
    }
    Note-Problem "installation de $name"
    return $false
}
function Set-DeployValue([string]$wt, [string]$pattern, [string]$replacement, [string]$message) {
    $vf = Join-Path $wt "helm\catalog-api\values.yaml"
    (Get-Content $vf) -replace $pattern, $replacement | Set-Content $vf -Encoding ascii
    Push-Location $wt
    git --no-pager diff | Out-Host
    cmd /c "git commit -q -am ""$message"" 2>&1" | Out-Host
    cmd /c "git push -q origin deploy 2>&1" | Out-Host
    $h = (git rev-parse HEAD).Trim()
    Pop-Location
    Request-Refresh
    return $h
}

# ===========================================================================
# 0. Pre-requis
# ===========================================================================
cmd /c "git checkout -q main 2>&1" | Out-Null
cmd /c "kubectl get nodes >NUL 2>&1"
if ($LASTEXITCODE -ne 0) { cmd /c "docker start tp2-control-plane >NUL 2>&1"; Start-Sleep -Seconds 40 }
$freeGb = [math]::Round((Get-PSDrive C).Free / 1GB, 1)
Write-Host "Espace disque libre : $freeGb Go" -ForegroundColor $(if ($freeGb -lt 10) { "Yellow" } else { "Green" })

# ===========================================================================
# ETAPE 4 - A. Instrumentation de l'application
# ===========================================================================
Show-Section "Etape 4 - Instrumentation OpenTelemetry (app/telemetry.py)"
Write-Host ""
Write-Host "PS> Get-Content app\telemetry.py" -ForegroundColor Yellow
Get-Content app\telemetry.py | Select-Object -Skip 22 | Out-Host
Save-Capture "E4_01_code_instrumentation_otel"

Show-Section "Etape 4 - Tests de l'instrumentation (logs JSON correles aux traces)"
Invoke-Step "& '$py' -m pip install --quiet -r requirements.txt -r requirements-dev.txt"
Invoke-Step "& '$py' -m pytest -q --cov=app --cov-report=term-missing --cov-fail-under=85 -p no:cacheprovider"
if ($LASTEXITCODE -ne 0) { Note-Problem "tests locaux" }
Save-Capture "E4_02_tests_instrumentation"

Show-Section "Etape 4 - Push : nouvelle version instrumentee (CI -> GHCR -> branche deploy -> ArgoCD)"
Invoke-Cmd "git add -A"
Invoke-Cmd "git commit -q -m ""feat(observabilite): traces OpenTelemetry, logs JSON correles, stack Prometheus/Loki/Tempo, SLO et test k6"""
Invoke-Cmd "git push origin main"
$appSha = (git rev-parse HEAD).Trim()
Save-Capture "E4_03_push_version_instrumentee"

# ===========================================================================
# ETAPE 4 - B. Stack d'observabilite (pendant que la CI tourne)
# ===========================================================================
Show-Section "Etape 4 - Secrets (mot de passe Grafana, webhook Slack)"
$grafPwdFile = "$Root\.secrets\grafana_admin.txt"
if (-not (Test-Path $grafPwdFile)) { [guid]::NewGuid().ToString("N").Substring(0, 20) | Set-Content $grafPwdFile -NoNewline }
$grafPwd = (Get-Content $grafPwdFile -Raw).Trim()
cmd /c "kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f - >NUL 2>&1"
cmd /c "kubectl -n monitoring create secret generic grafana-admin --from-literal=admin-user=admin --from-literal=admin-password=$grafPwd --dry-run=client -o yaml | kubectl apply -f - >NUL 2>&1"
$slackFile = "$Root\.secrets\slack_webhook.txt"
$useSlack = (Test-Path $slackFile) -and ((Get-Content $slackFile -Raw).Trim() -like "https://hooks.slack.com/*")
if ($useSlack) {
    cmd /c "kubectl -n monitoring create secret generic slack-webhook --from-file=url=""$slackFile"" --dry-run=client -o yaml | kubectl apply -f - >NUL 2>&1"
    $amValues = "observability/alertmanager-slack.yaml"
    Write-Host "Webhook Slack trouve : Warning -> Slack #new-channel, Critical -> Page (Slack @channel)" -ForegroundColor Green
} else {
    Invoke-Cmd "kubectl apply -f observability/alert-receiver.yaml"
    $amValues = "observability/alertmanager-mock.yaml"
    Write-Host "Pas de webhook Slack : alertes envoyees au recepteur local alert-receiver" -ForegroundColor Yellow
}
Invoke-Cmd "kubectl get secrets -n monitoring"
Write-Host ""
Write-Host "Les valeurs des secrets ne sont jamais affichees ni commitees (.secrets/ est dans .gitignore)." -ForegroundColor DarkGray
Save-Capture "E4_04_secrets_kubernetes"

Show-Section "Etape 4 - Installation de kube-prometheus-stack (Prometheus, Alertmanager, Grafana)"
Invoke-Cmd "helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update"
Invoke-Cmd "helm repo add grafana https://grafana.github.io/helm-charts --force-update"
Invoke-Cmd "helm repo add grafana-community https://grafana-community.github.io/helm-charts --force-update"
cmd /c "helm repo update >NUL 2>&1"
Invoke-Cmd "helm upgrade --install kps prometheus-community/kube-prometheus-stack --namespace monitoring -f observability/kps-values.yaml -f $amValues --wait --timeout 15m"
if ($LASTEXITCODE -ne 0) { Note-Problem "installation kube-prometheus-stack" }
Save-Capture "E4_05_installation_kube_prometheus_stack"

Show-Section "Etape 4 - Installation de Loki, Tempo et Grafana Alloy"
$null = Install-Chart "loki" @("grafana-community/loki", "grafana/loki") "observability/loki-values.yaml"
$null = Install-Chart "tempo" @("grafana-community/tempo", "grafana/tempo") "observability/tempo-values.yaml"
$null = Install-Chart "alloy" @("grafana/alloy") "observability/alloy-values.yaml"
Save-Capture "E4_06_installation_loki_tempo_alloy"

Show-Section "Etape 4 - Stack d'observabilite operationnelle"
Invoke-Cmd "helm list -A"
Invoke-Cmd "kubectl get pods -n monitoring"
Save-Capture "E4_07_pods_monitoring"

# ===========================================================================
# ETAPE 4 - C. Deploiement de la version instrumentee
# ===========================================================================
Show-Section "Etape 4 - CI de la version instrumentee"
$run = Wait-GitHubRun -Sha $appSha -Event "push" -TimeoutMinutes 25
if ($run) { Show-RunJobs $run }
if (-not $run -or $run.conclusion -ne "success") { Note-Problem "pipeline CI de la version instrumentee" }
Save-Capture "E4_08_ci_version_instrumentee"

Show-Section "Etape 4 - ArgoCD deploie automatiquement la nouvelle version"
cmd /c "git fetch -q origin deploy 2>&1" | Out-Null
$deployHead = (git rev-parse origin/deploy).Trim()
Write-Host "Revision a deployer (branche deploy) : $deployHead"
if (-not (Wait-AppAtRevision $deployHead)) { Note-Problem "ArgoCD n'a pas deploye la version instrumentee" }
Invoke-Cmd "kubectl get pods -n tp-app -o wide"
Invoke-Cmd "kubectl get deploy catalog-api -n tp-app -o jsonpath={.spec.template.spec.containers[0].image}"
Write-Host ""
Save-Capture "E4_09_argocd_deploie_version_instrumentee"

# Trafic pour alimenter metriques, logs et traces
Write-Host "Generation de trafic (300 requetes)..." -ForegroundColor DarkGray
$body = '{"items":[{"product_id":1,"quantity":2}]}'
for ($i = 0; $i -lt 100; $i++) {
    try { Invoke-RestMethod -Method Post -Uri http://localhost:30080/checkout -ContentType "application/json" -Body $body | Out-Null } catch {}
    try { Invoke-WebRequest -UseBasicParsing http://localhost:30080/flaky | Out-Null } catch {}
    try { Invoke-WebRequest -UseBasicParsing http://localhost:30080/products/2 | Out-Null } catch {}
}
Start-Sleep -Seconds 30

Show-Section "Etape 4 - Logs JSON de l'application (trace_id / span_id)"
Write-Host ""
Write-Host "PS> kubectl logs -n tp-app -l app.kubernetes.io/name=catalog-api --tail=200 | Select-String trace_id | Select-Object -Last 8" -ForegroundColor Yellow
kubectl logs -n tp-app -l app.kubernetes.io/name=catalog-api --tail=200 | Select-String "trace_id" | Select-Object -Last 8 | ForEach-Object { $_.Line } | Out-Host
Save-Capture "E4_10_logs_json_trace_id"

# Captures web : Prometheus, Grafana, Loki, Tempo, correlation
Save-BrowserCapture -Name "E4_11_prometheus_targets_app" -Url "$Prom/targets?search=kubernetes-pods" -WaitSeconds 10
$q = [uri]::EscapeDataString('sum by (route, status) (rate(http_requests_total{namespace="tp-app"}[1m]))')
Save-BrowserCapture -Name "E4_12_prometheus_metriques_app" -Url "$Prom/query?g0.expr=$q&g0.tab=graph&g0.range_input=15m" -WaitSeconds 10
Save-BrowserCapture -Name "E4_13_grafana_datasources" -Url "$Graf/connections/datasources" -WaitSeconds 12

$traceId = $null
try {
    $lq = [uri]::EscapeDataString('{namespace="tp-app"} |= "trace_id" |= "checkout"')
    $start = [DateTimeOffset]::UtcNow.AddMinutes(-20).ToUnixTimeMilliseconds() * 1000000
    $lr = Invoke-RestMethod -Uri "$Graf/api/datasources/proxy/uid/loki/loki/api/v1/query_range?query=$lq&limit=20&start=$start"
    foreach ($s in $lr.data.result) { foreach ($v in $s.values) { if ($v[1] -match '"trace_id":\s*"([0-9a-f]{32})"') { $traceId = $Matches[1]; break } }; if ($traceId) { break } }
} catch { Write-Host "Requete Loki impossible : $($_.Exception.Message)" -ForegroundColor Yellow }
Write-Host "trace_id choisi pour la correlation : $traceId" -ForegroundColor Cyan

function Explore-Url($panes) {
    $json = $panes | ConvertTo-Json -Depth 10 -Compress
    return "$Graf/explore?schemaVersion=1&orgId=1&panes=$([uri]::EscapeDataString($json))"
}
$range = @{ from = "now-30m"; to = "now" }
$lokiPane = @{ datasource = "loki"; range = $range; queries = @(@{ refId = "A"; datasource = @{ type = "loki"; uid = "loki" }; expr = '{namespace="tp-app"} | json | trace_id != ""' }) }
Save-BrowserCapture -Name "E4_14_grafana_loki_logs_json" -Url (Explore-Url @{ a = $lokiPane }) -WaitSeconds 15
$tempoSearch = @{ datasource = "tempo"; range = $range; queries = @(@{ refId = "A"; datasource = @{ type = "tempo"; uid = "tempo" }; queryType = "traceql"; query = '{resource.service.name="catalog-api" && name="process_payment"}' }) }
Save-BrowserCapture -Name "E4_15_grafana_tempo_recherche_traces" -Url (Explore-Url @{ a = $tempoSearch }) -WaitSeconds 15
if ($traceId) {
    $tracePane = @{ datasource = "tempo"; range = $range; queries = @(@{ refId = "A"; datasource = @{ type = "tempo"; uid = "tempo" }; queryType = "traceql"; query = $traceId }) }
    Save-BrowserCapture -Name "E4_16_grafana_tempo_trace_waterfall" -Url (Explore-Url @{ a = $tracePane }) -WaitSeconds 15
    $logPane = @{ datasource = "loki"; range = $range; queries = @(@{ refId = "A"; datasource = @{ type = "loki"; uid = "loki" }; expr = "{namespace=`"tp-app`"} |= `"$traceId`"" }) }
    Save-BrowserCapture -Name "E4_17_correlation_logs_traces" -Url (Explore-Url @{ a = $logPane; b = $tracePane }) -WaitSeconds 18
} else { Note-Problem "aucun trace_id trouve dans Loki (captures Tempo/correlation)" }

# ===========================================================================
# ETAPE 5 - A. SLO, regles d'alerte, dashboard
# ===========================================================================
Show-Section "Etape 5 - Definition des SLI / SLO / Error Budget / Burn rate"
Write-Host ""
Write-Host "PS> Get-Content observability\slo-rules.yaml (en-tete)" -ForegroundColor Yellow
Get-Content observability\slo-rules.yaml | Select-Object -First 30 | Out-Host
Save-Capture "E5_01_definition_slo_slis"

Show-Section "Etape 5 - Regles d'alerte burn rate (multi-fenetres)"
Get-Content observability\slo-rules.yaml | Select-String -Pattern "alert:|expr:|slo:burn_rate:(1h|5m|6h|30m) >|for:|severity:|summary:" | ForEach-Object { $_.Line } | Out-Host
Invoke-Cmd "kubectl apply -f observability/slo-rules.yaml"
cmd /c "kubectl -n monitoring create configmap dashboard-sre-red --from-file=sre-red.json=observability/dashboard-sre-red.json --dry-run=client -o yaml > %TEMP%\dash.yaml"
cmd /c "kubectl label --local -f %TEMP%\dash.yaml grafana_dashboard=1 -o yaml | kubectl apply -f - 2>&1" | Out-Host
Invoke-Cmd "kubectl get prometheusrules -n monitoring"
Save-Capture "E5_02_regles_alerte_burn_rate"

Show-Section "Etape 5 - Routage des alertes (Alertmanager)"
Write-Host ""
Write-Host "PS> Get-Content $amValues" -ForegroundColor Yellow
Get-Content $amValues | Out-Host
Save-Capture "E5_03_routage_alertmanager"

Start-Sleep -Seconds 30
Save-BrowserCapture -Name "E5_04_prometheus_regles_slo" -Url "$Prom/rules" -WaitSeconds 10
Save-BrowserCapture -Name "E5_05_prometheus_alertes_avant_test" -Url "$Prom/alerts" -WaitSeconds 10
Save-BrowserCapture -Name "E5_06_dashboard_avant_test" -Url "$Graf/d/sre-red-catalog-api?orgId=1&from=now-30m&to=now&kiosk" -WaitSeconds 18

# ===========================================================================
# ETAPE 5 - B. Test de charge k6 + incident (deploiement defectueux via GitOps)
# ===========================================================================
Show-Section "Etape 5 - Script k6 : 3 scenarios (ramp-up 100, stress 500, spike 1500 VUs)"
Get-Content k6\load-test.js | Select-Object -First 52 | Out-Host
Save-Capture "E5_07_script_k6_scenarios"

$env:K6_WEB_DASHBOARD = "true"
$env:K6_WEB_DASHBOARD_OPEN = "false"
$env:K6_WEB_DASHBOARD_EXPORT = "$Root\docs\k6\rapport-k6.html"
$k6Out = "$Root\docs\k6\k6-sortie.txt"
$testStart = Get-Date
$k6 = Start-Process -FilePath "k6" -ArgumentList @("run", "--summary-export", "docs/k6/summary.json", "k6/load-test.js") -RedirectStandardOutput $k6Out -RedirectStandardError "$Root\docs\k6\k6-erreurs.txt" -NoNewWindow -PassThru
Show-Section "Etape 5 - Test de charge en cours (k6, environ 8 min)"
Write-Host "k6 demarre a $(Get-Date -Format HH:mm:ss) (PID $($k6.Id))"
Start-Sleep -Seconds 150

Show-Section "Etape 5 - INCIDENT : deploiement d'une version defectueuse (taux d'erreur /flaky 60 %)"
$wt = Join-Path $env:TEMP "tp2-deploy-wt"
cmd /c "git worktree remove --force ""$wt"" >NUL 2>&1"
cmd /c "git worktree prune >NUL 2>&1"
cmd /c "git fetch -q origin deploy 2>&1" | Out-Null
cmd /c "git worktree add -q -B deploy ""$wt"" origin/deploy 2>&1" | Out-Host
$incidentStart = Get-Date
$badRev = Set-DeployValue $wt '^(\s+FLAKY_ERROR_RATE:).*' '$1 "0.6"' "release: FLAKY_ERROR_RATE=0.6 (version defectueuse - incident simule)"
Write-Host ""
Write-Host "Incident declenche a $(Get-Date -Format HH:mm:ss) : ArgoCD va deployer la version defectueuse." -ForegroundColor Red
Save-Capture "E5_08_incident_deploiement_defectueux"

Show-Section "Etape 5 - Surveillance : burn rate et alertes"
$critical = $false; $warning = $false
for ($i = 0; $i -lt 36; $i++) {
    $br5 = Prom-Query "slo:burn_rate:5m"; $br1h = Prom-Query "slo:burn_rate:1h"
    $alerts = @()
    try { $alerts = (Invoke-RestMethod -Uri "$Prom/api/v1/alerts").data.alerts } catch {}
    $firing = @($alerts | Where-Object { $_.state -eq "firing" } | ForEach-Object { "$($_.labels.alertname)($($_.labels.severity))" })
    $pending = @($alerts | Where-Object { $_.state -eq "pending" } | ForEach-Object { $_.labels.alertname })
    Write-Host ("  [{0}] burn5m={1:N1} burn1h={2:N1} | firing: {3} | pending: {4}" -f (Get-Date -Format HH:mm:ss), $br5, $br1h, ($firing -join ", "), ($pending -join ", "))
    if ($firing -match "critical") { $critical = $true }
    if ($firing -match "warning") { $warning = $true }
    if ($critical -and $warning) { break }
    Start-Sleep -Seconds 10
}
if (-not $critical) { Note-Problem "l'alerte critique n'a pas ete declenchee" }
$alertTime = Get-Date
Save-Capture "E5_09_alertes_declenchees_terminal"
Save-BrowserCapture -Name "E5_10_prometheus_alertes_firing" -Url "$Prom/alerts" -WaitSeconds 10
Save-BrowserCapture -Name "E5_11_alertmanager_alertes" -Url "$AM/#/alerts" -WaitSeconds 10
Save-BrowserCapture -Name "E5_12_dashboard_pendant_incident" -Url "$Graf/d/sre-red-catalog-api?orgId=1&from=now-15m&to=now&kiosk" -WaitSeconds 18
if (-not $useSlack) {
    Show-Section "Etape 5 - Notifications recues par le recepteur (Page / Warning)"
    kubectl logs -n monitoring deploy/alert-receiver --tail=400 | Select-String -Pattern '"path"|alertname|"status"' | Select-Object -Last 20 | ForEach-Object { $_.Line } | Out-Host
    Save-Capture "E5_13_notifications_recues"
}

Show-Section "Etape 5 - Remediation : rollback GitOps (git revert) de la version defectueuse"
Push-Location $wt
cmd /c "git revert --no-edit HEAD 2>&1" | Out-Host
cmd /c "git push -q origin deploy 2>&1" | Out-Host
$goodRev = (git rev-parse HEAD).Trim()
Invoke-Cmd "git --no-pager log --oneline -3"
Pop-Location
Request-Refresh
$rollbackTime = Get-Date
$null = Wait-AppAtRevision $goodRev 18
Write-Host "Rollback effectue a $(Get-Date -Format HH:mm:ss)" -ForegroundColor Green
Save-Capture "E5_14_rollback_git_revert"

Show-Section "Etape 5 - Fin du test de charge"
Write-Host "Attente de la fin de k6..."
$k6.WaitForExit(900000) | Out-Null
$testEnd = Get-Date
Get-Content $k6Out -Tail 70 | Out-Host
Save-Capture "E5_15_k6_resultats_terminal"
if (Test-Path "$Root\docs\k6\rapport-k6.html") {
    Save-BrowserCapture -Name "E5_16_k6_rapport_html" -Url ("file:///" + ("$Root\docs\k6\rapport-k6.html" -replace "\\", "/")) -WaitSeconds 10
}

Start-Sleep -Seconds 60
Save-BrowserCapture -Name "E5_17_dashboard_test_complet" -Url "$Graf/d/sre-red-catalog-api?orgId=1&from=now-20m&to=now&kiosk" -WaitSeconds 18
Save-BrowserCapture -Name "E5_18_prometheus_alertes_apres_rollback" -Url "$Prom/alerts" -WaitSeconds 10
Save-BrowserCapture -Name "E5_19_argocd_historique" -Url "$ArgoUi/applications/argocd/catalog-api?view=tree&resource=&operation=false" -WaitSeconds 12

# ===========================================================================
# ETAPE 5 - C. Chiffres pour le rapport (calcul de l'Error Budget)
# ===========================================================================
Show-Section "Etape 5 - Chiffres de l'incident (Prometheus)"
$mins = [math]::Ceiling(((Get-Date) - $testStart).TotalMinutes) + 1
$m = [ordered]@{
    debut_test = $testStart.ToString("HH:mm:ss"); debut_incident = $incidentStart.ToString("HH:mm:ss")
    alertes = $alertTime.ToString("HH:mm:ss"); rollback = $rollbackTime.ToString("HH:mm:ss"); fin_test = $testEnd.ToString("HH:mm:ss")
    fenetre_minutes = $mins
    requetes_totales = Prom-Query "sum(increase(http_requests_total{namespace=`"tp-app`"}[${mins}m]))"
    requetes_5xx = Prom-Query "sum(increase(http_requests_total{namespace=`"tp-app`",status=~`"5..`"}[${mins}m]))"
    p95_max_s = Prom-Query "max_over_time(sli:latency:p95_5m[${mins}m])"
    part_sous_200ms_min = Prom-Query "min_over_time(sli:latency_good:ratio_rate5m[${mins}m])"
    burn_rate_5m_max = Prom-Query "max_over_time(slo:burn_rate:5m[${mins}m])"
    burn_rate_1h_max = Prom-Query "max_over_time(slo:burn_rate:1h[${mins}m])"
    burn_rate_6h_max = Prom-Query "max_over_time(slo:burn_rate:6h[${mins}m])"
    error_budget_restant = Prom-Query "slo:error_budget:remaining_ratio"
    alerte_critique = $critical; alerte_warning = $warning; slack = $useSlack
}
if ($m.requetes_totales) { $m.taux_erreur = $m.requetes_5xx / $m.requetes_totales }
$m | ConvertTo-Json | Set-Content "$Root\docs\sre-chiffres.json" -Encoding utf8
$m.GetEnumerator() | ForEach-Object { Write-Host ("  {0,-24} {1}" -f $_.Key, $_.Value) }
Save-Capture "E5_20_chiffres_incident"

cmd /c "git worktree remove --force ""$wt"" >NUL 2>&1"
Show-Section "Fin - Commit des captures et resultats"
Invoke-Cmd "git add -A"
Invoke-Cmd "git commit -q -m ""docs: captures et resultats des etapes 4 et 5"""
Invoke-Cmd "git push origin main"
Stop-Transcript | Out-Null
Write-Host ""
if ($problems.Count -gt 0) { Write-Host "Termine avec $($problems.Count) probleme(s) : $($problems -join ' ; ')" -ForegroundColor Yellow }
Write-Host "Etapes 4 et 5 terminees. Dis a Claude 'fini'." -ForegroundColor Green
