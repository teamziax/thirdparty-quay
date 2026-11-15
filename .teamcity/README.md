# TeamCity pipeline

This fork builds on [TeamCity](https://ziax.teamcity.com/project/ThirdParty_Quay), in the Third-Party project, not GitHub Actions, which stays off on the fork. The pipeline is Kotlin DSL:

- `settings.kts` is this repository's pipeline: **Build image**, which runs `ziax/build.sh` for every push to a `ziax/*` branch and publishes `quay.io/ziax/quay:<version>-<commit>` (`ziax/README.md`).
- `build-image.sh` is its step script, read in when TeamCity compiles the settings. It must not contain a percent sign, because TeamCity reads a pair of them as a parameter reference.
- `Ziax.kt` is a shared convention: every repository on our TeamCity carries an identical copy, so change them everywhere at once. This fork carries none of the shared image-publishing scripts, because it publishes its own way.

TeamCity reads this directory through versioned settings from the VCS root's default branch, `ziax/3.18.1`, and the project is read-only in the TeamCity UI: change the pipeline here. Builds of every branch use the default branch's settings. The VCS root watches only `ziax/*` branches, since master and the branches for upstream pull requests have no `ziax/` directory to build.

## Pull requests

*Build image* has no Pull Requests feature, unlike our other forks' CI builds. Anyone can open a pull request against a public fork, and this build holds the quay.io robot's login. A `ziax/*` branch, which only the organization can push, is built when it is pushed, and GitHub shows that build's status on any pull request from it.

## Inputs

The robot's login is two secure values, `QUAY_USERNAME` and `QUAY_PASSWORD` (`Input` in `settings.kts`): a quay.io robot with write on `quay.io/ziax/quay`. To set one up, in this project: *Project Settings → Actions → Generate token for a secure value*, paste the value, and put the `credentialsJSON:…` it returns in the input's `value`. Tokens work only in the project that generated them. Both were set up on 2026-11-15. Without one, a build builds and tests its image, then fails without publishing and names it.

## Checking a change locally

Compile and generate the settings exactly as the server does:

```sh
mvn -s path/to/settings.xml -f .teamcity/pom.xml teamcity-configs:generate
```

The Maven settings file holds a TeamCity access token for the server's DSL plugins repository, as in cubecraft's README. If the DSL jars are already in `~/.m2`, `mvn -o` works without one. It fails on anything the server would reject and writes the resulting configuration to `.teamcity/target/generated-configs/`.
