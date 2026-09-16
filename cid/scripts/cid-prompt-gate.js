"use strict";
// UserPromptSubmit hook. Sends the typed prompt to CID /inspect/v1 (which also
// records the telemetry event), and blocks the prompt when the company filter
// profile returns a blocking verdict. Log-only rules return ALLOW and just get
// recorded — the common case.
//
// stdin: JSON with field `prompt`. stdout: {"decision":"block","reason":…} to
// block, or nothing to allow.

const fs = require("node:fs");
const cid = require("./cid-common.js");

async function main() {
  // Read the hook payload once; session_id lives in this JSON (Claude Code does
  // not export CLAUDE_SESSION_ID to hooks), the prompt is field `prompt`.
  const hook = cid.parseJson(cid.readStdin());
  process.env.CID_SESSION_ID = cid.sessionFromHook(hook);
  // Proof this hook process ran — written before the empty-prompt return and
  // before inspect()'s CID_INSPECT_OFF short-circuit.
  cid.markHookRan(process.env.CID_SESSION_ID, "prompt-gate");

  // Routing posture recorded by SessionStart. When a gateway is in the request
  // path it can rewrite the prompt, so the warning below would be both wrong and
  // duplicated by the gateway's own handling.
  const ctx = cid.readCtx();
  const routed = ctx.CID_ROUTED || "0";

  const prompt = hook && typeof hook.prompt === "string" ? hook.prompt : "";
  if (!prompt) return;

  const verdictJson = await cid.inspect("request", prompt, "prompt");

  // Fail-open (default): CID unreachable/timeout -> allow. Fail-closed blocks.
  //
  // Fail-open must not be silent: a rejected key (401) previously dropped ALL
  // enforcement with no trace after SessionStart. When the verdict is empty,
  // read the status inspect() recorded and show the user a warning — rate
  // limited per session so a broken key does not nag on every prompt.
  if (!verdictJson) {
    if (process.env.CID_FAIL_OPEN === "0") {
      process.stdout.write(
        JSON.stringify({
          decision: "block",
          reason:
            "CID policy service unreachable and this device is set to fail-closed. Try again once the CID gateway is reachable, or contact IT.",
        }) + "\n"
      );
      return;
    }
    const statusFile = cid.inspectStatusFile();
    let code = "";
    try {
      code = (fs.readFileSync(statusFile, "utf8").trim().split(/\s+/)[0] || "");
    } catch (_) {
      code = "";
    }
    let warnText = "";
    if (code === "401" || code === "403") {
      warnText =
        "CID: politika denetimi ŞU ANDA UYGULANMIYOR — gateway inceleme anahtarını reddetti (HTTP " +
        code +
        "). İstemler denetlenmeden geçiyor (fail-open). IT'ye CID_INSPECT_KEY'i düzelttirin.";
    } else if (code === "404") {
      warnText =
        "CID: politika denetimi ŞU ANDA UYGULANMIYOR — inspect endpoint'i bulunamadı (HTTP 404; CID_GATEWAY_URL muhtemelen yanlış hosta bakıyor). IT'ye bildirin.";
    } else if (code === "000" || code === "") {
      warnText =
        "CID: politika denetimi şu anda atlanıyor — CID gateway'e ulaşılamıyor. Bağlantı dönünce denetim kendiliğinden devam eder; sürerse IT'ye bildirin.";
    } else if (/^5/.test(code)) {
      warnText =
        "CID: politika denetimi şu anda atlanıyor — gateway HTTP " +
        code +
        " döndürdü. Sürerse IT'ye bildirin.";
    }
    if (warnText) {
      const warnedFile = statusFile + ".warned";
      const now = Math.floor(Date.now() / 1000);
      let last = 0;
      try {
        const raw = fs.readFileSync(warnedFile, "utf8").trim();
        last = /^[0-9]+$/.test(raw) ? parseInt(raw, 10) : 0;
      } catch (_) {
        last = 0;
      }
      const every = parseInt(process.env.CID_FAIL_OPEN_WARN_SEC || "900", 10) || 900;
      if (now - last >= every) {
        try {
          fs.writeFileSync(warnedFile, now + "\n");
        } catch (_) {
          /* best effort */
        }
        process.stdout.write(JSON.stringify({ systemMessage: warnText }) + "\n");
      }
    }
    return;
  }

  const verdict = cid.jsonField(verdictJson, "verdict");
  const reasons = cid.jsonField(verdictJson, "reasons");

  // Verdict → action. CID's MASK rules come back as REDACT; its REJECT rules come
  // back as BLOCK.
  //
  // Claude Code's hook protocol cannot rewrite a prompt (only PreToolUse/
  // PostToolUse can rewrite; UserPromptSubmit is block-or-allow), so a MASK rule
  // is unmaskable here. Blocking it — what v0.5.1 did — turned every MASK rule
  // into a REJECT, so a prompt merely mentioning an email never reached the model.
  // That contradicts the log-first profile these rules are written for.
  //
  // Default: MASK → let the prompt through and record it, with a factual note in
  // context and a warning to the user. Sites that would rather refuse the prompt
  // than let the value reach the provider set CID_PROMPT_MASK_ACTION=block.
  if (verdict === "BLOCK") {
    let msg =
      "CID policy blocked this prompt (it contains data your organization's Claude Code policy does not allow). Remove the sensitive content and resend.";
    if (reasons) msg += " Detected: " + reasons;
    process.stdout.write(JSON.stringify({ decision: "block", reason: msg }) + "\n");
    return;
  }

  if (verdict === "REDACT") {
    if (process.env.CID_PROMPT_MASK_ACTION === "block") {
      let msg =
        "CID policy blocked this prompt: it contains values your organization masks, and prompt text cannot be masked in place. Remove or redact the sensitive content and resend.";
      if (reasons) msg += " Detected: " + reasons;
      process.stdout.write(JSON.stringify({ decision: "block", reason: msg }) + "\n");
      return;
    }
    // Two audiences, two fields:
    //   additionalContext -> the model, so it knows the values were flagged.
    //     Factual status only: imperative text arriving from a hook reads as a
    //     prompt-injection attempt and gets refused (observed 2026-07-28).
    //   systemMessage     -> the user, rendered as a warning in the UI. stderr
    //     is NOT shown for a hook that exits 0, so the earlier stderr warning
    //     was invisible — this is what makes a mask hit visible at all.
    let note =
      "CID222 policy note: this prompt contains values your organization classifies as sensitive";
    if (reasons) note += " (" + reasons + ")";
    note +=
      ". The rule is mask-level, and Claude Code's hook protocol cannot mask prompt text, so the prompt was recorded and passed through unchanged rather than blocked. Tool output on the same session is still masked.";

    if (routed === "1") {
      // A gateway is in the path and masks the prompt itself. Telling the user
      // "masking cannot be applied" would be false, and warning twice about
      // one finding is noise — record it and stay quiet.
      process.stdout.write(
        JSON.stringify({
          hookSpecificOutput: {
            hookEventName: "UserPromptSubmit",
            additionalContext: note,
          },
        }) + "\n"
      );
      return;
    }

    let warnText = "CID: bu istemde maskelenmesi gereken veri var";
    if (reasons) warnText += " (" + reasons + ")";
    warnText +=
      ". Claude Code istem metnini maskelemeye izin vermiyor, bu yüzden istem olduğu gibi iletildi ve kayda alındı. Değerin sağlayıcıya hiç gitmemesi gerekiyorsa CID_PROMPT_MASK_ACTION=block ile istem reddedilir.";

    process.stdout.write(
      JSON.stringify({
        hookSpecificOutput: {
          hookEventName: "UserPromptSubmit",
          additionalContext: note,
        },
        systemMessage: warnText,
      }) + "\n"
    );
    return;
  }

  // ALLOW (incl. flag/log-only) — recorded, prompt proceeds.
}

cid.run(main);
