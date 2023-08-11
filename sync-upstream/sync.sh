#!/usr/bin/env bash

# Always start with a new line.
echo ""

# Enable script debugging in non-CI environments when the DEBUG environment variable is set to true.
if [ "$CI" != "true" ] && [ "$DEBUG" == "true" ]; then
    echo "! DEBUG MODE ENABLED !"
    set -x
fi
# set -x

# Set GITHUB_OUTPUT to a temporary file if not running in a CI environment.
if [ "$CI" != "true" ]; then
    GITHUB_OUTPUT=$(mktemp)
    trap "echo \"\"; echo \"GITHUB_OUTPUT:\"; cat ${GITHUB_OUTPUT}; rm -f $GITHUB_OUTPUT || true" EXIT
fi

# Current logging indentation level as a string when not running in a CI environment.
INDENTATION_LEVEL=""

# Functions for logging to GitHub Actions or stdout/stderr,
# based on whether we're running in a CI environment or not.
log() { if [ "$CI" != "true" ]; then echo -e "${INDENTATION_LEVEL}${1}"; else echo "::debug::${1}"; fi }
info() { if [ "$CI" != "true" ]; then echo -e "${INDENTATION_LEVEL}${1}"; else echo "::info::${1}"; fi }
warning() { if [ "$CI" != "true" ]; then echo -e "${INDENTATION_LEVEL}${1}"; else echo "::warning::${1}"; fi }
error() { if [ "$CI" != "true" ]; then echo -e "${INDENTATION_LEVEL}${1}"; else echo "::error::${1}"; exit 1; fi; }

# Functions for creating and ending logging groups in GitHub Actions, or setting and removing simple identation when not running in a CI environment.
group_start() {
    if [ "$CI" != "true" ]; then
        # Print the group name.
        echo -e "${INDENTATION_LEVEL}${1}";

        # Add 2 spaces to the indentation level string.
        INDENTATION_LEVEL="${INDENTATION_LEVEL}  "
    else
        echo "::group::${1}";
    fi
}
group_end() {
    if [ "$CI" != "true" ]; then
        # Remove 2 spaces from the indentation level string.
        INDENTATION_LEVEL="${INDENTATION_LEVEL%  }"
        # Print a newline to separate the group from the next line.
        echo -en "${INDENTATION_LEVEL}\n"
    else
        echo "::endgroup::"
    fi
}

# Function for running the given command silently and returning the exit code status of the command, while only echoing the command instead of running it when not in a CI environment.
run() {
    if [ "$CI" == "true" ]; then
        # Run the command silently.
        $* > /dev/null 2>&1
    else
        # Print the command.
        echo -e "${INDENTATION_LEVEL}${*} (simulated)"
    fi
}

# Begin validation
group_start "Validating environment and input parameters"

# Check if current directory is a valid git repository.
if [ ! -d ".git" ] || ! run git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    echo "::error::The current directory doesn't appear to be a valid Git repository, the 'git' command is unavailable or an unexpected error occurred. Ensure that the 'checkout' action has run successfully before executing this action."
    exit 1
fi

# Validate that we have GITHUB_REPOSITORY set.
if [ -z "$GITHUB_REPOSITORY" ]; then
    error "GITHUB_REPOSITORY is not set. Something went wrong."
fi

# If no branch is provided as an argument, use the current branch.
BRANCH=${1:-$(git rev-parse --abbrev-ref HEAD)}
if [ -z "$BRANCH" ]; then
    error "Branch name is invalid or not set. Please provide a valid branch name to sync."
fi

# Get the upstream repository in GitHub format.
UPSTREAM_REPO=${2}
if [ -z "$UPSTREAM_REPO" ]; then
    error "Upstream repository is invalid or not set. Please provide a valid upstream repository in the GitHub format of 'owner/repo'."
fi

# Get the list of protected branches in comma-separated format.
PROTECTED_BRANCHES_INPUT=${3:-"master,main,production"}

# If the protected-branches input is provided but is empty, set PROTECTED_BRANCHES to an empty array.
if [ -z "$PROTECTED_BRANCHES_INPUT" ]; then
    PROTECTED_BRANCHES=()
else
    IFS=',' read -ra PROTECTED_BRANCHES <<< "$PROTECTED_BRANCHES_INPUT"
fi

# Safety Check: If the branch is in the list of protected branches, exit.
for protected in "${PROTECTED_BRANCHES[@]}"; do
    if [ "$BRANCH" == "$protected" ]; then
        error "${BRANCH} is a protected branch and cannot be synced!"
    fi
done

# Get the GitHub Token from the input.
REPO_TOKEN=${4}
if [ -z "$REPO_TOKEN" ]; then
    error "GitHub Token is invalid or not set. Please provide a valid GitHub Token with the 'repo' scope."
fi

# Get the fetch depth from the input.
FETCH_DEPTH=${5:-1}
if [ -z "$FETCH_DEPTH" ]; then
    error "Fetch depth is invalid or not set. Please provide a valid fetch depth."
fi

# End validation
group_end

# Set up Git credentials
group_start "Setting up git credentials"
if ! run git config --global user.email "actions@github.com"; then
    error "Failed to configure git user email."
fi
if ! run git config --global user.name "GitHub Actions"; then
    error "Failed to configure git user name."
fi
group_end

# Set the GitHub token for authentication
group_start "Setting up GitHub Token for repository ${GITHUB_REPOSITORY}"
if ! run git remote set-url origin "https://x-access-token:${REPO_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"; then
    error "Failed to set the GitHub token for authentication. Make sure you have push access and that the GitHub Token is valid."
fi
group_end

# Ensure we're on the correct branch. If this fails, exit with an error.
group_start "Ensuring we are on branch ${BRANCH}"
if ! run git checkout "${BRANCH}"; then
    error "Failed to switch to branch ${BRANCH}. Make sure the branch exists and that you have permissions to access it."
fi
group_end

# Add remote upstream. If this fails, exit with an error.
group_start "Adding upstream repository ${UPSTREAM_REPO}"
if ! run git remote add upstream "https://github.com/${UPSTREAM_REPO}.git"; then
    error "Failed to add remote upstream repository ${UPSTREAM_REPO}. Make sure the repository format or URL is correct."
fi
group_end

# Fetch from upstream. If this fails, exit with an error.
group_start "Fetching changes from upstream repository ${UPSTREAM_REPO}"
if ! run git fetch upstream --depth=${FETCH_DEPTH}; then
    warning "Shallow fetch with depth ${FETCH_DEPTH} failed, falling back to fetching complete history."
    if ! run git fetch upstream; then
        error "Failed to fetch from upstream repository ${UPSTREAM_REPO}. Make sure you have permissions to access it."
    fi
fi
group_end

# Check if the latest commit SHA from upstream branch matches the one in the current branch.
group_start "Checking for changes to sync"
# if git rev-parse HEAD == git rev-parse upstream/${BRANCH}; then
if [[ $(run git rev-parse HEAD) == $(run git rev-parse upstream/${BRANCH}) ]]; then
    # No changes to sync.
    info "No changes detected. Branch ${BRANCH} is already up-to-date with upstream."
    echo "synced=false" >> $GITHUB_OUTPUT
    group_end
    exit 0
else
    info "Changes detected, proceeding with sync."
fi
group_end

# Reset branch to match the upstream branch. If this fails, exit with an error.
group_start "Resetting branch ${BRANCH} to match upstream repository ${UPSTREAM_REPO}"
if ! run git reset --hard upstream/${BRANCH}; then
    error "Failed to reset the branch ${BRANCH}. Make sure the branch ${BRANCH} exists in the upstream repository ${UPSTREAM_REPO}."
fi
group_end

# Push to the forked repository. If this fails, exit with an error.
group_start "Pushing changes to forked repository ${GITHUB_REPOSITORY}"
if ! run git push origin ${BRANCH} --force; then
    error "Failed to push changes. Make sure you have push access and ensure that your inputs correctly set and valid."
fi
group_end

# Set the output variable to true to indicate that the branch was synced, then terminate.
echo "synced=true" >> $GITHUB_OUTPUT
info "Branch ${BRANCH} successfully synced with upstream repository ${UPSTREAM_REPO}."
exit 0
