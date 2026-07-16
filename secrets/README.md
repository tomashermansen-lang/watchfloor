# secrets/

Operator-local copies of API keys used by dotfiles tooling. **Files matching
`*.env` are gitignored** — never commit a real key. `*.env.example` files are
tracked templates.

## Setup

After cloning the repo on a new machine:

```bash
cp secrets/openai.env.example secrets/openai.env
# Edit secrets/openai.env and paste in your real key
```

## Files

| File | Purpose | Tracked |
|---|---|---|
| `openai.env.example` | Template showing the variable name | yes |
| `openai.env` | Your real OpenAI API key — used by `sync.sh diff --explain` | **no** |
| `README.md` | This file | yes |

## Why a file in the repo (and not `~/.config/...`)?

Single source of truth: the dotfiles repo is where all dotfiles tooling lives,
so all dependencies — including secret references — are co-located. The
`*.env` ignore rule is enforced by both Git and review.

If you accidentally commit a key, rotate it immediately at the provider's
dashboard. `git rm --cached` is not enough — keys remain in history.
