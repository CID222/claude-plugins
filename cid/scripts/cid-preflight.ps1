# CID222 preflight — SessionStart hook, Windows equivalent of cid-preflight.sh.
# Same contract: verify inspection reachability, warn on bypass, announce the
# session (seat/repo/branch) so gateway token reports can be attributed.
# Stdout is added to Claude's context; stderr is shown to the user.
#
# NOTE ON WORDING: stdout is a FACTUAL STATUS REPORT only — never an
# instruction to the model ("tell the user…", "do not suggest…"), which models
# correctly treat as a possible prompt injection and refuse to act on.
$ErrorActionPreference = 'SilentlyContinue'

if ($env:CID_PREFLIGHT_OFF -eq '1') { exit 0 }

function Normalize-Url([string]$u) {
  if ([string]::IsNullOrEmpty($u)) { return $u }
  if ($u -match '^https?://') { return $u }
  return "https://$u"
}

# Inspection model: hooks send content to <gateway>/inspect/v1. ANTHROPIC_BASE_URL
# is NOT changed. Posture = "is CID inspection configured and reachable".
$CidDefaultGateway = 'https://api.cid222.live'
$CidDefaultKey = ''
$gwEnv = if ([string]::IsNullOrEmpty($env:CID_GATEWAY_URL)) { $CidDefaultGateway } else { $env:CID_GATEWAY_URL }
$gateway = Normalize-Url $gwEnv

$origin = $null
if ($gateway) {
  try { $u = [Uri]$gateway; $origin = $u.GetLeftPart([UriPartial]::Authority) } catch {}
}

$pluginVersion = 'unknown'
if ($env:CLAUDE_PLUGIN_ROOT) {
  $manifest = Join-Path $env:CLAUDE_PLUGIN_ROOT '.claude-plugin\plugin.json'
  if (Test-Path $manifest) {
    try { $pluginVersion = (Get-Content $manifest -Raw | ConvertFrom-Json).version } catch {}
  }
}

if ($env:CID_INSPECT_OFF -eq '1') {
  Write-Output "[CID] CID inspection is disabled for this session (CID_INSPECT_OFF=1). Prompts and tool output are not inspected against company AI-usage policy."
  exit 0
}

# Identity for the probe, which doubles as this session's announcement — see the
# same block in cid-preflight.sh. A heartbeat used to go to
# /plugin-telemetry/v1/heartbeat, a path no server has ever served (404 in prod,
# 2026-07-31); this replaces it. CID_TELEMETRY_OFF=1 probes anonymously.
$probeMeta = '{}'
if ($env:CID_TELEMETRY_OFF -ne '1') {
  # Claude Code passes the hook payload on stdin and does not export
  # CLAUDE_SESSION_ID, so the session id has to be read from there.
  $sessionId = ''
  try {
    $hookJson = [Console]::In.ReadToEnd()
    if ($hookJson) { $sessionId = ([string](ConvertFrom-Json $hookJson).session_id) }
  } catch {}
  if (-not $sessionId) { $sessionId = [string]$env:CLAUDE_SESSION_ID }

  $repo = ''; $branch = ''; $cwdBase = ''
  try {
    $repo = (git config --get remote.origin.url) 2>$null
    # strip credentials embedded in the URL (https://user:tok@host/…)
    if ($repo) { $repo = [regex]::Replace($repo, '(https?://)[^@/]*@', '$1') }
    $branch = (git rev-parse --abbrev-ref HEAD) 2>$null
    $root = (git rev-parse --show-toplevel) 2>$null
    $cwdBase = Split-Path -Leaf ($(if ($root) { $root } else { $PWD.Path }))
  } catch {}

  $email = ''
  try {
    $claudeJson = Join-Path $env:USERPROFILE '.claude.json'
    if (Test-Path $claudeJson) {
      $email = [string](Get-Content $claudeJson -Raw | ConvertFrom-Json).oauthAccount.emailAddress
    }
  } catch {}

  $probeMeta = @{
    tool = 'claude-code'; event = 'session_start'
    repo = [string]$repo; branch = [string]$branch; cwd = [string]$cwdBase
    session = [string]$sessionId; user_email = $email
    plugin_version = [string]$pluginVersion
  } | ConvertTo-Json -Compress
}

# Probe the ACTUAL inspect endpoint, not /health: a wrong gateway host can
# answer /health 200 while /inspect/v1 404s, which would report "active" while
# nothing is inspected (fail-open). The empty payload carries session_start
# metadata, so a 2xx also registers who this session belongs to.
$probeUrl = "$origin/inspect/v1/claude-code"
$probeKey = if ($env:CID_INSPECT_KEY) { $env:CID_INSPECT_KEY } else { $CidDefaultKey }
if (-not $probeKey) {
  Write-Output "[CID] CID inspection has no key configured (managed CID_INSPECT_KEY was not delivered). Inspection is NOT applying policy (fail-open); the user should contact IT to deliver the managed CID_INSPECT_KEY."
  [Console]::Error.WriteLine("[CID] CID_INSPECT_KEY tanimli degil - inceleme YAPILMIYOR (fail-open). IT'ye bildirin.")
  exit 0
}
$code = 0
try {
  $resp = Invoke-WebRequest -Uri $probeUrl -Method Post -TimeoutSec 4 -UseBasicParsing `
    -ContentType 'application/json' -Headers @{ Authorization = "Bearer $probeKey" } `
    -Body "{`"direction`":`"request`",`"payload`":`"`",`"metadata`":$probeMeta}"
  $code = [int]$resp.StatusCode
} catch {
  if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode } else { $code = 0 }
}

if ($code -ge 200 -and $code -lt 300) {
  Write-Output "[CID] CID inspection is active for this Claude Code session via $gateway. Prompts and tool output are checked against your organization's AI-usage policy (mostly logged; some data redacted or blocked). This is normal company monitoring; do not attempt to disable or bypass it."
} elseif ($code -eq 401 -or $code -eq 403) {
  Write-Output "[CID] CID inspection is configured ($gateway) but the gateway rejected the inspection key (HTTP $code). Inspection is NOT applying policy (fail-open); the user should contact IT to fix the CID_INSPECT_KEY."
  [Console]::Error.WriteLine("[CID] CID anahtar reddedildi (HTTP $code): $probeUrl - IT'ye bildirin.")
} elseif ($code -eq 404) {
  Write-Output "[CID] CID inspection is misconfigured: $probeUrl returned 404 - the gateway host serves no inspect endpoint, so NO prompts or tool output are being inspected (fail-open). The CID_GATEWAY_URL is likely pointing at the wrong host; the user should contact IT."
  [Console]::Error.WriteLine("[CID] CID gateway yanlis gorunuyor ($probeUrl -> 404) - inceleme YAPILMIYOR. IT'ye bildirin.")
} elseif ($code -eq 0) {
  Write-Output "[CID] CID inspection is configured ($gateway) but the gateway is unreachable. Inspection may be skipping (fail-open); tell the user to check connectivity or contact IT if this persists."
  [Console]::Error.WriteLine("[CID] CID gateway erisilemiyor: $probeUrl")
} else {
  Write-Output "[CID] CID inspection is configured ($gateway) but the inspect endpoint returned HTTP $code. Inspection may be skipping (fail-open); contact IT if this persists."
  [Console]::Error.WriteLine("[CID] CID inspect endpoint HTTP $code dondu: $probeUrl")
}

exit 0
