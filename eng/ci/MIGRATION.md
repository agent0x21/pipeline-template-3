# Migrating an existing repository

This guide moves a repository from global release tags such as `v1.3.0` to independent component tags such as `api/v1.4.0` and `web/v2.1.0`. The migration does not require rewriting Git history or deleting existing tags.

## Before changing configuration

Create an inventory of the existing release tags and identify which components were included in each release:

```powershell
git fetch --tags --force
git tag --list 'v*' --sort=version:refname
git show --no-patch --format='%H %cI %s' v1.3.0
```

For every component, record:

- Its repository-relative `path`.
- Its new unique `tagPrefix`.
- The latest stable version that applies to that component.
- The commit on which that version was released.
- Whether the component should receive a beta, RC, or stable release first.

Do not assume that a repository-global tag applies to every component. If a global tag only changed one application, use that application’s version as the baseline and leave unrelated components at their own baseline.

## Recommended migration: create component baseline tags

When a global release represents a known version for multiple components, create equivalent component-scoped stable tags at the same commit. For example, if `v1.3.0` was a release containing `api` and `web`:

```powershell
$commit = (git rev-list -n 1 v1.3.0).Trim()
git tag -a api/v1.3.0 $commit -m 'Baseline api version 1.3.0 during tag migration'
git tag -a web/v1.3.0 $commit -m 'Baseline web version 1.3.0 during tag migration'
git push origin api/v1.3.0 web/v1.3.0
```

Review the mapping and commit before pushing. Existing global tags remain as historical compatibility markers; the release engine ignores them because they do not match a configured component’s `<tagPrefix>/v<SemVer>` pattern.

If a component-scoped tag already exists, do not replace it. Verify that it points to the expected commit and let the release engine use the existing tag. A tag pointing to a different commit requires investigation, not a force push.

## Configuration-only migration

If creating baseline tags is not appropriate, set each component’s `initialVersion` to the latest known stable version:

```yaml
components:
  api:
    path: apps/api
    tagPrefix: api
    initialVersion: 1.3.0

  web:
    path: apps/web
    tagPrefix: web
    initialVersion: 2.1.0
```

`initialVersion` is a version floor, not a release tag. With the default `minor` bump, the first release after this configuration becomes `api/v1.4.0` and `web/v2.2.0`. Use `-ExactVersionsJson` for a deliberately exact first component release:

```powershell
pwsh ./eng/ci/New-ReleasePlan.ps1 `
  -Branch main `
  -BaseRef HEAD~1 `
  -ExactVersionsJson '{"api":"1.3.0","web":"2.1.0"}'
```

Exact versions must be reviewed carefully. They must be compatible with the branch channel and must not conflict with existing component tags.

## First migrated release

1. Add and validate `.releasepipeline.yml`.
2. Fetch complete history and tags.
3. Create baseline tags or set `initialVersion` floors.
4. Generate a plan without pushing tags:

   ```powershell
   pwsh ./eng/ci/New-ReleasePlan.ps1 -Branch dev -BaseRef HEAD~1 -OutputPath migration-plan.json
   Get-Content ./migration-plan.json
   ```

5. Confirm every component, commit, channel, bump, version, and tag in the plan.
6. Build, test, and package the plan.
7. Obtain the configured release approval.
8. Create tags with the reviewed plan:

   ```powershell
   pwsh ./eng/ci/New-ReleaseTags.ps1 -PlanPath ./migration-plan.json -Push
   ```

For an existing repository, use `-ReleaseAll` only for an explicitly approved full bootstrap release. Otherwise, changed-file detection releases only affected components and propagates their configured dependents.

## Channel and history rules

- Keep old global tags; do not rename or delete them as part of migration.
- Use stable component tags as the version floor for later beta and RC releases.
- Development releases must remain above stable and RC floors; QA/RC releases must remain above stable.
- Do not use a beta or RC tag as `initialVersion`.
- Do not create a component tag on a different commit merely to make a version calculation pass.
- If a plan is stale, the commit changes, or a tag conflict appears, regenerate and review the plan.

## Validation checklist

Before declaring migration complete, verify:

- Every component has a unique `tagPrefix`.
- All component paths and build/package paths exist.
- Existing global tags are preserved.
- Baseline component tags, if used, point to the intended commits.
- A plan on `dev`, `qa`, and `main` produces the expected channel and version floors.
- A rerun reuses an existing tag instead of allocating another version.
- The first beta/RC/stable artifact has provenance containing its commit, tag, semantic version, and SHA-256 digest.
