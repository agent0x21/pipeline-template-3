# Main-based release conversion roadmap

**Current focus:** Local implementation and validation of the main-based release conversion are complete. Discovery/configuration-generation requirements are documented; the discovery engine is not implemented. Next: review the documentation/diff, apply the external cutover checklist, and smoke-test the release workflows on GitHub. No live repository settings, branches, tags, releases or registry images have been changed.

## Agreed behavior

- main is the only permanent branch; temporary feature, bugfix, hotfix and release branches are allowed.
- CI is automatic. DEV artifacts are manual, from main only. RC artifacts are a separate manual build.
- Independent component versions; immutable ZIPs and container digests; RC to stable without rebuilding.
- Installation stays manual. QA sign-off and PROD approval are separate GitHub Environment gates.

## Implementation checkpoints

- [x] 1. Replace branch channels with explicit RC planning, reachable stable baselines, shared paths and hotfix support.
- [x] 2. Add durable release-set publication, verified handoff, approval evidence and retry handling.
- [x] 3. Split CI, DEV, RC, QA and PROD workflows; remove source-branch promotion.
- [x] 4. Add frontend runtime configuration and update governance tooling.
- [x] 5. Update requirements, contributor docs, templates and recovery instructions.
- [x] 6. Run Pester, workflow/static checks, web lint/build and .NET builds; record results below.

Implemented workflows: ci.yml, dev-build.yml, build-release.yml, prepare-qa.yml and promote-prod.yml. The former combined release.yml, recovery promote.yml and branch-promotion scripts are removed. Legacy v1 inspection helpers remain separate from the new v2 approval path.

## Discovery engine extension (planned)

- [x] Capture the supplied [discovery requirements](DISCOVERY-REQUIREMENTS.md), add first-file generation/application criteria, and link them from the README and product/release requirements.
- [ ] Define the discovery report schema, PowerShell interface, classification coverage and YAML editing/validation strategy.
- [ ] Implement discovery, evidence/classification, dependency/impact analysis and configuration proposals.
- [ ] Implement and validate explicit first-file creation/additive application, preservation, concurrency checks and idempotency.
- [ ] Validate the discovery acceptance scenarios with representative fixtures; record results before marking the engine available.

## External cutover (not performed by code changes)

- [ ] Reconcile outstanding dev/qa work into main through reviewed PRs; finish or cancel old releases.
- [ ] Configure Windows runner labels/tooling, GHCR access and GitHub CLI authentication.
- [ ] Protect main with CI and PR review; protect release tags; remove old promotion rulesets.
- [ ] Create DEV, QA and PROD environments; assign separate QA/PROD reviewers and migrate secrets.
- [ ] Exercise a DEV build, RC/QA/PROD promotion and an older-line hotfix in a test repository.
- [ ] Retire environment branches and obsolete environments after confirming no unique work remains.

## Validation log

Validated locally on Windows, 2026-09-16:

| Check | Result |
| --- | --- |
| pnpm version | 12.3.4 |
| pwsh -NoProfile -File eng/ci/Invoke-ReleasePipelineTests.ps1 | 62 passed, 0 failed |
| pnpm --filter ./apps/web lint | Passed |
| pnpm build-web | Passed |
| dotnet build apps/api -c Release | Passed; 0 warnings/errors |
| dotnet build apps/desktop -c Release | Passed; 0 warnings/errors |
| PowerShell parser over CI scripts/modules/manifests | Passed |
| YAML parse of all workflows and composite actions | Passed |
| git diff --check | Passed |

The integration fixture uses real temporary Git repositories, tags, ZIP packaging and hashes with mocked GitHub HTTP. It interrupts component publication, resumes without another build, performs QA sign-off and stable publication, retries production, and proves stable/RC ZIP digest equality. Separate fixtures cover off-main source rejection, older-line hotfix versions, shared paths, actual reviewer evidence and changed/missing artifact identities.

Pester needed execution outside the sandbox for its temporary Windows registry area. Vite also needed an unsandboxed build because Windows subprocess creation returned EPERM. Both succeeded on retry. No application dependencies were changed.

Not yet verified: real GitHub Actions execution, environment protection behavior, real GHCR publication/retagging, hosted runtime configuration and actual manual installation. YAML parsing does not substitute for a live Actions run. These remain explicit external cutover checks, not completed deployments.

## Resume instructions

Documentation update, 2026-09-18: incorporated the supplied discovery specification, clarified current adapter/dependency support and added configuration-generation acceptance criteria. Read its section 60 before planning implementation. This is documentation only; `.releasepipeline.yml`, application code and workflows are unchanged. Discovery tests have not been implemented or run.

Documentation update, 2026-09-17: added [functional requirements](FUNCTIONAL-REQUIREMENTS.md) and linked the document from the root README. Requirements and acceptance scenarios were checked against the current workflows, configuration, release planning and handoff/recovery implementation. This documentation-only update does not complete any external cutover checks or change pipeline behavior.

Read this file, eng/documentation/RELEASE-STANDARD.md, eng/documentation/MIGRATION.md and git diff first. Implementation changes are uncommitted in the working tree. Continue with the external cutover checklist; use the documented governance -WhatIf command before applying settings. Do not recreate published versions, delete branches, or apply live governance settings as part of local recovery. Preserve existing release artifacts and use publication retries.

For a failed release run, rerun that original run: its release/run-id, persisted source SHA, reserved versions and build bundle are the recovery identity. Use Prepare QA's successful run ID when requesting PROD promotion. A new dispatch is a new release request, not a retry.
