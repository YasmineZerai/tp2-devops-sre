# scripts/etape-02b-sonar-ci.ps1
# Etape 2 (partie B1) : pipeline CI (Lint & Test -> SonarQube + Quality Gate) sur main,
# puis preparation d'une branche volontairement non conforme pour la PR de demonstration.
# Lancement : powershell -ExecutionPolicy Bypass -File .\scripts\etape-02b-sonar-ci.ps1

$ErrorActionPreference = "Continue"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root
. "$Root\tools\capture.ps1"
New-Item -ItemType Directory -Force "$Root\docs\logs" | Out-Null
Start-Transcript -Path "$Root\docs\logs\etape-02b.log" -Force | Out-Null
function Stop-WithError([string]$Message) {
    Write-Host ""; Write-Host "ERREUR : $Message" -ForegroundColor Red
    Stop-Transcript | Out-Null; exit 1
}
$Sonar = "https://sonarcloud.io"
$ProjectKey = "YasmineZerai_tp2-devops-sre"
$Repo = "https://github.com/YasmineZerai/tp2-devops-sre"

cmd /c "git checkout -q main 2>&1" | Out-Null
# Le pipeline est livre dans ci\ci.yml : on l'installe a son emplacement GitHub Actions
New-Item -ItemType Directory -Force "$Root\.github\workflows" | Out-Null
Copy-Item "$Root\ci\ci.yml" "$Root\.github\workflows\ci.yml" -Force

# ---------------------------------------------------------------------------
# 1. Configuration presentee pour le rapport
# ---------------------------------------------------------------------------
Show-Section "Etape 2 - Configuration SonarQube (sonar-project.properties)"
Write-Host ""
Write-Host "PS> Get-Content sonar-project.properties" -ForegroundColor Yellow
Get-Content sonar-project.properties | Out-Host
Write-Host ""
Write-Host "Quality Gate 'TP2-SRE-Gate' (sur le New Code) :" -ForegroundColor Cyan
Write-Host "  - Coverage                    < 85 %   => ECHEC"
Write-Host "  - Security Hotspots Reviewed  < 100 %  => ECHEC (1 seul hotspot non revise suffit)"
Write-Host "  - Duplicated Lines (%)        > 3 %    => ECHEC"
Save-Capture "E2_15_config_sonar_properties"

Show-Section "Etape 2 - Pipeline CI GitHub Actions (.github/workflows/ci.yml)"
Write-Host ""
Write-Host "PS> Get-Content .github\workflows\ci.yml" -ForegroundColor Yellow
Get-Content .github\workflows\ci.yml | Out-Host
Save-Capture "E2_16_workflow_ci_yaml"

# ---------------------------------------------------------------------------
# 2. Push sur main => declenchement de la CI
# ---------------------------------------------------------------------------
Show-Section "Etape 2 - Push du pipeline sur main (declenche la CI)"
Invoke-Cmd "git add -A"
Invoke-Cmd "git commit -q -m ""ci: pipeline Lint & Test + SonarQube Quality Gate bloquante"""
Invoke-Cmd "git push origin main"
$sha = (git rev-parse HEAD).Trim()
Write-Host ""; Write-Host "Commit pousse : $sha" -ForegroundColor Green
Save-Capture "E2_17_push_pipeline_main"

Show-Section "Etape 2 - Execution de la CI sur main (suivi via l'API GitHub)"
$run = Wait-GitHubRun -Sha $sha -Event "push"
if (-not $run) { Stop-WithError "Workflow introuvable sur GitHub." }
Write-Host ""
Write-Host "Resultat du workflow : $($run.conclusion)" -ForegroundColor $(if ($run.conclusion -eq "success") { "Green" } else { "Red" })
Show-RunJobs $run
Save-Capture "E2_18_ci_main_resultat"

Save-BrowserCapture -Name "E2_19_ci_main_github_actions" -Url $run.html_url
Save-BrowserCapture -Name "E2_20_sonar_dashboard_main" -Url "$Sonar/summary/overall?id=$ProjectKey&branch=main" -WaitSeconds 15
Save-BrowserCapture -Name "E2_21_sonar_quality_gate_conditions" -Url "$Sonar/organizations/yasminezerai/quality_gates/show/167033" -WaitSeconds 15
Save-BrowserCapture -Name "E2_22_sonar_profil_regles_python" -Url "$Sonar/organizations/yasminezerai/quality_profiles/show?language=py&name=TP2+Python" -WaitSeconds 15
if ($run.conclusion -ne "success") { Stop-WithError "La CI a echoue sur main : envoie le journal a Claude." }

# ---------------------------------------------------------------------------
# 3. Branche volontairement non conforme (pour la PR de demonstration)
# ---------------------------------------------------------------------------
Show-Section "Etape 2 - Branche feature/bad-quality (code volontairement non conforme)"
cmd /c "git branch -D feature/bad-quality >NUL 2>&1"
Invoke-Cmd "git checkout -b feature/bad-quality"
Copy-Item docs\demo\legacy.py app\legacy.py -Force
Copy-Item docs\demo\test_legacy.py tests\test_legacy.py -Force
Write-Host ""
Write-Host "Ajout de app\legacy.py : code duplique, MD5, IP en dur, fonction non testee" -ForegroundColor Yellow
Invoke-Cmd "git add app/legacy.py tests/test_legacy.py"
Invoke-Cmd "git commit -q -m ""feat: module legacy de facturation (PR de demonstration NON CONFORME)"""
Invoke-Cmd "git push -u origin feature/bad-quality --force"
Invoke-Cmd "git --no-pager log --oneline -3"
Save-Capture "E2_23_branche_non_conforme_poussee"
Invoke-Cmd "git checkout -q main"

Stop-Transcript | Out-Null
Write-Host ""
Write-Host "Etape 2B (partie 1) terminee. Dis a Claude 'fini' : il cree la PR et la regle de protection." -ForegroundColor Green
