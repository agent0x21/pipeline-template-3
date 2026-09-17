# Release standard

## Identities and lifecycle

- CI validates source without publishing deployable artifacts.
- DEV is a manually requested build from main history, labelled by source SHA and run/attempt. It creates no semantic tags and cannot be promoted.
- RC creation is independent of DEV. The default bump is minor, with workflow, component and exact-version overrides. Hotfix auto bump is patch.
- A release set `release/<run-id>` identifies one selected source SHA and a set of independently versioned components.
- QA approves the checksum of the complete v2 manifest after manual installation/testing. PROD independently approves stable publication of those exact bytes.
- No source branch is updated by release automation. No automatic installation runs.

## Source selection and release scope

Dispatch workflows from main. DEV accepts main or a full SHA reachable from main. RC creation also accepts temporary hotfix/release branches with an explicit stable component or release-set baseline tag that is an ancestor of the selected commit.

Resolve the source once; use its full SHA throughout. Release planning compares each component against its highest stable version tag reachable from that SHA. No baseline means bootstrap. Watched shared paths and dependent components participate; unrelated components do not. A requested full release includes all configured components.

RC sequence numbers are globally unique per component/base version. Reachable stable baselines allow an older hotfix line to coexist with newer main versions. Stable versions already allocated anywhere in the repository cannot be reused for a new RC. Existing RCs on the same source must be recovered through their original run instead of rebuilt.

## Workflow inputs

| Workflow | Inputs |
| --- | --- |
| DEV Artifacts | source_ref (main), components (all), push_image (true) |
| Build Release Candidate | source_ref (main), baseline_release (temporary sources only), version_bump (auto), component_overrides (JSON), exact_versions (JSON), release_all (false) |
| Prepare QA | release_id |
| Promote PROD | release_id, qa_run_id |

Auto means minor except for hotfix sources, where it means patch. Exact versions may specify a base version or explicit RC version. Component overrides affect only the named component; unknown names fail.

## Durable records and approval

`release-manifest/v2` records release ID, source SHA/ref, repository/build run, timestamp and each component's version, source tag, ZIP asset name/SHA-256 and optional container image/digest. The manifest is never rewritten during promotion.

Prepare QA verifies every ZIP and checks that each container digest is available. It writes an `artifact-handoff/v2` record with `status=prepared` and `installed=false`. The subsequent protected QA job verifies the same manifest checksum again and records actual reviewer identities from GitHub review history. Approving attests that all listed artifacts were manually installed and tested. The pipeline cannot independently observe manual installation.

`qa-signoff-<qa-run-id>.json` binds sign-off to the manifest checksum. PROD requires this record, a successful Prepare QA workflow on main, and matching GitHub reviewer evidence. It records its own reviewer evidence separately. Bypassing a protection gate is not approval evidence.

Stable releases contain the same ZIP bytes and a copy of the source manifest. Container version aliases must resolve to the original digest. Stable embedded application versions remain those of the RC build. Mutable environment aliases are not release identity.

## Concurrency and recovery

Version allocation and publication share the release-publication concurrency group. Approval waits are separate from RC creation. Git tags are reserved before building; a failed build may reserve an RC number. Never delete/reallocate it to recover a run.

A draft release stores the original plan and staged build bundle before component publication. Retry the original run to reuse that plan, bundle and bytes. Once published, asset names cannot be overwritten with different hashes. A new dispatch is a new release request, not a retry. See [recovery](RECOVERY.md).

GitHub Environments are DEV (no reviewers), QA and PROD (separate required reviewers). Each environment job creates a GitHub deployment record that represents its artifact handoff or stable publication, with a URL to the relevant run or persisted release set; it does not claim that installation occurred. Do not add environment-specific compilation or repackaging when connecting future deployment adapters.
