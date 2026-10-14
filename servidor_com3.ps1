# Servidor del semáforo con ESP32 real por USB (sin dependencias, PowerShell).
# Lee el puerto serial (115200 baud) donde el ESP32 envía una línea JSON por segundo:
#   {"estado":"rojo","restante":19,"duracion":20,"pin":2}
# y sirve:  GET /            -> index.html
#           GET /api/status  -> JSON con el último estado
#           GET /events      -> SSE (una foto del estado + retry 1 s; el navegador reconecta solo)
# Si el ESP32 no está conectado, la página muestra SIN CONEXIÓN y reintenta solo.
# Uso: powershell -ExecutionPolicy Bypass -File servidor_com3.ps1 -ComPort COM3 -WebPort 8000
param([string]$ComPort = 'COM3', [int]$BaudRate = 115200, [int]$WebPort = 8000)

$here = $PSScriptRoot
$htmlPath = Join-Path $here 'index.html'

$shared = [hashtable]::Synchronized(@{
  buf = ''
  estado = 'rojo'; restante = 20; duracion = 20; pin = 2
  conectado = $false; puerto = $ComPort; fuente = 'esp32'
  actualizado = 0
})

# --- Puerto serial (patrón probado: sin ctor con args, sin colisión de nombres) ---
$serial = New-Object System.IO.Ports.SerialPort
$serial.PortName = $ComPort
$serial.BaudRate = $BaudRate
$serial.ReadTimeout = 500

function Open-Serial {
  if ($serial.IsOpen) { return $true }
  try {
    $serial.Open()
    Write-Host ('[serial] conectado a ' + $ComPort + ' @ ' + $BaudRate)
    return $true
  } catch {
    return $false
  }
}

if (-not (Open-Serial)) {
  Write-Host ('[serial] ' + $ComPort + ' no disponible todavía; reintentando solo.')
  Write-Host ('[info] puertos visibles: ' + (([System.IO.Ports.SerialPort]::GetPortNames()) -join ', '))
}

# Hilo de eventos: cada bloque que llega se parsea y actualiza el estado compartido.
$sub = Register-ObjectEvent -InputObject $serial -EventName DataReceived -MessageData $shared -Action {
  $sh = $Event.MessageData
  try { $rx = $Event.Sender.ReadExisting() } catch { return }
  if ([string]::IsNullOrEmpty($rx)) { return }
  $sh.buf += $rx
  $parts = $sh.buf -split "`n"
  $sh.buf = $parts[-1]
  for ($k = 0; $k -lt $parts.Count - 1; $k++) {
    $ln = $parts[$k].Trim()
    if (-not $ln) { continue }
    try { $msg = $ln | ConvertFrom-Json } catch { continue }  # ignora boot del ESP32, etc.
    $st = "$($msg.estado)".ToLower()
    if ($st -notin @('rojo', 'verde', 'amarillo')) { continue }
    $sh.estado = $st
    $sh.restante = [int]$msg.restante
    $sh.duracion = [int]$msg.duracion
    $sh.pin = [int]$msg.pin
    $sh.conectado = $true
    $sh.fuente = 'esp32'
    $sh.actualizado = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  }
}

function Get-Json {
  $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $con = $shared.conectado -and (($now - $shared.actualizado) -le 3)
  [ordered]@{
    estado = $shared.estado; restante = $shared.restante; duracion = $shared.duracion
    pin = $shared.pin; conectado = $con; puerto = $shared.puerto
    fuente = $shared.fuente; actualizado = $shared.actualizado
  } | ConvertTo-Json -Compress
}

# --- Servidor web (un hilo; /events responde una foto y cierra: sin inanición) ---
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add(('http://localhost:' + $WebPort + '/'))
$listener.Prefixes.Add(('http://127.0.0.1:' + $WebPort + '/'))
$listener.Start()
Write-Host ('[web] http://localhost:' + $WebPort + '  leyendo de ' + $ComPort + '  (Ctrl+C para detener)')

$lastTry = 0
try {
  $ar = $listener.BeginGetContext($null, $null)
  while ($listener.IsListening) {
    if ($ar.AsyncWaitHandle.WaitOne(500)) {
      $ctx = $listener.EndGetContext($ar)
      $ar = $listener.BeginGetContext($null, $null)
      $rq = $ctx.Request; $rp = $ctx.Response
      $rp.Headers.Add('Access-Control-Allow-Origin', '*')
      try {
        switch ($rq.Url.AbsolutePath) {
          '/' {
            $bytes = [Text.Encoding]::UTF8.GetBytes([IO.File]::ReadAllText($htmlPath))
            $rp.ContentType = 'text/html; charset=utf-8'
            $rp.ContentLength64 = $bytes.Length
            $rp.OutputStream.Write($bytes, 0, $bytes.Length)
          }
          '/index.html' {
            $bytes = [Text.Encoding]::UTF8.GetBytes([IO.File]::ReadAllText($htmlPath))
            $rp.ContentType = 'text/html; charset=utf-8'
            $rp.ContentLength64 = $bytes.Length
            $rp.OutputStream.Write($bytes, 0, $bytes.Length)
          }
          '/api/status' {
            $bytes = [Text.Encoding]::UTF8.GetBytes((Get-Json))
            $rp.ContentType = 'application/json'
            $rp.ContentLength64 = $bytes.Length
            $rp.OutputStream.Write($bytes, 0, $bytes.Length)
          }
          '/events' {
            $body = 'retry: 1000' + "`n" + 'data: ' + (Get-Json) + "`n`n"
            $bytes = [Text.Encoding]::UTF8.GetBytes($body)
            $rp.ContentType = 'text/event-stream'
            $rp.Headers.Add('Cache-Control', 'no-cache')
            $rp.ContentLength64 = $bytes.Length
            $rp.OutputStream.Write($bytes, 0, $bytes.Length)
          }
          default { $rp.StatusCode = 404 }
        }
      } catch { }
      finally { try { $rp.OutputStream.Close() } catch { } }
    }
    # Reintento de apertura del serial cada 3 s (por si el ESP32 se conecta después)
    $nowS = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if ((-not $serial.IsOpen) -and ($nowS - $lastTry -ge 3)) {
      $lastTry = $nowS
      if (Open-Serial) { $shared.puerto = $ComPort }
    }
  }
} finally {
  Unregister-Event -SubscriptionId $sub.Id -ErrorAction SilentlyContinue
  try { $serial.Close() } catch { }
  $listener.Stop()
}
