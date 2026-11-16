# tools/capture.ps1 - fonctions partagees par les scripts d'etape
# Save-Capture : enregistre une capture de l'ecran principal dans docs\captures\<Nom>.png
# Show-Section : efface la console et affiche un titre (pour des captures lisibles)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
if (-not ("TP2Dpi" -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public class TP2Dpi {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
"@
}
[void][TP2Dpi]::SetProcessDPIAware()   # sinon la capture est tronquee sur les ecrans a 125/150 %

$script:RepoRoot    = Split-Path -Parent $PSScriptRoot
$script:CapturesDir = Join-Path $script:RepoRoot "docs\captures"
New-Item -ItemType Directory -Force $script:CapturesDir | Out-Null

function Save-Capture {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [int]$DelaySeconds = 1
    )
    Start-Sleep -Seconds $DelaySeconds
    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bmp = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
    $path = Join-Path $script:CapturesDir "$Name.png"
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose()
    $bmp.Dispose()
    Write-Host "[capture enregistree] docs\captures\$Name.png" -ForegroundColor Green
}

function Show-Section {
    param([Parameter(Mandatory = $true)][string]$Title)
    Clear-Host
    $line = "=" * 78
    Write-Host $line -ForegroundColor Cyan
    Write-Host "  TP2 DevOps Avance  |  $Title" -ForegroundColor Cyan
    Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  |  $env:COMPUTERNAME" -ForegroundColor DarkCyan
    Write-Host $line -ForegroundColor Cyan
}

function Invoke-Step {
    # Affiche la commande comme dans un terminal, puis l'execute
    param([Parameter(Mandatory = $true)][string]$Command)
    Write-Host ""
    Write-Host "PS> $Command" -ForegroundColor Yellow
    Invoke-Expression $Command
}
