# CI/CD Tooling Roadmap

This roadmap turns `prompt/main-prompt.md` into incremental, verifiable work. Update the checkboxes and the **Current focus** section whenever a milestone changes. The framework remains provider-neutral; GitHub Actions is the first concrete adapter.

## Current status

**Current focus:** Validate the first release in GitHub Actions, then add publishing and promotion.

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
- [ ] Review the plan and create initial component tags only after approval.
- [ ] Run the GitHub workflow manually and verify Windows runner/tool checks.

### 2. Harden the release engine

- [ ] Add fixture repositories for stable tags, prereleases, legacy tags, reruns, and tag conflicts.
- [ ] Expand Pester coverage for exact versions, prerelease numbering, dependency traversal, and concurrency retries.
- [ ] Validate configuration schemas and reject cycles, missing dependencies, invalid paths, and duplicate tag prefixes.
- [ ] Test a real legacy .NET Framework solution through `vswhere.exe` and MSBuild.

### 3. Publish and promote immutable artifacts

- [ ] Add GitHub artifact retention and release metadata publication.
- [ ] Add registry adapters for NuGet, npm, and container images where required.
- [ ] Model beta → RC → stable promotion without rebuilding artifacts.
- [ ] Add environment approvals, least-privilege permissions, and OIDC-ready publishing hooks.

### 4. Provider portability and adoption

- [ ] Document Azure DevOps/Jenkins input mappings to the normalized PowerShell interface.
- [ ] Add migration guidance for repository-global tags and bootstrap versions.
- [ ] Provide reusable templates for single applications and polyglot monorepos.
- [ ] Define recovery for partial component releases and publication/deployment retries.

## Definition of done

A milestone is complete when its tests pass, documentation is updated, and behavior has been exercised on a Windows runner or equivalent local fixture. Never create release tags from an unreviewed or stale plan.
