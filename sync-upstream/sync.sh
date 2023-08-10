#!/usr/bin/env bash

# Enable script debugging.
# set -x

# Check if current directory is a valid git repository.
if [ ! -d ".git" ] || ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    echo "::error::The current directory doesn't appear to be a valid Git repository, the 'git' command is unavailable or an unexpected error occurred. Ensure that the 'checkout' action has run successfully before executing this action."
    exit 1
fi

# Validate that we have GITHUB_REPOSITORY set.
if [ -z "$GITHUB_REPOSITORY" ]; then
    echo "::error::GITHUB_REPOSITORY is not set. Something went wrong."
    exit 1
fi

# If no branch is provided as an argument, use the current branch.
BRANCH=${1:-$(git rev-parse --abbrev-ref HEAD)}
if [ -z "$BRANCH" ]; then
    echo "::error::Branch name is invalid or not set. Please provide a valid branch name to sync."
    exit 1
fi

# Get the upstream repository in GitHub format.
UPSTREAM_REPO=${2}
if [ -z "$UPSTREAM_REPO" ]; then
    echo "::error::Upstream repository is invalid or not set. Please provide a valid upstream repository in the GitHub format of 'owner/repo'."
    exit 1
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
        echo "::error::${BRANCH} is a protected branch and cannot be synced!"
        exit 1
    fi
done

# Get the GitHub Token from the input.
REPO_TOKEN=${4}
if [ -z "$REPO_TOKEN" ]; then
    echo "::error::GitHub Token is invalid or not set. Please provide a valid GitHub Token with the 'repo' scope."
    exit 1
fi

# Set up Git credentials
echo "::group::Setting up git credentials"
if ! git config --global user.email "actions@github.com"; then
    echo "::error::Failed to configure git user email."
    exit 1
fi
if ! git config --global user.name "GitHub Actions"; then
    echo "::error::Failed to configure git user name."
    exit 1
fi
echo "::endgroup::"

# Set the GitHub token for authentication
echo "::group::Setting up GitHub Token for repository ${GITHUB_REPOSITORY}"
if ! git remote set-url origin "https://x-access-token:${REPO_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"; then
    echo "::error::Failed to set the GitHub token for authentication. Make sure you have push access and that the GitHub Token is valid."
    exit 1
fi
echo "::endgroup::"

# Ensure we're on the correct branch. If this fails, exit with an error.
echo "::group::Ensuring we are on branch ${BRANCH}"
if ! git checkout "${BRANCH}"; then
    echo "::error::Failed to switch to branch ${BRANCH}. Make sure the branch exists and that you have permissions to access it."
    exit 1
fi
echo "::endgroup::"

# Add remote upstream. If this fails, exit with an error.
echo "::group::Adding upstream repository ${UPSTREAM_REPO}"
if ! git remote add upstream "https://github.com/${UPSTREAM_REPO}.git"; then
    echo "::error::Failed to add remote upstream repository ${UPSTREAM_REPO}. Make sure the repository format or URL is correct."
    exit 1
fi
echo "::endgroup::"

# Fetch from upstream. If this fails, exit with an error.
echo "::group::Fetching changes from upstream repository ${UPSTREAM_REPO}"
if ! git fetch upstream; then
    echo "::error::Failed to fetch from upstream repository ${UPSTREAM_REPO}. Make sure you have permissions to access it."
    exit 1
fi
echo "::endgroup::"

# Check if the latest commit SHA from upstream branch matches the one in the current branch.
echo "::group::Checking for changes to sync"
# if git rev-parse HEAD == git rev-parse upstream/${BRANCH}; then
if [[ $(git rev-parse HEAD) == $(git rev-parse upstream/${BRANCH}) ]]; then
    # No changes to sync.
    echo "::info::No changes detected. Branch ${BRANCH} is already up-to-date with upstream."
    echo "synced=false" >> $GITHUB_OUTPUT
    echo "::endgroup::"
    exit 0
else
    echo "::info::Changes detected, proceeding with sync."
fi
echo "::endgroup::"

# Reset branch to match the upstream branch. If this fails, exit with an error.
echo "::group::Resetting branch ${BRANCH} to match upstream repository ${UPSTREAM_REPO}"
if ! git reset --hard upstream/${BRANCH}; then
    echo "::error::Failed to reset the branch ${BRANCH}. Make sure the branch ${BRANCH} exists in the upstream repository ${UPSTREAM_REPO}."
    exit 1
fi
echo "::endgroup::"

# Push to the forked repository. If this fails, exit with an error.
echo "::group::Pushing changes to forked repository ${GITHUB_REPOSITORY}"
if ! git push origin ${BRANCH} --force; then
    echo "::error::Failed to push changes. Make sure you have push access and ensure that your inputs correctly set and valid."
    exit 1
fi
echo "::endgroup::"

# Set the output variable to true to indicate that the branch was synced, then terminate.
echo "synced=true" >> $GITHUB_OUTPUT
echo "::info::Branch ${BRANCH} successfully synced with upstream repository ${UPSTREAM_REPO}."
exit 0
