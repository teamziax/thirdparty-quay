import jetbrains.buildServer.configs.kotlin.*
import jetbrains.buildServer.configs.kotlin.buildSteps.script
import jetbrains.buildServer.configs.kotlin.triggers.vcs

/*
 * TeamCity pipeline for teamziax/thirdparty-quay, our fork of quay/quay. It builds quay.io/ziax/quay, upstream's Quay
 * image with the changes on a ziax/<version> branch written over it (ziax/README.md), which man1-prod1's Quay runs.
 * The fork is temporary: it carries changes until a Quay release has them.
 *
 * TeamCity loads this directory through versioned settings on Third-Party / Quay
 * (https://ziax.teamcity.com/project/ThirdParty_Quay) from the VCS root's default branch, ziax/3.18.1, and builds of
 * every branch use those settings. The VCS root watches only the branches under ziax/; master and the branches for
 * upstream pull requests carry no ziax/ directory to build. GitHub Actions stays off on the fork and .github/ is left
 * as upstream has it. Ziax.kt is shared with the other repositories; README.md says how to check a change locally.
 */

// TeamCity Cloud has refused settings newer than 2026.1 since its update of 2026-11-02 ("settings version 2026.2 is not
// supported").
version = "2026.1"

project {
    params {
        // This fork publishes from TeamCity. The Root project defaults this to false, which keeps the deploy jobs
        // ported from repositories that have not cut over yet build-only.
        param("deploy.push.enabled", "true")
    }

    buildType(BuildImage)
}

/**
 * A secure value the build needs, named for the environment variable it becomes: a token for TeamCity's secure store,
 * generated in this project (Project Settings → Actions → Generate token for a secure value) and put in [value] as
 * "credentialsJSON:<token>". While one has no value, a build builds and smoke-tests its image, then fails without
 * publishing and names it.
 */
enum class Input(val value: String?) {
    // A quay.io robot with write on quay.io/ziax/quay: its name, and its token.
    QUAY_USERNAME(null),
    QUAY_PASSWORD(null),
}

object BuildImage : BuildType({
    id("BuildImage")
    name = "Build image"
    description = "ziax/build.sh: upstream's Quay image with the branch's changes, smoke-tested and published to " +
        "quay.io/ziax/quay as <version>-<commit>"

    // One build at a time, so two builds of a new commit cannot both find its tag missing and push it.
    maxRunningBuilds = 1

    vcs {
        root(DslContext.settingsRoot)
    }

    params {
        // A Docker config of the build's own, in its temporary directory: see build-image.sh.
        param("env.DOCKER_CONFIG", "%system.teamcity.build.tempDir%/docker")
        param("env.FORK_COMMIT", "%build.vcs.number%")
        param("env.DEPLOY_PUSH", "%deploy.push.enabled%")
        for (input in Input.values()) {
            val value = input.value ?: continue
            password("env.${input.name}", value)
        }
        val missing = Input.values().filter { it.value == null }
        if (missing.isNotEmpty()) param("env.MISSING_INPUTS", missing.joinToString(" "))
    }

    steps {
        script {
            name = "Build, test and publish the image"
            scriptContent = "#!/bin/bash\n" + scriptFile("build-image.sh")
        }
    }

    triggers {
        // Every push to a branch under ziax/ builds and publishes its commit, so a branch can be tried on a cluster
        // before it merges. Pull requests never reach this configuration: it has no Pull Requests feature, and anyone
        // can open a pull request against a public fork, while this build holds the robot's login.
        vcs {
            branchFilter = "+:*"
        }
    }

    features {
        githubCommitStatus()
    }

    requirements {
        exists("docker.server.version")
    }

    failureConditions {
        executionTimeoutMin = 30
    }
})
