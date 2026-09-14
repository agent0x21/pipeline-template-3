# CI/CD Tooling Roadmap

This roadmap turns `prompt/main-prompt.md` into incremental, verifiable work. Update the checkboxes and the **Current focus** section whenever a milestone changes. The framework remains provider-neutral; GitHub Actions is the first concrete adapter.

## Current status

**Current focus:** Deterministic promotion is implemented end to end. Next: wire real deployment targets into `environments.*.deploy.command`, and confirm the branch/ruleset changes on the live repository.

Completed foundation:

- [x] PowerShell `ReleasePipeline` module with strict error handling.
- [x] YAML configuration with independent components and branch channels.
- [x] Git-tag SemVer calculation with default minor bumps.
- [x] Workflow-wide, per-component, and exact-version inputs.
- [x] Beta/RC sequencing, change detection, and dependency propagation.
- [x] JSON release plans containing commit, bump, channel, tag, and build metadata.
- [x] Node and modern .NET command adapters.
- [x] Legacy MSBuild adapter contract with PATH/`vswhere.exe` discovery.
- [x] Deployable ZIPs plus SHA-256 provenance.
- [x] Idempotent tag creation with atomic push support.
- [x] Windows GitHub Actions workflow and Pester test harness.

## Next milestones

### 1. First repository release

- [x] Add `.release-output/`, `release-plan.json`, and test result files to `.gitignore`.
- [x] Run `pnpm release-plan`, `pnpm test-ci`, and `pnpm release-package` on a clean checkout.
- [x] Release changed components from a parentless bootstrap commit and support approved manual full releases.
- [x] Enforce production/QA version floors so development and QA cannot create lower release tags.
- [x] Review the plan and create initial component tags only after approval.
- [x] Run the GitHub workflow manually and verify Windows runner/tool checks.

### 2. Harden the release engine

- [x] Add fixture repositories for stable tags, prereleases, legacy tags, reruns, and tag conflicts.
- [x] Expand Pester coverage for exact versions, prerelease numbering, dependency traversal, and concurrency retries.
- [x] Validate configuration schemas and reject cycles, missing dependencies, invalid paths, and duplicate tag prefixes.
- [x] Test a real legacy .NET Framework solution through `vswhere.exe` and MSBuild.

### 3. Publish and promote immutable artifacts

- [x] Add GitHub artifact retention and release metadata publication.
- [x] Attach verified deployable ZIPs to GitHub release records.
- [x] Package and publish the API as an immutable GHCR container image.
- [x] Add registry adapters for NuGet, npm, and container images where required.
- [x] Model beta → RC → stable promotion without rebuilding artifacts.
- [x] Add environment approvals, least-privilege permissions, and OIDC-ready publishing hooks.

### 4. Provider portability and adoption

- [x] Document Azure DevOps/Jenkins input mappings to the normalized PowerShell interface.
- [x] Add migration guidance for repository-global tags and bootstrap versions.
- [x] Provide reusable templates for single applications and polyglot monorepos.
- [x] Define recovery for partial component releases and publication/deployment retries.

### 5. Deterministic, automatically promoted releases

- [x] Separate normal CI, on-demand development artifacts, and release candidates into distinct workflows.
- [x] Capture the candidate SHA from the trigger context and verify it against the checked-out `HEAD`.
- [x] Persist a `release-manifest.json` release identity (SHA + version + immutable artifact digest) and consume it in every later stage.
- [x] Resolve and record the registry manifest digest at publication time.
- [x] Advance `qa` and `main` automatically by fast-forward, or by a merge commit that preserves the approved SHA in ancestry.
- [x] Gate QA approval on the specific release identity rather than on a branch head.
- [x] Prove digest equality between QA and production, and fail production if any build output is present.
- [x] Restrict `qa`/`main` writes to the automation identity and serialize release candidates.
- [ ] Wire concrete deployment targets into `environments.*.deploy.command` for QA and production.
- [ ] Apply the branch protections/rulesets on the live repository and confirm the automation identity can advance `qa` and `main`.

## Definition of done

A milestone is complete when its tests pass, documentation is updated, and behavior has been exercised on a Windows runner or equivalent local fixture. Never create release tags from an unreviewed or stale plan.
