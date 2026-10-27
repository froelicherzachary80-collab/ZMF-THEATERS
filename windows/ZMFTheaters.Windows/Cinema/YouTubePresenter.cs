using System.Globalization;
using System.IO;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;

namespace ZMFTheaters.Cinema;

/// Plays a YouTube presentation inside the cinema with YouTube's official
/// embedded player (WebView2). Nothing is downloaded or extracted. The page is
/// served from https://zmftheaters.app (a local virtual host) so YouTube sees
/// a real embedding origin; if the uploader blocks embedding (errors 101/150/
/// 152/153) the same video opens on YouTube's own watch page instead.
/// 4DX: the page draws water/mist/wind/flash over the player and leans the
/// picture with the virtual seat. 3D: a red/cyan stereo-window filter (the
/// pixels can't be read, so this is a uniform stereo offset, not depth AI).
public sealed class YouTubePresenter
{
    public const string Host = "zmftheaters.app";
    public Border Panel { get; }
    readonly Grid webHost = new();
    WebView2? web;
    readonly TextBlock titleText = new() { FontWeight = FontWeights.Bold, Foreground = Brushes.White, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
    readonly TextBlock badge = new() { FontWeight = FontWeights.Black, Foreground = new SolidColorBrush(Color.FromRgb(0x4D, 0xD0, 0xE1)), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(10, 0, 0, 0) };
    readonly TextBlock note = new() { Foreground = new SolidColorBrush(Color.FromRgb(0xFF, 0xB7, 0x4D)), FontSize = 11, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 6, 0, 0) };
    TaskCompletionSource<bool>? done;
    string videoId = "";
    bool watchPage;
    public bool Playing { get; private set; }
    public double Time { get; private set; }
    public bool Active => done != null;
    public event Action? SkipAllRequested;

    public static string? VideoId(string raw)
    {
        if (!Uri.TryCreate(raw.Trim(), UriKind.Absolute, out var u) || u.Scheme != "https") return null;
        var host = u.Host.ToLowerInvariant();
        string? id = null;
        var path = u.AbsolutePath.Trim('/').Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (host is "youtu.be" or "www.youtu.be") id = path.FirstOrDefault();
        else if (host is "youtube.com" or "www.youtube.com" or "m.youtube.com" or "music.youtube.com")
        {
            if (path.FirstOrDefault() == "watch")
                id = u.Query.TrimStart('?').Split('&').Select(p => p.Split('=')).FirstOrDefault(p => p.Length == 2 && p[0] == "v")?[1];
            else if (path.Length > 1 && path[0] is "shorts" or "embed" or "live") id = path[1];
        }
        return id != null && Regex.IsMatch(id, "^[A-Za-z0-9_-]{11}$") ? id : null;
    }

    public YouTubePresenter()
    {
        var next = new Button { Content = "Next presentation", Margin = new Thickness(6, 0, 0, 0), Padding = new Thickness(10, 4, 10, 4) };
        next.Click += (_, _) => Finish();
        var skip = new Button { Content = "Skip preshow", Margin = new Thickness(6, 0, 0, 0), Padding = new Thickness(10, 4, 10, 4) };
        skip.Click += (_, _) => { SkipAllRequested?.Invoke(); Finish(); };
        var header = new DockPanel { Margin = new Thickness(0, 0, 0, 8) };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal };
        buttons.Children.Add(next); buttons.Children.Add(skip);
        DockPanel.SetDock(buttons, Dock.Right);
        header.Children.Add(buttons);
        header.Children.Add(new TextBlock { Text = "▶  ZMF THEATERS+ · YOUTUBE PRESENTATION", FontWeight = FontWeights.Black, Foreground = Brushes.White, VerticalAlignment = VerticalAlignment.Center });
        header.Children.Add(badge);
        var stack = new StackPanel();
        stack.Children.Add(header);
        webHost.Height = 9.0 / 16 * 900;
        webHost.Background = Brushes.Black;
        stack.Children.Add(webHost);
        stack.Children.Add(titleText);
        stack.Children.Add(note);
        Panel = new Border
        {
            Child = stack, Padding = new Thickness(14), CornerRadius = new CornerRadius(14), Width = 928,
            Background = new SolidColorBrush(Color.FromArgb(0xF0, 0x08, 0x08, 0x0C)),
            BorderBrush = new SolidColorBrush(Color.FromArgb(0x55, 0x4D, 0xD0, 0xE1)), BorderThickness = new Thickness(1),
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Visibility = Visibility.Collapsed,
        };
    }

    static string WebFolder => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ZMFTheaters", "web");

    async Task<bool> EnsureWebAsync()
    {
        if (web?.CoreWebView2 != null) return true;
        try
        {
            Directory.CreateDirectory(WebFolder);
            File.WriteAllText(Path.Combine(WebFolder, "yt.html"), PageHtml);
            var env = await CoreWebView2Environment.CreateAsync(null,
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ZMFTheaters", "WebView2"));
            web = new WebView2 { DefaultBackgroundColor = System.Drawing.Color.Black };
            webHost.Children.Add(web);
            await web.EnsureCoreWebView2Async(env);
            web.CoreWebView2.SetVirtualHostNameToFolderMapping(Host, WebFolder, CoreWebView2HostResourceAccessKind.Allow);
            web.CoreWebView2.Settings.AreDevToolsEnabled = false;
            web.CoreWebView2.WebMessageReceived += OnMessage;
            await web.CoreWebView2.AddScriptToExecuteOnDocumentCreatedAsync(WatchClockScript);
            return true;
        }
        catch (Exception ex)
        {
            note.Text = "YouTube presentations need the Microsoft Edge WebView2 Runtime (included with Windows 10/11): " + ex.Message;
            return false;
        }
    }

    /// Shows the presentation and completes when it ends, errors or is skipped.
    public async Task PlayAsync(string id, string title, bool stereo, bool fourDX, CancellationToken ct)
    {
        videoId = id; watchPage = false; Playing = false; Time = 0;
        titleText.Text = title;
        badge.Text = (fourDX, stereo) switch { (true, true) => "4DX 3D", (true, false) => "4DX VIRTUAL MOTION", (false, true) => "3D · red/cyan", _ => "2D" };
        note.Text = stereo ? "Put on red/cyan glasses. Press Play in the player if it doesn't start." : "Press Play in the player if it doesn't start.";
        Panel.Visibility = Visibility.Visible;
        done = new TaskCompletionSource<bool>();
        using var reg = ct.Register(() => Finish());
        if (await EnsureWebAsync())
            web!.CoreWebView2.Navigate($"https://{Host}/yt.html?v={id}&s3d={(stereo ? 1 : 0)}");
        else
            await Task.WhenAny(done.Task, Task.Delay(6000, CancellationToken.None));
        var timeout = Task.Delay(TimeSpan.FromMinutes(6), CancellationToken.None);
        await Task.WhenAny(done.Task, timeout);
        Finish();
        Panel.Visibility = Visibility.Collapsed;
        try { web?.CoreWebView2?.Navigate("about:blank"); } catch { }
    }

    void Finish() { Playing = false; var d = done; done = null; d?.TrySetResult(true); }

    /// Pushes the current 4DX screen-layer values into the page (~20 Hz).
    public void SendFx(double water, double wind, double flash, double shakeX, double shakeY, double roll)
    {
        if (web?.CoreWebView2 == null || watchPage || !Active) return;
        string F(double v) => (double.IsFinite(v) ? v : 0).ToString("0.###", CultureInfo.InvariantCulture);
        _ = web.CoreWebView2.ExecuteScriptAsync($"window.zmfFX&&zmfFX({F(water)},{F(wind)},{F(flash)},{F(shakeX)},{F(shakeY)},{F(roll)})");
    }

    void OnMessage(object? sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        try
        {
            using var doc = JsonDocument.Parse(e.WebMessageAsJson);
            var root = doc.RootElement;
            var kind = root.GetProperty("kind").GetString();
            switch (kind)
            {
                case "tick":
                    Playing = root.GetProperty("playing").GetBoolean();
                    var t = root.GetProperty("time").GetDouble();
                    Time = double.IsFinite(t) ? Math.Max(0, t) : 0;
                    break;
                case "ended": Finish(); break;
                case "error":
                    var code = root.GetProperty("code").GetInt32();
                    if (code is 101 or 150 or 152 or 153 && !watchPage)
                    {
                        watchPage = true;
                        note.Text = "This uploader limits embedded playback, so it's playing on YouTube's own page.";
                        web!.CoreWebView2.Navigate("https://www.youtube.com/watch?v=" + videoId);
                    }
                    else { note.Text = $"YouTube could not play this video (error {code})."; _ = Task.Delay(2500).ContinueWith(_ => Panel.Dispatcher.BeginInvoke(Finish)); }
                    break;
            }
        }
        catch { }
    }

    const string WatchClockScript = """
        (function(){
          if (!/(^|\.)youtube\.com$/.test(location.hostname)) return;
          var ended = false;
          setInterval(function(){
            var v = document.querySelector('video'); if (!v) return;
            window.chrome.webview.postMessage({kind:'tick', playing: !v.paused && !v.ended && v.readyState > 2, time: v.currentTime || 0});
            if (v.ended && !ended) { ended = true; window.chrome.webview.postMessage({kind:'ended'}); }
          }, 350);
        })();
        """;

    const string PageHtml = """
        <!doctype html><html><head><meta charset="utf-8"><meta name="referrer" content="strict-origin-when-cross-origin">
        <style>html,body{margin:0;background:#000;width:100%;height:100%;overflow:hidden}
        #wrap{position:absolute;inset:0;transform-origin:50% 50%}#player{width:100%;height:100%}
        #wrap.s3d{filter:url(#zmfAnaglyph)}#fx{position:absolute;inset:0;pointer-events:none}</style></head><body>
        <svg width="0" height="0" style="position:absolute"><filter id="zmfAnaglyph" color-interpolation-filters="sRGB" x="0" y="0" width="100%" height="100%">
          <feOffset in="SourceGraphic" id="zl" dx="-5" result="L"/>
          <feColorMatrix in="L" type="matrix" values="0.3 0.6 0.1 0 0  0 0 0 0 0  0 0 0 0 0  0 0 0 1 0" result="R"/>
          <feOffset in="SourceGraphic" id="zr" dx="5" result="Rt"/>
          <feColorMatrix in="Rt" type="matrix" values="0 0 0 0 0  0 1 0 0 0  0 0 1 0 0  0 0 0 1 0" result="C"/>
          <feComposite in="R" in2="C" operator="arithmetic" k1="0" k2="1" k3="1" k4="0"/></filter></svg>
        <div id="wrap"><div id="player"></div></div><canvas id="fx"></canvas>
        <script>
        var q = new URLSearchParams(location.search), vid = q.get('v') || '';
        function tell(m){ try { window.chrome.webview.postMessage(m); } catch(e){} }
        if (q.get('s3d') === '1') { var d = Math.max(2, Math.round(innerWidth * 0.006)); document.getElementById('zl').setAttribute('dx', -d); document.getElementById('zr').setAttribute('dx', d); document.getElementById('wrap').className = 's3d'; }
        var player;
        function onYouTubeIframeAPIReady(){
          player = new YT.Player('player', { videoId: vid, width:'100%', height:'100%',
            playerVars:{playsinline:1, controls:1, rel:0, autoplay:1, enablejsapi:1, origin: location.origin, widget_referrer: location.origin},
            events:{ onStateChange:function(e){ if(e.data===0) tell({kind:'ended'}); },
                     onError:function(e){ tell({kind:'error', code:e.data}); } } });
        }
        setInterval(function(){ if (player && player.getPlayerState) { try { tell({kind:'tick', playing: player.getPlayerState()===1, time: player.getCurrentTime()||0}); } catch(e){} } }, 350);
        // 4DX screen layer: water droplets, mist, wind streaks, flash; the picture leans with the seat.
        var fx = {water:0, wind:0, flash:0}, cv = document.getElementById('fx'), cx = cv.getContext('2d');
        function zmfFX(w, wd, f, sx, sy, r){ fx.water = w; fx.wind = wd; fx.flash = f;
          document.getElementById('wrap').style.transform = 'translate(' + (sx*100).toFixed(2) + 'px,' + (sy*100).toFixed(2) + 'px) rotate(' + (r*20).toFixed(3) + 'deg)'; }
        function h(n){ var v = Math.sin(n*12.9898)*43758.5453; return v - Math.floor(v); }
        function frame(ts){
          var W = cv.width = innerWidth, H = cv.height = innerHeight, t = ts/1000; cx.clearRect(0,0,W,H);
          if (fx.water > 0.02) { cx.fillStyle = 'rgba(255,255,255,' + Math.min(0.16, fx.water*0.1) + ')'; cx.fillRect(0,0,W,H); }
          var n = Math.floor(Math.min(1, fx.water)*70);
          for (var i=0;i<n;i++){ var s=i*7.31, life=(t*(0.08+h(s+3)*0.16)+h(s))%1, fade=Math.min(1,life/0.05)*Math.min(1,(1-life)/0.4);
            var r=(3+h(s+1)*9)*(W/900+0.4), x=h(s+2)*W, y=h(s+5)*H+life*H*0.18*h(s+9);
            var g=cx.createRadialGradient(x,y,0,x,y,r*1.2); g.addColorStop(0,'rgba(255,255,255,'+0.05*fade+')'); g.addColorStop(0.75,'rgba(220,235,255,'+0.24*fade+')'); g.addColorStop(1,'rgba(0,10,20,'+0.3*fade+')');
            cx.fillStyle=g; cx.beginPath(); cx.ellipse(x,y,r,r*1.15,0,0,6.283); cx.fill();
            cx.fillStyle='rgba(255,255,255,'+0.7*fade+')'; cx.beginPath(); cx.ellipse(x-r*0.25,y-r*0.55,r*0.2,r*0.16,0,0,6.283); cx.fill(); }
          var m = Math.floor(fx.wind*26); cx.strokeStyle='rgba(255,255,255,'+fx.wind*0.25+')'; cx.lineWidth=1.2;
          for (var k=0;k<m;k++){ var s2=k*3.7+100, yy=h(s2)*H; if (Math.abs(yy/H-0.5)<0.22 && h(s2+6)<0.7) continue;
            var len=(0.08+h(s2+1)*0.18)*W, xx=((t*(0.9+h(s2+2)*1.6)+h(s2+3))%1)*(W+len)-len; cx.beginPath(); cx.moveTo(xx,yy); cx.lineTo(xx+len,yy+len*0.02); cx.stroke(); }
          if (fx.flash > 0.01) { cx.fillStyle='rgba(255,250,240,'+Math.min(0.35,fx.flash)+')'; cx.fillRect(0,0,W,H); }
          requestAnimationFrame(frame);
        }
        requestAnimationFrame(frame);
        </script><script src="https://www.youtube.com/iframe_api"></script></body></html>
        """;
}
