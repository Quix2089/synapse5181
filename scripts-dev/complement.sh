#!/usr/bin/env bash
# This script is designed for developers who want to test their code
# against Complement.
#
# It makes a Synapse image which represents the current checkout,
# builds a synapse-complement image on top, then runs tests with it.
#
# By default the script will fetch the latest Complement main branch and
# run tests with that. This can be overridden to use a custom Complement
# checkout by setting the COMPLEMENT_DIR environment variable to the
# filepath of a local Complement checkout or by setting the COMPLEMENT_REF
# environment variable to pull a different branch or commit.
#
# By default Synapse is run in monolith mode. This can be overridden by
# setting the WORKERS environment variable.
#
# You can optionally give a "-f" argument (for "fast") before any to skip
# rebuilding the docker images, if you just want to rerun the tests.
#
# Remaining commandline arguments are passed through to `go test`. For example,
# you can supply a regular expression of test method names via the "-run"
# argument:
#
# ./complement.sh -run "TestOutboundFederation(Profile|Send)"
#
# Specifying TEST_ONLY_SKIP_DEP_HASH_VERIFICATION=1 will cause `poetry export`
# to not emit any hashes when building the Docker image. This then means that
# you can use 'unverifiable' sources such as git repositories as dependencies.

# Exit if a line returns a non-zero exit code
set -e


# Helper to emit annotations that collapse portions of the log in GitHub Actions
echo_if_github() {
  if [[ -n "$GITHUB_WORKFLOW" ]]; then
    echo $*
  fi
}

# Helper to print out the usage instructions
usage() {
    cat >&2 <<EOF
Usage: $0 [-f] <go test arguments>...
Run the complement test suite on Synapse.

  -f, --fast
        Skip rebuilding the docker images, and just use the most recent
        'complement-synapse:latest' image.
        Conflicts with --build-only.

  --build-only
        Only build the Docker images. Don't actually run Complement.
        Conflicts with -f/--fast.

  -e, --editable
        Use an editable build of Synapse, rebuilding the image if necessary.
        This is suitable for use in development where a fast turn-around time
        is important.
        Not suitable for use in CI in case the editable environment is impure.

For help on arguments to 'go test', run 'go help testflag'.
EOF
}

# parse our arguments
skip_docker_build=""
skip_complement_run=""
while [ $# -ge 1 ]; do
    arg=$1
    case "$arg" in
        "-h")
            usage
            exit 1
            ;;
        "-f"|"--fast")
            skip_docker_build=1
            ;;
        "--build-only")
            skip_complement_run=1
            ;;
        "-e"|"--editable")
            use_editable_synapse=1
            ;;
        *)
            # unknown arg: presumably an argument to gotest. break the loop.
            break
    esac
    shift
done

# enable buildkit for the docker builds
export DOCKER_BUILDKIT=1

# Change to the repository root
cd "$(dirname $0)/.."

# Check for a user-specified Complement checkout
if [[ -z "$COMPLEMENT_DIR" ]]; then
  COMPLEMENT_REF=${COMPLEMENT_REF:-main}
  echo "COMPLEMENT_DIR not set. Fetching Complement checkout from ${COMPLEMENT_REF}..."
  wget -Nq https://github.com/matrix-org/complement/archive/${COMPLEMENT_REF}.tar.gz
  tar -xzf ${COMPLEMENT_REF}.tar.gz
  COMPLEMENT_DIR=complement-${COMPLEMENT_REF}
  echo "Checkout available at 'complement-${COMPLEMENT_REF}'"
fi

if [ -n "$use_editable_synapse" ]; then
    if [[ -e synapse/synapse_rust.abi3.so ]]; then
        # In an editable install, back up the host's compiled Rust module to prevent
        # inconvenience; the container will overwrite the module with its own copy.
        mv -n synapse/synapse_rust.abi3.so synapse/synapse_rust.abi3.so~host
        # And restore it on exit:
        synapse_pkg=`realpath synapse`
        trap "mv -f '$synapse_pkg/synapse_rust.abi3.so~host' '$synapse_pkg/synapse_rust.abi3.so'" EXIT
    fi

    editable_mount="$(realpath .):/editable-src:z"
    if docker inspect complement-synapse-editable &>/dev/null; then
        # complement-synapse-editable already exists: see if we can still use it:
        # - The Rust module must still be importable; it will fail to import if the Rust source has changed.
        # - The Poetry lock file must be the same (otherwise we assume dependencies have changed)

        # First set up the module in the right place for an editable installation.
        docker run --rm -v $editable_mount --entrypoint 'cp' complement-synapse-editable -- /synapse_rust.abi3.so.bak /editable-src/synapse/synapse_rust.abi3.so

        if (docker run --rm -v $editable_mount --entrypoint 'python' complement-synapse-editable -c 'import synapse.synapse_rust' \
            && docker run --rm -v $editable_mount --entrypoint 'diff' complement-synapse-editable --brief /editable-src/poetry.lock /poetry.lock.bak); then
            skip_docker_build=1
        else
            echo "Editable Synapse image is stale. Will rebuild."
            unset skip_docker_build
        fi
    fi
fi

if [ -z "$skip_docker_build" ]; then
    if [ -n "$use_editable_synapse" ]; then

        # Build a special image designed for use in development with editable
        # installs.
        docker build -t synapse-editable \
            -f "docker/editable.Dockerfile" .

        docker build -t synapse-workers-editable \
            --build-arg FROM=synapse-editable \
            -f "docker/Dockerfile-workers" .

        docker build -t complement-synapse-editable \
            --build-arg FROM=synapse-workers-editable \
            -f "docker/complement/Dockerfile" "docker/complement"

        # Prepare the Rust module
        docker run --rm -v $editable_mount --entrypoint 'cp' complement-synapse-editable -- /synapse_rust.abi3.so.bak /editable-src/synapse/synapse_rust.abi3.so

    else

        # Build the base Synapse image from the local checkout
        echo_if_github "::group::Build Docker image: matrixdotorg/synapse"
        docker build -t matrixdotorg/synapse \
        --build-arg TEST_ONLY_SKIP_DEP_HASH_VERIFICATION \
        --build-arg TEST_ONLY_IGNORE_POETRY_LOCKFILE \
        -f "docker/Dockerfile" .
        echo_if_github "::endgroup::"

        # Build the workers docker image (from the base Synapse image we just built).
        echo_if_github "::group::Build Docker image: matrixdotorg/synapse-workers"
        docker build -t matrixdotorg/synapse-workers -f "docker/Dockerfile-workers" .
        echo_if_github "::endgroup::"

        # Build the unified Complement image (from the worker Synapse image we just built).
        echo_if_github "::group::Build Docker image: complement/Dockerfile"
        docker build -t complement-synapse \
            -f "docker/complement/Dockerfile" "docker/complement"
        echo_if_github "::endgroup::"

    fi
fi

if [ -n "$skip_complement_run" ]; then
    echo "Skipping Complement run as requested."
    exit
fi

export COMPLEMENT_BASE_IMAGE=complement-synapse
if [ -n "$use_editable_synapse" ]; then
    export COMPLEMENT_BASE_IMAGE=complement-synapse-editable
    export COMPLEMENT_HOST_MOUNTS="$editable_mount"
fi

extra_test_args=()

test_tags="synapse_blacklist,msc3787,msc3874"

# All environment variables starting with PASS_ will be shared.
# (The prefix is stripped off before reaching the container.)
export COMPLEMENT_SHARE_ENV_PREFIX=PASS_

# It takes longer than 10m to run the whole suite.
extra_test_args+=("-timeout=60m")

if [[ -n "$WORKERS" ]]; then
  # Use workers.
  export PASS_SYNAPSE_COMPLEMENT_USE_WORKERS=true

  # Pass through the workers defined. If none, it will be an empty string
  export PASS_SYNAPSE_WORKER_TYPES="$WORKER_TYPES"

  # Workers can only use Postgres as a database.
  export PASS_SYNAPSE_COMPLEMENT_DATABASE=postgres

  # And provide some more configuration to complement.

  # It can take quite a while to spin up a worker-mode Synapse for the first
  # time (the main problem is that we start 14 python processes for each test,
  # and complement likes to do two of them in parallel).
  export COMPLEMENT_SPAWN_HS_TIMEOUT_SECS=120
else
  export PASS_SYNAPSE_COMPLEMENT_USE_WORKERS=
  if [[ -n "$POSTGRES" ]]; then
    export PASS_SYNAPSE_COMPLEMENT_DATABASE=postgres
  else
    export PASS_SYNAPSE_COMPLEMENT_DATABASE=sqlite
  fi

  # We only test faster room joins on monoliths, because they are purposefully
  # being developed without worker support to start with.
  #
  # The tests for importing historical messages (MSC2716) also only pass with monoliths,
  # currently.
  test_tags="$test_tags,faster_joins,msc2716"
fi


if [[ -n "$SYNAPSE_TEST_LOG_LEVEL" ]]; then
  # Set the log level to what is desired
  export PASS_SYNAPSE_LOG_LEVEL="$SYNAPSE_TEST_LOG_LEVEL"

  # Allow logging sensitive things (currently SQL queries & parameters).
  # (This won't have any effect if we're not logging at DEBUG level overall.)
  # Since this is just a test suite, this is fine and won't reveal anyone's
  # personal information
  export PASS_SYNAPSE_LOG_SENSITIVE=1
fi

# Run the tests!
echo "Images built; running complement"
cd "$COMPLEMENT_DIR"

go test -v -tags $test_tags -count=1 "${extra_test_args[@]}" "$@" ./tests/...
