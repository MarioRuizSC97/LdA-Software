# Host-mediated reviewer results rejected by native artifact admission

**Local draft — not published.** Two earlier reviewer completions were rejected before admission; a later reliability run exhausted its output budget. After the user reported applying a session-only reviewer profile and authorized another attempt, reliability completed and the review was approved and acknowledged. Root cause of the earlier malformed outputs is still not established; the successful retry is recovery evidence, not proof of a permanent integration fix.

## Observed impact

A committed-range review initially failed native artifact admission and later stalled on output-budget exhaustion. It subsequently completed successfully without changing candidate source or replaying rejected output. The validation boundary rejected the malformed outputs rather than accepting them. This report is not a confirmed application defect or evidence of invalid review approval.

## Environment and scope

| Component | Evidence |
| --- | --- |
| Host integration | Installed `gentle-pi` 4.5.1 |
| Mirrored provider contract | Bundle 1.4.0 |
| Native dependency | Package-local Gentle AI 4.3.1, verified earlier in this session's history; not rechecked during artifact diagnosis |
| Transport | `pi_host_relay` |
| Selected lenses | `review-readability`, `review-reliability` |
| Candidate | Frozen committed range, 20 changed files, 1,636 additions plus deletions |
| Reviewer model/provider | Reliability failure telemetry identifies `nan/glm5.3-flash`; earlier readability routing is not established and user configuration was not inspected |
| Final observed state | Native `approved`, followed by successful exact acknowledgement; authority consumed |

Repository name, local username, absolute home paths, lineage, opaque repository context, target identity and full artifact hashes are intentionally omitted from this shareable draft. Original evidence remains local; do not attach full rejected artifacts without a separate privacy review.

## Observed sequence (not a deterministic reproducer)

1. Inspect an existing detached worktree and start a committed-range ordinary review with readability and reliability lenses.
2. Obtain the provider-issued reviewer bindings through bound STATUS.
3. Forecast and execute the exact complete reviewer group through `gentle_review_capture_group`.
4. The first submission, for readability, is rejected with `binding_mismatch`. The tool reports two prepared reviewers and zero submitted reviewers; no lens slot is consumed.
5. Read fresh bound STATUS. It reoffers the unconsumed reviewer slots.
6. Forecast and execute one fresh readability completion using the exact current slot through `gentle_review_capture`.
7. Admission rejects this new completion for missing required finding data. It again reports no mutation.
8. Read bound STATUS once more: the review still requires reviewer results. At that checkpoint no third completion, acknowledgement, abandonment or payload rewrite had occurred.
9. After a later explicit user retry request, read fresh bound STATUS and forecast/execute one new readability completion. Native admission succeeds (`native-reviewer-result-captured`, admission `completed`). Fresh STATUS offers only reliability.
10. Forecast and execute the pending reliability slot once. The relay returns `reviewer-empty-output`: `nan/glm5.3-flash`, `stopReason: length`, elapsed 624,640 ms (about 10m25s), not timed out. Usage reports 34,231 input and 19,641 output tokens, all output classified as reasoning; one thinking block, zero text blocks and zero result-text characters. No result was admitted for this slot.
11. Read fresh bound STATUS: readability remains admitted, only reliability is pending. No automatic reliability retry follows at that checkpoint.
12. The user reports having now applied the session-only profile and explicitly requests another attempt. Read fresh bound STATUS and forecast/execute only the reoffered reliability slot once.
13. Native last-event closure reports `approved` with five nonblocking advisories. Exact `acknowledge-approved` succeeds with authority consumed. The successful run's model/provider is not included in the returned telemetry. No candidate edits, fabricated output or replay of refused bytes is involved.

All executions used the supported host relay. The initial malformed-output failures and the later empty-output budget exhaustion are distinct observations, not a claim that every model or candidate reproduces them. No configuration change was made by the agent. Applying the session profile is user-reported; the successful capture does not independently establish the chosen model or isolate routing as the cause of recovery.

## Expected versus actual

| Attempt | Expected | Actual confirmed from rejected artifact |
| --- | --- | --- |
| Group's first readability result | Echo the exact provider-bound `subject_hash`, a `sha256:` prefix followed by 64 hexadecimal characters | The completion echoed 48 hexadecimal characters; native admission rejected the binding |
| Fresh single readability result | Return findings satisfying the provider's required finding shape | Subject hash had the expected 64 hexadecimal characters, but finding entries omitted `location`; canonicalization rejected the completion |

Sanitized native rejection text:

```text
reviewer artifact admission binding_mismatch:
reviewer result echoed a different artifact subject
```

```text
canonicalize reviewer result 1: lens result finding[0]:
id, lens, location, severity, and neutral claim are required
```

The complete original errors also identify retained rejected-result files and state that the lens slot was not consumed.

## Causal evidence and limits

Installed integration source references, relative to the `gentle-pi` package root:

- `lib/review-host-relay.ts:805-825`: the submit path writes the prepared result bytes unchanged, then passes the file through the provider-issued submission form. Parent spot-check confirmed this code path.
- `lib/inprocess-reviewer.ts:11,296`: static diagnostic inspection traced reviewer invocation to the Go-materialized prompt, rather than the orchestrator's own instructions.
- `contracts/review-provider-contract-mirror/v1.4.0/bundle/schemas/lens.schema.json:9-12`: the mirrored schema specifies a 64-hex subject digest and requires finding locations.
- `lib/review-host-relay.ts:176-184`: malformed output and binding mismatch are recognized rejection conditions compatible with an unconsumed slot.

These references describe the installed copy, not an independently checked upstream source revision. Line numbers may differ in another release.

Confirmed: invalid completion payloads reached native admission, and the relay's inspected submission path does not reshape those bytes.

Not proven:

- Whether the exact native-generated reviewer prompt contained the complete hash and correct required-field instructions.
- Whether model noncompliance, prompt rendering or another integration condition caused the invalid outputs.
- Whether an actual schema incompatibility exists. The aggregate native error wording alone does not prove that its required-field set differs from the mirrored schema; optional binding fields may be derived during canonicalization.
- Which reviewer model/provider was selected, or whether a different model would avoid the failure.

## Safe recovery boundary

Preserve the current frozen candidate and review authority. Do not modify rejected JSON, invent findings or verdicts, replay refused bytes, or count rejected output as an accepted review. Do not patch the installed package or discard the lineage as a workaround.

A supported recovery needs one of the following, with its applicable authorization:

1. Maintainer-supported inspection of the exact bound prompt's identity and schema instructions without launching a reviewer or admitting a result.
2. A documented user-owned reviewer-routing change through `/gentle:profiles`: select the desired provider/model and effort for `review-readability`, then press `u` / **Use in this session**. After explicit authorization for one new model run, obtain fresh bound STATUS and use only the exact reoffered slot through the normal forecast/capture route. Never reuse the refused completion. This is a possible mitigation, not a demonstrated fix; changing a model must not change the frozen candidate or fabricate authority.

The exposed review facade does not currently offer a read-only prompt-materialization operation. Raw native lifecycle commands are not an authorized substitute. No additional reviewer run is proposed until there is a supported route and a deliberate decision on its cost.

### Supported routing control verified after the initial diagnosis

- Installed `docs/readme-reference.md:1015-1035` documents `/gentle:profiles`, role Model/Effort editing and `u` / Use in this session.
- Parent spot-check of `lib/session-profile-binding.ts:1-9,36-61` confirms that session binding copies the routing snapshot into an in-process store keyed by session ID; it never writes shared routing files. A later profile edit does not refresh an already-bound snapshot without explicit re-selection.
- Installed `extensions/gentle-ai.ts:2484-2486` resolves session binding before repository pin and global routing. `docs/review-integration.md:15,24-30,46` reserves frozen candidate, lineage and review semantics to the native provider.
- `d` / Make default is a different, persistent operation and is not requested. Do not inspect or modify user routing settings or credentials as a shortcut.
- Static investigation found no supported user-facing control for inspecting the bound prompt metadata before a model run. `/gentle:doctor` and `/gentle:status` do not supply that missing proof.

No model/provider/effort was changed by the agent. The authorized recovery preserved the accepted readability artifact and frozen candidate and produced one valid reliability result, followed by exact acknowledgement. This candidate is now closed: do not run further capture or STATUS for its consumed authority, or reopen it merely to test the mitigation. The malformed-output root cause and general effectiveness of a routing change remain unproven.

## Maintainer questions

- Can the supported integration expose bound prompt identity/schema diagnostics without a reviewer run or candidate-content disclosure?
- Do the materialized instructions match the canonicalizer contract in the pinned native release?
- A successful retry followed the user's reported session-profile activation. Which model/effort was actually selected, and does it reliably mitigate these failure modes? This single success does not establish either fact.

## Report status

- [x] Two rejected completions examined in place; no payload edits.
- [x] Relay's unchanged-byte submission path spot-checked.
- [x] Current authority preserved; rejected output was not acknowledged.
- [ ] Exact materialized prompt inspected through a supported diagnostic route.
- [x] This candidate recovered: native approval and exact acknowledgement observed.
- [ ] Root cause established and a general remedy verified.
- [ ] Remote destination, contribution form and duplicates checked under explicit authorization.
- [ ] Published (not authorized).
