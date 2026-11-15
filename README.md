# r-release-actions

Reusable GitHub workflows and composite actions that take an R package through a CRAN release.
A package's own workflows call them by a pinned release.

**Status: under construction.**
The CRAN submission is the first workflow; the check that builds the tarball it submits, the release gate,
win-builder and the workflow that publishes a release after acceptance follow.
Nothing here is released yet.

## How a release flows

A release is cut on a release branch, or, for a small fix, made directly on `main`.
Before each round of checks, one commit sets the release date in both places it appears:
the `NEWS.md` heading `# <package> X.Y.Z (YYYY-MM-DD)` and `Date:` in `DESCRIPTION`.
The check workflow builds the source tarball once and checks that very file,
and the submission uploads it, so nothing is rebuilt between a check and CRAN.
Every release run is dispatched by hand, and every run reports to the release's checklist pull request.
No tag is written at submission: `vX.Y.Z` marks what CRAN accepted, is written once at acceptance, and never moves.

## CRAN submission

[`.github/workflows/cran-submission.yaml`](.github/workflows/cran-submission.yaml) submits the package at a given commit.
It runs no check and builds nothing: dispatch it only once every check of that commit is green.

```yaml
on:
  workflow_dispatch:
    inputs:
      dry-run:
        type: boolean
        default: true

jobs:
  submit:
    uses: krlmlr/r-release-actions/.github/workflows/cran-submission.yaml@<sha> # vX.Y.Z
    permissions:
      actions: read
      contents: write
      pull-requests: write
    with:
      sha: ${{ github.sha }}
      dry-run: ${{ inputs.dry-run }}
```

Inputs:

- `sha` (required): the full SHA of the commit to submit, normally the head of the branch the caller was dispatched on.
- `dry-run` (required): read and verify everything, report what a real run would write and send, and write and send nothing.
- `check-workflow`: the file name of the check workflow that built the tarball, `R-CMD-check.yaml` by default.
- `check-run-id`: the check run to take the tarball from; by default, the newest run of `check-workflow` on `sha` that holds it.

What a run does, job by job:

- **version** refuses a fork, and reads `Package:` and `Version:` from `DESCRIPTION`.
  It stops on a development version, one with more than three components.
  It verifies the dates without changing them: exactly one `NEWS.md` section for the version,
  whose heading carries the same date as `Date:` in `DESCRIPTION`, within a day of the run's date in UTC.
  A stale date fails a real run and only warns on a dry run.
  It then finds the checklist pull request, which a real run requires.
- **tarball** finds the check run of `sha` and its artifact, downloads the file, and verifies it:
  its SHA-256 is the artifact's digest, its name is `<package>_<version>.tar.gz`, and it holds that package and version.
  It refuses while CRAN's incoming queue holds a submission of the package, which CRAN's policy forbids.
- **draft** keeps one draft GitHub release per version, titled `<package> X.Y.Z`, for the tag name `vX.Y.Z`.
  The first submission creates it, and each resubmission updates it:
  its target is `sha`, its one asset the checked tarball, replacing an earlier attempt's,
  and its notes the version's `NEWS.md` section, ending with the marker `<!-- cran-submission: <package> X.Y.Z -->`,
  by which the workflow that publishes the release at acceptance will find it.
  It writes no tag, and stops instead when the tag exists, when the version's release is published, or when several drafts exist.
  This is the only job that holds a token that can write to the repository.
- **upload** posts the tarball to CRAN's submission form in the form's own two steps, as `devtools:::upload_cran()` does,
  with the single line `<package> X.Y.Z` as the comment and the maintainer from the tarball's `DESCRIPTION`.
  CRAN then e-mails the maintainer, and the submission counts once the link in that e-mail is followed.
  A form that answers 404 means CRAN is closed for maintenance, and the run shows CRAN's message.
- **report** keeps the workflow's one comment on the checklist pull request, updated in place by every run, dry or real.
  After a real upload it also adds a new comment for the attempt, which nothing edits afterwards:
  the attempt's number for the version, the commit's SHA, the tarball's SHA-256, and links to the run and the draft.
  Reply under it with CRAN's answer and what fixed it.

Only one submission per repository runs at a time, and none is cancelled.
Each step writes what it read, checked and did to the run's summary, with how to resolve a failure.

### What the submission expects from the package

- **The checked tarball.** A run of the check workflow on the commit keeps the source tarball it checked as an artifact,
  uploaded with `actions/upload-artifact` v7 or later and `archive: false`, so that the artifact is the raw file
  `<package>_<version>.tar.gz` and its digest is the file's SHA-256.
  An artifact expires after at most 90 days, which the draft's asset outlives.
- **The checklist pull request.** One open pull request tracks the release:
  the release branch's pull request into `main`, or an empty pull request beside a fix made on `main`.
  Its body carries the marker `<!-- release-checklist: <package> X.Y.Z -->`,
  and it is opened by an owner, member or collaborator of the repository;
  a pull request carrying the marker by anyone else is ignored with a warning.
- **The dates**, set by the date commit before the checks, as described above.
- **The permissions** the calling job grants: `actions: read` to find and download the artifact,
  `contents: write` to draft the release, and `pull-requests: write` to report.
  The run needs no secret beyond the workflow's own token.

## Layout

- `.github/workflows/` holds the reusable workflows, each triggered by `workflow_call`.
- `actions/<name>/` holds one composite action each, in `action.yml`.
  A script the action runs lives beside it, with its offline test next to it,
  so that each action can be tested without a network or a package to release.
  `actions/cran-lib/` holds the shell helpers the scripts and their tests share.
- The tests run with `for t in actions/*/*-test.sh; do "$t"; done`, against stubs and local servers:
  they reach neither GitHub nor CRAN.
- A reusable workflow calls this repository's actions at `@main`,
  because a workflow cannot name the commit it is in; every other action is pinned by full SHA.

## Versioning

Releases of this repository are tagged `vX.Y.Z`.
A caller pins a release tag, or its full commit SHA with the tag in a comment for stronger guarantees:

```yaml
jobs:
  release:
    uses: krlmlr/r-release-actions/.github/workflows/<workflow>.yaml@<sha> # vX.Y.Z
```

Dependabot keeps such pins up to date in the calling repository.

## License

MIT, see [`LICENSE`](LICENSE).
