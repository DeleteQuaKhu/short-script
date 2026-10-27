<#
  Tool Launcher (WinForms) - Windows PowerShell 5.1 / pwsh 7
  GUI : powershell -STA -File .\Launcher.ps1
  Run : .\Launcher.ps1 -Run <id|hotkey>     (headless, used by shortcuts / links)
  tools.json fields: hotkey, name, group, command (PowerShell), cwd, admin, console
#>
param([string]$Run)

if (-not $Run -and [Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    & (Get-Process -Id $PID).Path -NoProfile -STA -File $PSCommandPath
    exit $LASTEXITCODE
}

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

if (-not ('Win32Dark' -as [type])) {
    Add-Type @'
using System; using System.Runtime.InteropServices;
public static class Win32Dark {
    [DllImport("dwmapi.dll")]  public static extern int DwmSetWindowAttribute(IntPtr h, int a, ref int v, int s);
    [DllImport("uxtheme.dll", CharSet=CharSet.Unicode)] public static extern int SetWindowTheme(IntPtr h, string app, string idList);
}
'@
}

# ============================== Theme ==============================
function HexC($h) { [Drawing.ColorTranslator]::FromHtml($h) }
$C = @{
    Bg      = HexC '#262624'; Surface = HexC '#30302E'; Border = HexC '#43423E'
    Sel     = HexC '#3A3526'; Accent  = HexC '#D4AF37'; AccentHi = HexC '#F0CF65'
    Muted   = HexC '#9C9A92'; Err     = HexC '#E5645A'
    Flash   = HexC '#4D4426'; ErrBg   = HexC '#3A2624'
}
$font     = New-Object Drawing.Font('Segoe UI', 10)
$fontBold = New-Object Drawing.Font('Segoe UI', 10, [Drawing.FontStyle]::Bold)
$txtFlags = 'VerticalCenter, Left, EndEllipsis, NoPrefix'

# ============================== Animation config ==============================
$Anim = $true                          # $false = no timer, no chevrons, no mascot
$Chev = '', '>', '>>', '>>>'
$script:Tick = 0; $script:Face = 'idle'; $script:FaceUntil = 0
$script:JsonFixed = $false; $script:Sweep = $null; $script:ErrRow = -1; $script:ErrUntil = 0; $script:OnResult = $null
$TW        = 14                        # width of the speed-trail area left of the plane
$PlaneRows = @(                        # 10 rows x 38 cols: slightly tilted, far wing short, near wing + keel for depth
    " '-----..____                         "
    "|'---..___   '-----..____             "
    "|            '---..___   '-----..___  "
    "|                       '------------>"
    "<----------------------.         .-'  "
    "|                __..--' __..---'     "
    "|        __..--' __..---'             "
    "|__..--' __..---'                     "
    "|__..---'                             "
    "          '-.__________..-'           "
)
$TrailPat   = '=---  --  -----  -  ~- '
$SmokePat   = '.  o  .   ..  o '
$TrailVis   = @{
    idle  = 0,2,4,7,10,8,6,3,0,0
    gust  = 0,5,8,11,14,12,10,7,3,0
    boost = 0,5,8,11,14,12,10,7,3,0
    err   = 0,0,0,2,4,3,2,0,0,0
}
$PlaneSpark = @(@(0,30,0), @(1,34,2), @(0,36,1), @(8,30,3), @(7,34,1), @(6,36,3))
function Get-Plane([string]$state, [int]$t) {
    $vis  = $TrailVis[$state]
    $pat  = if ($state -eq 'err') { $SmokePat } else { $TrailPat }
    $fast = if ($state -eq 'boost' -or $state -eq 'gust') { 3 } else { 2 }
    $rows = @(for ($r = 0; $r -lt $PlaneRows.Count; $r++) {
        $tr = ' ' * $TW
        if ($vis[$r]) {                                   # streaks flow backwards (to the left)
            $w  = ($pat * 3).Substring(($t * $fast + $r * 3) % $pat.Length, $TW)
            $tr = (' ' * ($TW - $vis[$r])) + $w.Substring($TW - $vis[$r])
        }
        $tr + $PlaneRows[$r]
    })
    if ($state -eq 'err') { $c = $rows[3].ToCharArray(); $c[$TW + 37] = [char]'X'; $rows[3] = -join $c }
    $spk = ' ', '.', '+', '*'
    foreach ($k in $PlaneSpark) {
        $c = $rows[$k[0]].ToCharArray()
        $c[$TW + $k[1]] = [char]$spk[(($t -shr 1) + $k[2]) % 4]
        $rows[$k[0]] = -join $c
    }
    $rows -join "`r`n"
}

# ============================== Config ==============================
$cfg      = Join-Path $PSScriptRoot 'tools.json'
$utf8     = [Text.UTF8Encoding]::new($false)

if (-not (Test-Path $cfg)) {
    [IO.File]::WriteAllText($cfg, @'
[
  {"hotkey": "1", "name": "Calculator", "group": "Sys", "command": "Start-Process calc.exe"},
  {"hotkey": "2", "name": "Clock", "group": "Sys", "command": "Start-Process ms-clock:"},
  {"hotkey": "t", "name": "Terminal", "group": "Dev", "command": "Start-Process wt.exe"},
  {"hotkey": "c", "name": "VS Code", "group": "Dev", "cwd": "%USERPROFILE%\\Projects", "command": "Start-Process \"$env:LOCALAPPDATA\\Programs\\Microsoft VS Code\\Code.exe\" -ArgumentList '--new-window','.'"},
  {"hotkey": "r", "name": "Regedit", "group": "Sys", "command": "Start-Process regedit.exe", "admin": true},
  {"hotkey": "p", "name": "Listening ports", "group": "Net", "console": true, "command": "Get-NetTCPConnection -State Listen | Sort-Object LocalPort | Format-Table LocalAddress,LocalPort,OwningProcess -AutoSize"}
]
'@, $utf8)
}

# ============================== Helpers ==============================
function Set-Status([string]$msg, [bool]$isErr = $false) {
    if ($statusLbl) {
        $statusLbl.ForeColor = if ($isErr) { $C.Err } else { $C.Muted }
        $statusLbl.Text = $msg
    } elseif ($isErr) {   # -Run mode: no GUI
        [void][Windows.Forms.MessageBox]::Show($msg, 'Tool Launcher', 'OK', 'Error')
    }
}

function Convert-LegacyArg([string]$s) {
    if ($s -notmatch '%\w+%') { return "'" + $s.Replace("'", "''") + "'" }
    $e = $s.Replace('`', '``').Replace('"', '`"').Replace('$', '`$')
    '"' + [regex]::Replace($e, '%(\w+)%', { param($m) '${env:' + $m.Groups[1].Value + '}' }) + '"'
}

function Import-Tools {
    $txt = Get-Content $cfg -Raw -Encoding UTF8
    try { $raw = $txt | ConvertFrom-Json }
    catch {                                               # strict parse failed: retry once without trailing commas
        $fixed = [regex]::Replace($txt, ',(\s*[\]}])', '$1')
        if ($fixed -ceq $txt) { throw }
        $raw = $fixed | ConvertFrom-Json
        $script:JsonFixed = $true
    }
    $ids = @{}
    $out = foreach ($t in @($raw | ForEach-Object { $_ })) {   # ForEach-Object { $_ }: PS 5.1 returns the whole array as one object
        if (-not $t.name) { continue }
        if (-not $t.command) {                      # migrate old path/args entries to a PowerShell command
            if (-not $t.path) { continue }
            $cmd = 'Start-Process -FilePath ' + (Convert-LegacyArg ([string]$t.path))
            if ($t.args) { $cmd += ' -ArgumentList ' + (Convert-LegacyArg ([string]$t.args)) }
            Add-Member -InputObject $t -NotePropertyName command -NotePropertyValue $cmd -Force
            [void]$t.PSObject.Properties.Remove('path'); [void]$t.PSObject.Properties.Remove('args')
        }
        $hk = if ($null -ne $t.hotkey) { "$($t.hotkey)".Trim().ToLower() } else { '' }
        Add-Member -InputObject $t -NotePropertyName hotkey -NotePropertyValue $hk -Force
        if ($null -eq $t.group) { Add-Member -InputObject $t -NotePropertyName group -NotePropertyValue '' -Force }
        # stable id for links/shortcuts: unchanged when the hotkey is edited
        $id = if ($t.id) { "$($t.id)" } else { ("$($t.name)".ToLower() -replace '[^a-z0-9]+', '-').Trim('-') }
        if (-not $id) { $id = 'tool' }
        $base = $id; $n = 2
        while ($ids.ContainsKey($id)) { $id = "$base-$n"; $n++ }
        $ids[$id] = 1
        Add-Member -InputObject $t -NotePropertyName id -NotePropertyValue $id -Force
        $t
    }
    @($out)
}

function Save-Tools {
    if (Test-Path $cfg) { Copy-Item $cfg "$cfg.bak" -Force }
    [IO.File]::WriteAllText($cfg, (ConvertTo-Json -InputObject @($tools) -Depth 5), $utf8)
}

function Test-Dups {
    $d = @($tools | Where-Object { $_.hotkey } | Group-Object { $_.hotkey.ToLower() } | Where-Object Count -gt 1)
    if ($d.Count) { Set-Status ('Duplicate hotkey: ' + (($d | ForEach-Object Name) -join ', ')) $true }
    $d.Count -eq 0
}

function Start-Tool($t) {
    # the command runs in a separate PowerShell process (same edition as the launcher); -EncodedCommand avoids all quoting issues
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes([string]$t.command))
    $ps  = @('-NoProfile', '-ExecutionPolicy', 'Bypass')
    if ($t.console) { $ps += '-NoExit' }               # keep the window open so output/errors stay visible
    $ps += '-EncodedCommand', $enc
    $p = @{ FilePath = (Get-Process -Id $PID).Path; ArgumentList = $ps; WindowStyle = $(if ($t.console) { 'Normal' } else { 'Hidden' }) }
    if ($t.cwd)   { $p.WorkingDirectory = [Environment]::ExpandEnvironmentVariables([string]$t.cwd) }
    if ($t.admin) { $p.Verb             = 'RunAs' }
    try {
        Start-Process @p -ErrorAction Stop
        Set-Status "Started: $($t.name)"
        if ($script:OnResult) { $null = & $script:OnResult $true $t }
        $true
    } catch {
        Set-Status "Error: $($_.Exception.Message)" $true
        if ($script:OnResult) { $null = & $script:OnResult $false $t }
        $false
    }
}

# ============================== Load ==============================
$tools = @(); $loadErr = $null
try { $tools = Import-Tools }
catch {
    $m = $_.Exception.Message -replace '\s+', ' '
    if ($m.Length -gt 110) { $m = $m.Substring(0, 110) + '...' }
    $loadErr = "tools.json: $m"
}

# ============================== Headless: -Run ==============================
if ($Run) {
    if ($loadErr) { Set-Status $loadErr $true; exit 4 }
    $q = [Uri]::UnescapeDataString($Run)
    $q = ($q -replace '^toollauncher:(//)?(run/)?', '') -replace '/+$', ''
    # whitelist: blocks argument injection via URI; only matches tools declared in tools.json, never arbitrary paths
    if ($q -notmatch '^[a-z0-9._-]+$') { Set-Status "Invalid link: $Run" $true; exit 2 }
    $t = $tools | Where-Object { $_.id -ieq $q -or $_.hotkey -ieq $q } | Select-Object -First 1
    if (-not $t) { Set-Status "No such tool: $q" $true; exit 3 }
    $ok = Start-Tool $t
    exit ([int](-not $ok))
}

# ============================== UI ==============================
function New-Btn([string]$text, [int]$w = 110) {
    $b = New-Object Windows.Forms.Button -Property @{
        Text = $text; Width = $w; Height = 30; FlatStyle = 'Flat'
        BackColor = $C.Surface; ForeColor = $C.Accent; UseVisualStyleBackColor = $false
    }
    $b.FlatAppearance.BorderColor = $C.Border
    $b.FlatAppearance.MouseOverBackColor = $C.Sel
    $b
}
function Set-DarkTitle($f) {
    $f.Add_HandleCreated({
        param($s, $e)
        try { $v = 1; [void][Win32Dark]::DwmSetWindowAttribute($s.Handle, 20, [ref]$v, 4) } catch {}
    })
}

$form = New-Object Windows.Forms.Form -Property @{
    Text = 'Tool Launcher'; StartPosition = 'CenterScreen'; KeyPreview = $true
    Size = [Drawing.Size]::new(700, 560); BackColor = $C.Bg; ForeColor = $C.Accent; Font = $font
}
Set-DarkTitle $form

$searchPanel = New-Object Windows.Forms.Panel -Property @{
    Dock = 'Top'; Height = 46; BackColor = $C.Bg; Padding = [Windows.Forms.Padding]::new(10, 10, 10, 6)
}
$search = New-Object Windows.Forms.TextBox -Property @{
    Dock = 'Fill'; BackColor = $C.Surface; ForeColor = $C.Accent
    BorderStyle = 'FixedSingle'; Font = New-Object Drawing.Font('Segoe UI', 11)
}
$gap    = New-Object Windows.Forms.Panel -Property @{ Dock = 'Right'; Width = 6; BackColor = $C.Bg }
$btnCfg = New-Btn ([string][char]0x2699) 36
$btnCfg.Dock = 'Right'; $btnCfg.Font = New-Object Drawing.Font('Segoe UI Symbol', 10)
$searchPanel.Controls.AddRange(@($search, $gap, $btnCfg))   # controls added later are docked first

$list = New-Object Windows.Forms.ListView -Property @{
    Dock = 'Fill'; View = 'Details'; FullRowSelect = $true; HideSelection = $false
    BorderStyle = 'None'; BackColor = $C.Bg; ForeColor = $C.Accent
    OwnerDraw = $true; HeaderStyle = 'Nonclickable'; MultiSelect = $false
}
[void]$list.Columns.Add('Key', 60); [void]$list.Columns.Add('Name', 330); [void]$list.Columns.Add('Group', 200)
[Windows.Forms.ListView].GetProperty('DoubleBuffered', [Reflection.BindingFlags]'NonPublic,Instance').SetValue($list, $true)

$status    = New-Object Windows.Forms.StatusStrip -Property @{ BackColor = $C.Surface; SizingGrip = $false }
$statusLbl = New-Object Windows.Forms.ToolStripStatusLabel -Property @{ Text = 'Ready'; ForeColor = $C.Muted }
[void]$status.Items.Add($statusLbl)

$form.Controls.AddRange(@($list, $searchPanel, $status))

# --- Owner-draw ---
$list.Add_DrawColumnHeader({
    param($s, $e)
    $b = New-Object Drawing.SolidBrush $C.Surface
    $e.Graphics.FillRectangle($b, $e.Bounds); $b.Dispose()
    $pen = New-Object Drawing.Pen $C.Border
    $e.Graphics.DrawLine($pen, $e.Bounds.Left, $e.Bounds.Bottom - 1, $e.Bounds.Right, $e.Bounds.Bottom - 1); $pen.Dispose()
    $r = [Drawing.Rectangle]::new($e.Bounds.X + 6, $e.Bounds.Y, $e.Bounds.Width - 8, $e.Bounds.Height)
    [Windows.Forms.TextRenderer]::DrawText($e.Graphics, $e.Header.Text, $font, $r, $C.Muted, $txtFlags)
})

$list.Add_DrawSubItem({
    param($s, $e)
    $idx = $e.Item.Index
    $bg  = if ($e.Item.Selected) { $C.Sel } else { $C.Bg }
    if ($idx -eq $script:ErrRow) { $bg = $C.ErrBg }
    if ($script:Sweep -and $script:Sweep.Row -eq $idx -and $script:Sweep.Col -eq $e.ColumnIndex) { $bg = $C.Flash }
    $b = New-Object Drawing.SolidBrush $bg
    $e.Graphics.FillRectangle($b, $e.Bounds); $b.Dispose()
    switch ($e.ColumnIndex) {
        0       { $fg = $C.AccentHi; $f = $fontBold }
        1       { $fg = $C.Accent;   $f = $font }
        default { $fg = $C.Muted;    $f = $font }
    }
    $r = [Drawing.Rectangle]::new($e.Bounds.X + 6, $e.Bounds.Y, $e.Bounds.Width - 8, $e.Bounds.Height)
    [Windows.Forms.TextRenderer]::DrawText($e.Graphics, $e.SubItem.Text, $f, $r, $fg, $txtFlags)
    if ($Anim -and $e.ColumnIndex -eq 0 -and $e.Item.Selected) {   # marching chevrons next to the key
        $ch = $Chev[($script:Tick -shr 1) % 4]
        if ($ch) {
            $r2 = [Drawing.Rectangle]::new($e.Bounds.X + 28, $e.Bounds.Y, 40, $e.Bounds.Height)
            [Windows.Forms.TextRenderer]::DrawText($e.Graphics, $ch, $fontBold, $r2, $C.Accent, $txtFlags)
        }
    }
})

function Fit-Columns {
    $w = $list.ClientSize.Width - $list.Columns[0].Width - $list.Columns[1].Width
    if ($w -gt 40) { $list.Columns[2].Width = $w }
}
$list.Add_Resize({ Fit-Columns; Place-Pet })
$form.Add_Shown({ Fit-Columns; Place-Pet })

$list.Add_HandleCreated({
    param($s, $e)
    try { [void][Win32Dark]::SetWindowTheme($s.Handle, 'DarkMode_Explorer', $null) } catch {}
})

# --- List logic ---
function Update-List([string]$q) {
    $list.BeginUpdate()
    try {
        $list.Items.Clear()
        foreach ($t in $tools) {
            if ($q -and "$($t.name)".IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -lt 0 `
                   -and "$($t.group)".IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
            $it = $list.Items.Add([string]$t.hotkey)
            [void]$it.SubItems.Add([string]$t.name); [void]$it.SubItems.Add([string]$t.group)
            $it.Tag = $t
        }
        if ($list.Items.Count) { $list.Items[0].Selected = $true }
    } finally { $list.EndUpdate() }
    Place-Pet
}

function Invoke-Selected { if ($list.SelectedItems.Count) { [void](Start-Tool $list.SelectedItems[0].Tag) } }

function Move-Selection([int]$d) {
    if (-not $list.Items.Count) { return }
    $i = if ($list.SelectedIndices.Count) { $list.SelectedIndices[0] + $d } else { 0 }
    $i = [Math]::Max(0, [Math]::Min($list.Items.Count - 1, $i))
    $list.Items[$i].Selected = $true; $list.Items[$i].EnsureVisible()
}

# ============================== Mascot + animation ==============================
$pet = New-Object Windows.Forms.Label -Property @{
    AutoSize = $true; UseMnemonic = $false; Font = New-Object Drawing.Font('Consolas', 10)
    BackColor = $C.Bg; ForeColor = $C.Accent; Visible = $false
}
$petSay = New-Object Windows.Forms.Label -Property @{
    AutoSize = $true; UseMnemonic = $false; Text = 'ready'; Font = New-Object Drawing.Font('Segoe UI', 9)
    BackColor = $C.Bg; ForeColor = $C.Muted; Visible = $false
}
$list.Controls.AddRange(@($pet, $petSay))
[Windows.Forms.Control].GetProperty('DoubleBuffered', [Reflection.BindingFlags]'NonPublic,Instance').SetValue($pet, $true)
$pet.Text = Get-Plane 'idle' 0

function Place-Pet([int]$dx = 0, [int]$dy = 0) {
    # show the mascot only when the empty area below the rows is big enough
    $bottom = if ($list.Items.Count) { $list.Items[$list.Items.Count - 1].Bounds.Bottom } else { 26 }
    $free   = $list.ClientSize.Height - $bottom
    $show   = $Anim -and $list.ClientSize.Width -gt ($pet.Width + 40) -and $free -gt ($pet.Height + 12)
    $pet.Visible = $show; $petSay.Visible = $show
    if (-not $show) { return }
    $pet.Location    = [Drawing.Point]::new($list.ClientSize.Width - $pet.Width - 18 + $dx, $list.ClientSize.Height - $pet.Height - 8 + $dy)
    $petSay.Location = [Drawing.Point]::new($pet.Left + 4, $pet.Top + 4)
}

function Set-Face([string]$f, [int]$ticks, [string]$say) {
    $script:Face = $f; $script:FaceUntil = $script:Tick + $ticks; $petSay.Text = $say
}

$script:OnResult = {
    param($ok, $t)
    $idx = -1
    foreach ($it in $list.Items) { if ($it.Tag.id -ceq $t.id) { $idx = $it.Index; break } }
    if ($ok) {
        if ($idx -ge 0) { $script:Sweep = @{ Row = $idx; Col = 0 } }
        Set-Face 'boost' 10 'go!'
    } else {
        if ($idx -ge 0) { $script:ErrRow = $idx; $script:ErrUntil = $script:Tick + 8 }
        Set-Face 'err' 10 'oops'
    }
    if ($idx -ge 0) { $list.RedrawItems($idx, $idx, $true) }
}

$timer = New-Object Windows.Forms.Timer -Property @{ Interval = 130 }
$timer.Add_Tick({
    try {
        $script:Tick++
        $n = $list.Items.Count
        if ($list.SelectedIndices.Count -and (($script:Tick -band 1) -eq 0)) {   # chevron frame changes every 2 ticks
            $i = $list.SelectedIndices[0]; $list.RedrawItems($i, $i, $true)
        }
        if ($script:Sweep) {                                                      # Key -> Name -> Group sweep
            $r = $script:Sweep.Row; $script:Sweep.Col++
            if ($script:Sweep.Col -gt 2) { $script:Sweep = $null }
            if ($r -ge 0 -and $r -lt $n) { $list.RedrawItems($r, $r, $true) }
        }
        if ($script:ErrRow -ge 0 -and $script:Tick -ge $script:ErrUntil) {
            $r = $script:ErrRow; $script:ErrRow = -1
            if ($r -lt $n) { $list.RedrawItems($r, $r, $true) }
        }
        if ($script:Face -ne 'idle' -and $script:Tick -ge $script:FaceUntil) { Set-Face 'idle' 0 'ready' }
        elseif ($script:Face -eq 'idle' -and ($script:Tick % 24) -eq 0)       { Set-Face 'gust' 5 'whoosh' }   # gust of speed ~every 3 s

        $txt = Get-Plane $script:Face $script:Tick
        if ($pet.Text -cne $txt) { $pet.Text = $txt }
        $k = (1 + [Math]::Sin($script:Tick / 3.0)) / 2                            # soft golden glow
        $a = $C.Accent; $b = $C.AccentHi
        $pet.ForeColor = [Drawing.Color]::FromArgb([int]($a.R + ($b.R - $a.R) * $k), [int]($a.G + ($b.G - $a.G) * $k), [int]($a.B + ($b.B - $a.B) * $k))
        $dy = if ((($script:Tick -shr 2) -band 1) -eq 1) { -3 } else { 0 }        # float up/down
        $dx = if ($script:Face -eq 'err') { ($script:Tick -band 1) * 6 - 3 } elseif ($script:Face -eq 'boost') { 12 } else { 0 }   # shake on error, lunge forward on launch
        Place-Pet $dx $dy
    } catch {}
})
$form.Add_Deactivate({ $timer.Stop() })
$form.Add_Activated({ if ($Anim) { $timer.Start() } })

# ============================== Settings dialog ==============================
function Show-Settings {
    $dlg = New-Object Windows.Forms.Form -Property @{
        Text = 'Settings - Hotkeys & Commands'; StartPosition = 'CenterParent'; FormBorderStyle = 'FixedDialog'
        MinimizeBox = $false; MaximizeBox = $false; ShowInTaskbar = $false; KeyPreview = $true
        ClientSize = [Drawing.Size]::new(880, 360); BackColor = $C.Bg; ForeColor = $C.Accent; Font = $font
    }
    Set-DarkTitle $dlg

    $g = New-Object Windows.Forms.DataGridView -Property @{
        Dock = 'Fill'; BackgroundColor = $C.Bg; BorderStyle = 'None'; GridColor = $C.Border
        AllowUserToAddRows = $false; AllowUserToDeleteRows = $false; AllowUserToResizeRows = $false
        RowHeadersVisible = $false; SelectionMode = 'FullRowSelect'; MultiSelect = $false
        EnableHeadersVisualStyles = $false; AutoSizeColumnsMode = 'Fill'
    }
    $g.ColumnHeadersHeightSizeMode = 'DisableResizing'; $g.ColumnHeadersHeight = 30
    $hs = $g.ColumnHeadersDefaultCellStyle
    $hs.BackColor = $C.Surface; $hs.ForeColor = $C.Muted; $hs.SelectionBackColor = $C.Surface; $hs.SelectionForeColor = $C.Muted
    $cs = $g.DefaultCellStyle
    $cs.BackColor = $C.Bg; $cs.ForeColor = $C.Accent; $cs.SelectionBackColor = $C.Sel; $cs.SelectionForeColor = $C.AccentHi
    [void]$g.Columns.Add('hk', 'Key'); [void]$g.Columns.Add('name', 'Name')
    [void]$g.Columns.Add('grp', 'Group'); [void]$g.Columns.Add('cmd', 'Command (PowerShell)')
    $w = 10, 25, 15, 50
    for ($i = 0; $i -lt 4; $i++) {
        $g.Columns[$i].FillWeight = $w[$i]
    }
    $g.Columns[0].DefaultCellStyle.Font = $fontBold
    $g.Columns[0].DefaultCellStyle.ForeColor = $C.AccentHi
    foreach ($t in $tools) {
        $i = $g.Rows.Add([string]$t.hotkey, [string]$t.name, [string]$t.group, [string]$t.command)
        $g.Rows[$i].Tag = $t
    }
    $g.Add_HandleCreated({
        param($s, $e)
        try { [void][Win32Dark]::SetWindowTheme($s.Handle, 'DarkMode_Explorer', $null) } catch {}
    })

    $hintDef = 'Double-click any cell to edit, Enter to apply (auto-saved to tools.json), Esc to close.'
    $hint = New-Object Windows.Forms.Label -Property @{
        Dock = 'Bottom'; Height = 28; ForeColor = $C.Muted; TextAlign = 'MiddleLeft'
        Padding = [Windows.Forms.Padding]::new(10, 0, 0, 0); Text = $hintDef
    }
    $say = { param($m, $isErr) $hint.ForeColor = $(if ($isErr) { $C.Err } else { $C.Muted }); $hint.Text = $m }
    $dlg.Controls.AddRange(@($g, $hint))   # hint is docked first, grid fills the rest

    # --- validate before the edit is committed ---
    $g.Add_CellValidating({
        param($s, $e)
        $v = "$($e.FormattedValue)".Trim()
        $err = $null
        if ($e.ColumnIndex -eq 0) {
            if ($v -and $v -notmatch '^[a-z0-9]$') { $err = "Invalid key: '$v' (a-z, 0-9 only)" }
            else {
                for ($i = 0; $v -and $i -lt $s.Rows.Count; $i++) {
                    if ($i -ne $e.RowIndex -and "$($s.Rows[$i].Cells[0].Value)" -ieq $v) { $err = "'$v' is already used by '$($s.Rows[$i].Cells[1].Value)'"; break }
                }
            }
        }
        elseif (($e.ColumnIndex -eq 1 -or $e.ColumnIndex -eq 3) -and -not $v) { $err = 'This field cannot be empty' }
        if ($err) { $e.Cancel = $true; & $say $err $true } else { & $say $hintDef $false }
    })

    # --- apply + auto-save after Enter ---
    $props = 'hotkey', 'name', 'group', 'command'
    $g.Add_CellEndEdit({
        param($s, $e)
        $r = $s.Rows[$e.RowIndex]; $t = $r.Tag; $col = $e.ColumnIndex; $prop = $props[$col]
        $v = "$($r.Cells[$col].Value)".Trim()
        if ($col -eq 0) { $v = $v.ToLower() }
        $r.Cells[$col].Value = $v
        if ($v -ceq [string]$t.$prop) { return }   # unchanged or Esc: nothing to save
        $t.$prop = $v
        try {
            Save-Tools
            $warn = $null
            if ($col -eq 3) {                                   # syntax check only, nothing is executed
                $tok = $null; $perr = $null
                [void][Management.Automation.Language.Parser]::ParseInput($v, [ref]$tok, [ref]$perr)
                if ($perr.Count) { $warn = $perr[0].Message }
            }
            if ($warn) { & $say "Saved: $($t.name) (syntax warning: $warn)" $true } else { & $say "Saved: $($t.name)" $false }
        } catch { & $say "Save failed: $($_.Exception.Message)" $true }
    })

    # FullRowSelect suppresses mouse-initiated editing, so start it explicitly
    $g.Add_CellDoubleClick({
        param($s, $e)
        if ($e.RowIndex -lt 0 -or $e.ColumnIndex -lt 0) { return }
        $s.CurrentCell = $s.Rows[$e.RowIndex].Cells[$e.ColumnIndex]
        [void]$s.BeginEdit($true)
    })

    $dlg.Add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq 'Escape' -and -not $g.IsCurrentCellInEditMode) { $dlg.Close() }
    })

    [void]$dlg.ShowDialog($form)
    $dlg.Dispose()
}

function Open-Settings {
    if ($loadErr) { Set-Status "Fix tools.json before opening Settings ($loadErr)" $true; return }
    [void](Show-Settings)
    Update-List $search.Text
    if (Test-Dups) { Set-Status 'Ready' }
    [void]$list.Focus()
}

# ============================== Events ==============================
$search.Add_TextChanged({ Update-List $search.Text })
$list.Add_ItemActivate({ Invoke-Selected })
$btnCfg.Add_Click({ Open-Settings })

$form.Add_KeyDown({
    param($s, $e)
    if ($e.Control -and $e.KeyCode -eq 'F') { [void]$search.Focus(); $search.SelectAll(); $e.SuppressKeyPress = $true; return }
    if ($e.KeyCode -eq 'F2')     { Open-Settings; $e.SuppressKeyPress = $true; return }
    if ($e.KeyCode -eq 'Escape') { $search.Clear(); [void]$list.Focus(); $e.SuppressKeyPress = $true; return }

    if ($form.ActiveControl -eq $search -and -not $e.Alt) {   # typing in search: navigation only, no hotkeys
        if     ($e.KeyCode -eq 'Return') { Invoke-Selected; $e.SuppressKeyPress = $true }
        elseif ($e.KeyCode -eq 'Down')   { Move-Selection 1;  $e.SuppressKeyPress = $true }
        elseif ($e.KeyCode -eq 'Up')     { Move-Selection -1; $e.SuppressKeyPress = $true }
        return
    }
    if (($e.Control -or $e.Shift) -and -not $e.Alt) { return }   # Ctrl+C, Shift+x... are not hotkeys

    $k = $e.KeyCode.ToString() -replace '^(?:D|NumPad)(\d)$', '$1'
    $t = $tools | Where-Object { $_.hotkey -and $_.hotkey -ieq $k } | Select-Object -First 1
    if ($t) { [void](Start-Tool $t); $e.SuppressKeyPress = $true }
})

# ============================== Go ==============================
Update-List ''
if ($loadErr)         { Set-Status $loadErr $true }
elseif (Test-Dups)    { Set-Status ("Loaded $($tools.Count) tools  |  F2: Settings" + $(if ($script:JsonFixed) { "  |  tools.json had a trailing comma (fixed in memory)" })) }
[void]$list.Focus()
if ($Anim) { $timer.Start() }
[void]$form.ShowDialog()
