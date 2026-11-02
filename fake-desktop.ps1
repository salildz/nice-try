# fake-desktop.ps1
# Takes a screenshot of every monitor and shows it full screen as a "frozen desktop".
# Nothing triggers during the first $GRACE seconds (so you have time to walk away).
# After that, if the mouse moves, a mouse button is clicked or a key is pressed:
# shows "Nice try :D" (plus the GIF, if present) and then actually locks the PC.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class K { [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey); }
"@

# Secret exit combo: Ctrl + Alt + Q  (clean exit, no gotcha and no lock)
# Want a different key? Replace 0x51 (= Q) in Test-ExitCombo with another VK code,
# and Keys::Q in the KeyDown handler below with the matching key.

$script:triggered  = $false
$script:forms      = @()
$script:timer      = $null
$script:lockTimer  = $null
$script:startTime  = Get-Date
$GRACE = 2         # seconds: nothing triggers during this period
$HOLD_MS = 6000    # how many ms the gotcha screen stays up before locking. 1000 = 1 s
$IMAGE = Join-Path $PSScriptRoot "laughinggif2.gif"   # png/jpg/gif in the same folder; GIFs animate. If missing, only the text is shown

function Exit-Clean {
    # No gotcha, no lock: close the windows and return to the real desktop
    if ($script:timer) { $script:timer.Stop() }
    if ($script:lockTimer) { $script:lockTimer.Stop() }
    [System.Windows.Forms.Application]::Exit()
}

function Test-ExitCombo {
    # Are Ctrl (0x11) + Alt (0x12) + Q (0x51) all held down at the same time?
    $ctrl = ([K]::GetAsyncKeyState(0x11) -band 0x8000) -ne 0
    $alt  = ([K]::GetAsyncKeyState(0x12) -band 0x8000) -ne 0
    $q    = ([K]::GetAsyncKeyState(0x51) -band 0x8000) -ne 0
    return ($ctrl -and $alt -and $q)
}

function Invoke-Gotcha {
    if ($script:triggered) { return }
    if (((Get-Date) - $script:startTime).TotalSeconds -lt $GRACE) { return }
    $script:triggered = $true
    if ($script:timer) { $script:timer.Stop() }

    $dark = [System.Drawing.Color]::FromArgb(15, 15, 22)
    $hasImage = (Test-Path $IMAGE)
    $bytes = $null
    if ($hasImage) { $bytes = [System.IO.File]::ReadAllBytes($IMAGE) }
    $script:streams = @()   # keep the GIF streams referenced so they don't get garbage collected

    foreach ($f in $script:forms) {
        $f.Controls.Clear()
        $f.BackColor = $dark

        if ($hasImage) {
            # Top half text, bottom half image/GIF
            $tlp = New-Object System.Windows.Forms.TableLayoutPanel
            $tlp.Dock = 'Fill'
            $tlp.BackColor = $dark
            $tlp.RowCount = 2
            $tlp.ColumnCount = 1
            $tlp.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 50))) | Out-Null
            $tlp.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 50))) | Out-Null

            $lbl = New-Object System.Windows.Forms.Label
            $lbl.Dock = 'Fill'
            $lbl.TextAlign = 'MiddleCenter'
            $lbl.ForeColor = [System.Drawing.Color]::White
            $lbl.Font = New-Object System.Drawing.Font('Segoe UI Emoji', 40, [System.Drawing.FontStyle]::Bold)
            $lbl.Text = "Nice try" + [Environment]::NewLine + ":D"

            $ms = New-Object System.IO.MemoryStream (,$bytes)   # separate copy per screen -> the GIF animates on each one
            $script:streams += $ms
            $pb = New-Object System.Windows.Forms.PictureBox
            $pb.Dock = 'Fill'
            $pb.SizeMode = 'Zoom'
            $pb.BackColor = $dark
            $pb.Image = [System.Drawing.Image]::FromStream($ms)

            $tlp.Controls.Add($lbl, 0, 0)
            $tlp.Controls.Add($pb,  0, 1)
            $f.Controls.Add($tlp)
        } else {
            $lbl = New-Object System.Windows.Forms.Label
            $lbl.Dock = 'Fill'
            $lbl.TextAlign = 'MiddleCenter'
            $lbl.ForeColor = [System.Drawing.Color]::White
            $lbl.Font = New-Object System.Drawing.Font('Segoe UI Emoji', 40, [System.Drawing.FontStyle]::Bold)
            $lbl.Text = "Nice try" + [Environment]::NewLine + ":D"
            $f.Controls.Add($lbl)
        }
        $f.Refresh()
    }

    $script:lockTimer = New-Object System.Windows.Forms.Timer
    $script:lockTimer.Interval = $HOLD_MS
    $script:lockTimer.Add_Tick({
        $script:lockTimer.Stop()
        rundll32.exe user32.dll, LockWorkStation
        [System.Windows.Forms.Application]::Exit()
    })
    $script:lockTimer.Start()
}

# --- 1) Take a screenshot of every screen ---
$screens = [System.Windows.Forms.Screen]::AllScreens
$shots = @{}
foreach ($s in $screens) {
    $b = $s.Bounds
    $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
    $g.Dispose()
    $shots[$s.DeviceName] = $bmp
}

# --- 2) Put a full-screen fake desktop window on every screen ---
foreach ($s in $screens) {
    $f = New-Object System.Windows.Forms.Form
    $f.FormBorderStyle = 'None'
    $f.StartPosition   = 'Manual'
    $f.Bounds          = $s.Bounds
    $f.TopMost         = $true
    $f.ShowInTaskbar   = $false
    $f.KeyPreview      = $true

    $pb = New-Object System.Windows.Forms.PictureBox
    $pb.Dock = 'Fill'
    $pb.SizeMode = 'Normal'
    $pb.Image = $shots[$s.DeviceName]
    $f.Controls.Add($pb)

    $f.Add_KeyDown({
        param($s2, $e)
        $k = $e.KeyCode
        # Modifier keys on their own shouldn't trigger the gotcha (needed for the exit combo)
        if ($k -eq [System.Windows.Forms.Keys]::ControlKey -or
            $k -eq [System.Windows.Forms.Keys]::ShiftKey   -or
            $k -eq [System.Windows.Forms.Keys]::Menu        -or
            $k -eq [System.Windows.Forms.Keys]::LWin        -or
            $k -eq [System.Windows.Forms.Keys]::RWin) { return }
        if ($e.Control -and $e.Alt -and $k -eq [System.Windows.Forms.Keys]::Q) { Exit-Clean } else { Invoke-Gotcha }
    })
    $f.Add_MouseDown({ Invoke-Gotcha })
    $pb.Add_MouseDown({ Invoke-Gotcha })

    $script:forms += $f
}

foreach ($f in $script:forms) { $f.Show() }
if ($script:forms.Count -gt 0) { $script:forms[0].Activate() }

# --- 3) Watch mouse movement (during the grace period the origin keeps resetting, no trigger) ---
$script:mouseOrigin = [System.Windows.Forms.Cursor]::Position
$script:timer = New-Object System.Windows.Forms.Timer
$script:timer.Interval = 120
$script:timer.Add_Tick({
    # The secret exit works at any time (even during the grace period): Ctrl+Alt+Q
    if (Test-ExitCombo) { Exit-Clean; return }
    if (((Get-Date) - $script:startTime).TotalSeconds -lt $GRACE) {
        # Grace period: update the origin, don't trigger
        $script:mouseOrigin = [System.Windows.Forms.Cursor]::Position
        return
    }
    $p = [System.Windows.Forms.Cursor]::Position
    $dx = [math]::Abs($p.X - $script:mouseOrigin.X)
    $dy = [math]::Abs($p.Y - $script:mouseOrigin.Y)
    if ($dx -gt 8 -or $dy -gt 8) { Invoke-Gotcha }
})
$script:timer.Start()

[System.Windows.Forms.Application]::Run()
