# team5-ewaste-platform
DevSecOps-enabled e-waste collection, recycling traceability, and environmental impact platform.

---

## Code Quality & Pre-Commit Hooks

This repository uses [pre-commit](https://pre-commit.com/) to automatically check code formatting, syntax correctness, and security policies on every `git commit`.

For detailed setup, installation commands, and usage guidelines, please see the [Pre-Commit Setup & Usage Guide](PRECOMMIT.md).

### Quick Start
```bash
# 1. Install pre-commit
pip install pre-commit

# 2. Install git hooks into .git/hooks/
pre-commit install

# 3. Test hooks on all files
pre-commit run --all-files
```
