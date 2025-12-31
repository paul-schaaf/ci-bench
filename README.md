# ci-bench

A CLI tool to analyze GitHub Actions CI runtimes across PR runs. Track how code changes affect specific job/step durations over time.

## Installation

```bash
# Clone the repo
git clone https://github.com/YOUR_USERNAME/ci-bench.git

# Make executable (already set)
chmod +x ci-bench.sh
```

### Dependencies

- [GitHub CLI](https://cli.github.com/) (`gh`)
- [jq](https://jqlang.github.io/jq/)

```bash
# macOS
brew install gh jq

# Ubuntu/Debian
sudo apt install gh jq
```

## Usage

### Interactive mode

```bash
./ci-bench.sh --repo owner/repo --pr 1234 -i
```

Prompts you to select:
1. Workflow (e.g., "CI", "Tests")
2. Job (e.g., "build", "test-ubuntu-latest")
3. Step (e.g., "make", "Run tests") or total job time

### Direct arguments

```bash
# Specific step
./ci-bench.sh --repo redis/redis --pr 1234 --workflow "CI" --job "build" --step "make"

# Total job time
./ci-bench.sh --repo redis/redis --pr 1234 --workflow "CI" --job "build" --step total
```

## Example output

```
Job: "test-ubuntu-latest" / Step: "test"
PR #14635 - 3 runs analyzed

Run        Commit    Date         Duration   Delta      Message
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
#19398     d7def50   2025-12-20   12m 11s    -          rdb: pre-size hash dicts using original length on load
#19512     a3b4c5d   2025-12-21   11m 45s    -26s       Optimize memory allocation
#19687     e6f7g8h   2025-12-22   10m 30s    -1m 15s    Further performance improvements
```

## Options

| Option | Description |
|--------|-------------|
| `--repo <owner/repo>` | GitHub repository (required) |
| `--pr <number>` | Pull request number (required) |
| `-i, --interactive` | Interactive mode |
| `--workflow <name>` | Workflow name |
| `--job <name>` | Job name |
| `--step <name>` | Step name, or `total` for total job time |
| `-h, --help` | Show help |

## License

MIT
