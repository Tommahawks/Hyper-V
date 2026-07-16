# PowerShell script to generate PDF documentation from README.md
param(
    [string]$MarkdownFile = "README.md",
    [string]$OutputFile = "HyperV-Lab-Instructions.pdf"
)

Write-Host "=== Hyper-V Automation Lab Deploy - Documentation Generator ===" -ForegroundColor Cyan
Write-Host ""

# Check if markdown file exists
if (-not (Test-Path $MarkdownFile)) {
    Write-Host "Error: Markdown file '$MarkdownFile' not found!" -ForegroundColor Red
    exit 1
}

Write-Host "Reading README.md and generating HTML documentation..." -ForegroundColor Yellow

# Read markdown content
$markdownContent = Get-Content -Path $MarkdownFile -Raw

# Simple markdown to HTML conversion function
function Convert-MarkdownToHtml {
    param([string]$Markdown)
    
    # Split into lines for processing
    $lines = $Markdown -split '\r?\n'
    $htmlLines = @()
    $inCodeBlock = $false
    
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        
        # Handle code blocks
        if ($line -match '^```(.*)$') {
            if (-not $inCodeBlock) {
                $inCodeBlock = $true
                $htmlLines += '<pre><code>'
            } else {
                $inCodeBlock = $false
                $htmlLines += '</code></pre>'
            }
            continue
        }
        
        if ($inCodeBlock) {
            # Escape HTML special characters in code blocks
            $escapedLine = [System.Security.SecurityElement]::Escape($line)
            $htmlLines += $escapedLine
            continue
        }
        
        # Handle empty lines
        if ([string]::IsNullOrWhiteSpace($line)) {
            $htmlLines += ''
            continue
        }
        
        # Handle headers (h1-h6)
        if ($line -match '^(#{1,6})\s+(.*)$') {
            $level = $matches[1].Length
            $headerText = $matches[2]
            
            # Convert inline code in headers
            $headerText = $headerText -replace '`([^`]+)`', '<code>$1</code>'
            
            $htmlLines += "<h$level>$headerText</h$level>"
            continue
        }
        
        # Handle unordered lists
        if ($line -match '^\s*-\s+(.*)$') {
            $item = $matches[1]
            # Convert bold and inline code in list items
            $item = $item -replace '\*\*([^*]+)\*\*', '<strong>$1</strong>'
            $item = $item -replace '`([^`]+)`', '<code>$1</code>'
            $htmlLines += "<li>$item</li>"
            continue
        }
        
        # Handle ordered lists
        if ($line -match '^\s*\d+\.\s+(.*)$') {
            $item = $matches[1]
            $item = $item -replace '\*\*([^*]+)\*\*', '<strong>$1</strong>'
            $item = $item -replace '`([^`]+)`', '<code>$1</code>'
            $htmlLines += "<li>$item</li>"
            continue
        }
        
        # Handle paragraphs with bold text
        if ($line -match '^\*\*(.+)\*\*$') {
            $text = $matches[1]
            $htmlLines += "<p><strong>$text</strong></p>"
            continue
        }
        
        # Convert inline code and bold in regular lines
        $processedLine = $line
        $processedLine = $processedLine -replace '\*\*([^*]+)\*\*', '<strong>$1</strong>'
        $processedLine = $processedLine -replace '`([^`]+)`', '<code>$1</code>'
        
        # Skip if already handled as list item or header
        if (-not ($line -match '^\s*[-\d]') -and -not ($line -match '^#{1,6}')) {
            $htmlLines += "<p>$processedLine</p>"
        }
    }
    
    return $htmlLines -join "`n"
}

# Generate HTML from parsed markdown
$parsedHtml = Convert-MarkdownToHtml -Markdown $markdownContent

# Create final HTML document with styling
$htmlContent = @"
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <title>Hyper-V Automation Lab Deploy - Instructions</title>
    <style>
        body { font-family: Segoe UI, Tahoma, Geneva, Verdana, sans-serif; line-height: 1.6; max-width: 900px; margin: 40px auto; padding: 20px; color: #333; }
        h1 { color: #2c3e50; border-bottom: 2px solid #3498db; padding-bottom: 10px; }
        h2 { color: #34495e; margin-top: 25px; border-bottom: 1px solid #ecf0f1; padding-bottom: 5px; }
        h3 { color: #7f8c8d; margin-top: 20px; }
        h4 { color: #95a5a6; margin-top: 15px; }
        pre { background: #f4f4f4; padding: 15px; border-radius: 5px; overflow-x: auto; border: 1px solid #ddd; }
        code { background: #f4f4f4; padding: 2px 6px; border-radius: 3px; font-family: Consolas, Monaco, monospace; }
        blockquote { border-left: 4px solid #3498db; margin: 0; padding-left: 20px; color: #666; background: #f9f9f9; }
        table { border-collapse: collapse; width: 100%; margin: 20px 0; }
        th, td { border: 1px solid #ddd; padding: 12px; text-align: left; }
        th { background: #3498db; color: white; }
        tr:nth-child(even) { background: #f2f2f2; }
        ul, ol { margin: 15px 0; padding-left: 30px; }
        li { margin: 5px 0; }
        .note { background: #fff3cd; border-left: 4px solid #ffc107; padding: 15px; margin: 15px 0; }
        .warning { background: #f8d7da; border-left: 4px solid #dc3545; padding: 15px; margin: 15px 0; }
        .success { background: #d4edda; border-left: 4px solid #28a745; padding: 15px; margin: 15px 0; }
        a { color: #3498db; text-decoration: none; }
        a:hover { text-decoration: underline; }
        .footer { margin-top: 40px; padding-top: 20px; border-top: 1px solid #ddd; font-size: 0.9em; color: #777; text-align: center; }
    </style>
</head>
<body>
$(Convert-MarkdownToHtml -Markdown $markdownContent)
<div class="footer">
    <p>Generated on $(Get-Date -Format 'yyyy-MM-dd') | From README.md</p>
</div>
</body>
</html>
"@

# Save HTML
$htmlFile = $OutputFile -replace '\.pdf$', '.html'
Set-Content -Path $htmlFile -Value $htmlContent -Encoding UTF8
Write-Host "HTML created: $htmlFile" -ForegroundColor Green

Write-Host ""
Write-Host "=== PDF Generation Instructions ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "To convert the HTML file to PDF, use one of these methods:" -ForegroundColor Yellow
Write-Host ""
Write-Host "Method 1: Using Chrome/Edge (Recommended)" -ForegroundColor White
Write-Host "  1. Open $htmlFile in Chrome or Edge" -ForegroundColor Gray
Write-Host "  2. Press Ctrl+P (Print)" -ForegroundColor Gray
Write-Host "  3. Select 'Save as PDF' as destination" -ForegroundColor Gray
Write-Host "  4. Click 'Save'" -ForegroundColor Gray
Write-Host ""
Write-Host "Method 2: Using PowerShell (if Print-Module available)" -ForegroundColor White
Write-Host "  Install-Module -Name Print-Module -Force" -ForegroundColor Gray
Write-Host "  Then use: Print-HTMLToPDF -HtmlFile '$htmlFile' -PdfFile '$OutputFile'" -ForegroundColor Gray
Write-Host ""
Write-Host "Method 3: Using Pandoc" -ForegroundColor White
Write-Host "  pandoc '$htmlFile' -o '$OutputFile' --pdf-engine=wkhtmltopdf" -ForegroundColor Gray
Write-Host ""
Write-Host "The HTML file can also be used directly as web documentation." -ForegroundColor Cyan
