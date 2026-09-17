**Delete all remote tags from `origin`:**

```powershell
git ls-remote --tags --refs origin | ForEach-Object { ($_ -split "`t")[1] -replace '^refs/tags/', '' } | ForEach-Object { git push origin --delete $_ }
```

**Delete all local tags:**

```powershell
git tag -l | ForEach-Object { git tag -d $_ }
```

**Delete all remote and local tags:**

```powershell
$remoteTags = git ls-remote --tags --refs origin | ForEach-Object { ($_ -split "`t")[1] -replace '^refs/tags/', '' }; $localTags = git tag -l; $remoteTags | ForEach-Object { git push origin --delete $_ }; $localTags | ForEach-Object { git tag -d $_ }
```

**Preview remote tags:**

```powershell
git ls-remote --tags --refs origin | ForEach-Object { ($_ -split "`t")[1] -replace '^refs/tags/', '' }
```

**Preview local tags:**

```powershell
git tag -l
```
