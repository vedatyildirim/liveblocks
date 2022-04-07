#!/bin/sh
set -eu

# The output directory for the package build
ROOT="$(git rev-parse --show-toplevel)"
GITHUB_URL="https://github.com/liveblocks/liveblocks"
PACKAGE_DIRS=(
    "packages/liveblocks-client"
    "packages/liveblocks-react"
    "packages/liveblocks-redux"
    "packages/liveblocks-zustand"
)
PRIMARY_PKG=${PACKAGE_DIRS[0]}
SECONDARY_PKGS=${PACKAGE_DIRS[@]:1}

err () {
    echo "$@" >&2
}

is_valid_version () {
    echo "$1" | grep -qEe "^[0-9]+[.][0-9]+[.][0-9]+(-[[:alnum:].]+)?$"
}

is_valid_otp_token () {
    echo "$1" | grep -qEe "^[0-9]{6}?$"
}

usage () {
    err "usage: publish.sh [-V <version> [-t <tag>] [-h]"
    # err "usage: publish.sh [-Vtnh]"
    err
    err ""
    err "Publish a new version of the Liveblocks packages to NPM."
    err
    err "Options:"
    err "-V <version>  Set version to publish (default: prompt)"
    err "-t <tag>      Sets the tag to use on NPM (default: latest)"
    # err "-n            Dry run"
    err "-h            Show this help"
}

VERSION=
TAG=
# dryrun=0
# while getopts V:t:nh flag; do
while getopts V:t:h flag; do
    case "$flag" in
        V) VERSION=$OPTARG;;
        t) TAG=$OPTARG;;
        # n) dryrun=1;;
        *) usage; exit 2;;
    esac
done
shift $(($OPTIND - 1))

if [ "$#" -ne 0 ]; then
    err "Unknown arguments: $@"
    usage
    exit 2
fi

check_git_toolbelt_installed () {
    # Test existence of a random toolbelt command
    if ! which -s git-root; then
        err ""
        err "Oops!"
        err "git-toolbelt is not installed. The git-toolbelt is"
        err "a collection of useful small scripts that make writing"
        err "shell scripts easier. This script relies on it!"
        err ""
        err "You can find it at:"
        err "  https://github.com/nvie/git-toolbelt"
        err ""
        err "Please run:"
        err "  brew install fzf"
        err "  brew tap nvie/tap"
        err "  brew install nvie/tap/git-toolbelt"
        err ""
        exit 2
    fi
}

check_moreutils_installed () {
    if ! which -s sponge; then
        err ""
        err "Moreutils is not installed. It's a fantastic toolkit of UNIX"
        err "tools that make writing scripts like this much easier."
        err ""
        err "You can find more info at:"
        err "  https://joeyh.name/code/moreutils"
        err ""
        err "Please run:"
        err "  brew install moreutils"
        err ""
        exit 2
    fi
}

check_jq_installed () {
    if ! which -s jq; then
        err ""
        err "jq is not installed."
        err ""
        err "You can find it at:"
        err "  https://stedolan.github.io/jq/"
        err ""
        err "Please run:"
        err "  brew install jq"
        err ""
        exit 2
    fi
}

check_current_branch () {
    # Check we're on the main branch
    if [ -z "$TAG" -a "$(git current-branch)" != "main" ]; then
        err "To publish a package without a tag, you must be on \"main\" branch."
        exit 2
    fi
}

check_up_to_date_with_upstream () {
    # Update to latest version
    git fetch

    if [ "$(git sha)" != "$(git sha $(git current-branch))" ]; then
        err "Not up to date with upstream. Please pull/push latest changes before publishing."
        exit 2
    fi
}

check_cwd () {
    if [ "$(pwd)" != "$ROOT" ]; then
        err "This script must be run from the project's root directory."
        exit 2
    fi
}

check_no_local_changes () {
    if git is-dirty; then
        err "There are local changes. Please commit those before publishing."
        exit 3
    fi
}

check_npm_stuff_is_stable () {
    for pkg in ${PACKAGE_DIRS[@]}; do
        echo "Rebuilding node_modules inside $pkg (this may take a while)..."
        ( cd "$pkg" && (
            # Before bumping anything, first make sure that all projects have
            # a clean and stable node_modules directory and lock files!
            rm -rf node_modules

            logfile="$(mktemp)"
            if ! npm install > "$logfile" 2> "$logfile"; then
                cat "$logfile" >&2
                err ""
                err "The error above happened during the building of $PKGDIR."
                exit 4
            fi

            if git is-dirty; then
                err "I just removed node_modules and reinstalled all package dependencies"
                err "inside $pkg, and found unexpected changes in the following files:"
                err ""
                ( cd "$ROOT" && git modified )
                err ""
                err "Please fix those issues first."
                exit 2
            fi
        ) )
    done
}

check_all_the_things () {
    if [ -n "$VERSION" ] && ! is_valid_version "$VERSION"; then
        # Check for typos early on
        err "Invalid version: $VERSION"
        exit 2
    fi

    check_git_toolbelt_installed
    check_jq_installed
    check_moreutils_installed
    check_current_branch
    check_up_to_date_with_upstream
    check_cwd
    check_no_local_changes
    # check_npm_stuff_is_stable # TODO: Put back, this is disabled for speed/testing only
}

check_all_the_things

if [ -z "$VERSION" ]; then
    echo "The current version is: $(jq -r .version "$PRIMARY_PKG/package.json")"
fi

while ! is_valid_version "$VERSION"; do
    if [ -n "$VERSION" ]; then
        err "Invalid version number: $VERSION"
        err "Please try again."
        err ""
    fi
    read -p "Enter a new version: " VERSION
done

bump_version_in_pkg () {
    PKGDIR="$1"
    VERSION="$2"

    jq ".version=\"$VERSION\"" package.json | sponge package.json

    # If this is one of the client packages, also bump the peer dependency
    if [ "$(jq '.peerDependencies."@liveblocks/client"' package.json)" != "null" ]; then
        jq ".peerDependencies.\"@liveblocks/client\"=\"$VERSION\"" package.json | sponge package.json
    fi

    prettier --write package.json

    logfile="$(mktemp)"
    if ! npm install > "$logfile" 2> "$logfile"; then
        cat "$logfile" >&2
        err ""
        err "The error above happened during the building of $PKGDIR."
        exit 4
    fi

    if ! git modified | grep -qEe package-lock.json; then
        err "Hmm. package-lock.json wasn\'t affected by the version bump. This is fishy. Please manually inspect!"
        exit 5
    fi
}

build_pkg () {
    rm -rf lib
    npm run build
}

publish_to_npm () {
    PKG="$1"
    echo "I'm ready to publish $PKG to NPM, under $VERSION!"
    echo "For this, I'll need the One-Time Password (OTP) token."

    OTP=""
    while ! is_valid_otp_token "$OTP"; do
        if [ -n "$OTP" ]; then
            err "Invalid OTP token: $OTP"
            err "Please try again."
            err ""
        fi
        read -p "OTP token? " OTP
    done

    npm publish --tag "${TAG:-latest}" --otp "$OTP"
}

commit_to_git () {
    ( cd "$ROOT" && (
        git reset --quiet HEAD
        git add "$@"
        if git is-dirty -i; then
            git commit -m "Bump to $VERSION"
        fi
    ) )
}

# First build and publish the primary package
( cd "$PRIMARY_PKG" && (
    echo "==> Building and publishing $PRIMARY_PKG"
     bump_version_in_pkg "$PRIMARY_PKG" "$VERSION"
     build_pkg
     publish_to_npm "$PRIMARY_PKG"
     commit_to_git "$PRIMARY_PKG" 
) )

# Then, build and publish all the other packages
for pkg in ${SECONDARY_PKGS}; do
    echo "==> Building and publishing ${pkg}"
    ( cd "$pkg" && (
        bump_version_in_pkg "$pkg" "$VERSION"
        build_pkg
        publish_to_npm "$pkg"
    ) )
done
commit_to_git "$pkg" 

echo "==> Pushing changes to GitHub"
git push-current

# Open browser tab to create new release
open "${GITHUB_URL}/releases/new?tag=${VERSION}&target=$(git sha)&title=${VERSION}&body=%23%23%20%60%40liveblocks%2Fclient%60%0A%0A-%20%2A%2ATODO%3A%20Describe%20relevant%20changes%20for%20this%20package%2A%2A%0A%0A%0A%23%23%20%60%40liveblocks%2Freact%60%0A%0A-%20%2A%2ATODO%3A%20Describe%20relevant%20changes%20for%20this%20package%2A%2A%0A%0A%0A%23%23%20%60%40liveblocks%2Fredux%60%0A%0A-%20%2A%2ATODO%3A%20Describe%20relevant%20changes%20for%20this%20package%2A%2A%0A%0A%0A%23%23%20%60%40liveblocks%2Fzustand%60%0A%0A-%20%2A%2ATODO%3A%20Describe%20relevant%20changes%20for%20this%20package%2A%2A%0A%0A"
echo "Done! Please finish it off by writing a nice changelog entry on GitHub."
echo ""
echo "You can double-check the published releases here:"
echo "  - https://www.npmjs.com/package/@liveblocks/client"
echo "  - https://www.npmjs.com/package/@liveblocks/react"
echo "  - https://www.npmjs.com/package/@liveblocks/redux"
echo "  - https://www.npmjs.com/package/@liveblocks/zustand"
echo ""
