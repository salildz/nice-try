# fake-desktop.ps1
# Takes a screenshot of every monitor and shows it full screen as a "frozen desktop".
# Nothing triggers during the first $GRACE seconds (so you have time to walk away).
# After that, if the mouse moves, a mouse button is clicked or a key is pressed:
# shows "Nice try :D" (plus the GIF and, optionally, the webcam feed) and then actually locks the PC.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class K { [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey); }
"@

# Secret exit combo: Ctrl + Alt + Q  (skips the gotcha screen, but still locks the PC just in case)
# Want a different key? Replace 0x51 (= Q) in Test-ExitCombo with another VK code,
# and Keys::Q in the KeyDown handler below with the matching key.

$script:triggered  = $false
$script:forms      = @()
$script:timer      = $null
$script:lockTimer  = $null
$script:cam        = $null
$script:startTime  = Get-Date
$GRACE = 2         # seconds: nothing triggers during this period
$HOLD_MS = 6000    # how many ms the gotcha screen stays up before locking. 1000 = 1 s
$IMAGE = Join-Path $PSScriptRoot "laughinggif2.gif"   # png/jpg/gif in the same folder; GIFs animate. If missing, only the text is shown
$CAMERA = $false   # $true: also show the webcam feed next to the GIF when someone gets caught (Windows PowerShell 5.1 only)

function Exit-Clean {
    # No gotcha: close the windows and go straight to the lock screen
    if ($script:timer) { $script:timer.Stop() }
    if ($script:lockTimer) { $script:lockTimer.Stop() }
    rundll32.exe user32.dll, LockWorkStation
    [System.Windows.Forms.Application]::Exit()
}

function Test-ExitCombo {
    # Are Ctrl (0x11) + Alt (0x12) + Q (0x51) all held down at the same time?
    $ctrl = ([K]::GetAsyncKeyState(0x11) -band 0x8000) -ne 0
    $alt  = ([K]::GetAsyncKeyState(0x12) -band 0x8000) -ne 0
    $q    = ([K]::GetAsyncKeyState(0x51) -band 0x8000) -ne 0
    return ($ctrl -and $alt -and $q)
}

function Start-Camera {
    # Grabs webcam frames in a background runspace so the GIF keeps animating while the camera starts up.
    # The newest JPEG frame is handed over through a synchronized hashtable; nothing is saved to disk.
    $script:cam = [hashtable]::Synchronized(@{ Frame = $null; Stop = $false; Error = $null })
    $script:camBoxes = @()
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = [System.Threading.ApartmentState]::MTA
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('cam', $script:cam)
    $script:camPs = [powershell]::Create()
    $script:camPs.Runspace = $rs
    [void]$script:camPs.AddScript({
        try {
            Add-Type -AssemblyName System.Runtime.WindowsRuntime
            $null = [Windows.Media.Capture.MediaCapture, Windows.Media.Capture, ContentType = WindowsRuntime]
            $null = [Windows.Media.Capture.MediaCaptureInitializationSettings, Windows.Media.Capture, ContentType = WindowsRuntime]
            $null = [Windows.Media.Capture.LowLagPhotoCapture, Windows.Media.Capture, ContentType = WindowsRuntime]
            $null = [Windows.Media.Capture.CapturedPhoto, Windows.Media.Capture, ContentType = WindowsRuntime]
            $null = [Windows.Media.MediaProperties.ImageEncodingProperties, Windows.Media.MediaProperties, ContentType = WindowsRuntime]
            $null = [Windows.Devices.Enumeration.DeviceInformation, Windows.Devices.Enumeration, ContentType = WindowsRuntime]

            # WinRT async calls -> .NET tasks we can wait on
            $ext = [System.WindowsRuntimeSystemExtensions].GetMethods()
            $asTaskOp = $ext | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
            $asTaskAction = $ext | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction' } | Select-Object -First 1
            function Wait-Op($op, [type]$type) { $t = $asTaskOp.MakeGenericMethod($type).Invoke($null, @($op)); $t.Wait(-1) | Out-Null; $t.Result }
            function Wait-Action($action) { $t = $asTaskAction.Invoke($null, @($action)); $t.Wait(-1) | Out-Null }

            # Prefer the built-in front camera over virtual ones (e.g. a phone connected through Phone Link)
            $devices = Wait-Op ([Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync([Windows.Devices.Enumeration.DeviceClass]::VideoCapture)) ([Windows.Devices.Enumeration.DeviceInformationCollection])
            $device = $devices | Where-Object { $_.IsEnabled -and $_.EnclosureLocation -and $_.EnclosureLocation.Panel -eq 'Front' } | Select-Object -First 1
            if (-not $device) { $device = $devices | Where-Object { $_.IsEnabled } | Select-Object -First 1 }
            if (-not $device) { throw 'No camera found' }

            $settings = New-Object Windows.Media.Capture.MediaCaptureInitializationSettings
            $settings.VideoDeviceId = $device.Id
            $settings.StreamingCaptureMode = [Windows.Media.Capture.StreamingCaptureMode]::Video
            $mc = New-Object Windows.Media.Capture.MediaCapture
            Wait-Action ($mc.InitializeAsync($settings))
            $lowLag = Wait-Op ($mc.PrepareLowLagPhotoCaptureAsync([Windows.Media.MediaProperties.ImageEncodingProperties]::CreateJpeg())) ([Windows.Media.Capture.LowLagPhotoCapture])

            while (-not $cam.Stop) {
                $photo = Wait-Op ($lowLag.CaptureAsync()) ([Windows.Media.Capture.CapturedPhoto])
                $s = [System.IO.WindowsRuntimeStreamExtensions]::AsStreamForRead($photo.Frame)
                $ms = New-Object System.IO.MemoryStream
                $s.CopyTo($ms)
                $cam.Frame = $ms.ToArray()
                $s.Dispose(); $ms.Dispose()
            }
            Wait-Action ($lowLag.FinishAsync())
            $mc.Dispose()
        } catch {
            $cam.Error = "$_"
        }
    })
    $script:camHandle = $script:camPs.BeginInvoke()

    # Put the newest frame on every screen (mirrored, like a selfie camera)
    $script:camTimer = New-Object System.Windows.Forms.Timer
    $script:camTimer.Interval = 50
    $script:camTimer.Add_Tick({
        if ($script:cam.Error) {
            # No usable camera (missing, busy or blocked in privacy settings): give its space back to the GIF
            $script:camTimer.Stop()
            foreach ($cb in $script:camBoxes) {
                $tlp = $cb.Parent
                if ($tlp.ColumnCount -gt 1) { $tlp.ColumnStyles[$tlp.GetColumn($cb)].Width = 0 } else { $tlp.RowStyles[1].Height = 0 }
                $cb.Visible = $false
            }
            return
        }
        $frame = $script:cam.Frame
        if (-not $frame) { return }
        $script:cam.Frame = $null
        $ms = New-Object System.IO.MemoryStream (,$frame)
        $img = [System.Drawing.Image]::FromStream($ms)
        $bmp = New-Object System.Drawing.Bitmap $img
        $img.Dispose(); $ms.Dispose()
        $bmp.RotateFlip([System.Drawing.RotateFlipType]::RotateNoneFlipX)
        foreach ($cb in $script:camBoxes) { $cb.Image = $bmp }
        if ($script:camFrame) { $script:camFrame.Dispose() }
        $script:camFrame = $bmp
    })
    $script:camTimer.Start()
}

function Stop-Camera {
    # Let the capture loop finish so the webcam (and its LED) is released right away
    if (-not $script:cam) { return }
    $script:camTimer.Stop()
    $script:cam.Stop = $true
    [void]$script:camHandle.AsyncWaitHandle.WaitOne(3000)
}

function Invoke-Gotcha {
    if ($script:triggered) { return }
    if (((Get-Date) - $script:startTime).TotalSeconds -lt $GRACE) { return }
    $script:triggered = $true
    if ($script:timer) { $script:timer.Stop() }
    if ($CAMERA) { Start-Camera }   # start first: the camera needs a second or two to wake up

    $dark = [System.Drawing.Color]::FromArgb(15, 15, 22)
    $hasImage = (Test-Path $IMAGE)
    $bytes = $null
    if ($hasImage) { $bytes = [System.IO.File]::ReadAllBytes($IMAGE) }
    $script:streams = @()   # keep the GIF streams referenced so they don't get garbage collected

    foreach ($f in $script:forms) {
        $f.Controls.Clear()
        $f.BackColor = $dark

        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Dock = 'Fill'
        $lbl.TextAlign = 'MiddleCenter'
        $lbl.ForeColor = [System.Drawing.Color]::White
        $lbl.Font = New-Object System.Drawing.Font('Segoe UI Emoji', 40, [System.Drawing.FontStyle]::Bold)
        $lbl.Text = "Nice try" + [Environment]::NewLine + ":D"

        # Bottom half: the image/GIF and/or the camera feed, side by side
        $cells = @()
        if ($hasImage) {
            $ms = New-Object System.IO.MemoryStream (,$bytes)   # separate copy per screen -> the GIF animates on each one
            $script:streams += $ms
            $pb = New-Object System.Windows.Forms.PictureBox
            $pb.Dock = 'Fill'
            $pb.SizeMode = 'Zoom'
            $pb.BackColor = $dark
            $pb.Image = [System.Drawing.Image]::FromStream($ms)
            $cells += $pb
        }
        if ($script:cam) {
            $cb = New-Object System.Windows.Forms.PictureBox
            $cb.Dock = 'Fill'
            $cb.SizeMode = 'Zoom'
            $cb.BackColor = $dark
            $script:camBoxes += $cb
            $cells += $cb
        }

        if ($cells.Count -gt 0) {
            # Top half text, bottom half image/GIF (and camera)
            $tlp = New-Object System.Windows.Forms.TableLayoutPanel
            $tlp.Dock = 'Fill'
            $tlp.BackColor = $dark
            $tlp.RowCount = 2
            $tlp.ColumnCount = $cells.Count
            $tlp.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 50))) | Out-Null
            $tlp.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 50))) | Out-Null

            $tlp.Controls.Add($lbl, 0, 0)
            $tlp.SetColumnSpan($lbl, $cells.Count)
            for ($i = 0; $i -lt $cells.Count; $i++) {
                $tlp.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50))) | Out-Null
                $tlp.Controls.Add($cells[$i], $i, 1)
            }
            $f.Controls.Add($tlp)
        } else {
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
Stop-Camera
