# Contributing

Thank you for looking. This is a young project run in spare time; small, well-described contributions are the
ones that get in.

## Reporting a problem

In the app, choose **Help › Report a Problem**. It shows a short report (versions, the state of Setup, the end
of the job log) with names, device and team identifiers and paths from your home folder removed. Copy it into a
[new issue](../../issues/new/choose) and add what you did and what you expected. Without that report it is
usually impossible to tell what happened.

Please do not post access tokens, account names or game files. Nobody needs them to help you.

## Code

```bash
cd core
swift test
tools/make-app.sh        # builds ../dist/AVP Play.app for this Mac
```

- `AVPPlayCore` is the library, `AVPPlayApp` the Mac app, `avpplay` a command-line tool on the same library.
- Every text a user can see exists in English and German, written where it is used: `L("English", "Deutsch")`.
  A change that adds a text adds both.
- Code comments are German for historical reasons. New comments may be English.
- Add a test for behaviour you add or fix. `swift test` must pass.
- The app has a `--snapshot <folder>` mode that renders every view into images without showing a window; it is
  how layout changes are checked.

Things the project will not accept: anything that distributes game content, anything that weakens the
ownership checks or tries files to see whether Meta serves them, and anything that sends data anywhere other
than to Meta (for the user's own downloads) and GitHub (for the update check).

## Adding a game

A game needs two things: a recipe ([format](docs/recipes.md)) and a *target* in the toolchain that makes the
game actually run. The second part is the real work. The toolchain is a fork of
[Klepton](https://github.com/shinyquagsire23/Klepton); its complete source is inside the toolchain package
attached to every release (`klepton-toolchain-*.tar.gz`), with its own `BUILDING.md`.

If you got a game running with Klepton and want it in AVP Play, open an issue first and describe the game, the
build you used and what you had to change. Recipes for builds nobody has seen running are not merged.
