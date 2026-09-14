# Release and publication recovery

This runbook covers failures after a release plan is generated. Its main rule is simple: reuse a reviewed plan only when its commit, configuration, and immutable artifacts are still valid. Generate and approve a new plan whenever any of those facts change.

## Decide whether to reuse the plan

Reuse the existing `release-plan.json` or `promotion-plan.json` only when all of these are true:

- The planned commit is still the intended commit.
- `.releasepipeline.yml`, version inputs, and component scope have not changed.
- Every existing release tag in the plan points to the planned commit.
- The retained artifact and its provenance SHA-256 are available and match.

Do **not** reuse the plan after a different commit is selected, a tag points elsewhere, a component/version mapping changes, or immutable artifact verification fails. Regenerate, review, and approve a new plan instead.

Keep the plan and its provenance artifact for the full retention period. They are the recovery record for the release.

## Failure before tag creation

| Failure | Recovery |
| --- | --- |
| Plan generation fails | Correct the configuration, Git history, or input validation error; generate and review a new plan. |
| Build, test, or package fails | Fix the failure. If the commit and plan remain valid, rerun packaging with the same plan; otherwise generate and review a new plan. No tag exists yet. |
| Artifact upload fails | Do not tag. Restore or rerun packaging and verify `artifacts/provenance.json` before seeking approval again. |
| Approval expires or is rejected | Keep the artifacts, address the concern, then obtain a new approval for the same valid plan. |

## Partial or failed tag creation

`New-ReleaseTags.ps1` and `Invoke-ArtifactPromotion.ps1` create one component tag at a time. A transient failure can therefore leave a plan partly tagged.

Do not delete, move, or force-push a release tag. First inspect every planned tag:

```powershell
$plan = Get-Content ./release-plan.json -Raw | ConvertFrom-Json
$plan.releases | ForEach-Object {
  "$($_.tag) -> $(git rev-list -n 1 $_.tag 2>$null)"
}
```

If existing tags point to the planned commit, rerun the exact reviewed plan:

```powershell
pwsh ./eng/ci/New-ReleaseTags.ps1 -PlanPath ./release-plan.json -Push
```

Matching tags are reported as `already-exists`; remaining tags are created. If any tag points to another commit, stop. Regenerate and review a plan only after investigating the conflict. Never force a tag to match the plan.

Apply the same approach to a partial promotion, preserving the original promotion plan so RC sequencing is not recalculated:

```powershell
pwsh ./eng/ci/Invoke-ArtifactPromotion.ps1 -PlanPath ./promotion-plan.json -Push
```

## GitHub release metadata failure

Tags can exist even when GitHub release metadata fails. Rerun only the metadata operation with the same release or promotion plan:

```powershell
pwsh ./eng/ci/providers/github/Publish-GitHubReleaseMetadata.ps1 -PlanPath ./release-plan.json
```

The metadata script checks for a release record by tag and skips records that already exist. Run it in CI after the provider has supplied `GITHUB_TOKEN`, or use the provider’s short-lived authentication mechanism; do not place a token in a committed file or a process argument.

## Registry publication failure

Always inspect the registry first. Verify the package/image version and digest against `registry-publication-plan.json` before retrying.

| Adapter | Retry behavior |
| --- | --- |
| NuGet | The adapter uses `--skip-duplicate`; rerunning the same component is safe when the registry recognizes the existing immutable package. |
| npm | npm rejects republishing an existing version. Retry only the component that failed after confirming already-published versions and integrity. |
| Container | Re-pushing an alias is registry-specific. Verify the target tag resolves to the expected digest before and after retrying. |

Retry only a failed component with the reviewed publication plan:

```powershell
pwsh ./eng/ci/Publish-RegistryArtifacts.ps1 `
  -PlanPath ./registry-publication-plan.json `
  -Component api `
  -OutputPath ./registry-publication-retry.json
```

The `-Component` filter is intentionally a publication retry control; it does not create a new version, artifact, or tag. If the original artifact is unavailable or its digest differs, stop and regenerate from a valid release plan rather than publishing a replacement artifact under the existing version.

## Promotion and artifact-transfer failure

Promotion must use the retained source artifact, including `artifacts/provenance.json`. If download or layout validation fails:

1. Confirm the source run/build and artifact retention period.
2. Download the source artifact again and verify the provenance digest.
3. Reuse the original `promotion-plan.json` if it exists and all planned tags still match the intended commit.
4. If the plan is unavailable, generate a new promotion plan only after confirming no partial RC/stable tags were created.

Do not rebuild from source to replace a missing promoted artifact. A new build is a new release candidate and requires a new release plan, version, review, and approval.

## Deployment failure after QA approval

The release identity is already fixed at this point, so recovery never rebuilds. Rerun the **Redeploy Approved Release** workflow with the Release Candidate run ID and the target environment. It downloads `release-manifest.json` and `approved-release-manifest.json` from that run, asserts they still match, resolves each `image@sha256:...`, and redeploys. If the two manifests do not match, or the registry no longer serves the approved digest, stop: the artifact QA approved cannot be proven and a new candidate is required.

## Branch promotion failure

| Failure | Recovery |
| --- | --- |
| `cannot fast-forward` on `main` | `main` advanced independently. Rerun `Update-PromotionBranch.ps1` with `-AllowMerge` to record a merge commit preserving the approved SHA in ancestry, or create a new candidate from the current `main`. Never cherry-pick or squash the approved commit. |
| `The 'qa'/'main' ref changed during promotion` | Another promotion moved the branch. Re-read the head and rerun; the release artifact is unaffected. |
| Push rejected as non-fast-forward | Same cause. Rerun the promotion job; do not force-push. |
| Merge conflict | The approved commit cannot be merged cleanly. Resolve the divergence on a development branch and create a new candidate; do not resolve conflicts inside the promotion job. |

Re-running a promotion is safe: `up-to-date` and `already-contains` are no-ops, and `New-ReleaseTag` treats an existing tag on the same commit as `already-exists`.

## Recovery record

For every incident, retain:

- The release or promotion plan.
- `artifacts/provenance.json` and its artifact SHA-256 values.
- Tag status (`created` or `already-exists`) for each component.
- Registry publication records and relevant registry digest evidence.
- The failed run URL/build number and the recovery run URL/build number.

This record makes partial releases auditable and lets a later retry prove that it used the same commit and immutable artifact.
