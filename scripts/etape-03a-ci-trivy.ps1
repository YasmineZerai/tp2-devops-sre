# scripts/etape-03a-ci-trivy.ps1
# Etape 3 (partie A) : pipeline complete Lint&Test -> Sonar -> Build -> Trivy -> Push GHCR -> GitOps
# Lancement : powershell -ExecutionPolicy Bypass -File .\scripts\etape-03a-ci-trivy.ps1

$ErrorActionPreference = "Continue"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root
. "$Root\tools\capture.ps1"
New-Item -ItemType Directory -Force "$Root\docs\logs" | Out-Null
Start-Transcript -Path "$Root\docs\logs\etape-03a.log" -Force | Out-Null
function Stop-WithError([string]$Message) {
    Write-Host ""; Write-Host "ERREUR : $Message" -ForegroundColor Red
    Stop-Transcript | Out-Null; exit 1
}
$Repo = "https://github.com/YasmineZerai/tp2-devops-sre"
$Api = "https://api.github.com/repos/YasmineZerai/tp2-devops-sre"

cmd /c "git checkout -q main 2>&1" | Out-Null
cmd /c "git pull -q --rebase origin main 2>&1" | Out-Null
New-Item -ItemType Directory -Force "$Root\.github\workflows" | Out-Null
Copy-Item "$Root\ci\ci.yml" "$Root\.github\workflows\ci.yml" -Force

# ---------------------------------------------------------------------------
# 1. Presentation de la pipeline et du chart Helm
# ---------------------------------------------------------------------------
Show-Section "Etape 3 - Pipeline CI/CD : jobs Build / Trivy / Push / GitOps (ci.yml)"
Write-Host ""
Write-Host "PS> Get-Content .github\workflows\ci.yml  (extrait : jobs build-scan-push et deploy-gitops)" -ForegroundColor Yellow
$lines = Get-Content .github\workflows\ci.yml
$start = ($lines | Select-String -Pattern "^  build-scan-push:").LineNumber
$lines[($start - 1)..($lines.Count - 1)] | Out-Host
Save-Capture "E3_01_pipeline_build_trivy_push_gitops"

Show-Section "Etape 3 - Chart Helm catalog-api (values.yaml + deployment.yaml)"
Write-Host ""
Write-Host "PS> Get-Content helm\catalog-api\values.yaml" -ForegroundColor Yellow
Get-Content helm\catalog-api\values.yaml | Out-Host
Save-Capture "E3_02_helm_values"

Show-Section "Etape 3 - Chart Helm : template du Deployment"
Write-Host ""
Write-Host "PS> Get-Content helm\catalog-api\templates\deployment.yaml" -ForegroundColor Yellow
Get-Content helm\catalog-api\templates\deployment.yaml | Out-Host
Save-Capture "E3_03_helm_deployment_template"

Show-Section "Etape 3 - Validation du chart (helm lint + helm template)"
Invoke-Cmd "helm lint helm/catalog-api"
if ($LASTEXITCODE -ne 0) { Stop-WithError "helm lint a echoue." }
Write-Host ""
Write-Host "PS> helm template catalog-api helm/catalog-api --set image.tag=demo123 | Select-String 'kind:|image:|cpu:|memory:|nodePort'" -ForegroundColor Yellow
helm template catalog-api helm/catalog-api --set image.tag=demo123 | Select-String -Pattern "kind:|image:|cpu:|memory:|nodePort" | ForEach-Object { $_.Line } | Out-Host
Write-Host ""
Write-Host "Test du rendu face a Gatekeeper (dry-run cote serveur) :" -ForegroundColor Cyan
helm template catalog-api helm/catalog-api --set image.tag=demo123 --namespace tp-app | Out-File -Encoding utf8 "$env:TEMP\catalog-render.yaml"
Invoke-Cmd "kubectl apply --dry-run=server -n tp-app -f $env:TEMP\catalog-render.yaml"
Save-Capture "E3_04_helm_lint_template"

# ---------------------------------------------------------------------------
# 2. Push sur main => pipeline complete
# ---------------------------------------------------------------------------
Show-Section "Etape 3 - Push sur main : declenchement de la pipeline complete"
Invoke-Cmd "git add -A"
Invoke-Cmd "git commit -q -m ""feat(cicd): build, scan Trivy, push GHCR et deploiement GitOps (chart Helm + ArgoCD)"""
Invoke-Cmd "git push origin main"
if ($LASTEXITCODE -ne 0) { Stop-WithError "git push refuse (regle de protection ?)." }
$sha = (git rev-parse HEAD).Trim()
Write-Host ""; Write-Host "Commit pousse : $sha" -ForegroundColor Green
Save-Capture "E3_05_push_main"

Show-Section "Etape 3 - Execution de la pipeline sur main"
$run = Wait-GitHubRun -Sha $sha -Event "push" -TimeoutMinutes 20
if (-not $run) { Stop-WithError "Workflow introuvable." }
Write-Host ""
Write-Host "Resultat de la pipeline : $($run.conclusion)" -ForegroundColor $(if ($run.conclusion -eq "success") { "Green" } else { "Red" })
Show-RunJobs $run
Save-Capture "E3_06_pipeline_main_resultat"

# Liens directs vers les etapes Trivy du job Build (pour afficher les logs deplies)
$jobs = Invoke-RestMethod -Uri "$Api/actions/runs/$($run.id)/jobs" -Headers @{ "User-Agent" = "tp2-script" }
$build = $jobs.jobs | Where-Object { $_.name -like "Build*" } | Select-Object -First 1
$stepReport = ($build.steps | Where-Object { $_.name -like "*rapport complet*" } | Select-Object -First 1).number
$stepGate = ($build.steps | Where-Object { $_.name -like "*porte bloquante*" } | Select-Object -First 1).number
$stepPush = ($build.steps | Where-Object { $_.name -like "Push*" } | Select-Object -First 1).number

Save-BrowserCapture -Name "E3_07_pipeline_main_github_actions" -Url $run.html_url -WaitSeconds 15
Save-BrowserCapture -Name "E3_08_trivy_rapport_vulnerabilites" -Url "$($build.html_url)#step:$($stepReport):1" -WaitSeconds 18
Save-BrowserCapture -Name "E3_09_trivy_porte_critical_ok" -Url "$($build.html_url)#step:$($stepGate):1" -WaitSeconds 18
Save-BrowserCapture -Name "E3_10_push_image_ghcr_log" -Url "$($build.html_url)#step:$($stepPush):1" -WaitSeconds 18
if ($run.conclusion -ne "success") { Stop-WithError "La pipeline a echoue sur main : dis-le a Claude." }

Save-BrowserCapture -Name "E3_11_ghcr_package_tag_sha" -Url "https://github.com/YasmineZerai/tp2-devops-sre/pkgs/container/catalog-api" -WaitSeconds 15
Save-BrowserCapture -Name "E3_12_branche_deploy_commit_bot" -Url "$Repo/commits/deploy" -WaitSeconds 15
Save-BrowserCapture -Name "E3_13_secrets_github_actions" -Url "$Repo/settings/secrets/actions" -WaitSeconds 12

Show-Section "Etape 3 - Branche deploy : le tag d'image ecrit par la CI"
cmd /c "git fetch -q origin deploy 2>&1" | Out-Null
Invoke-Cmd "git --no-pager log --oneline -3 origin/deploy"
Write-Host ""
Write-Host "PS> git show origin/deploy:helm/catalog-api/values.yaml | Select-String 'repository|tag:'" -ForegroundColor Yellow
git show origin/deploy:helm/catalog-api/values.yaml | Select-String -Pattern "repository|tag:" | ForEach-Object { $_.Line } | Out-Host
Write-Host ""
Write-Host "=> Le SHA du commit $($sha.Substring(0,7)) est maintenant la version 'desiree' dans Git." -ForegroundColor Green
Save-Capture "E3_14_branche_deploy_tag_sha"

# ---------------------------------------------------------------------------
# 3. Branche de demonstration : image avec une vulnerabilite CRITICAL
# ---------------------------------------------------------------------------
Show-Section "Etape 3 - Branche feature/trivy-vulnerable (dependance vulnerable)"
cmd /c "git branch -D feature/trivy-vulnerable >NUL 2>&1"
Invoke-Cmd "git checkout -q -b feature/trivy-vulnerable"
$df = Get-Content Dockerfile -Encoding UTF8
$idx = ($df | Select-String -Pattern "^COPY app/").LineNumber
$new = @()
$new += $df[0..($idx - 2)]
$new += "# DEMO TRIVY : dependance volontairement vulnerable (Django 2.2, CVE critiques)"
$new += "RUN pip install --no-cache-dir ""django==2.2"""
$new += $df[($idx - 1)..($df.Count - 1)]
[System.IO.File]::WriteAllLines("$Root\Dockerfile", [string[]]$new, (New-Object System.Text.UTF8Encoding($false)))
Write-Host ""
Write-Host "PS> git diff Dockerfile" -ForegroundColor Yellow
git --no-pager diff Dockerfile | Out-Host
Invoke-Cmd "git commit -q -am ""demo(trivy): ajout d'une dependance vulnerable (doit etre bloquee par Trivy)"""
Invoke-Cmd "git push -u origin feature/trivy-vulnerable --force"
Save-Capture "E3_15_branche_vulnerable_poussee"
Invoke-Cmd "git checkout -q main"

Stop-Transcript | Out-Null
Write-Host ""
Write-Host "Etape 3A terminee. Dis a Claude 'fini' : il rend l'image publique et cree la PR Trivy." -ForegroundColor Green
