# Servidor del semáforo sin dependencias (PowerShell + HttpListener).
# Simula la misma secuencia del ESP32: verde 15 s -> amarillo 5 s -> rojo 20 s.
# Sirve:  GET /            -> index.html
#         GET /api/status  -> JSON con estado actual
#         GET /events      -> Server-Sent Events (1 msg/seg)
# Uso: powershell -ExecutionPolicy Bypass -File servidor.ps1 -Port 8000
param([int]$Port = 8000)

$base = $PSScriptRoot
$indexPath = Join-Path $base 'index.html'

function Get-Estado {
  $Pin = @{ rojo = 2; amarillo = 4; verde = 5 }
  $Dur = @{ rojo = 20; verde = 15; amarillo = 5 }
  # Ciclo de 40 s: verde [0,15) -> amarillo [15,20) -> rojo [20,40)
  $t = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() % 40
  if ($t -lt 15) { $e = 'verde'; $r = 15 - $t }
  elseif ($t -lt 20) { $e = 'amarillo'; $r = 20 - $t }
  else { $e = 'rojo'; $r = 40 - $t }
  [ordered]@{
    estado = $e; restante = $r; duracion = $Dur[$e]; pin = $Pin[$e]
    conectado = $true; puerto = 'simulado'; fuente = 'simulacion'
    actualizado = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  } | ConvertTo-Json -Compress
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Start()
Write-Host "[web] http://localhost:$Port  (Ctrl+C para detener)"

try {
  while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    $req = $ctx.Request; $res = $ctx.Response
    $res.Headers.Add('Access-Control-Allow-Origin', '*')
    try {
      switch ($req.Url.AbsolutePath) {
        '/' {
          $bytes = [Text.Encoding]::UTF8.GetBytes([IO.File]::ReadAllText($indexPath))
          $res.ContentType = 'text/html; charset=utf-8'
          $res.ContentLength64 = $bytes.Length
          $res.OutputStream.Write($bytes, 0, $bytes.Length)
        }
        '/index.html' {
          $bytes = [Text.Encoding]::UTF8.GetBytes([IO.File]::ReadAllText($indexPath))
          $res.ContentType = 'text/html; charset=utf-8'
          $res.ContentLength64 = $bytes.Length
          $res.OutputStream.Write($bytes, 0, $bytes.Length)
        }
        '/api/status' {
          $bytes = [Text.Encoding]::UTF8.GetBytes((Get-Estado))
          $res.ContentType = 'application/json'
          $res.ContentLength64 = $bytes.Length
          $res.OutputStream.Write($bytes, 0, $bytes.Length)
        }
        '/events' {
          $res.ContentType = 'text/event-stream'
          $res.Headers.Add('Cache-Control', 'no-cache')
          $res.Headers.Add('Connection', 'keep-alive')
          $res.SendChunked = $true
          $w = New-Object IO.StreamWriter($res.OutputStream)
          $w.AutoFlush = $true
          try { while ($true) { $w.WriteLine('data: ' + (Get-Estado)); $w.WriteLine(); Start-Sleep -Seconds 1 } }
          catch { }
          finally { $w.Dispose() }
        }
        default { $res.StatusCode = 404 }
      }
    } catch { }
    finally { try { $res.OutputStream.Close() } catch { } }
  }
} finally { $listener.Stop() }
