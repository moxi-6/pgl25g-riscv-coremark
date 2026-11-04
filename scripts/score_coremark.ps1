param(
    [Parameter(Mandatory=$true)][string]$CapturePath,
    [string]$OutputDir,
    [ValidateRange(1,2147483647)][long]$ClockHz=50000000,
    [ValidateRange(1,2147483647)][int]$LutCount,
    [ValidateSet('Unknown','Simulation','Fixture','BoardCapture')][string]$EvidenceKind='Unknown'
)
$ErrorActionPreference='Stop'
$capture=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($CapturePath)
if (-not (Test-Path -LiteralPath $capture -PathType Leaf)) {throw "Capture not found: $capture"}
$python=Get-Command python -ErrorAction SilentlyContinue
if (-not $python) {$python=Get-Command python3 -ErrorAction Stop}
$arguments=@((Join-Path $PSScriptRoot 'coremark_score.py'),'--capture',$capture,'--clock-hz',"$ClockHz",'--evidence-kind',$EvidenceKind)
if ($OutputDir) {$arguments+=@('--output-dir',$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDir))}
if ($PSBoundParameters.ContainsKey('LutCount')) {$arguments+=@('--lut-count',"$LutCount")}
& $python.Source @arguments
if ($LASTEXITCODE -ne 0) {throw 'CoreMark report rejected; inspect coremark_score.json.'}