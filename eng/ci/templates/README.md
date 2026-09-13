# Release configuration templates

Copy one of these `.releasepipeline.yml` files to the root of the target repository, then replace the example paths, commands, package directories, and tag prefixes before running a release plan.

The existing GitHub Actions workflows, Jenkinsfiles, and PowerShell scripts consume this configuration directly. They do not need a language-specific rewrite.

| Template | Use it when |
| --- | --- |
| [single-application](single-application) | The repository ships one application as one versioned release unit. |
| [polyglot-monorepo](polyglot-monorepo) | The repository ships independently versioned Node, modern .NET, and/or legacy .NET Framework components. |

## Adoption checklist

1. Copy the chosen `.releasepipeline.yml` to the repository root.
2. Replace every example `path`, `package.path`, `build.command`, and `test.command` value.
3. Choose unique, permanent `tagPrefix` values. Tags become `<tagPrefix>/v<SemVer>`.
4. Set `initialVersion` only when migrating an existing component without a component-scoped baseline tag. See [MIGRATION.md](../MIGRATION.md).
5. Run `pwsh ./eng/ci/New-ReleasePlan.ps1 -Branch dev` and review the generated plan before enabling tag pushes.
6. Configure GitHub Actions or Jenkins with the provider mappings in [PROVIDER-MAPPINGS.md](../PROVIDER-MAPPINGS.md).

`dependencies` controls release propagation: when a dependency changes, its dependents are included in the same plan. It does not install packages or change source references; keep package-manager and project-file dependencies in their native tooling.
