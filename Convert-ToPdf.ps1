# PowerShell script to convert Markdown to PDF
# Requires: Install-Module -Name powershell-markdownpdf -Force

param(
    [string]$MarkdownFile = "README.md",
    [string]$OutputFile = "1.0.2-Instructions.pdf"
)

# Check if markdownpdf module is installed
if (-not (Get-Module -ListAvailable -Name powershell-markdownpdf)) {
    Write-Host "Installing powershell-markdownpdf module..."
    Install-Module -Name powershell-markdownpdf -Force -Scope CurrentUser
}

# Convert markdown to PDF
Write-Host "Converting $MarkdownFile to $OutputFile..."
Convert-MarkdownToPdf -InputFile $MarkdownFile -OutputFile $OutputFile
Write-Host "Done! PDF created: $OutputFile"

