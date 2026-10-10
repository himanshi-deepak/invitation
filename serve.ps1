# The page is an ES-module app, so it must be served over http:// (file:// is blocked by CORS).
param([int]$Port = 8777)

$url = "http://localhost:$Port/"
Write-Host "Serving $PSScriptRoot on $url" -ForegroundColor Cyan
Start-Process $url
python -m http.server $Port --directory $PSScriptRoot
