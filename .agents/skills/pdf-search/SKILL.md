---
name: pdf-search
description: Search indexed PDF documents with sova. Use when looking up information in a local reference library.
allowed-tools: AskUserQuestion, Bash, Read
---

# PDF Search Skill (sova)

Use `sova` to search indexed PDF projects.

## When to Use

- Looking up details in reference PDFs.
- Finding relevant sections across multiple documents.
- Verifying facts and quotes from source material.

## Quick Start

```bash
# First-time setup
uv run sova-install

# Register + index a docs folder
sova index /path/to/pdfs

# Show project ids
sova projects

# Search (default mode)
sova <project-id> "your search query"
```

## Common Commands

```bash
# Help
sova help

# Search
sova <project-id> "query"
sova <project-id> "query" -n 20

# Status / indexing
sova list <project-id>
sova index <project-id>
sova index /path/to/pdfs

# Reset / remove project
sova remove <project-id>
sova remove <project-id> --keep-data
```

## Notes

- There is no default project; always pass `<project-id>`.
- Search output includes `path:start-end` and chunk text.
- Use `Read` with a line buffer around returned ranges for extra context.

## Known Project

```bash
sova list operating-system-documents
```

Expected current status:

- `project: operating-system-documents`
- `docs: ~/Developer/operating-system-documents`
- `indexed: 11/11`

## Troubleshooting

```bash
# Reinstall runtime/services
uv run sova-remove
uv run sova-install

# Full cleanup including ~/.sova
uv run sova-remove --purge-data
```
