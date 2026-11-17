# scripts/etape-02c-pr-bloquee.ps1
# Etape 2 (partie B2) : la PR non conforme #1 est bloquee par la Quality Gate SonarQube
# Lancement : powershell -ExecutionPolicy Bypass -File .\scripts\etape-02c-pr-bloquee.ps1

$ErrorActionPreference = "Continue"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root
. "$Root\tools\capture.ps1"
New-Item -ItemType Directory -Force "$Root\docs\logs" | Out-Null
Start-Transcript -Path "$Root\docs\logs\etape-02c.log" -Force | Out-Null
$Sonar = "https://sonarcloud.io"
$ProjectKey = "YasmineZerai_tp2-devops-sre"
$Repo = "https://github.com/YasmineZerai/tp2-devops-sre"
$Pr = 1

cmd /c "git fetch -q origin 2>&1" | Out-Null
$sha = (git rev-parse origin/feature/bad-quality).Trim()

Show-Section "Etape 2 - PR #$Pr non conforme : execution de la CI (Quality Gate)"
Write-Host "Commit de la PR : $sha"
$run = Wait-GitHubRun -Sha $sha -Event "pull_request"
if (-not $run) { Write-Host "Workflow de la PR introuvable" -ForegroundColor Red; Stop-Transcript | Out-Null; exit 1 }
Write-Host ""
Write-Host "Resultat du workflow de la PR : $($run.conclusion)" -ForegroundColor $(if ($run.conclusion -eq "failure") { "Red" } else { "Yellow" })
Show-RunJobs $run
Write-Host ""
Write-Host "=> La Quality Gate SonarQube a fait ECHOUER la pipeline : la PR ne peut pas etre mergee." -ForegroundColor Red
Save-Capture "E2_24_ci_pr_echec_quality_gate"

Write-Host "Attente de la decoration de la PR par SonarQube Cloud (60 s)..." -ForegroundColor DarkGray
Start-Sleep -Seconds 60

# --- GitHub : PR bloquee ---------------------------------------------------
Save-BrowserCapture -Name "E2_25_pr_github_conversation_sonar" -Url "$Repo/pull/$Pr" -WaitSeconds 15
Save-BrowserCapture -Name "E2_26_pr_github_merge_bloque" -Url "$Repo/pull/$Pr#partial-pull-merging" -WaitSeconds 15
Save-BrowserCapture -Name "E2_27_pr_github_checks_en_echec" -Url "$Repo/pull/$Pr/checks" -WaitSeconds 15
Save-BrowserCapture -Name "E2_28_pr_github_actions_job_sonar" -Url $run.html_url -WaitSeconds 15

# --- SonarQube Cloud : detail de l'echec -----------------------------------
Save-BrowserCapture -Name "E2_29_sonar_pr_quality_gate_failed" -Url "$Sonar/summary/new_code?id=$ProjectKey&pullRequest=$Pr" -WaitSeconds 18
Save-BrowserCapture -Name "E2_30_sonar_pr_security_hotspots" -Url "$Sonar/project/security_hotspots?id=$ProjectKey&pullRequest=$Pr" -WaitSeconds 18
Save-BrowserCapture -Name "E2_31_sonar_pr_duplications" -Url "$Sonar/component_measures?id=$ProjectKey&pullRequest=$Pr&metric=new_duplicated_lines_density&view=list" -WaitSeconds 18
Save-BrowserCapture -Name "E2_32_sonar_pr_couverture" -Url "$Sonar/component_measures?id=$ProjectKey&pullRequest=$Pr&metric=new_coverage&view=list" -WaitSeconds 18

# Quality Gate mise a jour (4 conditions, dont la note de securite du nouveau code)
Save-BrowserCapture -Name "E2_21_sonar_quality_gate_conditions" -Url "$Sonar/organizations/yasminezerai/quality_gates/show/167033" -WaitSeconds 15

# --- Regle de protection de main ------------------------------------------
Save-BrowserCapture -Name "E2_33_github_regle_protection_main" -Url "$Repo/settings/rules" -WaitSeconds 12

Stop-Transcript | Out-Null
Write-Host ""
Write-Host "Etape 2 terminee. Dis a Claude 'fini'." -ForegroundColor Green
