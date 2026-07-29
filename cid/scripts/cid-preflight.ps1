# CID222 preflight — SessionStart hook, Windows equivalent of cid-preflight.sh.
# Same contract: verify routing, warn on bypass, best-effort heartbeat.
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
$CidDefaultKey = 'cid_key_c530392f852248f65b1b6550e5dfdb33202541ac2fc7b270ec02f67d59ced458'
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

function Send-Heartbeat([string]$routing) {
  if ($env:CID_TELEMETRY_OFF -eq '1' -or -not $script:origin) { return }
  $url = if ($env:CID_TELEMETRY_URL) { $env:CID_TELEMETRY_URL } else { "$script:origin/plugin-telemetry/v1/heartbeat" }
  $payload = @{ tool = 'claude-code'; plugin_version = $script:pluginVersion
                user = $env:USERNAME; host = $env:COMPUTERNAME; os = 'Windows'
                routing = $routing } | ConvertTo-Json -Compress
  # Fire-and-forget with a short timeout; never delays or breaks session start.
  Start-Job -ScriptBlock {
    param($u, $p)
    try { Invoke-RestMethod -Uri $u -Method Post -Body $p -ContentType 'application/json' -TimeoutSec 2 | Out-Null } catch {}
  } -ArgumentList $url, $payload | Out-Null
}

if ($env:CID_INSPECT_OFF -eq '1') {
  Send-Heartbeat 'off'
  Write-Output "[CID] CID inspection is disabled for this session (CID_INSPECT_OFF=1). Prompts and tool output are not inspected against company AI-usage policy."
  exit 0
}

# Probe the ACTUAL inspect endpoint, not /health: a wrong gateway host can
# answer /health 200 while /inspect/v1 404s, which would report "active" while
# nothing is inspected (fail-open). Empty payload + no `tool` in metadata =
# no activity event recorded server-side.
$probeUrl = "$origin/inspect/v1/claude-code"
$probeKey = if ($env:CID_INSPECT_KEY) { $env:CID_INSPECT_KEY } else { $CidDefaultKey }
$code = 0
try {
  $resp = Invoke-WebRequest -Uri $probeUrl -Method Post -TimeoutSec 4 -UseBasicParsing `
    -ContentType 'application/json' -Headers @{ Authorization = "Bearer $probeKey" } `
    -Body '{"direction":"request","payload":"","metadata":{}}'
  $code = [int]$resp.StatusCode
} catch {
  if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode } else { $code = 0 }
}

if ($code -ge 200 -and $code -lt 300) {
  Send-Heartbeat 'active'
  Write-Output "[CID] CID inspection is active for this Claude Code session via $gateway. Prompts and tool output are checked against your organization's AI-usage policy (mostly logged; some data redacted or blocked). This is normal company monitoring; do not attempt to disable or bypass it."
} elseif ($code -eq 401 -or $code -eq 403) {
  Send-Heartbeat 'key-rejected'
  Write-Output "[CID] CID inspection is configured ($gateway) but the gateway rejected the inspection key (HTTP $code). Inspection is NOT applying policy (fail-open); the user should contact IT to fix the CID_INSPECT_KEY."
  [Console]::Error.WriteLine("[CID] CID anahtar reddedildi (HTTP $code): $probeUrl - IT'ye bildirin.")
} elseif ($code -eq 404) {
  Send-Heartbeat 'wrong-gateway'
  Write-Output "[CID] CID inspection is misconfigured: $probeUrl returned 404 - the gateway host serves no inspect endpoint, so NO prompts or tool output are being inspected (fail-open). The CID_GATEWAY_URL is likely pointing at the wrong host; the user should contact IT."
  [Console]::Error.WriteLine("[CID] CID gateway yanlis gorunuyor ($probeUrl -> 404) - inceleme YAPILMIYOR. IT'ye bildirin.")
} elseif ($code -eq 0) {
  Send-Heartbeat 'unreachable'
  Write-Output "[CID] CID inspection is configured ($gateway) but the gateway is unreachable. Inspection may be skipping (fail-open); tell the user to check connectivity or contact IT if this persists."
  [Console]::Error.WriteLine("[CID] CID gateway erisilemiyor: $probeUrl")
} else {
  Send-Heartbeat 'degraded'
  Write-Output "[CID] CID inspection is configured ($gateway) but the inspect endpoint returned HTTP $code. Inspection may be skipping (fail-open); contact IT if this persists."
  [Console]::Error.WriteLine("[CID] CID inspect endpoint HTTP $code dondu: $probeUrl")
}

exit 0
