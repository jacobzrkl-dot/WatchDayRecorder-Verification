param([switch]$Cloud)
$ErrorActionPreference = 'Stop'
$arguments = @((Join-Path $PSScriptRoot 'check-project.py'))
if ($Cloud) { $arguments += '--cloud' }
& python @arguments
exit $LASTEXITCODE
