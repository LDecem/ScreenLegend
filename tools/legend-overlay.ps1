# ScreenLegend - floating legend overlay
# Runs invisibly next to the editor. The editor page POSTs a PNG of the legend
# to http://127.0.0.1:8777/ and this script paints it into a borderless,
# always-on-top, per-pixel-alpha window that is exactly the size of the image
# (so a region screenshot contains the legend and nothing else).
#
# Left-drag moves it (the OS does the dragging), right-click hides it,
# fully transparent pixels let clicks through to whatever is underneath.

param([int]$Port = 8777)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class SLOverlay {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll", SetLastError = true)] public static extern IntPtr GetDC(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);
    [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleDC(IntPtr hdc);
    [DllImport("gdi32.dll")] public static extern IntPtr SelectObject(IntPtr hdc, IntPtr obj);
    [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr obj);
    [DllImport("gdi32.dll")] public static extern bool DeleteDC(IntPtr hdc);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr hdcDst, ref POINT pptDst, ref SIZE psize,
        IntPtr hdcSrc, ref POINT pptSrc, int crKey, ref BLENDFUNCTION pblend, int dwFlags);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")] public static extern bool ScreenToClient(IntPtr hWnd, ref POINT p);

    public struct POINT { public int X; public int Y; }
    public struct SIZE { public int cx; public int cy; }
    public struct RECT { public int L; public int T; public int R; public int B; }
    public struct BLENDFUNCTION { public byte BlendOp; public byte BlendFlags; public byte SourceConstantAlpha; public byte AlphaFormat; }
}

public class SLOverlayWindow : NativeWindow {
    public Action RightClicked;

    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x0084) {              // WM_NCHITTEST
            base.WndProc(ref m);
            /* the whole card is a drag handle, transparent pixels included */
            if ((int)m.Result == 1) m.Result = (IntPtr)2;   // HTCAPTION
            return;
        }
        if (m.Msg == 0x0205 || m.Msg == 0x00A5) {   // WM_RBUTTONUP / WM_NCRBUTTONUP
            if (RightClicked != null) RightClicked();
            return;
        }
        base.WndProc(ref m);
    }
}
"@

[SLOverlay]::SetProcessDPIAware() | Out-Null

# ---------------------------------------------------------------- http server

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
try {
    $listener.Start()
} catch {
    # another copy is already serving this port
    exit 0
}

function Read-Request($client) {
    $stream = $client.GetStream()
    $stream.ReadTimeout = 3000
    $buffer = New-Object byte[] 65536
    $all = New-Object System.Collections.Generic.List[byte]
    $headerEnd = -1
    $contentLength = 0

    while ($true) {
        $read = $stream.Read($buffer, 0, $buffer.Length)
        if ($read -le 0) { break }
        for ($i = 0; $i -lt $read; $i++) { $all.Add($buffer[$i]) }
        $text = [System.Text.Encoding]::UTF8.GetString($all.ToArray())
        if ($headerEnd -lt 0) {
            $idx = $text.IndexOf("`r`n`r`n")
            if ($idx -ge 0) {
                $headerEnd = $idx + 4
                $head = $text.Substring(0, $idx)
                if ($head -match '(?i)content-length:\s*(\d+)') { $contentLength = [int]$Matches[1] }
            }
        }
        if ($headerEnd -ge 0 -and $all.Count -ge ($headerEnd + $contentLength)) { break }
    }

    $bytes = $all.ToArray()
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ($headerEnd -lt 0) { $headerEnd = [Math]::Min($text.Length, $bytes.Length) }
    $head = $text.Substring(0, [Math]::Min($headerEnd, $text.Length))
    $bodyStart = [Math]::Min($headerEnd, $bytes.Length)
    $bodyBytes = New-Object byte[] ([Math]::Max(0, $bytes.Length - $bodyStart))
    if ($bodyBytes.Length -gt 0) { [Array]::Copy($bytes, $bodyStart, $bodyBytes, 0, $bodyBytes.Length) }
    return @{
        Head = $head
        Body = [System.Text.Encoding]::UTF8.GetString($bodyBytes)
        Stream = $stream
    }
}

function Send-Response($stream, $json) {
    $body = [System.Text.Encoding]::UTF8.GetBytes($json)
    $head = "HTTP/1.1 200 OK`r`n" +
            "Access-Control-Allow-Origin: *`r`n" +
            "Access-Control-Allow-Headers: *`r`n" +
            "Access-Control-Allow-Private-Network: true`r`n" +
            "Content-Type: application/json; charset=utf-8`r`n" +
            "Content-Length: $($body.Length)`r`n" +
            "Connection: close`r`n`r`n"
    $headBytes = [System.Text.Encoding]::UTF8.GetBytes($head)
    $stream.Write($headBytes, 0, $headBytes.Length)
    $stream.Write($body, 0, $body.Length)
    $stream.Flush()
}

# ---------------------------------------------------------------- the overlay

$script:form = New-Object System.Windows.Forms.Form
$script:form.FormBorderStyle = 'None'
$script:form.ShowInTaskbar = $false
$script:form.TopMost = $true
$script:form.StartPosition = 'Manual'
$script:form.Text = 'ScreenLegendOverlay'
$script:form.Width = 8
$script:form.Height = 8

# reading Handle creates the window without ever showing it, so starting the
# helper cannot steal the foreground (and the IME) from the editor
$script:hwnd = $script:form.Handle
$ex = [SLOverlay]::GetWindowLong($script:hwnd, -20)
# layered + tool window + no-activate (never steals focus from the map app)
[SLOverlay]::SetWindowLong($script:hwnd, -20, ($ex -bor 0x00080000 -bor 0x00000080 -bor 0x08000000)) | Out-Null

$script:showing = $false
$script:curBmp = $null

function Paint-Overlay([System.Drawing.Bitmap]$bmp, [int]$x, [int]$y) {
    $screenDc = [SLOverlay]::GetDC([IntPtr]::Zero)
    $memDc = [SLOverlay]::CreateCompatibleDC($screenDc)
    $hBmp = $bmp.GetHbitmap([System.Drawing.Color]::FromArgb(0, 0, 0, 0))
    $old = [SLOverlay]::SelectObject($memDc, $hBmp)

    $dst = New-Object SLOverlay+POINT
    $dst.X = $x
    $dst.Y = $y
    $size = New-Object SLOverlay+SIZE
    $size.cx = $bmp.Width
    $size.cy = $bmp.Height
    $src = New-Object SLOverlay+POINT
    $src.X = 0
    $src.Y = 0
    $blend = New-Object SLOverlay+BLENDFUNCTION
    $blend.BlendOp = 0
    $blend.BlendFlags = 0
    $blend.SourceConstantAlpha = 255
    $blend.AlphaFormat = 1
    [SLOverlay]::UpdateLayeredWindow($script:hwnd, $screenDc, [ref]$dst, [ref]$size, $memDc, [ref]$src, 0, [ref]$blend, 2) | Out-Null

    [SLOverlay]::SelectObject($memDc, $old) | Out-Null
    [SLOverlay]::DeleteObject($hBmp) | Out-Null
    [SLOverlay]::DeleteDC($memDc) | Out-Null
    [SLOverlay]::ReleaseDC([IntPtr]::Zero, $screenDc) | Out-Null

    $script:curBmp = $bmp
}

function Current-Position() {
    $r = New-Object SLOverlay+RECT
    [SLOverlay]::GetWindowRect($script:hwnd, [ref]$r) | Out-Null
    return @($r.L, $r.T)
}

function Show-Overlay([System.Drawing.Bitmap]$bmp, [bool]$reposition) {
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    if ($reposition -or -not $script:showing) {
        $x = $wa.Right - $bmp.Width - 24
        $y = $wa.Bottom - $bmp.Height - 60
        if ($x -lt $wa.Left) { $x = $wa.Left }
        if ($y -lt $wa.Top) { $y = $wa.Top }
    } else {
        $pos = Current-Position
        $x = $pos[0]
        $y = $pos[1]
    }
    Paint-Overlay $bmp $x $y
    # Showing / re-z-ordering the overlay must never activate it: stealing the
    # foreground would detach the editor's IME (Chinese input stops working
    # until the window is activated again).
    if (-not $script:showing) { $script:form.Show() }
    [SLOverlay]::SetWindowPos($script:hwnd, [IntPtr](-1), 0, 0, 0, 0, 0x0013) | Out-Null   # NOSIZE|NOMOVE|NOACTIVATE
    $script:showing = $true
}

function Hide-Overlay() {
    $script:showing = $false
    $script:form.Hide()
}

$hit = New-Object SLOverlayWindow
$hit.RightClicked = { Hide-Overlay }
$hit.AssignHandle($script:hwnd)

# ---------------------------------------------------------------- pump

$script:lastActivity = Get-Date

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 80
$timer.Add_Tick({
    while ($listener.Pending()) {
        $client = $listener.AcceptTcpClient()
        try {
            $req = Read-Request $client
            $method = 'GET'
            $path = '/'
            if ($req.Head -match '^(\w+)\s+(\S+)') {
                $method = $Matches[1]
                $path = $Matches[2]
            }
            $reply = '{"ok":true}'
            if ($path -like '/state*') {
                $reply = '{"ok":true,"showing":' + $(if ($script:showing) { 'true' } else { 'false' }) + '}'
            } elseif ($path -like '/legend*' -and $req.Body) {
                $data = $req.Body | ConvertFrom-Json
                if ($data.show -eq $false) {
                    Hide-Overlay
                    $reply = '{"ok":true,"showing":false}'
                } elseif ($data.png) {
                    $raw = [System.Convert]::FromBase64String($data.png)
                    $ms = New-Object System.IO.MemoryStream(, $raw)
                    $bmp = [System.Drawing.Bitmap]::FromStream($ms)
                    $changed = ($null -eq $script:curBmp) -or ($bmp.Width -ne $script:curBmp.Width) -or ($bmp.Height -ne $script:curBmp.Height)
                    Show-Overlay $bmp $changed
                    $reply = '{"ok":true,"showing":true,"w":' + $bmp.Width + ',"h":' + $bmp.Height + '}'
                }
            } elseif ($path -like '/hide*') {
                Hide-Overlay
                $reply = '{"ok":true,"showing":false}'
            }
            Send-Response $req.Stream $reply
            $script:lastActivity = Get-Date
        } catch {
            # ignore malformed requests, keep serving
        } finally {
            $client.Close()
        }
    }
    # idle exit: half an hour without traffic
    if (((Get-Date) - $script:lastActivity).TotalMinutes -gt 30) {
        $listener.Stop()
        [System.Windows.Forms.Application]::Exit()
    }
})
$timer.Start()

[System.Windows.Forms.Application]::Run()

$listener.Stop()
