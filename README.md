# r-release-actions

Reusable GitHub workflows and composite actions that take an R package through a CRAN release.
A package's own workflows call them by a pinned release.

**Status: under construction.**
The CRAN submission, the builder checks, the release gate and the release status are the first workflows;
the check that builds the tarball they use follows.
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
It runs no check and builds nothing: it takes the tarball from a check run of that commit, and fails unless that run is green.

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

For now the workflow runs this repository's actions from `main`, because a workflow cannot name the commit it is in:
pinning the workflow by SHA pins its own steps, not yet the actions they call.

Inputs:

- `sha` (required): the full SHA of the commit to submit, the head of the branch the caller was dispatched on.
- `dry-run` (required): read and verify everything, report what a real run would write and send, and write and send nothing.
- `check-workflow`: the file name of the check workflow that built the tarball;
  by default `R-CMD-check.yaml`, the check workflow of the cynkra/cynkratemplate package template.
- `check-run-id`: the check run to take the tarball from; by default, the newest run of `check-workflow` on `sha` that holds it.
- `resubmit`: submit a version that an earlier attempt submitted already, after a rejection and its fix
  or when CRAN never received the upload; off by default.

What a run does, job by job:

- **version** reads `Package:` and `Version:` from `DESCRIPTION`.
  It stops on a development version, one with more than three components.
  It verifies the dates without changing them: exactly one `NEWS.md` section for the version,
  whose heading carries a date, the same as the `Date:` field that `DESCRIPTION` must have,
  within a day of the run's date in UTC.
  A stale date fails a real run and only warns on a dry run.
  It then finds the checklist pull request, which a real run requires.
- **tarball** checks that `sha` is the head of the branch the submission was dispatched on, in the repository,
  because GitHub resolves a commit that exists only in a fork as well.
  It finds the newest push or dispatch run of the check workflow on `sha` in the repository that holds the tarball,
  skipping pull request runs, which check a merge commit, and runs of a fork's branch; a given `check-run-id` must be such a run.
  That run must have completed with success: otherwise the submission fails, naming the run, its conclusion and its URL.
  It downloads the file and verifies it:
  its SHA-256 is the artifact's digest, its name is `<package>_<version>.tar.gz`, and it holds that package and version.
  It refuses a version that an earlier attempt comment records, whatever that attempt's commit or tarball, unless `resubmit` is on,
  because an upload whose confirmation link nobody followed does not show in CRAN's queue,
  and a rebuilt tarball of the same commit differs in its digest.
  It refuses while CRAN's incoming queue holds a submission of the package, which CRAN's policy forbids.
- **draft**, on a real run only, keeps one draft GitHub release per version, titled `<package> X.Y.Z`, for the tag name `vX.Y.Z`.
  The first submission creates it, and each resubmission updates it:
  its target is `sha`, its one asset the checked tarball, replacing an earlier attempt's,
  and its notes the version's `NEWS.md` section, ending with the marker `<!-- cran-submission: <package> X.Y.Z -->`,
  by which the workflow that publishes the release at acceptance will find it.
  It writes no tag, and stops instead when the tag exists, when the version's release is published, or when several drafts exist.
  This is the only job that holds a token that can write to the repository.
- **preview**, on a dry run only, reports what **draft** would write, with a token that cannot write.
  Such a token may not see draft releases, so it can report creating a draft that a real run updates.
- **upload** posts the tarball to CRAN's submission form in the form's own two steps, as `devtools:::upload_cran()` does,
  with the single line `<package> X.Y.Z` as the comment and the maintainer from the tarball's `DESCRIPTION`.
  CRAN then emails the maintainer, and the submission counts once the link in that email is followed.
  A form that answers 404 means CRAN is closed for maintenance, and the run shows CRAN's message.
  A dry run reports every field it would send, and sends nothing.
- **report**, on a real run only, adds a new comment for the attempt to the checklist pull request, which nothing edits afterwards:
  the attempt's number for the version, the commit's SHA, the tarball's SHA-256, and links to the run and the draft.
  Reply under it with CRAN's answer and what fixed it.
  It then updates the workflow's one comment there with the jobs' results.

### Releasing from a fork

A fork submits like any repository, from its own branch, check run and checklist pull request:
the commit must head the dispatched branch of the fork, the tarball come from a push or dispatch run in the fork,
and the checklist pull request be open in the fork, where the draft release and the attempt comments are written too.
Nothing is written to the parent repository, the one the fork's repository page names as its source.
Instead, the run ends with a block of commands that bring the parent in line by hand,
in the log of the last job (**report**, or **upload** on a dry run) and in its summary:
push the submitted commit to the branch of the same name in the parent, which fails rather than overwrite it;
copy the draft release with its notes and tarball to the parent, or update the parent's draft of the version;
and comment on the parent's checklist pull request with a link to the fork's attempts.
The commands are printed, not run: someone with push access to the parent runs them from a clone of it
in which the remote `upstream` is the parent and `origin` the fork, after a real run.
A run outside a fork prints no such block.
A fork that carries a caller of this workflow can submit the package on its own,
so the maintainer's confirmation email from CRAN can come from a run in any such fork:
follow its link only for a submission you expect, and check the commit and the run it names.

A dry run holds no token that can write, and writes nothing: no release, no comment, nothing to CRAN.
Its results are in the run's summary.
It still fails where a real run would stop before writing: on a development version, a missing or doubled `NEWS.md` section,
dates that differ, a missing `Date:`, a commit that is not the head of the dispatched branch, a missing or mismatched tarball,
a check run that is not green, an existing tag, or a published release.
Its read-only token may not list draft releases, so it does not reliably catch several drafts of the version.
It only warns about a stale date, a missing checklist pull request, a version submitted before, and a queued submission.

Only one submission per repository runs at a time, and none is cancelled.
Each step writes what it read, checked and did to the run's summary, with how to resolve a failure.

### What the submission expects from the package

- **The checked tarball.** This is the contract the check workflow implements:
  - The check workflow builds the source tarball once per run, and each `R CMD check` job of the run checks that tarball,
    not the checkout.
  - Exactly one job of the run uploads the tarball, the job that ran `R CMD check` on it,
    with `actions/upload-artifact` v7 or later, `archive: false`, and the file unchanged after the check.
  - The artifact is the raw file, named exactly `<package>_<version>.tar.gz` as `R CMD build` names it,
    so that its digest is the file's SHA-256.
    Other jobs of the matrix may upload other artifacts, but no other artifact of the run has that name:
    the submission takes the artifact with that exact name.
    A re-run of the check keeps the earlier attempts' artifacts in the run, so of several the newest is taken,
    and the log names the one chosen and the ones skipped.
  - The run is a push or dispatch run of the commit in the package's own repository, and it completes with success.
  An artifact expires after at most 90 days, which the draft's asset outlives.
  The standard check workflow runs on a push only to `main` or `master`,
  so on a release branch someone dispatches the check workflow on the branch before dispatching the submission.
- **The checklist pull request.** One open pull request tracks the release:
  the release branch's pull request into `main`, or an empty pull request beside a fix made on `main`.
  The first line of its body is the marker `<!-- release-checklist: <package> X.Y.Z -->`, before any heading or preamble;
  a byte order mark and whitespace around it do not matter.
  Whoever creates checklist pull requests, a person, an App or an agent's session, starts the body like this:

  ```markdown
  <!-- release-checklist: <package> X.Y.Z -->
  # Release <package> X.Y.Z
  ```

  A pull request that carries the marker further down, as one quoting other text might, is ignored
  with the warning "Checklist pull request ignored", which names it as "#N by <login> (the marker is not the body's first line)".
  A GitHub App opens it, which is the normal case, or a person with write access to the repository.
  A bot account's pull request (`<app>[bot]`) counts when its head branch is in the repository itself.
  Opening one needs only `pull-requests: write` on the repository:
  any App installed with that permission can, and so can any workflow of the repository with its token, as `github-actions[bot]`.
  This is why the marker must start the body, and why a real run fails unless exactly one pull request counts.
  Dependabot's and Renovate's pull requests, which quote their dependencies' release notes, are ignored with a warning,
  as is a bot's pull request from a fork.
  A person's counts when the person has write, maintain or admin access.
  Where a person's access cannot be read, the author's association decides:
  a pull request by anyone but an owner, member or collaborator is ignored with a warning, so a stray marker blocks nothing,
  while an owner's, member's or collaborator's fails a real run with GitHub's error and is accepted with a warning on a dry run.
  Two or more pull requests that count fail a real run with "No single checklist pull request".
- **The dates**, set by the date commit before the checks, as described above: `Date:` in `DESCRIPTION` is required.
- **The permissions** the calling job grants: `actions: read` to find and download the artifact,
  `contents: write` to draft the release, and `pull-requests: write` to report.
  The run needs no secret beyond the workflow's own token.

## Builder checks

[`.github/workflows/builders.yaml`](.github/workflows/builders.yaml) uploads the same checked tarball
to win-builder and to macbuilder, and reports both on the checklist pull request.
These checks inform the release and never gate it: the submission neither waits for them nor reads their results.
Win-builder checks on the queues that `queues` names, R-devel by default, and macbuilder on R-devel only.
The workflow takes the tarball exactly as the submission does, from a green check run of the commit,
so what the builders check is the file that CRAN receives.

```yaml
on:
  workflow_dispatch:
    inputs:
      dry-run:
        type: boolean
        default: true

jobs:
  builders:
    uses: krlmlr/r-release-actions/.github/workflows/builders.yaml@<sha> # vX.Y.Z
    permissions:
      actions: read
      contents: read
      pull-requests: write
    with:
      sha: ${{ github.sha }}
      dry-run: ${{ inputs.dry-run }}
```

Inputs:

- `sha`, `dry-run`, `check-workflow` and `check-run-id`: as for the CRAN submission.
- `queues`: the win-builder queues to upload to, separated by spaces, of `R-devel`, `R-release` and `R-oldrelease`;
  by default `R-devel`.
- `macbuilder-timeout-minutes`: how long to wait for macbuilder's result, by default 60 and at most 150.

What a run does, job by job:

- **version** reads `Package:` and `Version:` from `DESCRIPTION`, and only warns about the dates,
  because the builders may run days before the submission.
  It finds the checklist pull request, and runs on without one.
- **tarball** finds the check run and its tarball artifact, and verifies the file, as the submission's job of that name does.
- **winbuilder** uploads the tarball by anonymous FTP to `ftp://win-builder.r-project.org/<queue>/` for each queue in `queues`,
  as `devtools::check_win_devel()` does for `R-devel`, retrying a refused connection or an unresolved host twice.
  It tries every queue, and fails after the others when one upload failed.
  Win-builder emails the results to the maintainer named in the tarball, usually within 30 minutes.
  A failed upload fails the job.
- **macbuilder** posts the tarball to `https://mac.r-project.org/macbuilder/v1/submit` for `r-devel`,
  as `devtools::check_mac_devel()` does,
  and polls the result page it answers with, once a minute, until the page shows a finished check log or the wait ends.
  Macbuilder documents no states: a page counts as finished when its check log ends in the `Status:` line,
  macbuilder's `* result classification:` line and the end of the log, as finished pages do,
  so that a `Status:` line in a test's output does not end the wait.
  A check that ends in a note, a warning or an error, a status that is none of `R CMD check`'s, reported as `unknown`
  with the result page to read, and a wait that ends without a result are reported with a warning,
  and do not fail the job; a failed upload does.
- **report**, on a real run with a checklist pull request that nobody cancelled, creates or updates the workflow's one comment there,
  marked `<!-- release-builders: <package> X.Y.Z -->`: each win-builder upload, and macbuilder's status with a link to its result page.
- **preview**, on a dry run, shows that comment in the run's summary, with no permission.

A dry run uploads nothing and writes nothing: it verifies the tarball, and reports the URLs and fields a real run would send.
The calling job grants `actions: read` and `contents: read` to find and download the artifact,
and `pull-requests: write` to report.

## Release gate

[`.github/workflows/release-gate.yaml`](.github/workflows/release-gate.yaml) checks that a commit is ready for a CRAN release,
on the release branch or, on the fast path, on `main`, after the date commit and the check workflow's run on it.
It fails on what CRAN requires, reports on what CRAN expects without failing on it,
and keeps one comment on the checklist pull request, which later runs update in place.

```yaml
on:
  workflow_dispatch:

jobs:
  gate:
    uses: krlmlr/r-release-actions/.github/workflows/release-gate.yaml@<sha> # vX.Y.Z
    permissions:
      actions: read
      contents: read
      pull-requests: write
    with:
      sha: ${{ github.sha }}
```

Inputs:

- `sha` (required): the full SHA of the commit to check, the head of the branch the caller was dispatched on.
- `check-workflow`: the file name of the check workflow that built the tarball, by default `R-CMD-check.yaml`.
- `check-run-id`: the check run to take the tarball from; by default, the newest run of `check-workflow` on `sha` that holds it.

What a run does, job by job:

- **hard** runs every check that CRAN requires, and fails when any fails, with an error for each that names its cause:
  - `Version:` has exactly three components, such as `1.2.3` or `1.2-3`.
    A version with two components, such as `1.0`, fails on purpose: this process releases three-component versions only.
  - `DESCRIPTION` has no `Remotes` field.
  - CRAN's package database, [`packages.rds`](https://cran.r-project.org/web/packages/packages.rds), can be read.
    The next checks use it, and a database that cannot be read fails, because what they check is then unknown.
  - No dependency in `Depends`, `Imports`, `LinkingTo`, `Suggests` or `Enhances` names a source outside CRAN as `Remotes` does,
    such as `owner/repo` or `github::owner/repo`, or requires a version that CRAN does not have:
    one higher than CRAN's current version for `>=` and `>`, another one for `==`.
    A constraint with four components, such as `Matrix (>= 1.6-1.1)`, passes when CRAN has that version or a later one.
    Base packages such as `stats` pass; recommended packages such as `Matrix` are on CRAN, and are checked as any other.
    A package that is not on CRAN passes, reported in the comment, when Bioconductor's release lists it
    in its software, annotation data or experiment data index, the `PACKAGES` files under
    `https://bioconductor.org/packages/release/`, because CRAN installs from Bioconductor too;
    `biocViews` in `DESCRIPTION` plays no part.
    A package in `Suggests` or `Enhances` may also come from a repository named in `Additional_repositories`,
    as [CRAN's policy](https://cran.r-project.org/web/packages/policies.html) allows; it passes, reported.
    The field itself is reported too, for a look at whether each repository is needed and reachable.
    Any other package that is not on CRAN fails.
    A version constraint on a Bioconductor package is checked against the version in its index, as for CRAN.
    The gate reads Bioconductor's release indexes only, so a package that exists only in Bioconductor's devel branch fails.
    Bioconductor's indexes that cannot be read are reported once,
    and a package that is not on CRAN then fails, with that cause in its error.
  - `NEWS.md` has exactly one section for the version, found by its heading `# <package> X.Y.Z` with or without a date,
    outside code fences.
    Without one, the error names the headings that mention the version, such as `## <package> X.Y.Z` or `# <package> vX.Y.Z`.
    The heading carries a date, the same as `Date:` in `DESCRIPTION`, at most 31 days before the run's date in UTC
    and at most a day after it.
    A missing `Date:` fails on purpose, because the date commit sets it with the heading's date.

  It then finds the checklist pull request as the submission does; without one, the run reports only to its summary.
- **checks** reports on what CRAN expects, and fails on no finding.
  It installs the package's dependencies, rmarkdown, spelling and urlchecker, and reports:
  - a setup step that failed, such as installing a dependency, with the checks it keeps from running;
  - a `Deadline` that CRAN's package database sets for the package, with its date.
    A deadline asks for a fix in a release, so it never blocks the release that brings the fix;
    the report points at CRAN's check results;
  - help pages with a `\usage` section and without a `\value` section, leaving out pages of data sets and of the package;
  - `README.md`, when `README.Rmd` was committed after it, or when knitting `README.Rmd` gives another `README.md`;
  - the URLs that `urlchecker::url_check()` flags;
  - the words that `spelling::spell_check_package()` flags;
  - `R CMD check --as-cran --no-manual` with CRAN's incoming checks, the remote ones included,
    on the tarball that the check workflow built and checked, taken as the submission takes it.
    Nothing skips the incoming check of the dates.
    Without a green check run holding the tarball, or when taking it fails, this check is reported as not run,
    quoting the error of the step that took it, with a link to the job.
    It is reported as not run, too, when the package's dependencies could not be installed.

  A check that cannot run, such as a knit that fails, is reported as not run.
- **report** updates the release gate's comment on the checklist pull request:
  whether the release is ready, which is whether **hard** passed, then the result of each check.
  A report too long for a comment is cut, and the run's summary page has all of it.

The gate has no dry run: it writes nothing but its comment, and every run that finds the checklist pull request updates it.
Runs on the same branch cancel each other, and the newest one reports.
The calling job grants `contents: read` to read the commit, `actions: read` to find the tarball,
and `pull-requests: write` to report.
The package's own code runs only in **checks**, and only after the steps that use a token:
the one that takes the checked tarball, and the one that finds the job's URL for the comment's links.
That step finds the job by the name it passes as `job-name`, which must match the `name:` of **checks**;
if it does not, the comment links the run instead of the job.

## Release status

[`.github/workflows/release-status.yaml`](.github/workflows/release-status.yaml) finishes a release once CRAN has accepted it:
it writes the tag, publishes the draft release, and brings the release and the development bump to the default branch.
A package calls it nightly and on dispatch, from its own repository, with its own token.

```yaml
on:
  schedule:
    - cron: "43 5 * * *"
  workflow_dispatch:
    inputs:
      dry-run:
        type: boolean
        default: false

jobs:
  release-status:
    uses: krlmlr/r-release-actions/.github/workflows/release-status.yaml@<sha> # vX.Y.Z
    permissions:
      contents: write
      pull-requests: write
    with:
      dry-run: ${{ inputs.dry-run == true }}
```

The schedule stays on between releases, and a run without a draft release does nothing.
In a public repository GitHub disables a schedule after 60 days without activity,
so a release of a package that quiet starts with enabling the workflow again: `gh workflow enable <file> --repo <owner>/<repo>`.

Inputs:

- `dry-run`: read and check everything, report what a real run would write, and write nothing; off by default,
  and off on a scheduled run.

What a run does:

- It lists the releases whose notes carry the submission marker `<!-- cran-submission: <package> X.Y.Z -->`
  and whose tag name is `vX.Y.Z`: every draft, and every published release whose checklist pull request is still open,
  which an earlier run left unfinished.
  It stops when there is none, and fails before writing anything when the releases, the open pull requests
  or the repository's default branch cannot be read.
- It reads the source index of Posit's package manager,
  `https://packagemanager.posit.co/cran/latest/src/contrib/PACKAGES.gz`, once.
  That is the test `fledge:::release_after_cran_built_binaries()` made, and a listing there also means the binaries are on their way.
  A version the index does not list yet is a line in the run's summary, and the run stays green.
  A later version in the index counts too, so that a draft left behind by a missed run still finishes.
  A run finishes at most one accepted release, and leaves any other for the next run, so that it fits the job's timeout.
- For a draft whose version the index lists, it takes these steps in order, and stops at the first that fails:
  - **compare**: it checks that the draft's target is a full commit SHA, as the submission writes it,
    and that `DESCRIPTION` there carries the package and the version.
    It downloads CRAN's tarball of the version, from `src/contrib/` or `src/contrib/Archive/<package>/`,
    and the draft's asset `<package>_X.Y.Z.tar.gz`, checked against the digest GitHub records.
    The two must hold the same paths, of the same types and executable bits, with the same contents,
    but for CRAN's `MD5` file and the fields CRAN adds to `DESCRIPTION`, `Repository` and `Date/Publication`;
    symbolic links are compared as links.
    A difference refuses the tag and fails the run, because CRAN then accepted another upload than the draft records,
    as when a stale confirmation link from an earlier attempt was followed.
    A draft without that asset, or several drafts of the version, fail as well.
  - **tag**: it writes the annotated tag `vX.Y.Z` on the draft's target,
    with `<package> X.Y.Z`, a blank line and the version's `NEWS.md` section at that commit as its message.
    A tag that exists on the target already is kept; one on another commit fails the run, since a tag is never moved.
  - **publish**: it publishes the draft, which is what says that the version is on CRAN,
    as the latest release when the index lists this version, and below the latest when it lists a later one.
  - **finish**: it finds the checklist pull request as the submission does.
    One that changes no file is the fast path's empty checklist pull request; any other is the release pull request.
    - On the default path it checks that the release branch, the pull request's head, reaches the released commit,
      merges the default branch into the release branch unless the branch carries the bump already, commits the development bump on it,
      and merges the release pull request with a merge commit, at the commit it just wrote.
    - On the fast path it checks that the default branch reaches the released commit,
      commits the development bump to the default branch, and closes the empty checklist pull request.
    - A write it cannot make it hands over, and the run stays green with a warning:
      a merge of the default branch that conflicts, as a hotfix's does by construction,
      with the bump and the merge of the release pull request after it;
      a merge or a push that the default branch's protection refuses;
      and a release pull request from another repository or into another branch.
      On the fast path the empty checklist pull request then stays open until the bump lands.
- For a published release whose checklist pull request is open, it requires the index to list the version or a later one,
  and warns and writes nothing otherwise, as for a release published by hand too early.
  It then takes the **compare** step again against the release's asset, which catches a resubmission that moved the branch on,
  checks that the tag is on the release's target, and takes the **finish** step.
- For each accepted version it keeps one comment on the checklist pull request, marked `<!-- release-status: <package> X.Y.Z -->`:
  what it checked and wrote, and what is left, with the commands that do it.
  Without a checklist pull request it tags and publishes, warns, and leaves the rest to the maintainer.

A merge or a push made with the workflow's own token starts no workflows on the default branch, so none runs there until its next push.
A run is idempotent: a tag on the target, a published release, a branch that carries the bump
and a branch that holds the default branch already count as done.
A run that stops after publishing, even one killed before its comment, leaves the checklist pull request open,
so the next run lists the published release and finishes it.
The bump checks that the branch it writes to carries the released version, or its bump, and hands over otherwise.
A dry run holds the same token, because only a token that can write sees draft releases, and writes nothing:
its summary shows what a real run would tag, publish, commit, merge and close, and the comment it would write.
The run checks out nothing and runs none of the package's code.
Its downloads are bounded so that one accepted release fits well within the job's 30 minutes,
and one run per repository runs at a time, never cancelled.
The calling job grants `contents: write` to tag, publish and commit, and `pull-requests: write` to merge, close and comment.

### The development bump

[`actions/dev-bump/dev-bump.sh`](actions/dev-bump/dev-bump.sh) writes the development bump into a checkout,
and the release status workflow runs it on the files it commits.
It sets `Version: X.Y.Z.9000` in `DESCRIPTION`, and puts the development section at the top of `NEWS.md`,
replacing one that is there:

```markdown
# <package> (development version)

Changes since vX.Y.Z: <https://github.com/<owner>/<repo>/compare/vX.Y.Z...main>
```

It needs the release's own section in `NEWS.md`, changes nothing in a checkout that carries the bump already, and commits nothing.
A maintainer who takes over the bump runs it from the repository's root:

```sh
curl -fsSL https://raw.githubusercontent.com/krlmlr/r-release-actions/main/actions/dev-bump/dev-bump.sh |
  bash -s -- . <owner>/<repo> main
```

## Layout

- `.github/workflows/` holds the reusable workflows, each triggered by `workflow_call`.
- `actions/<name>/` holds one composite action each, in `action.yml`.
  A script the action runs lives beside it, with its offline test next to it,
  so that each action can be tested without a network or a package to release.
  `actions/cran-lib/` holds the shell helpers the scripts and their tests share.
- The tests run with `for t in actions/*/*-test.sh; do "$t"; done`, against stubs and local servers:
  they reach neither GitHub, nor CRAN, nor the builders.
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
