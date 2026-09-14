Delete **all remote tags** from `origin`:

```powershell
git tag -l | ForEach-Object {
    git push origin --delete $_
}
```

Delete **all local tags**:

```powershell
git tag -l | ForEach-Object {
    git tag -d $_
}
```

Delete **both remote and local tags** using the same captured tag list:

```powershell
$tags = git tag -l

$tags | ForEach-Object {
    git push origin --delete $_
}

$tags | ForEach-Object {
    git tag -d $_
}
```

And to preview them first:

```powershell
git tag -l
```

The `$tags = git tag -l` version is preferable for deleting both, because after deleting local tags you no longer have the local list available.
