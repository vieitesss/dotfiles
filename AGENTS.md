# AGENTS.md

Guidance for agents working in this dotfiles repository.

## Repository purpose

This repository stores personal dotfiles and configuration directories. It
should stay simple, dependency-light, and easy to inspect.

## Installation model

- Configuration files are installed with symlinks.
- Config sources live at the repository root, for example:
  - `zsh/`
  - `git/`
  - `tmux/`
  - `kitty/`

## Manifest files

The repository should define two simple manifest files:

- one manifest for macOS machines
- one manifest for Linux machines

Each manifest should list the symlinks to install using a simple line-based
format:

```text
source|destination
```

Example:

```text
zsh/.zshrc|~/.zshrc
git/.gitconfig|~/.gitconfig
tmux/.tmux.conf|~/.tmux.conf
kitty|~/.config/kitty
```

Manifest rules:

- Blank lines are ignored.
- Lines starting with `#` are ignored.
- The source path is relative to the repository root.
- The destination path is the target path on the machine.
- `~` in destinations means the user's home directory.
- Sources may be files or directories.

## Install script expectations

The install script should:

1. Detect the operating system.
   - `Darwin` means macOS.
   - `Linux` means Linux.
2. Select the matching manifest automatically.
3. For each manifest entry:
   - resolve the source relative to the repository root
   - expand the destination path
   - create the destination parent directory if needed
   - if the destination already exists as a file, directory, or symlink, warn the user and leave it unchanged
   - create the symlink only when the destination does not already exist
4. Print clear actions as it runs.

## Development guidelines

- Keep scripts POSIX-shell friendly where practical.
- Avoid external dependencies unless explicitly requested.
- Prefer small, readable code over clever abstractions.
- Preserve existing config directory names and root-level layout.
- When adding new managed configs, add them to the appropriate OS manifest instead of moving them under another directory.
