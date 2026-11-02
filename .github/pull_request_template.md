## Summary

<!-- What this pull request does, in one or two sentences. -->

## Related issue

Closes #

## Type of change

- [ ] feat: new feature
- [ ] fix: bug fix
- [ ] test: tests only
- [ ] refactor: code change with no behaviour change
- [ ] docs: documentation only
- [ ] chore: build, CI or repository setup
- [ ] style: formatting only

## Changes

<!-- One line per change, with the file or module it touches. -->

-

## PVMS design rules covered

<!-- For example: Rule 2 (one feature code path), Rule 9 (offline first). Write "none" for repository or documentation changes. -->

## Depends on

<!-- Pull requests that must be merged into develop first, for example #14. Write "none" if this pull request is independent. -->

## How to test

<!-- The exact commands and steps the reviewer runs. -->

```powershell

```

## Author checklist

- [ ] Branch is up to date with `develop`
- [ ] `flutter analyze` reports no issues (app changes)
- [ ] `flutter test` passes (app changes)
- [ ] `python -m pytest -q` passes in `backend/` (backend changes)
- [ ] `python train_model.py` rerun and report updated (feature or model changes)
- [ ] `flutter pub get` and a full rebuild done (`pubspec.yaml` changes)
- [ ] Commit messages follow Conventional Commits
- [ ] No secrets, dataset, trained models or real-car recordings committed
- [ ] Screenshots attached (UI changes)

## Reviewer checklist

- [ ] Checked out this branch and ran the tests locally
- [ ] Read every changed file and understand it
