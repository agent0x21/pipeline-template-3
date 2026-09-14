# ReleasePipeline

`ReleasePipeline` is the provider-neutral PowerShell core for this repository's CI/CD framework. It uses Git tags as the canonical version source and treats each configured component as independently releasable.

## Local usage

Install the YAML parser and the pinned Pester test dependency once, then plan and package:

```powershell
Install-Module powershell-yaml -Scope CurrentUser
Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser
pwsh ./eng/ci/New-ReleasePlan.ps1 -Branch dev
pwsh ./eng/ci/Invoke-ReleasePackage.ps1 -PlanPath ./release-plan.json
```

Manual overrides are normalized JSON maps:

```powershell
./eng/ci/New-ReleasePlan.ps1 -VersionBump patch `
  -ComponentOverridesJson '{"api":"major"}' `
  -ExactVersionsJson '{}'
```

The precedence order is component override, workflow-wide override, then `versioning.defaultBump` (which defaults to `minor`). Tags use `<tagPrefix>/v<SemVer>`. Beta and RC sequence numbers are calculated from existing tags, independently for each component, base version, and channel.

A parentless repository commit is treated as a bootstrap change: every configured component present in that commit receives its initial release version. For an existing repository, use the manual GitHub `release_all` input (or `New-ReleasePlan.ps1 -ReleaseAll`) only when an approved release must include every configured component regardless of source changes.

Channel version floors prevent branch regressions: QA releases must be above the latest stable version, and development releases must be above both the latest stable and QA/RC versions. The same validation applies to exact-version overrides; reruns of an existing tag remain idempotent.

Configuration loading rejects duplicate tag prefixes, invalid or escaping component paths, missing dependencies, dependency cycles, and unsupported branch channels. Component paths and optional legacy `build.solution` paths must exist relative to the configuration file. When a release tag for the planned component and channel already points to the planned commit, the plan is treated as a rerun and reuses that immutable version.

Tag pushes are atomic and retry transient push failures up to three times. If another runner creates the same tag first, the provisional local tag is removed; a matching remote commit is treated as an idempotent rerun, while a different remote commit fails safely and requires a newly reviewed plan.

The GitHub Actions adapter retains workflow artifacts for 30 days and publishes an idempotent GitHub release record for each tagged component. It also attaches the verified deployable ZIP to that component's GitHub release. For push-triggered runs it compares GitHub's pre-push SHA to the new tip, so a multi-commit branch promotion releases every changed component in the pushed range. The provider-specific metadata and asset scripts use `GITHUB_TOKEN`; their behavior is intentionally kept outside the provider-neutral release module.

The release workflow uploads the generated plan with the tested artifacts, then pauses at the protected `release-beta`, `release-rc`, or `release-stable` environment before creating tags. The approval job names list the components and tags being approved, and the workflow summary includes the channel, commit, versions, and tags. When the plan has no releases, the workflow retains the empty plan and provenance for auditability but skips tag creation, GitHub release assets, and registry publication. Reviewers can inspect `release-plan.json` in the workflow artifact and approve the deployment from the Actions run page. Tag creation and GitHub release metadata use a separate least-privilege job with `contents: write`; the build/package job has read-only repository permissions.

Configure the GitHub governance from an authenticated `gh` session. This is idempotent and does not accept or print a token:

```powershell
gh auth login
pwsh ./eng/ci/providers/github/Set-GitHubReleaseGovernance.ps1 `
  -Repository 'OWNER/REPOSITORY' `
  -Reviewer @('reviewer-user', 'my-org/release-managers') `
  -PreventSelfReview
```

The script protects `dev`, `qa`, and `main` with pull-request reviews, stale-review dismissal, last-push approval, conversation resolution, and no force pushes/deletions. It creates or updates `release-beta`, `release-rc`, `release-stable`, `beta`, `rc`, and `stable` with the selected users/teams as required reviewers. Preview the API changes first with `-WhatIf`. On GitHub Free, required environment reviewers require a public repository; private repositories need a compatible paid plan.

### Preserve the approved source commit through QA and production

For the branch-driven promotion path, merge the approved `dev` change into `qa` and the approved `qa` change into `main` with a regular **merge commit**. Do not squash or rebase either promotion PR: those strategies create replacement commits, so `main` no longer contains the commit identified by the beta/RC tag and immutable artifact provenance.

`Find-BranchPromotionSources.ps1` enforces this relationship before it creates an RC or stable promotion: the tagged source commit must be an ancestor of the destination branch tip, and the promoted component must be unchanged after that commit. This means a stable tag identifies the same source commit that QA approved, while `main` contains that commit in its history (a fast-forward is also valid when GitHub can perform one).

To configure GitHub so PR authors cannot choose squash or rebase merges, run the governance command with `-PreservePromotionCommits` (use `-WhatIf` first):

```powershell
pwsh ./eng/ci/providers/github/Set-GitHubReleaseGovernance.ps1 `
  -Repository 'OWNER/REPOSITORY' `
  -Reviewer @('reviewer-user', 'my-org/release-managers') `
  -PreventSelfReview `
  -PreservePromotionCommits
```

This repository-level setting permits merge commits and disables squash and rebase merging. The manual **Promote Release** workflow remains a recovery path; use the branch-triggered workflow for normal QA-to-production promotion when commit-to-`main` traceability is required.

Promotion consumes an existing release artifact's `provenance.json`, validates its component/version/digest entries, and creates tags for the same commit without invoking a build. Only `beta -> rc` and `rc -> stable` are allowed. A push to `qa` or `main` now performs this automatically: it finds the one beta/RC tag introduced by that promotion, verifies that the component content still matches, then downloads the immutable GitHub Release assets and provenance. Multiple candidates, a missing source release, or changed component content stop safely for an explicit release-manager decision. The **Promote Release** workflow remains available for an explicit source-run promotion and recovery scenario.

Registry publication is opt-in per component through `publishing.adapter`: `nuget`, `npm`, or `container`. Generate a publication plan with `pnpm registry-plan -ProvenancePath ...`; for promotion, also pass `-PromotionPlanPath promotion-plan.json`. The plan carries the immutable source artifact digest while using the target RC/stable version, without copying credentials. `pnpm registry-publish` invokes `dotnet nuget push`, `npm publish --provenance`, or `docker push`. Authenticate those tools in the provider workflow using a short-lived/OIDC credential or a preconfigured credential helper; never put tokens in command-line arguments. The workflows publish only after their `beta`, `rc`, or `stable` environment approval and grant `id-token: write` only to the publication job.

The API is configured as a GHCR container component. Packaging builds `apps/api/Dockerfile`, saves its versioned image as a SHA-256-provenanced `.container.tar` artifact, and the publication job reloads that artifact before pushing it. Run `pnpm test-container-api` to build and smoke-test the API container locally.

`pnpm test-ci-legacy` builds the included non-SDK-style .NET Framework 4.8 solution through `vswhere.exe` and MSBuild. Run it on a Windows machine with Visual Studio Build Tools and the [.NET Framework 4.8 Developer Pack](https://aka.ms/msbuild/developerpacks) installed; the command checks for the targeting pack before starting a build.

Packaging creates generic ZIP files and `artifacts/provenance.json`. The explicit `New-ReleaseTags.ps1` step is the only operation that mutates Git. It is idempotent when the requested tag already points to the planned commit and fails safely on a conflicting tag.

For legacy .NET components, set `type: legacy-dotnet-framework` and provide a PowerShell build command that discovers MSBuild (for example through `vswhere.exe`) and invokes it. Provider-specific workflows should pass normalized parameters to these scripts rather than embedding release logic.

See [PROVIDER-MAPPINGS.md](PROVIDER-MAPPINGS.md) for Azure DevOps and Jenkins examples, normalized input mappings, approval boundaries, and artifact-transfer requirements.

See [MIGRATION.md](MIGRATION.md) for moving from repository-global tags to component-scoped tags, selecting bootstrap version floors, and safely planning the first migrated release.

See [templates/README.md](templates/README.md) for copyable single-application and polyglot-monorepo `.releasepipeline.yml` starting points.

See [RECOVERY.md](RECOVERY.md) for safe handling of partial tags, metadata failures, registry retries, and promotion/artifact-transfer failures.
