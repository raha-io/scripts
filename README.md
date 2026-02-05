# scripts

DevOps automation scripts for configuration and infrastructure management at Raha-io.

## Overview

This repository provides tools to streamline common DevOps tasks including repository management, team access control, and infrastructure automation.

## Usage

Run scripts via the entry point:

```bash
./start.sh <script-name> [OPTIONS]
```

List available scripts:

```bash
./start.sh list
```

## Available Scripts

| Script          | Description                                          |
| --------------- | ---------------------------------------------------- |
| `gh-push-repos` | Push local git repositories to a GitHub organization |
| `gh-team-sync`  | Sync GitHub team configuration from a JSON file      |

## Requirements

- Bash 4.0+
- Additional dependencies vary per script (installed automatically when possible)

## Library

The `scripts/lib/` directory contains a shared shell library (from [1995parham/dotfiles.lib](https://github.com/1995parham/dotfiles.lib)) providing utilities for messaging, package management, git operations, and more.
