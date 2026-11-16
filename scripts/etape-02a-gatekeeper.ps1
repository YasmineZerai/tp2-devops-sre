# scripts/etape-02a-gatekeeper.ps1
# Etape 2 (partie A) : OPA Gatekeeper + 2 ConstraintTemplates (Rego) + tests de rejet
# Lancement : powershell -ExecutionPolicy Bypass -File .\scripts\etape-02a-gatekeeper.ps1

$ErrorActionPreference = "Continue"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root
. "$Root\tools\capture.ps1"
New-Item -ItemType Directory -Force "$Root\docs\logs" | Out-Null
Start-Transcript -Path "$Root\docs\logs\etape-02a.log" -Force | Out-Null

function Stop-WithError([string]$Message) {
    Write-Host ""; Write-Host "ERREUR : $Message" -ForegroundColor Red
    Stop-Transcript | Out-Null; exit 1
}

kubectl config use-context kind-tp2 | Out-Null

# Nettoyage d'un eventuel essai precedent
cmd /c "kubectl delete deployment bad-latest bad-no-tag bad-no-resources bad-missing-limits good-compliant -n tp-app --ignore-not-found >NUL 2>&1"
cmd /c "kubectl delete pod pod-interdit -n tp-app --ignore-not-found >NUL 2>&1"
cmd /c "helm status gatekeeper -n gatekeeper-system >NUL 2>&1"
$gkAlreadyInstalled = ($LASTEXITCODE -eq 0)

# ---------------------------------------------------------------------------
# 1. Installation de Gatekeeper (Helm)
# ---------------------------------------------------------------------------
Show-Section "Etape 2 - Installation d'OPA Gatekeeper avec Helm"
Invoke-Cmd "helm repo add gatekeeper https://open-policy-agent.github.io/gatekeeper/charts --force-update"
Invoke-Cmd "helm repo update gatekeeper"
Invoke-Cmd "helm upgrade --install gatekeeper gatekeeper/gatekeeper --namespace gatekeeper-system --create-namespace --wait --timeout 6m"
if ($LASTEXITCODE -ne 0) { Stop-WithError "L'installation de Gatekeeper a echoue." }
if (-not $gkAlreadyInstalled) { Save-Capture "E2_01_installation_gatekeeper_helm" }

Show-Section "Etape 2 - Gatekeeper est operationnel"
Invoke-Cmd "helm list -n gatekeeper-system"
Invoke-Cmd "kubectl get pods -n gatekeeper-system -o wide"
Invoke-Cmd "kubectl get validatingwebhookconfigurations"
Save-Capture "E2_02_pods_gatekeeper_running"

# ---------------------------------------------------------------------------
# 2. ConstraintTemplates (code Rego)
# ---------------------------------------------------------------------------
Show-Section "Etape 2 - ConstraintTemplate 1 : interdire le tag latest (Rego)"
Write-Host ""
Write-Host "PS> Get-Content policies\templates\k8sdisallowlatesttag.yaml" -ForegroundColor Yellow
Get-Content policies\templates\k8sdisallowlatesttag.yaml | Out-Host
Save-Capture "E2_03_template_rego_tag_latest"

Show-Section "Etape 2 - ConstraintTemplate 2 : requests/limits obligatoires (Rego)"
Write-Host ""
Write-Host "PS> Get-Content policies\templates\k8srequiredresources.yaml" -ForegroundColor Yellow
Get-Content policies\templates\k8srequiredresources.yaml | Out-Host
Save-Capture "E2_04_template_rego_resources"

Show-Section "Etape 2 - Application des ConstraintTemplates et des Constraints"
Invoke-Cmd "kubectl apply -f policies/templates/"
Write-Host ""
Write-Host "Attente de la creation des CRD par Gatekeeper..." -ForegroundColor DarkGray
$allCreated = $true
foreach ($crd in @("k8sdisallowlatesttag.constraints.gatekeeper.sh", "k8srequiredresources.constraints.gatekeeper.sh")) {
    $ok = $false
    for ($i = 0; $i -lt 30; $i++) {
        cmd /c "kubectl get crd $crd >NUL 2>&1"
        if ($LASTEXITCODE -eq 0) { $ok = $true; break }
        Start-Sleep -Seconds 2
    }
    if (-not $ok) { $allCreated = $false }
}
Invoke-Cmd "kubectl get constrainttemplates -o custom-columns=TEMPLATE:.metadata.name,CREE:.status.created"
if (-not $allCreated) {
    Write-Host ""
    Write-Host "Les CRD n'ont pas ete creees : statut detaille des templates (erreurs de compilation Rego) :" -ForegroundColor Red
    Invoke-Cmd "kubectl get constrainttemplate k8sdisallowlatesttag -o jsonpath={.status}"
    Write-Host ""
    Invoke-Cmd "kubectl get constrainttemplate k8srequiredresources -o jsonpath={.status}"
    Write-Host ""
    Invoke-Cmd "kubectl logs -n gatekeeper-system -l control-plane=controller-manager --tail=30"
    Stop-WithError "ConstraintTemplates non compilees (voir ci-dessus). Envoie le journal a Claude."
}
Invoke-Cmd "kubectl wait --for=condition=established crd/k8sdisallowlatesttag.constraints.gatekeeper.sh crd/k8srequiredresources.constraints.gatekeeper.sh --timeout=120s"
Invoke-Cmd "kubectl apply -f policies/constraints/"
Start-Sleep -Seconds 15   # le temps que le webhook charge les contraintes
Invoke-Cmd "kubectl get constrainttemplates"
Invoke-Cmd "kubectl get constraints"
Save-Capture "E2_05_templates_et_constraints_actifs"

Show-Section "Etape 2 - Detail d'une Constraint (perimetre et action)"
Invoke-Cmd "kubectl get k8sdisallowlatesttag disallow-latest-tag -o yaml"
Save-Capture "E2_06_detail_constraint"

# ---------------------------------------------------------------------------
# 3. Tests de rejet par l'API Server (admission webhook)
# ---------------------------------------------------------------------------
$tests = @(
    @{ File = "bad-latest";         Cap = "E2_07_rejet_tag_latest";          Title = "Test 1 : image nginx:latest (tag latest explicite)" },
    @{ File = "bad-no-tag";         Cap = "E2_08_rejet_image_sans_tag";      Title = "Test 2 : image nginx sans tag (latest implicite)" },
    @{ File = "bad-no-resources";   Cap = "E2_09_rejet_sans_resources";      Title = "Test 3 : aucune resources.requests / limits" },
    @{ File = "bad-missing-limits"; Cap = "E2_10_rejet_limits_manquantes";   Title = "Test 4 : requests presentes mais limits absentes" }
)
foreach ($t in $tests) {
    Show-Section "Etape 2 - $($t.Title)"
    Write-Host ""
    Write-Host "PS> Get-Content policies\tests\$($t.File).yaml" -ForegroundColor Yellow
    Get-Content "policies\tests\$($t.File).yaml" | Out-Host
    Invoke-Cmd "kubectl apply -f policies/tests/$($t.File).yaml"
    if ($LASTEXITCODE -eq 0) { Write-Host "ATTENTION : le manifeste a ete accepte !" -ForegroundColor Red }
    else { Write-Host ""; Write-Host "=> REJETE par l'API Server (admission webhook Gatekeeper)" -ForegroundColor Green }
    Save-Capture $t.Cap
}

Show-Section "Etape 2 - Test 5 : Pod cree directement (kubectl run nginx:latest)"
Invoke-Cmd "kubectl run pod-interdit --image=nginx:latest -n tp-app"
if ($LASTEXITCODE -eq 0) { Write-Host "ATTENTION : le pod a ete accepte !" -ForegroundColor Red }
else { Write-Host ""; Write-Host "=> REJETE : les deux contraintes sont violees en meme temps" -ForegroundColor Green }
Save-Capture "E2_11_rejet_pod_kubectl_run"

Show-Section "Etape 2 - Test 6 : manifeste conforme (tag fixe + requests/limits)"
Write-Host ""
Write-Host "PS> Get-Content policies\tests\good-compliant.yaml" -ForegroundColor Yellow
Get-Content "policies\tests\good-compliant.yaml" | Out-Host
Invoke-Cmd "kubectl apply -f policies/tests/good-compliant.yaml"
Invoke-Cmd "kubectl rollout status deployment/good-compliant -n tp-app --timeout=120s"
Invoke-Cmd "kubectl get deploy,pods -n tp-app"
Write-Host ""; Write-Host "=> ACCEPTE : le manifeste respecte les deux contraintes" -ForegroundColor Green
Save-Capture "E2_12_manifeste_conforme_accepte"
Invoke-Cmd "kubectl delete -f policies/tests/good-compliant.yaml --wait=false"

Show-Section "Etape 2 - Audit Gatekeeper (violations sur les ressources existantes)"
Start-Sleep -Seconds 5
Invoke-Cmd "kubectl get constraints -o custom-columns=CONSTRAINT:.metadata.name,ACTION:.spec.enforcementAction,VIOLATIONS:.status.totalViolations"
Save-Capture "E2_13_audit_gatekeeper"

# ---------------------------------------------------------------------------
# 4. Commit et push
# ---------------------------------------------------------------------------
Show-Section "Etape 2 - Commit et push des politiques"
cmd /c "git rm -q --cached --ignore-unmatch coverage.lcov >NUL 2>&1"
Invoke-Cmd "git add -A"
Invoke-Cmd "git commit -q -m ""fix(policies): ConstraintTemplates en syntaxe Rego classique + verification"""
Invoke-Cmd "git push origin HEAD"
Invoke-Cmd "git --no-pager log --oneline -3"
Save-Capture "E2_14_git_push_politiques"

Stop-Transcript | Out-Null
Write-Host ""
Write-Host "Etape 2A terminee. Captures dans docs\captures, journal dans docs\logs\etape-02a.log" -ForegroundColor Green
