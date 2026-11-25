# Tiny static file server for local preview (no Node/Python needed).
# Usage: powershell -ExecutionPolicy Bypass -File scripts/serve.ps1 [-Port 8123]
param([int]$Port = 8123)

$root = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$mime = @{
  '.html' = 'text/html; charset=utf-8'; '.js' = 'text/javascript; charset=utf-8'; '.css' = 'text/css; charset=utf-8'
  '.json' = 'application/json; charset=utf-8'; '.webmanifest' = 'application/manifest+json; charset=utf-8'
  '.ics' = 'text/calendar; charset=utf-8'; '.png' = 'image/png'; '.svg' = 'image/svg+xml'; '.ico' = 'image/x-icon'
}
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()
Write-Host "Serving $root at http://localhost:$Port/"
try {
  while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    try {
      $rel = [uri]::UnescapeDataString($ctx.Request.Url.AbsolutePath).TrimStart('/')
      if (-not $rel) { $rel = 'index.html' }
      $path = [System.IO.Path]::GetFullPath((Join-Path $root $rel))
      if ($path.StartsWith($root + [System.IO.Path]::DirectorySeparatorChar) -and (Test-Path $path -PathType Leaf)) {
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $ext = [System.IO.Path]::GetExtension($path).ToLowerInvariant()
        $ctx.Response.ContentType = if ($mime.ContainsKey($ext)) { $mime[$ext] } else { 'application/octet-stream' }
        $ctx.Response.Headers.Add('Cache-Control', 'no-cache')
        $ctx.Response.ContentLength64 = $bytes.Length
        $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
      } else {
        $ctx.Response.StatusCode = 404
      }
      Write-Host "$($ctx.Response.StatusCode) /$rel"
    } catch {
      Write-Host "error: $($_.Exception.Message)"
    } finally {
      $ctx.Response.Close()
    }
  }
} finally {
  $listener.Stop()
}
