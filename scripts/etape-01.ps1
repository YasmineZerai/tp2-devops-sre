# scripts/etape-01.ps1
# Etape 0 : cluster Kind + namespaces
# Etape 1 : microservice catalog-api, lint, tests, couverture >= 85 %, image Docker, endpoints
# Lancement (depuis le dossier du repo) :
#   powershell -ExecutionPolicy Bypass -File .\scripts\etape-01.ps1

$ErrorActionPreference = "Continue"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root
. "$Root\tools\capture.ps1"

New-Item -ItemType Directory -Force "$Root\docs\logs" | Out-Null
Start-Transcript -Path "$Root\docs\logs\etape-01.log" -Force | Out-Null

function Stop-WithError([string]$Message) {
    Write-Host ""
    Write-Host "ERREUR : $Message" -ForegroundColor Red
    Stop-Transcript | Out-Null
    exit 1
}

# ---------------------------------------------------------------------------
# 1. Prerequis
# ---------------------------------------------------------------------------
Show-Section "Etape 0 - Verification des prerequis"
Invoke-Step "git --version"
Invoke-Step "docker --version"
Invoke-Step "kind version"
Invoke-Step "kubectl version --client"
Invoke-Step "helm version --short"
Invoke-Step "k6 version"
Invoke-Step "python --version"
$ramGb = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
Write-Host ""
Write-Host "RAM totale du PC : $ramGb Go"
docker info --format "Docker Desktop : {{.ServerVersion}} | CPUs alloues : {{.NCPU}} | RAM allouee : {{.MemTotal}} octets"
if ($LASTEXITCODE -ne 0) { Stop-WithError "Docker Desktop ne repond pas. Lance Docker Desktop puis relance le script." }
Save-Capture "E1_01_prerequis_outils"

# ---------------------------------------------------------------------------
# 2. Cluster Kind
# ---------------------------------------------------------------------------
Show-Section "Etape 0 - Creation du cluster Kubernetes (Kind)"
$clusters = kind get clusters 2>$null
if ($clusters -contains "tp2") {
    Write-Host "Le cluster 'tp2' existe deja, on le reutilise."
} else {
    Invoke-Step "kind create cluster --config kind-config.yaml --wait 180s"
    if ($LASTEXITCODE -ne 0) { Stop-WithError "La creation du cluster Kind a echoue." }
}
Save-Capture "E1_02_creation_cluster_kind"

foreach ($ns in @("tp-app", "monitoring", "argocd")) {
    kubectl create namespace $ns --dry-run=client -o yaml | kubectl apply -f - | Out-Null
}

Show-Section "Etape 0 - Cluster pret : noeud et namespaces"
Invoke-Step "kubectl cluster-info --context kind-tp2"
Invoke-Step "kubectl get nodes -o wide"
Invoke-Step "kubectl get namespaces"
Save-Capture "E1_03_cluster_noeud_namespaces"

# ---------------------------------------------------------------------------
# 3. Environnement Python
# ---------------------------------------------------------------------------
Show-Section "Etape 1 - Installation des dependances Python"
if (-not (Test-Path "$Root\.venv")) { Invoke-Step "python -m venv .venv" }
$py = "$Root\.venv\Scripts\python.exe"
Invoke-Step "& '$py' -m pip install --quiet --upgrade pip"
Invoke-Step "& '$py' -m pip install --quiet -r requirements.txt -r requirements-dev.txt"
if ($LASTEXITCODE -ne 0) { Stop-WithError "L'installation des dependances Python a echoue." }

# ---------------------------------------------------------------------------
# 4. Lint
# ---------------------------------------------------------------------------
Show-Section "Etape 1 - Qualite du code : lint et format (ruff)"
Invoke-Step "& '$py' -m ruff check app tests"
Invoke-Step "& '$py' -m ruff format --check app tests"
Save-Capture "E1_04_lint_ruff_ok"

# ---------------------------------------------------------------------------
# 5. Tests unitaires (detail)
# ---------------------------------------------------------------------------
Show-Section "Etape 1 - Tests unitaires et d'integration (pytest -v)"
Invoke-Step "& '$py' -m pytest -v --no-cov -p no:cacheprovider"
Save-Capture "E1_05_tests_unitaires_detail"

# ---------------------------------------------------------------------------
# 6. Couverture (Cobertura XML + LCOV + HTML)
# ---------------------------------------------------------------------------
Show-Section "Etape 1 - Couverture de code (critere : >= 85 %)"
Invoke-Step "& '$py' -m pytest -q --cov=app --cov-report=term-missing --cov-report=xml --cov-report=lcov --cov-report=html --cov-fail-under=85"
$covOk = ($LASTEXITCODE -eq 0)
Write-Host ""
Write-Host "Rapports generes : coverage.xml (Cobertura), coverage.lcov (LCOV), htmlcov\index.html" -ForegroundColor Green
Save-Capture "E1_06_couverture_superieure_85"
if (-not $covOk) { Stop-WithError "Couverture inferieure a 85 % ou tests en echec." }

# ---------------------------------------------------------------------------
# 7. Image Docker
# ---------------------------------------------------------------------------
Show-Section "Etape 1 - Construction de l'image Docker"
Invoke-Step "docker build -t catalog-api:dev ."
if ($LASTEXITCODE -ne 0) { Stop-WithError "Le build Docker a echoue." }
Invoke-Step "docker images catalog-api"
Save-Capture "E1_07_docker_build"

# ---------------------------------------------------------------------------
# 8. Test des endpoints dans le conteneur
# ---------------------------------------------------------------------------
docker rm -f catalog-api-test 2>$null | Out-Null
docker run -d --name catalog-api-test -p 8000:8000 catalog-api:dev | Out-Null
$ready = $false
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 1
    $code = curl.exe -s -o NUL -w "%{http_code}" http://localhost:8000/health
    if ($code -eq "200") { $ready = $true; break }
}
if (-not $ready) { docker logs catalog-api-test; Stop-WithError "Le conteneur ne repond pas sur /health." }

Show-Section "Etape 1 - Test des endpoints de l'API (conteneur Docker)"
Invoke-Step "curl.exe -s http://localhost:8000/health"
Invoke-Step "curl.exe -s http://localhost:8000/products/1"
Invoke-Step "curl.exe -s -w ' -> HTTP %{http_code}' http://localhost:8000/products/999"
Write-Host ""
Write-Host "PS> POST /checkout (5 appels, latence mesuree)" -ForegroundColor Yellow
$body = '{"items":[{"product_id":1,"quantity":2},{"product_id":2,"quantity":1}]}'
for ($i = 1; $i -le 5; $i++) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-RestMethod -Method Post -Uri http://localhost:8000/checkout -ContentType "application/json" -Body $body
    $sw.Stop()
    Write-Host ("  checkout #{0} : status={1} total={2} latence={3} ms" -f $i, $r.status, $r.total, $sw.ElapsedMilliseconds)
}
Write-Host ""
Write-Host "PS> GET /flaky (30 appels, codes HTTP)" -ForegroundColor Yellow
$codes = @()
for ($i = 1; $i -le 30; $i++) { $codes += (curl.exe -s -o NUL -w "%{http_code}" http://localhost:8000/flaky) }
Write-Host ("  " + ($codes -join " "))
$nb503 = ($codes | Where-Object { $_ -eq "503" }).Count
Write-Host "  => $nb503 erreurs 503 sur 30 appels (taux configure : 10 %)"
Save-Capture "E1_08_endpoints_checkout_flaky"

Show-Section "Etape 1 - Endpoint /metrics au format Prometheus"
Write-Host "PS> curl.exe -s http://localhost:8000/metrics | Select-String 'http_requests_total|le=`"0.2`"'" -ForegroundColor Yellow
curl.exe -s http://localhost:8000/metrics | Select-String -Pattern '^http_requests_total|le="0.2"' | ForEach-Object { $_.Line }
Save-Capture "E1_09_metrics_prometheus"
docker rm -f catalog-api-test | Out-Null

# ---------------------------------------------------------------------------
# 9. Commit et push
# ---------------------------------------------------------------------------
Show-Section "Etape 1 - Commit et push sur GitHub"
if (-not (git config user.email)) {
    git config user.name "YasmineZerai"
    git config user.email "YasmineZerai@users.noreply.github.com"
}
Invoke-Step "git add -A"
Invoke-Step "git commit -q -m 'feat: microservice catalog-api, tests (couverture > 85 %), Dockerfile, cluster Kind'"
Invoke-Step "git push origin HEAD"
Invoke-Step "git log --oneline -5"
Save-Capture "E1_10_git_push"

# ---------------------------------------------------------------------------
# 10. Rapport HTML de couverture (en dernier : il ouvre le navigateur)
# ---------------------------------------------------------------------------
Start-Process "$Root\htmlcov\index.html"
Save-Capture "E1_11_rapport_couverture_html" -DelaySeconds 5

Stop-Transcript | Out-Null
Write-Host ""
Write-Host "Etape 1 terminee. Captures dans docs\captures, journal dans docs\logs\etape-01.log" -ForegroundColor Green
