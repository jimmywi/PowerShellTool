$message = 'Hello from Active Setup!'
$path = Join-Path $env:TEMP 'NActiveSetup-HelloWorld.txt'
$message | Set-Content -LiteralPath $path -Encoding UTF8
Write-Host $message
