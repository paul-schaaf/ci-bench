#!/bin/bash
set -euo pipefail

# CI Timing Analyzer - Track GitHub Actions job/step durations across PR runs

usage() {
    cat <<EOF
Usage: $(basename "$0") --repo <owner/repo> --pr <number> [options]

Analyze GitHub Actions CI runtimes across multiple PR runs to track
how code changes affect specific job/step durations over time.

Required:
    --repo <owner/repo>    GitHub repository (e.g., facebook/react)
    --pr <number>          Pull request number

Options:
    -i, --interactive      Interactive mode (prompt for workflow/job/step)
    --workflow <name>      Workflow name (e.g., "CI")
    --job <name>           Job name (e.g., "test-ubuntu-latest")
    --step <name>          Step name, or "total" for total job time
    -h, --help             Show this help message

Examples:
    $(basename "$0") --repo redis/redis --pr 1234 -i
    $(basename "$0") --repo redis/redis --pr 1234 --workflow "CI" --job "build" --step "make"
    $(basename "$0") --repo redis/redis --pr 1234 --workflow "CI" --job "build" --step total
EOF
    exit 0
}

error() {
    echo "Error: $1" >&2
    exit 1
}

format_duration() {
    local seconds=$1
    if [[ $seconds -ge 60 ]]; then
        local mins=$((seconds / 60))
        local secs=$((seconds % 60))
        echo "${mins}m ${secs}s"
    else
        echo "${seconds}s"
    fi
}

# Parse arguments
REPO=""
PR=""
INTERACTIVE=""
ARG_WORKFLOW=""
ARG_JOB=""
ARG_STEP=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --repo)
            REPO="$2"
            shift 2
            ;;
        --pr)
            PR="$2"
            shift 2
            ;;
        -i|--interactive)
            INTERACTIVE="1"
            shift
            ;;
        --workflow)
            ARG_WORKFLOW="$2"
            shift 2
            ;;
        --job)
            ARG_JOB="$2"
            shift 2
            ;;
        --step)
            ARG_STEP="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            error "Unknown option: $1"
            ;;
    esac
done

# Validate arguments
[[ -z "$REPO" ]] && error "Missing required argument: --repo"
[[ -z "$PR" ]] && error "Missing required argument: --pr"
[[ ! "$REPO" =~ ^[^/]+/[^/]+$ ]] && error "Invalid repo format. Expected: owner/repo"
[[ ! "$PR" =~ ^[0-9]+$ ]] && error "PR must be a number"

# Determine mode: interactive if -i flag or if workflow/job/step not all provided
if [[ -n "$INTERACTIVE" ]]; then
    MODE="interactive"
elif [[ -n "$ARG_WORKFLOW" && -n "$ARG_JOB" && -n "$ARG_STEP" ]]; then
    MODE="args"
else
    # Default to interactive if not all args provided
    MODE="interactive"
fi

# Check for required tools
command -v gh >/dev/null 2>&1 || error "GitHub CLI (gh) is required but not installed"
command -v jq >/dev/null 2>&1 || error "jq is required but not installed"

# Check GitHub authentication
echo "Checking GitHub authentication..."
if ! gh auth status >/dev/null 2>&1; then
    echo "Not logged in to GitHub. Starting login..."
    gh auth login
fi

echo "Fetching PR #$PR details..."

# Get PR head branch to filter workflow runs efficiently
PR_DATA=$(gh api "/repos/$REPO/pulls/$PR")
HEAD_BRANCH=$(echo "$PR_DATA" | jq -r '.head.ref')
HEAD_SHA=$(echo "$PR_DATA" | jq -r '.head.sha')

echo "PR branch: $HEAD_BRANCH"
echo "Fetching workflow runs..."

# Fetch workflow runs filtered by branch (much faster than fetching all)
ALL_RUNS_JSON=$(gh api "/repos/$REPO/actions/runs?branch=$HEAD_BRANCH&per_page=100" | \
    jq '[.workflow_runs] | add')

if [[ $(echo "$ALL_RUNS_JSON" | jq 'length') -eq 0 ]]; then
    error "No workflow runs found for PR #$PR"
fi

# Get unique workflow names
WORKFLOW_NAMES=$(echo "$ALL_RUNS_JSON" | jq '[.[].name] | unique | sort')
WORKFLOW_COUNT=$(echo "$WORKFLOW_NAMES" | jq 'length')

# Workflow selection
if [[ "$MODE" == "interactive" ]]; then
    echo ""
    echo "Available workflows:"
    echo "--------------------"
    for i in $(seq 0 $((WORKFLOW_COUNT - 1))); do
        WF_NAME=$(echo "$WORKFLOW_NAMES" | jq -r ".[$i]")
        WF_RUN_COUNT=$(echo "$ALL_RUNS_JSON" | jq --arg name "$WF_NAME" '[.[] | select(.name == $name)] | length')
        echo "  $((i + 1)). $WF_NAME ($WF_RUN_COUNT runs)"
    done
    echo ""

    read -p "Select a workflow (1-$WORKFLOW_COUNT): " WF_SELECTION
    [[ ! "$WF_SELECTION" =~ ^[0-9]+$ ]] && error "Invalid selection"
    [[ "$WF_SELECTION" -lt 1 || "$WF_SELECTION" -gt "$WORKFLOW_COUNT" ]] && error "Selection out of range"

    SELECTED_WORKFLOW=$(echo "$WORKFLOW_NAMES" | jq -r ".[$(($WF_SELECTION - 1))]")
    echo "Selected workflow: $SELECTED_WORKFLOW"
else
    # Validate workflow exists
    SELECTED_WORKFLOW="$ARG_WORKFLOW"
    if ! echo "$WORKFLOW_NAMES" | jq -e --arg name "$SELECTED_WORKFLOW" 'index($name) != null' >/dev/null; then
        echo "Available workflows: $(echo "$WORKFLOW_NAMES" | jq -r 'join(", ")')"
        error "Workflow not found: $SELECTED_WORKFLOW"
    fi
fi

# Filter runs by selected workflow
RUNS_JSON=$(echo "$ALL_RUNS_JSON" | jq --arg name "$SELECTED_WORKFLOW" \
    '[.[] | select(.name == $name)] | sort_by(.run_number)')

RUN_COUNT=$(echo "$RUNS_JSON" | jq 'length')
echo "Found $RUN_COUNT run(s) for workflow '$SELECTED_WORKFLOW'"

# Get first and latest run IDs
FIRST_RUN_ID=$(echo "$RUNS_JSON" | jq -r 'first.id')
LATEST_RUN_ID=$(echo "$RUNS_JSON" | jq -r 'last.id')

# Fetch jobs from first and latest runs
echo "Fetching job information..."
FIRST_JOBS=$(gh api "/repos/$REPO/actions/runs/$FIRST_RUN_ID/jobs" | jq '.jobs')
LATEST_JOBS=$(gh api "/repos/$REPO/actions/runs/$LATEST_RUN_ID/jobs" | jq '.jobs')

# Merge and deduplicate job names
JOB_NAMES=$(echo "$FIRST_JOBS $LATEST_JOBS" | jq -s 'add | [.[].name] | unique | sort')
JOB_COUNT=$(echo "$JOB_NAMES" | jq 'length')

if [[ "$JOB_COUNT" -eq 0 ]]; then
    error "No jobs found in workflow runs"
fi

# Job selection
if [[ "$MODE" == "interactive" ]]; then
    echo ""
    echo "Available jobs:"
    echo "---------------"
    for i in $(seq 0 $((JOB_COUNT - 1))); do
        JOB_NAME=$(echo "$JOB_NAMES" | jq -r ".[$i]")
        echo "  $((i + 1)). $JOB_NAME"
    done
    echo ""

    read -p "Select a job (1-$JOB_COUNT): " JOB_SELECTION
    [[ ! "$JOB_SELECTION" =~ ^[0-9]+$ ]] && error "Invalid selection"
    [[ "$JOB_SELECTION" -lt 1 || "$JOB_SELECTION" -gt "$JOB_COUNT" ]] && error "Selection out of range"

    SELECTED_JOB=$(echo "$JOB_NAMES" | jq -r ".[$(($JOB_SELECTION - 1))]")
    echo "Selected job: $SELECTED_JOB"
else
    # Validate job exists
    SELECTED_JOB="$ARG_JOB"
    if ! echo "$JOB_NAMES" | jq -e --arg name "$SELECTED_JOB" 'index($name) != null' >/dev/null; then
        echo "Available jobs: $(echo "$JOB_NAMES" | jq -r 'join(", ")')"
        error "Job not found: $SELECTED_JOB"
    fi
fi

# Get steps from selected job (from first and latest runs), filtering out GitHub internal steps
get_steps_for_job() {
    local jobs_json="$1"
    local job_name="$2"
    echo "$jobs_json" | jq -r --arg name "$job_name" \
        '[.[] | select(.name == $name) | .steps[].name] | unique | map(select(
            . != "Set up job" and
            . != "Complete job" and
            (startswith("Post ") | not) and
            (startswith("Run actions/") | not)
        ))'
}

FIRST_STEPS=$(get_steps_for_job "$FIRST_JOBS" "$SELECTED_JOB")
LATEST_STEPS=$(get_steps_for_job "$LATEST_JOBS" "$SELECTED_JOB")

# Merge and deduplicate step names
STEP_NAMES=$(echo "$FIRST_STEPS $LATEST_STEPS" | jq -s 'add | unique | sort')
STEP_COUNT=$(echo "$STEP_NAMES" | jq 'length')

# Step selection
if [[ "$MODE" == "interactive" ]]; then
    echo ""
    echo "Available steps:"
    echo "----------------"
    echo "  1. [Total job time]"
    for i in $(seq 0 $((STEP_COUNT - 1))); do
        STEP_NAME=$(echo "$STEP_NAMES" | jq -r ".[$i]")
        echo "  $((i + 2)). $STEP_NAME"
    done
    echo ""

    TOTAL_OPTIONS=$((STEP_COUNT + 1))
    read -p "Select a step (1-$TOTAL_OPTIONS): " STEP_SELECTION
    [[ ! "$STEP_SELECTION" =~ ^[0-9]+$ ]] && error "Invalid selection"
    [[ "$STEP_SELECTION" -lt 1 || "$STEP_SELECTION" -gt "$TOTAL_OPTIONS" ]] && error "Selection out of range"

    if [[ "$STEP_SELECTION" -eq 1 ]]; then
        SELECTED_STEP="__TOTAL__"
        echo "Selected: Total job time"
    else
        SELECTED_STEP=$(echo "$STEP_NAMES" | jq -r ".[$(($STEP_SELECTION - 2))]")
        echo "Selected step: $SELECTED_STEP"
    fi
else
    # Handle "total" keyword or validate step exists
    if [[ "$ARG_STEP" == "total" ]]; then
        SELECTED_STEP="__TOTAL__"
    else
        SELECTED_STEP="$ARG_STEP"
        if ! echo "$STEP_NAMES" | jq -e --arg name "$SELECTED_STEP" 'index($name) != null' >/dev/null; then
            echo "Available steps: total, $(echo "$STEP_NAMES" | jq -r 'join(", ")')"
            error "Step not found: $SELECTED_STEP"
        fi
    fi
fi

# Collect timing data for all runs
echo ""
echo "Collecting timing data..."
echo ""

# Print header
if [[ "$SELECTED_STEP" == "__TOTAL__" ]]; then
    printf "Job: \"%s\" / Total time\n" "$SELECTED_JOB"
else
    printf "Job: \"%s\" / Step: \"%s\"\n" "$SELECTED_JOB" "$SELECTED_STEP"
fi
printf "PR #%s - %s runs analyzed\n\n" "$PR" "$RUN_COUNT"
printf "%-10s %-9s %-12s %-10s %-10s %s\n" "Run" "Commit" "Date" "Duration" "Delta" "Message"
printf "%s\n" "────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────"

PREV_DURATION=""

# Process each run
echo "$RUNS_JSON" | jq -c '.[]' | while read -r run; do
    RUN_ID=$(echo "$run" | jq -r '.id')
    RUN_NUMBER=$(echo "$run" | jq -r '.run_number')
    COMMIT_SHA=$(echo "$run" | jq -r '.head_sha' | cut -c1-7)
    RUN_DATE=$(echo "$run" | jq -r '.created_at' | cut -d'T' -f1)
    COMMIT_MSG=$(echo "$run" | jq -r '.head_commit.message // ""' | head -1 | cut -c1-80)

    # Fetch jobs for this run
    JOBS_DATA=$(gh api "/repos/$REPO/actions/runs/$RUN_ID/jobs" 2>/dev/null || echo '{"jobs":[]}')

    # Find timing data (either job total or specific step)
    if [[ "$SELECTED_STEP" == "__TOTAL__" ]]; then
        # Get job start/end times
        TIMING_DATA=$(echo "$JOBS_DATA" | jq -r --arg job "$SELECTED_JOB" \
            '.jobs[] | select(.name == $job) | {started_at, completed_at}')
    else
        # Get specific step timing
        TIMING_DATA=$(echo "$JOBS_DATA" | jq -r --arg job "$SELECTED_JOB" --arg step "$SELECTED_STEP" \
            '.jobs[] | select(.name == $job) | .steps[] | select(.name == $step) | {started_at, completed_at}')
    fi

    if [[ -z "$TIMING_DATA" || "$TIMING_DATA" == "null" ]]; then
        printf "%-10s %-9s %-12s %-10s %-10s %s\n" "#$RUN_NUMBER" "$COMMIT_SHA" "$RUN_DATE" "N/A" "-" "$COMMIT_MSG"
        continue
    fi

    STARTED_AT=$(echo "$TIMING_DATA" | jq -r '.started_at')
    COMPLETED_AT=$(echo "$TIMING_DATA" | jq -r '.completed_at')

    if [[ "$STARTED_AT" == "null" || "$COMPLETED_AT" == "null" ]]; then
        printf "%-10s %-9s %-12s %-10s %-10s %s\n" "#$RUN_NUMBER" "$COMMIT_SHA" "$RUN_DATE" "N/A" "-" "$COMMIT_MSG"
        continue
    fi

    # Calculate duration in seconds
    START_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$STARTED_AT" "+%s" 2>/dev/null || \
                  date -d "$STARTED_AT" "+%s" 2>/dev/null)
    END_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$COMPLETED_AT" "+%s" 2>/dev/null || \
                date -d "$COMPLETED_AT" "+%s" 2>/dev/null)

    DURATION=$((END_EPOCH - START_EPOCH))
    DURATION_STR=$(format_duration $DURATION)

    # Calculate delta from previous
    if [[ -f /tmp/ci-bench-prev-$$ ]]; then
        PREV_DURATION=$(cat /tmp/ci-bench-prev-$$)
        DELTA=$((DURATION - PREV_DURATION))
        if [[ $DELTA -gt 0 ]]; then
            DELTA_STR="+$(format_duration $DELTA)"
        elif [[ $DELTA -lt 0 ]]; then
            DELTA_STR="-$(format_duration ${DELTA#-})"
        else
            DELTA_STR="0s"
        fi
    else
        DELTA_STR="-"
    fi

    echo "$DURATION" > /tmp/ci-bench-prev-$$

    printf "%-10s %-9s %-12s %-10s %-10s %s\n" "#$RUN_NUMBER" "$COMMIT_SHA" "$RUN_DATE" "$DURATION_STR" "$DELTA_STR" "$COMMIT_MSG"
done

# Cleanup
rm -f /tmp/ci-bench-prev-$$

echo ""
