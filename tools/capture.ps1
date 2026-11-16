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
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);

    // Fenetres visibles (avec titre) des processus donnes, dans l'ordre d'empilement (du dessus vers le dessous)
    public static IntPtr[] WindowsOf(uint[] pids) {
        System.Collections.Generic.List<IntPtr> list = new System.Collections.Generic.List<IntPtr>();
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            if (!IsWindowVisible(h) || GetWindowTextLength(h) == 0) return true;
            uint pid; GetWindowThreadProcessId(h, out pid);
            if (Array.IndexOf(pids, pid) >= 0) list.Add(h);
            return true;
        }, IntPtr.Zero);
        return list.ToArray();
    }
    public static string Title(IntPtr h) {
        System.Text.StringBuilder sb = new System.Text.StringBuilder(512);
        GetWindowText(h, sb, 512);
        return sb.ToString();
    }

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

function Get-EdgeWindows {
    $ids = @(Get-Process msedge -ErrorAction SilentlyContinue | ForEach-Object { [uint32]$_.Id })
    if ($ids.Count -eq 0) { return @() }
    return [TP2Win]::WindowsOf([uint32[]]$ids)
}

function Save-BrowserCapture {
    # Ouvre $Url dans une NOUVELLE fenetre Edge, la capture, puis ferme uniquement cette fenetre
    # (les fenetres et onglets deja ouverts ne sont jamais touches).
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Url,
        [int]$WaitSeconds = 12
    )
    $before = @(Get-EdgeWindows)
    Start-Process "msedge.exe" -ArgumentList @("--new-window", $Url)
    $hwnd = [IntPtr]::Zero
    for ($i = 0; $i -lt 20 -and $hwnd -eq [IntPtr]::Zero; $i++) {
        Start-Sleep -Milliseconds 500
        foreach ($h in @(Get-EdgeWindows)) { if ($before -notcontains $h) { $hwnd = $h; break } }
    }
    if ($hwnd -eq [IntPtr]::Zero) {
        Write-Host "[capture impossible] nouvelle fenetre Edge introuvable pour $Url" -ForegroundColor Red
        return
    }
    [void][TP2Win]::ShowWindow($hwnd, 3)
    Start-Sleep -Seconds $WaitSeconds
    Write-Host "  page : $([TP2Win]::Title($hwnd))" -ForegroundColor DarkGray
    Save-Bitmap (Capture-Window $hwnd) $Name
    [void][TP2Win]::PostMessage($hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)   # WM_CLOSE sur cette fenetre seulement
    Start-Sleep -Seconds 1
}

function Wait-GitHubRun {
    # Attend la fin du workflow GitHub Actions declenche par le commit $Sha (API publique GitHub)
    param([Parameter(Mandatory = $true)][string]$Sha, [string]$Event = "", [int]$TimeoutMinutes = 15)
    $repo = "YasmineZerai/tp2-devops-sre"
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $run = $null
    while ((Get-Date) -lt $deadline) {
        try {
            $url = "https://api.github.com/repos/$repo/actions/runs?head_sha=$Sha&per_page=5"
            if ($Event) { $url += "&event=$Event" }
            $runs = Invoke-RestMethod -Uri $url -Headers @{ "User-Agent" = "tp2-script" }
            $run = $runs.workflow_runs | Select-Object -First 1
        } catch { $run = $null }
        if ($run) {
            Write-Host ("  [{0}] workflow '{1}' : {2} {3}" -f (Get-Date -Format HH:mm:ss), $run.name, $run.status, $run.conclusion)
            if ($run.status -eq "completed") { return $run }
        } else {
            Write-Host ("  [{0}] en attente du demarrage du workflow..." -f (Get-Date -Format HH:mm:ss))
        }
        Start-Sleep -Seconds 20
    }
    return $run
}

function Show-RunJobs($run) {
    $jobs = Invoke-RestMethod -Uri "https://api.github.com/repos/YasmineZerai/tp2-devops-sre/actions/runs/$($run.id)/jobs" -Headers @{ "User-Agent" = "tp2-script" }
    foreach ($j in $jobs.jobs) {
        $color = if ($j.conclusion -eq "success") { "Green" } elseif ($j.conclusion -eq "failure") { "Red" } else { "Yellow" }
        Write-Host ("  {0,-40} {1}" -f $j.name, $j.conclusion) -ForegroundColor $color
        foreach ($st in $j.steps) {
            Write-Host ("      - {0,-60} {1}" -f $st.name, $st.conclusion) -ForegroundColor DarkGray
        }
    }
}
