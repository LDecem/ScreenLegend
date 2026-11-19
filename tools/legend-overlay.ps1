# ScreenLegend - floating legend + compass overlays
# Runs invisibly next to the editor. The editor page POSTs PNGs to
# http://127.0.0.1:8777/legend and /compass; this script paints each into its
# own borderless, always-on-top, per-pixel-alpha window that is exactly the
# size of the image (so a region screenshot contains the graphic and nothing
# else). The two windows are independent: separate bitmaps, positions and
# show/hide state.
#
# Left-drag moves a window (the OS does the dragging), right-click opens a
# quick-settings menu (the last item closes it), fully transparent pixels let
# clicks through to whatever is underneath.
#
# /pick runs a native full-screen colour picker: the editor steps out of the
# way, the screen is captured, and the user clicks a pixel. Right-click or Esc
# cancels. It runs in the helper rather than the browser so cancelling cannot
# depend on the system EyeDropper's key handling.

param([int]$Port = 8777)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @"
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

public class SLOverlay {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
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
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
    [DllImport("user32.dll")] public static extern int GetClassName(IntPtr hWnd, StringBuilder text, int count);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
    [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, IntPtr dwExtraInfo);

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

/* Full-screen colour picker. The screen is captured before the window appears,
   so neither the editor window nor the picker itself ends up in the sample.
   Left click picks, right click or Esc cancels. */
public class SLPicker : Form {
    public Bitmap Shot;
    public bool Cancelled = true;
    public Color Picked = Color.Black;

    const int SRC = 15;     // sampled pixels in the loupe (odd)
    const int ZOOM = 8;     // loupe magnification

    static readonly Font InfoFont = new Font("Microsoft YaHei UI", 9.5f, FontStyle.Regular);
    static readonly Font HintFont = new Font("Microsoft YaHei UI", 10f, FontStyle.Bold);

    int mx = -1;
    int my = -1;
    bool done = false;

    public SLPicker() {
        AutoScaleMode = AutoScaleMode.None;
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        Cursor = Cursors.Cross;
        KeyPreview = true;
        BackColor = Color.Black;
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint, true);
    }

    static GraphicsPath Pill(Rectangle r, int radius) {
        GraphicsPath p = new GraphicsPath();
        int d = radius * 2;
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }

    Rectangle LoupeRect() {
        int size = SRC * ZOOM;
        int gap = 24;
        int x = mx - size - gap;
        int y = my - size - gap;
        if (x < 0) x = Math.Min(mx + gap, ClientSize.Width - size);
        if (y < 0) y = Math.Min(my + gap, ClientSize.Height - size);
        if (x < 0) x = 0;
        if (y < 0) y = 0;
        return new Rectangle(x, y, size, size);
    }

    void InvalidateAt(int x, int y) {
        if (x < 0) return;
        Invalidate(new Rectangle(x - 240, y - 240, 480, 480));
        Invalidate(new Rectangle(0, y, ClientSize.Width, 2));
        Invalidate(new Rectangle(x, 0, 2, ClientSize.Height));
    }

    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        if (Shot == null) { base.OnPaint(e); return; }
        g.DrawImageUnscaled(Shot, 0, 0);

        if (mx >= 0) {
            using (Pen dark = new Pen(Color.FromArgb(170, 0, 0, 0), 1f))
            using (Pen light = new Pen(Color.FromArgb(235, 255, 255, 255), 1f)) {
                g.DrawLine(dark, 0, my, ClientSize.Width, my);
                g.DrawLine(light, 0, my + 1, ClientSize.Width, my + 1);
                g.DrawLine(dark, mx, 0, mx, ClientSize.Height);
                g.DrawLine(light, mx + 1, 0, mx + 1, ClientSize.Height);
            }
            DrawLoupe(g);
            DrawInfo(g);
        }
        DrawHint(g);
    }

    void DrawLoupe(Graphics g) {
        Rectangle dst = LoupeRect();
        int sx = Math.Max(0, Math.Min(Shot.Width - SRC, mx - SRC / 2));
        int sy = Math.Max(0, Math.Min(Shot.Height - SRC, my - SRC / 2));
        Rectangle src = new Rectangle(sx, sy, SRC, SRC);

        InterpolationMode oldInterp = g.InterpolationMode;
        PixelOffsetMode oldOffset = g.PixelOffsetMode;
        g.InterpolationMode = InterpolationMode.NearestNeighbor;
        g.PixelOffsetMode = PixelOffsetMode.Half;
        g.DrawImage(Shot, dst, src, GraphicsUnit.Pixel);
        g.InterpolationMode = oldInterp;
        g.PixelOffsetMode = oldOffset;

        using (Pen border = new Pen(Color.FromArgb(230, 17, 24, 39), 2f)) g.DrawRectangle(border, dst);
        int cx = dst.X + (mx - sx) * ZOOM;
        int cy = dst.Y + (my - sy) * ZOOM;
        using (Pen outer = new Pen(Color.FromArgb(230, 0, 0, 0), 3f))
        using (Pen inner = new Pen(Color.White, 1f)) {
            g.DrawRectangle(outer, cx - 2, cy - 2, ZOOM + 3, ZOOM + 3);
            g.DrawRectangle(inner, cx, cy, ZOOM, ZOOM);
        }
    }

    void DrawInfo(Graphics g) {
        Rectangle loupe = LoupeRect();
        int w = 252;
        int h = 54;
        int x = loupe.X;
        if (x + w > ClientSize.Width - 8) x = ClientSize.Width - w - 8;
        if (x < 8) x = 8;
        int y = loupe.Bottom + 8;
        if (y + h > ClientSize.Height - 8) y = loupe.Top - h - 8;
        if (y < 8) y = loupe.Bottom + 8;
        Rectangle box = new Rectangle(x, y, w, h);

        Color c = Color.Black;
        if (mx >= 0 && my >= 0 && mx < Shot.Width && my < Shot.Height) c = Shot.GetPixel(mx, my);

        using (GraphicsPath path = Pill(box, 8)) {
            using (SolidBrush bg = new SolidBrush(Color.FromArgb(238, 17, 24, 39))) g.FillPath(bg, path);
            using (Pen edge = new Pen(Color.FromArgb(70, 255, 255, 255), 1f)) g.DrawPath(edge, path);
        }
        Rectangle chip = new Rectangle(box.X + 9, box.Y + 9, 36, 36);
        using (SolidBrush fill = new SolidBrush(c)) g.FillRectangle(fill, chip);
        using (Pen edge = new Pen(Color.FromArgb(160, 0, 0, 0), 1f)) g.DrawRectangle(edge, chip);

        g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
        string hex = "#" + c.R.ToString("X2") + c.G.ToString("X2") + c.B.ToString("X2");
        string rgb = "R " + c.R + "   G " + c.G + "   B " + c.B;
        string pos = "X " + mx + "   Y " + my;
        using (SolidBrush white = new SolidBrush(Color.White))
        using (SolidBrush dim = new SolidBrush(Color.FromArgb(205, 229, 231, 235))) {
            g.DrawString(hex, InfoFont, white, box.X + 54, box.Y + 7);
            g.DrawString(rgb, InfoFont, dim, box.X + 54, box.Y + 28);
            SizeF pw = g.MeasureString(pos, InfoFont);
            g.DrawString(pos, InfoFont, dim, box.Right - pw.Width - 12, box.Y + 7);
        }
    }

    void DrawHint(Graphics g) {
        string text = "左键取色　·　右键 / Esc 取消";
        g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
        SizeF size = g.MeasureString(text, HintFont);
        int w = (int)size.Width + 40;
        int h = 42;
        int x = (ClientSize.Width - w) / 2;
        int y = 26;
        using (GraphicsPath path = Pill(new Rectangle(x, y, w, h), 21)) {
            using (SolidBrush bg = new SolidBrush(Color.FromArgb(235, 17, 24, 39))) g.FillPath(bg, path);
            using (Pen edge = new Pen(Color.FromArgb(70, 255, 255, 255), 1f)) g.DrawPath(edge, path);
        }
        g.DrawString(text, HintFont, Brushes.White, x + 20, y + (h - size.Height) / 2f);
    }

    protected override void OnMouseMove(MouseEventArgs e) {
        base.OnMouseMove(e);
        InvalidateAt(mx, my);
        mx = e.X;
        my = e.Y;
        InvalidateAt(mx, my);
    }

    protected override void OnMouseDown(MouseEventArgs e) {
        base.OnMouseDown(e);
        if (e.Button == MouseButtons.Left) {
            mx = e.X;
            my = e.Y;
            Finish(true);
        } else if (e.Button == MouseButtons.Right) {
            Finish(false);
        }
    }

    protected override void OnKeyDown(KeyEventArgs e) {
        base.OnKeyDown(e);
        if (e.KeyCode == Keys.Escape) {
            Finish(false);
            e.Handled = true;
        }
    }

    void Finish(bool pick) {
        if (done) return;
        done = true;
        if (pick && Shot != null) {
            int x = Math.Max(0, Math.Min(Shot.Width - 1, mx));
            int y = Math.Max(0, Math.Min(Shot.Height - 1, my));
            Picked = Shot.GetPixel(x, y);
            Cancelled = false;
        }
        DialogResult = DialogResult.OK;
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

# ---------------------------------------------------------------- the overlay windows
# Two independent layered windows: the legend card and the compass. They have
# separate bitmaps, positions and show/hide state; painting or moving one never
# touches the other.

function New-OverlayWindow([string]$title) {
    $form = New-Object System.Windows.Forms.Form
    $form.FormBorderStyle = 'None'
    $form.ShowInTaskbar = $false
    $form.TopMost = $true
    $form.StartPosition = 'Manual'
    $form.Text = $title
    $form.Width = 8
    $form.Height = 8

    # reading Handle creates the window without ever showing it, so starting the
    # helper cannot steal the foreground (and the IME) from the editor
    $hwnd = $form.Handle
    $ex = [SLOverlay]::GetWindowLong($hwnd, -20)
    # layered + tool window + no-activate (never steals focus from the map app)
    [SLOverlay]::SetWindowLong($hwnd, -20, ($ex -bor 0x00080000 -bor 0x00000080 -bor 0x08000000)) | Out-Null

    $hit = New-Object SLOverlayWindow
    $hit.AssignHandle($hwnd)

    return @{
        Form = $form
        Hwnd = $hwnd
        Hit = $hit
        Showing = $false
        W = 0
        H = 0
    }
}

$script:legendWin = New-OverlayWindow 'ScreenLegendOverlay'
$script:compassWin = New-OverlayWindow 'ScreenLegendCompass'
$script:legendWin.Hit.RightClicked = { Show-LegendMenu }
$script:compassWin.Hit.RightClicked = { Show-CompassMenu }

function Paint-Overlay($win, [System.Drawing.Bitmap]$bmp, [int]$x, [int]$y) {
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
    [SLOverlay]::UpdateLayeredWindow($win.Hwnd, $screenDc, [ref]$dst, [ref]$size, $memDc, [ref]$src, 0, [ref]$blend, 2) | Out-Null

    [SLOverlay]::SelectObject($memDc, $old) | Out-Null
    [SLOverlay]::DeleteObject($hBmp) | Out-Null
    [SLOverlay]::DeleteDC($memDc) | Out-Null
    [SLOverlay]::ReleaseDC([IntPtr]::Zero, $screenDc) | Out-Null

    $win.W = $bmp.Width
    $win.H = $bmp.Height
}

function Current-Position($win) {
    $r = New-Object SLOverlay+RECT
    [SLOverlay]::GetWindowRect($win.Hwnd, [ref]$r) | Out-Null
    return @($r.L, $r.T)
}

function Show-Overlay($win, [System.Drawing.Bitmap]$bmp, [bool]$reposition, [string]$anchor) {
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    if (-not $win.Showing) {
        $x = $wa.Right - $bmp.Width - 24
        if ($anchor -eq 'top-right') {
            $y = $wa.Top + 60
        } else {
            $y = $wa.Bottom - $bmp.Height - 60
        }
        if ($x -lt $wa.Left) { $x = $wa.Left }
        if ($y -lt $wa.Top) { $y = $wa.Top }
    } else {
        # Keep the user's position when the card changes size (title/columns/
        # opacity in the right-click menu); just keep it on screen.
        $pos = Current-Position $win
        $x = $pos[0]
        $y = $pos[1]
        if ($x + $bmp.Width -gt $wa.Right) { $x = $wa.Right - $bmp.Width }
        if ($y + $bmp.Height -gt $wa.Bottom) { $y = $wa.Bottom - $bmp.Height }
        if ($x -lt $wa.Left) { $x = $wa.Left }
        if ($y -lt $wa.Top) { $y = $wa.Top }
    }
    Paint-Overlay $win $bmp $x $y
    # Showing / re-z-ordering an overlay must never activate it: stealing the
    # foreground would detach the editor's IME (Chinese input stops working
    # until the window is activated again).
    if (-not $win.Showing) { $win.Form.Show() }
    [SLOverlay]::SetWindowPos($win.Hwnd, [IntPtr](-1), 0, 0, 0, 0, 0x0013) | Out-Null   # NOSIZE|NOMOVE|NOACTIVATE
    $win.Showing = $true
}

function Hide-Overlay($win) {
    $win.Showing = $false
    $win.Form.Hide()
}

$script:editorHwnd = [IntPtr]::Zero
$script:picking = $false
$script:legendMenuState = @{ showTitle = $true; columns = 1; opacity = 100 }
$script:compassMenuState = @{ style = 'needle'; angle = 0; opacity = 100 }
$script:pendingCommand = $null

# The editor is a browser window. Find it by its page title and Chromium class
# so the picker can step out of the way without depending on which window is
# foreground.
function Find-EditorWindow {
    $script:editorHwnd = [IntPtr]::Zero
    [SLOverlay]::EnumWindows({
        param($h, $l)
        if ([SLOverlay]::IsWindowVisible($h)) {
            $title = New-Object System.Text.StringBuilder 512
            [SLOverlay]::GetWindowText($h, $title, 512) | Out-Null
            $text = $title.ToString()
            if ($text -like '*ScreenLegend*' -and $text -notlike '*ScreenLegendOverlay*' -and $text -notlike '*ScreenLegendCompass*') {
                $cls = New-Object System.Text.StringBuilder 256
                [SLOverlay]::GetClassName($h, $cls, 256) | Out-Null
                if ($cls.ToString() -like 'Chrome_WidgetWin*') {
                    $script:editorHwnd = $h
                    return $false
                }
            }
        }
        return $true
    }, [IntPtr]::Zero) | Out-Null
    return $script:editorHwnd
}

function Invoke-ScreenPick {
    if ($script:picking) { return @{ busy = $true; cancelled = $true } }
    $script:picking = $true
    $hwnd = Find-EditorWindow
    $hidden = $false
    $shot = $null
    $form = $null
    try {
        # Step out of the way first: the sampled image must show what was
        # underneath the editor, not the editor card itself.
        if ($hwnd -ne [IntPtr]::Zero) {
            [SLOverlay]::ShowWindow($hwnd, 6) | Out-Null   # SW_MINIMIZE
            $hidden = $true
            Start-Sleep -Milliseconds 280
        }

        $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $shot = New-Object System.Drawing.Bitmap($vs.Width, $vs.Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($shot)
        try {
            $g.CopyFromScreen($vs.Left, $vs.Top, 0, 0, $shot.Size, [System.Drawing.CopyPixelOperation]::SourceCopy)
        } finally {
            $g.Dispose()
        }

        $form = New-Object SLPicker
        $form.Shot = $shot
        $form.Bounds = $vs
        [void]$form.ShowDialog()

        if ($form.Cancelled) { return @{ cancelled = $true } }
        $c = $form.Picked
        return @{
            cancelled = $false
            hex = '#' + $c.R.ToString('X2') + $c.G.ToString('X2') + $c.B.ToString('X2')
        }
    } finally {
        if ($form) { $form.Dispose() }
        if ($shot) { $shot.Dispose() }
        if ($hidden -and [SLOverlay]::IsWindow($hwnd)) {
            [SLOverlay]::ShowWindow($hwnd, 9) | Out-Null   # SW_RESTORE
            [SLOverlay]::SetForegroundWindow($hwnd) | Out-Null
        }
        $script:picking = $false
    }
}

function Set-MenuCommand($target, $action, $value) {
    $script:pendingCommand = @{ target = $target; action = $action; value = $value }
}

function Show-LegendMenu {
    $state = $script:legendMenuState
    $showTitle = $true
    $columns = 1
    $opacity = 100
    if ($state) {
        if ($null -ne $state.showTitle) { $showTitle = [bool]$state.showTitle }
        if ($null -ne $state.columns) { $columns = [int]$state.columns }
        if ($null -ne $state.opacity) { $opacity = [int]$state.opacity }
    }

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $header = New-Object System.Windows.Forms.ToolStripMenuItem '图例快捷设置'
    $header.Enabled = $false
    $menu.Items.Add($header) | Out-Null

    $title = New-Object System.Windows.Forms.ToolStripMenuItem '显示标题'
    $title.Checked = $showTitle
    $title.Tag = (-not $showTitle)
    $title.Add_Click({ Set-MenuCommand 'legend' 'showTitle' ([bool]$this.Tag) })
    $menu.Items.Add($title) | Out-Null

    $cols = New-Object System.Windows.Forms.ToolStripMenuItem '列数'
    foreach ($n in 1..4) {
        $item = New-Object System.Windows.Forms.ToolStripMenuItem ("$n 列")
        $item.Checked = ($columns -eq $n)
        $item.Tag = $n
        $item.Add_Click({ Set-MenuCommand 'legend' 'columns' ([int]$this.Tag) })
        $cols.DropDownItems.Add($item) | Out-Null
    }
    $menu.Items.Add($cols) | Out-Null

    $op = New-Object System.Windows.Forms.ToolStripMenuItem '背景不透明度'
    foreach ($pct in @(100, 80, 60, 40, 20, 0)) {
        $item = New-Object System.Windows.Forms.ToolStripMenuItem ("$pct%")
        $item.Checked = ($opacity -eq $pct)
        $item.Tag = $pct
        $item.Add_Click({ Set-MenuCommand 'legend' 'opacity' ([int]$this.Tag) })
        $op.DropDownItems.Add($item) | Out-Null
    }
    $menu.Items.Add($op) | Out-Null

    $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
    $close = New-Object System.Windows.Forms.ToolStripMenuItem '关闭图例'
    $close.Add_Click({ Hide-Overlay $script:legendWin })
    $menu.Items.Add($close) | Out-Null

    $menu.Show([System.Windows.Forms.Cursor]::Position)
}

function Show-CompassMenu {
    $state = $script:compassMenuState
    $style = 'needle'
    $angle = 0
    $opacity = 100
    if ($state) {
        if ($null -ne $state.style) { $style = [string]$state.style }
        if ($null -ne $state.angle) { $angle = [int]$state.angle }
        if ($null -ne $state.opacity) { $opacity = [int]$state.opacity }
    }

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $header = New-Object System.Windows.Forms.ToolStripMenuItem '罗盘快捷设置'
    $header.Enabled = $false
    $menu.Items.Add($header) | Out-Null

    $styleMenu = New-Object System.Windows.Forms.ToolStripMenuItem '样式'
    foreach ($pair in @(@('needle', '指针'), @('ring', '刻度'), @('rose', '玫瑰'))) {
        $item = New-Object System.Windows.Forms.ToolStripMenuItem $pair[1]
        $item.Checked = ($style -eq $pair[0])
        $item.Tag = $pair[0]
        $item.Add_Click({ Set-MenuCommand 'compass' 'style' ([string]$this.Tag) })
        $styleMenu.DropDownItems.Add($item) | Out-Null
    }
    $menu.Items.Add($styleMenu) | Out-Null

    $angleMenu = New-Object System.Windows.Forms.ToolStripMenuItem '旋转角度'
    $current = New-Object System.Windows.Forms.ToolStripMenuItem ("当前 $angle°")
    $current.Enabled = $false
    $angleMenu.DropDownItems.Add($current) | Out-Null
    foreach ($a in @(0, 45, 90, 135, 180, 225, 270, 315)) {
        $item = New-Object System.Windows.Forms.ToolStripMenuItem ("$a°")
        $item.Checked = ($angle -eq $a)
        $item.Tag = $a
        $item.Add_Click({ Set-MenuCommand 'compass' 'angle' ([int]$this.Tag) })
        $angleMenu.DropDownItems.Add($item) | Out-Null
    }
    $menu.Items.Add($angleMenu) | Out-Null

    $op = New-Object System.Windows.Forms.ToolStripMenuItem '背景不透明度'
    foreach ($pct in @(100, 80, 60, 40, 20, 0)) {
        $item = New-Object System.Windows.Forms.ToolStripMenuItem ("$pct%")
        $item.Checked = ($opacity -eq $pct)
        $item.Tag = $pct
        $item.Add_Click({ Set-MenuCommand 'compass' 'opacity' ([int]$this.Tag) })
        $op.DropDownItems.Add($item) | Out-Null
    }
    $menu.Items.Add($op) | Out-Null

    $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
    $close = New-Object System.Windows.Forms.ToolStripMenuItem '关闭罗盘'
    $close.Add_Click({ Hide-Overlay $script:compassWin })
    $menu.Items.Add($close) | Out-Null

    $menu.Show([System.Windows.Forms.Cursor]::Position)
}

# ---------------------------------------------------------------- pump

$script:lastActivity = Get-Date

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 80
$timer.Add_Tick({
    # A modal picker pumps messages, so this tick can run again inside it.
    if ($script:picking) { return }
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
                $legendOn = if ($script:legendWin.Showing) { 'true' } else { 'false' }
                $compassOn = if ($script:compassWin.Showing) { 'true' } else { 'false' }
                $cmdJson = if ($script:pendingCommand) { $script:pendingCommand | ConvertTo-Json -Compress } else { 'null' }
                $script:pendingCommand = $null
                $reply = '{"ok":true,"showing":' + $legendOn + ',"legend":' + $legendOn + ',"compass":' + $compassOn + ',"command":' + $cmdJson + '}'
            } elseif ($path -like '/pick*') {
                $picked = Invoke-ScreenPick
                if ($picked.busy) {
                    $reply = '{"ok":false,"busy":true,"cancelled":true}'
                } elseif ($picked.cancelled) {
                    $reply = '{"ok":true,"cancelled":true}'
                } else {
                    $reply = '{"ok":true,"cancelled":false,"hex":"' + $picked.hex + '"}'
                }
            } elseif ($path -like '/hide-compass*') {
                Hide-Overlay $script:compassWin
                $reply = '{"ok":true,"showing":false,"compass":false}'
            } elseif ($path -like '/hide-all*') {
                Hide-Overlay $script:legendWin
                Hide-Overlay $script:compassWin
                $reply = '{"ok":true,"showing":false,"legend":false,"compass":false}'
            } elseif ($path -like '/hide*') {
                Hide-Overlay $script:legendWin
                $reply = '{"ok":true,"showing":false,"legend":false}'
            } elseif ($path -like '/legend*' -and $req.Body) {
                $data = $req.Body | ConvertFrom-Json
                if ($data.menu) { $script:legendMenuState = $data.menu }
                if ($data.show -eq $false) {
                    Hide-Overlay $script:legendWin
                    $reply = '{"ok":true,"showing":false}'
                } elseif ($data.png) {
                    $raw = [System.Convert]::FromBase64String($data.png)
                    $ms = New-Object System.IO.MemoryStream(, $raw)
                    $bmp = [System.Drawing.Bitmap]::FromStream($ms)
                    $changed = ($script:legendWin.W -eq 0) -or ($bmp.Width -ne $script:legendWin.W) -or ($bmp.Height -ne $script:legendWin.H)
                    Show-Overlay $script:legendWin $bmp $changed 'bottom-right'
                    $reply = '{"ok":true,"showing":true,"w":' + $script:legendWin.W + ',"h":' + $script:legendWin.H + '}'
                    $bmp.Dispose()
                    $ms.Dispose()
                }
            } elseif ($path -like '/compass*' -and $req.Body) {
                $data = $req.Body | ConvertFrom-Json
                if ($data.menu) { $script:compassMenuState = $data.menu }
                if ($data.show -eq $false) {
                    Hide-Overlay $script:compassWin
                    $reply = '{"ok":true,"compass":false}'
                } elseif ($data.png) {
                    $raw = [System.Convert]::FromBase64String($data.png)
                    $ms = New-Object System.IO.MemoryStream(, $raw)
                    $bmp = [System.Drawing.Bitmap]::FromStream($ms)
                    $changed = ($script:compassWin.W -eq 0) -or ($bmp.Width -ne $script:compassWin.W) -or ($bmp.Height -ne $script:compassWin.H)
                    Show-Overlay $script:compassWin $bmp $changed 'top-right'
                    $reply = '{"ok":true,"compass":true,"w":' + $script:compassWin.W + ',"h":' + $script:compassWin.H + '}'
                    $bmp.Dispose()
                    $ms.Dispose()
                }
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
