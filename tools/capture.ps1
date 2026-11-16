﻿# tools/capture.ps1 - fonctions partagees par les scripts d'etape
#   Save-Capture        : capture la fenetre du terminal qui execute le script (meme si elle est derriere)
#   Save-WindowCapture  : capture une autre fenetre (navigateur...) reperee par son titre
#   Show-Section        : efface la console et affiche un titre
#   Invoke-Step         : affiche une commande "PS> ..." puis l'execute

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
if (-not ("TP2Win" -as [type])) {
    Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @"
using System;
using System.Drawing;
using System.Runtime.InteropServices;
public class TP2Win {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);

    // Capture du contenu d'une fenetre, meme masquee par une autre (PW_RENDERFULLCONTENT = 2)
    public static Bitmap Print(IntPtr h) {
        RECT r; GetWindowRect(h, out r);
        int w = r.Right - r.Left, hh = r.Bottom - r.Top;
        if (w <= 0 || hh <= 0) return null;
        Bitmap bmp = new Bitmap(w, hh);
        using (Graphics g = Graphics.FromImage(bmp)) {
            IntPtr hdc = g.GetHdc();
            PrintWindow(h, hdc, 2);
            g.ReleaseHdc(hdc);
        }
        return bmp;
    }

    // Image vide (noire/uniforme) => la capture PrintWindow a echoue
    public static bool LooksBlank(Bitmap b) {
        Color first = b.GetPixel(b.Width / 2, b.Height / 2);
        int diff = 0;
        for (int i = 1; i < 40; i++) {
            Color c = b.GetPixel((b.Width * i) / 41, (b.Height * ((i * 7) % 40 + 1)) / 41);
            if (c.ToArgb() != first.ToArgb()) diff++;
        }
        return diff < 3;
    }

    // Plan B : mettre la fenetre au premier plan puis photographier sa zone d'ecran
    public static Bitmap Screen(IntPtr h) {
        keybd_event(0x12, 0, 0, UIntPtr.Zero); keybd_event(0x12, 0, 2, UIntPtr.Zero);
        SetForegroundWindow(h);
        System.Threading.Thread.Sleep(700);
        RECT r; GetWindowRect(h, out r);
        int w = r.Right - r.Left, hh = r.Bottom - r.Top;
        Bitmap bmp = new Bitmap(w, hh);
        using (Graphics g = Graphics.FromImage(bmp)) {
            g.CopyFromScreen(r.Left, r.Top, 0, 0, new Size(w, hh));
        }
        return bmp;
    }
}
"@
}
[void][TP2Win]::SetProcessDPIAware()
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}   # accents corrects

$script:RepoRoot    = Split-Path -Parent $PSScriptRoot
$script:CapturesDir = Join-Path $script:RepoRoot "docs\captures"
New-Item -ItemType Directory -Force $script:CapturesDir | Out-Null
$script:TermHwnd = [IntPtr]::Zero

function Get-TerminalWindow {
    # Remonte les processus parents jusqu'a trouver la fenetre (Windows Terminal ou console classique)
    $p = Get-CimInstance Win32_Process -Filter "ProcessId=$PID"
    for ($i = 0; $i -lt 8 -and $p; $i++) {
        $proc = Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue
        if ($proc -and $proc.MainWindowHandle -ne [IntPtr]::Zero) { return $proc.MainWindowHandle }
        $p = Get-CimInstance Win32_Process -Filter "ProcessId=$($p.ParentProcessId)" -ErrorAction SilentlyContinue
    }
    $wt = Get-Process WindowsTerminal -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } | Select-Object -First 1
    if ($wt) { return $wt.MainWindowHandle }
    return [IntPtr]::Zero
}

function Save-Bitmap($bmp, [string]$Name) {
    $path = Join-Path $script:CapturesDir "$Name.png"
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Host "[capture enregistree] docs\captures\$Name.png" -ForegroundColor Green
}

function Capture-Window([IntPtr]$hwnd) {
    if ([TP2Win]::IsIconic($hwnd) -or -not [TP2Win]::IsZoomed($hwnd)) {
        [void][TP2Win]::ShowWindow($hwnd, 3)   # agrandir (plein ecran)
        Start-Sleep -Milliseconds 800
    }
    $bmp = [TP2Win]::Print($hwnd)
    if ($bmp -eq $null -or [TP2Win]::LooksBlank($bmp)) {
        if ($bmp) { $bmp.Dispose() }
        $bmp = [TP2Win]::Screen($hwnd)
    }
    return $bmp
}

function Save-Capture {
    # Capture la fenetre du terminal qui execute ce script
    param([Parameter(Mandatory = $true)][string]$Name, [int]$DelaySeconds = 1)
    Start-Sleep -Seconds $DelaySeconds
    if ($script:TermHwnd -eq [IntPtr]::Zero) { $script:TermHwnd = Get-TerminalWindow }
    if ($script:TermHwnd -ne [IntPtr]::Zero) {
        Save-Bitmap (Capture-Window $script:TermHwnd) $Name
    } else {
        $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
        $g.Dispose()
        Save-Bitmap $bmp $Name
    }
}

function Save-WindowCapture {
    # Capture une fenetre dont le titre contient $TitleLike (ex. un onglet de navigateur)
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$TitleLike,
        [int]$TimeoutSeconds = 20
    )
    $hwnd = [IntPtr]::Zero
    for ($i = 0; $i -lt $TimeoutSeconds; $i++) {
        $w = Get-Process | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero -and $_.MainWindowTitle -like "*$TitleLike*" } |
            Select-Object -First 1
        if ($w) { $hwnd = $w.MainWindowHandle; break }
        Start-Sleep -Seconds 1
    }
    if ($hwnd -eq [IntPtr]::Zero) {
        Write-Host "[capture impossible] aucune fenetre ne contient '$TitleLike'" -ForegroundColor Red
        return
    }
    Start-Sleep -Seconds 2   # laisser la page finir de s'afficher
    Save-Bitmap (Capture-Window $hwnd) $Name
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
    param([Parameter(Mandatory = $true)][string]$Command)
    Write-Host ""
    Write-Host "PS> $Command" -ForegroundColor Yellow
    Invoke-Expression $Command | Out-Host
}

function Invoke-Cmd {
    # Comme Invoke-Step, mais pour une commande native dont on veut aussi voir les erreurs
    # (stderr) en texte normal : utile pour montrer un refus de l'API Kubernetes.
    param([Parameter(Mandatory = $true)][string]$Command)
    Write-Host ""
    Write-Host "PS> $Command" -ForegroundColor Yellow
    cmd /c "$Command 2>&1" | Out-Host
}
