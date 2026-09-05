# Script to sign the Windows executable using the generated PFX code-signing certificate
param(
    [string]$TargetPath = "$PSScriptRoot\..\..\build\windows\x64\runner\Release\epilepsy_monitor.exe"
)

$PfxPath = "$PSScriptRoot\epilepsy_codesign.pfx"
$Password = ConvertTo-SecureString "EpilepsyGraduation2026!" -AsPlainText -Force

if (-not (Test-Path $TargetPath)) {
    Write-Warning "Target executable not found at: $TargetPath"
    Write-Host "Please build the Windows app first (e.g. flutter build windows --release)"
    exit 0
}

Write-Host "Signing $TargetPath with $PfxPath..."
$cert = Get-PfxCertificate -FilePath $PfxPath -Password $Password
$result = Set-AuthenticodeSignature -FilePath $TargetPath -Certificate $cert -TimestampServer "http://timestamp.digicert.com"

if ($result.Status -eq "Valid") {
    Write-Host "Application successfully signed with valid Authenticode signature!" -ForegroundColor Green
} else {
    Write-Host "Signature status: $($result.Status) - $($result.StatusMessage)" -ForegroundColor Yellow
}
