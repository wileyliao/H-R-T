param(
  [string]$ComposeFile = "docker-compose.yml",
  [string]$EnvFile = ".env",
  [string]$TagVarName = "IMAGE_TAG"
)

$ComposeFile = (Resolve-Path $ComposeFile).Path
$ComposeDir  = Split-Path -Parent $ComposeFile
$EnvFile     = Join-Path $ComposeDir $EnvFile

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-RepoFromCompose {
  param([string]$Path, [string]$VarName)

  if (-not (Test-Path -LiteralPath $Path)) {
    throw "Compose file not found: $Path"
  }

  $lines = Get-Content -LiteralPath $Path -Encoding UTF8

  # Match examples:
  # image: wjcl3gj94/toolkitpv:${IMAGE_TAG}
  # image: "wjcl3gj94/toolkitpv:${IMAGE_TAG}"
  # image: 'wjcl3gj94/toolkitpv:${IMAGE_TAG}'
  $pattern = "^\s*image\s*:\s*['""]?(?<repo>[a-z0-9]+(?:[._-][a-z0-9]+)*\/[a-z0-9]+(?:[._-][a-z0-9]+)*)\s*:\s*\$\{\s*$([regex]::Escape($VarName))\s*\}['""]?\s*$"

  $matches = @()
  foreach ($l in $lines) {
    $m = [regex]::Match($l, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) { $matches += $m.Groups["repo"].Value }
  }

  if ($matches.Count -eq 0) {
    throw "No image line found in $Path matching: image: <namespace>/<repo>:`${$VarName}"
  }

  # If multiple, pick the first but warn (you can extend later)
  $unique = @($matches | Select-Object -Unique)
  if ($unique.Count -gt 1) {
    Write-Warning ("Multiple repos found using `${$VarName}: " + ($unique -join ", ") + ". Using the first one: " + $unique[0])
  }

  return $unique[0]
}

function Get-AllDockerHubTags {
  param([string]$Namespace, [string]$Repo, [int]$PageSize = 100)

  $tags = New-Object System.Collections.Generic.List[string]
  $url = "https://hub.docker.com/v2/repositories/$Namespace/$Repo/tags?page_size=$PageSize"

  while ($null -ne $url -and $url -ne "") {
    $resp = Invoke-RestMethod -Uri $url -Method Get -Headers @{ "Accept" = "application/json" }
    if ($resp -and $resp.results) {
      foreach ($r in $resp.results) {
        if ($r.name) { $tags.Add([string]$r.name) }
      }
    }
    $url = $resp.next
  }

  return $tags
}

function Get-LatestVxyTag {
  param([System.Collections.Generic.List[string]]$Tags)

  # Only accept vX.Y, where X and Y are integers
  $re = [regex]"^v(?<maj>\d+)\.(?<min>\d+)$"

  $bestMaj = -1
  $bestMin = -1
  $bestTag = $null

  foreach ($t in $Tags) {
    $m = $re.Match($t)
    if (-not $m.Success) { continue }

    $maj = [int]$m.Groups["maj"].Value
    $min = [int]$m.Groups["min"].Value

    if ($maj -gt $bestMaj -or ($maj -eq $bestMaj -and $min -gt $bestMin)) {
      $bestMaj = $maj
      $bestMin = $min
      $bestTag = $t
    }
  }

  if (-not $bestTag) {
    throw "No tags matching vX.Y found on Docker Hub."
  }

  return $bestTag
}

function Write-EnvFile {
  param([string]$Path, [string]$VarName, [string]$Value)

  # Keep it simple: rewrite the whole file with just IMAGE_TAG=...
  # (If you later want multiple vars, we can upgrade to preserve existing keys.)
  $content = "$VarName=$Value`n"
  Set-Content -LiteralPath $Path -Value $content -Encoding ASCII
}

# --- Main ---
$repoFull = Get-RepoFromCompose -Path $ComposeFile -VarName $TagVarName
$parts = $repoFull.Split("/")
if ($parts.Count -ne 2) { throw "Unexpected repo format: $repoFull (expected namespace/repo)" }

$namespace = $parts[0]
$repo = $parts[1]

Write-Host "Compose: $ComposeFile"
Write-Host "Detected repo: $namespace/$repo"
Write-Host "Fetching tags from Docker Hub..."

$allTags = Get-AllDockerHubTags -Namespace $namespace -Repo $repo
Write-Host ("Fetched {0} tags." -f $allTags.Count)

$latest = Get-LatestVxyTag -Tags $allTags
Write-Host "Latest vX.Y tag: $latest"

Write-EnvFile -Path $EnvFile -VarName $TagVarName -Value $latest
Write-Host "Wrote $EnvFile => $TagVarName=$latest"

Write-Host "Running: docker compose up -d --pull always"
docker compose -f $ComposeFile --env-file $EnvFile up -d --pull always

# .\deploy_docker.ps1
# .\deploy_docker.ps1 -ComposeFile "C:\Projects\hsai_hos_po_vision\docker-compose.yml"