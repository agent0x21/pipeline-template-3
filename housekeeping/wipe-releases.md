Delete **all GitHub Releases** while keeping the Git tags:

```powershell
gh release list --limit 10000 --json tagName --jq '.[].tagName' | ForEach-Object {
    gh release delete $_ --yes
}
```

Delete **all GitHub Releases and their associated Git tags**:

```powershell
gh release list --limit 10000 --json tagName --jq '.[].tagName' | ForEach-Object {
    gh release delete $_ --yes --cleanup-tag
}
```

Preview the releases first:

```powershell
gh release list --limit 10000
```

You can also use the shorter PowerShell alias `%`:

```powershell
gh release list --limit 10000 --json tagName --jq '.[].tagName' | % { gh release delete $_ --yes }
```
