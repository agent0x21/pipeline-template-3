# Product requirements: reusable Windows release pipeline

This document incorporates the approved main-based release conversion and subsequent user clarifications. It supersedes the previous environment-branch model.

## Platform and scope

Provide a reusable CI/CD framework for single applications and polyglot monorepos, including React/TypeScript, modern .NET, WPF and legacy .NET Framework. Preserve independent component versioning and existing useful adapters. All pipeline orchestration is PowerShell, preferably PowerShell 7, on Windows runners. Legacy tools may require Windows PowerShell/MSBuild. Keep runner capability checks explicit and support provider adapters.

Use pnpm 12.3.4 for JavaScript; do not introduce another package manager. Retain configurable build, test, package and publishing commands; do not require application modernization.

## Branching and CI

Main is the only permanent branch. Developers use temporary feature/*, bugfix/* and hotfix/* branches. Temporary release/* branches are allowed only for actual stabilization/maintenance. No permanent environment branches and no automatic branch synchronization.

PRs and main pushes run validation, configured tests and application builds. CI creates no deployable release artifacts or semantic tags. DEV artifacts are created ONLY through a manual workflow, from main or a selected full SHA reachable from main. Actual installation remains manual.

## Release creation

A separate manual RC build selects and pins a source SHA. Normal sources must be reachable from main. Hotfix/release source exceptions require a baseline release tag in their ancestry. Do not infer channels or environments from branch names.

Keep component/v<semver> tags, independent component versions, default minor bumps, explicit patch/major overrides, per-component overrides and exact versions. Hotfix auto selection defaults to patch. Unknown inputs and conflicting tags fail.

Use each component's latest reachable stable tag as its baseline. Detect affected paths, shared inputs and dependency propagation. Bootstrap components without a stable tag and allow explicit full releases. Keep RC sequencing independent of build run identifiers. Scope stable baselines to the selected line and check tag uniqueness globally.

Build each RC artifact once. Create checksummed ZIPs and immutable container references where configured. Record a durable release set with source SHA, source ref, run/repository, component versions/tags, asset identifiers and digests. Reserved versions and publication retries must be recoverable.

## QA and production

QA receives a selected release set, not main's moving head. Prepare a verified manual-installation handoff first. QA then signs off on the exact manifest checksum, attesting to installation and testing of every included artifact. Actual reviewers must be recorded from provider evidence.

PROD independently approves stable release publication and consumes exactly the QA-approved bytes. Never build, repackage or change embedded binaries for stable promotion. Stable tags point to the RC source commit; container version aliases preserve the digest. ZIP-only components participate in approval checks.

GitHub Environments are DEV, QA and PROD. DEV requires no reviewer; QA and PROD have separate reviewers/protections. Use environment protection without claiming installation occurred. Environment-specific credentials/runtime configuration are separate from source branches and artifacts.

## Persistence and safety

Persist release manifests/artifacts and approval evidence beyond Actions artifact retention. Never overwrite an immutable asset with different bytes, move release tags or rebuild a published RC. Support recovery from partial tagging, registry publication and stable publication using the original plan and staged bytes. Serialize version allocation/publication; do not hold RC creation behind QA testing.

Use least privilege and short-lived credentials. PR validation never receives publishing secrets. Treat selected source and workflow orchestration separately; pin both. Preserve historical releases without automatic conversion of old approval evidence.

## Runtime configuration

React must support a separately supplied runtime configuration file with a local-development default. .NET consumes runtime configuration/environment variables. The same application bytes serve QA and PROD. Real deployment adapters and WPF installer distribution are outside this conversion.

## Hotfix and migration

Create hotfix branches from production component/release-set tags; build/test a patch RC, follow QA/PROD approval, and bring the fix back to main through a reviewed PR. Delete the temporary branch after completion. Do not automatically merge/cherry-pick.

Provide a migration checklist for outstanding dev/qa work, main protections, tag rules, environments/reviewers/secrets and retiring old branches. Do not delete historical tags or perform live governance changes as an implicit code-edit step.

## Repository discovery and configuration generation (planned)

Add a provider-neutral discovery and scaffolding engine as specified in [DISCOVERY-REQUIREMENTS.md](../eng/documentation/DISCOVERY-REQUIREMENTS.md), including its repository integration clarifications in section 60. That document is the detailed discovery requirements extension to this product requirements source; the engine is not yet implemented.

Discover JavaScript/TypeScript, React, Node, modern and legacy .NET projects; infer build/test/artifact candidates from static evidence; distinguish npm/NuGet publication capability from release intent; and report dependencies, watch relationships, direct/transitive impact, confidence and unresolved findings in a versioned model. Do not execute repository code during discovery or guess registries, credentials, approval policy or environments.

Generate reviewable `.releasepipeline.yml` proposals using supported parser/adapter capabilities. Preserve all existing human-authored configuration. Default discovery is read-only; scaffolding emits a proposal; explicit apply may create a complete valid new file using caller-supplied policy or a selected template, or add selected missing component entries. Validate before writing, detect concurrent edits and make repeat application idempotent. Discovery does not replace release version planning, build execution or the existing QA/PROD approval and recovery contracts.

## Validation and documentation

Maintain Pester tests for versioning, source eligibility, affected scope, hotfixes, immutable identity, publication recovery and workflow boundaries. Run web lint/build, API/desktop builds and configured tests. Verify the live workflow lifecycle on a Windows test runner before cutover.

Keep eng/documentation/ROADMAP.md restartable: ordered checkboxes, current focus, results, blockers, next steps and separate external cutover tasks. Documentation must explain manual DEV creation, RC selection, QA sign-off, production promotion, hotfixes and retry behavior without environment-branch instructions.
