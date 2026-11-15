# r-release-actions

Reusable GitHub workflows and composite actions that carry a CRAN release of an R package.
A package's own workflows call them by tag.

**Status: under construction.**
Nothing here is ready to call yet.

## Design

The release design these workflows implement is maintained separately.
This README will summarize it as the workflows land.

## Layout

- `.github/workflows/` will hold the reusable workflows, each triggered by `workflow_call`.
- `actions/<name>/` will hold one composite action each, in `action.yml`.
  A script the action runs lives beside it, with its offline test next to it,
  so that each action can be tested without a network or a package to release.

## Versioning

Releases of this repository are tagged `vX.Y.Z`.
A caller pins either a tag or, preferably, the tag's full commit SHA with the tag in a comment:

```yaml
jobs:
  release:
    uses: krlmlr/r-release-actions/.github/workflows/<workflow>.yaml@<sha> # vX.Y.Z
```

Dependabot keeps such pins up to date in the calling repository.

## License

MIT, see [`LICENSE`](LICENSE).
