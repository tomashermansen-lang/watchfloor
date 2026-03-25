---
description: Cleaner — remove temporary and generated files safely
argument-hint: [dry-run | public]
disable-model-invocation: true
---

# Cleaner: $ARGUMENTS

Remove unnecessary files from the repository. NEVER delete source code, tests, docs, or config.

**If argument is `public`:** skip to the [Public Release](#public-release) section below.

---

## Safe to Remove

```
__pycache__/          # Python bytecode
*.pyc                 # Compiled Python
.pytest_cache/        # Pytest cache
.mypy_cache/          # Mypy cache
.coverage             # Coverage data
htmlcov/              # Coverage HTML reports
*.egg-info/           # Python package metadata
dist/                 # Build artifacts
build/                # Build artifacts
.DS_Store             # macOS metadata
*.log                 # Log files
```

## NEVER Remove

- `src/` — source code
- `tests/` — test files
- `docs/` — documentation
- `data/` — corpora, evals, processed data
- `config/` — configuration
- `.claude/` — Claude commands and skills
- `ui_react/` — frontend and backend code
- `*.md` — documentation files
- `.git/` — version control
- `.venv/` — virtual environment (user manages this)
- `node_modules/` — npm deps (reinstall is slow)

## Workflow

1. **Dry-run by default.** Show what WOULD be removed without deleting.

2. **List candidates:**
   ```bash
   find . -type d -name "__pycache__" -not -path "./.venv/*"
   find . -type d -name ".pytest_cache" -not -path "./.venv/*"
   find . -type d -name ".mypy_cache" -not -path "./.venv/*"
   find . -type d -name "*.egg-info" -not -path "./.venv/*"
   find . -type d -name "htmlcov" -not -path "./.venv/*"
   find . -type f -name "*.pyc" -not -path "./.venv/*"
   find . -type f -name ".coverage" -not -path "./.venv/*"
   find . -type f -name ".DS_Store"
   ```

3. **Show summary:**
   ```
   Found X items to clean:
   - 12 __pycache__ directories
   - 3 .pyc files
   - 1 .pytest_cache
   - 5 .DS_Store files

   Total: ~X MB
   ```

4. **Ask for confirmation.** `[clean / stop]`

5. **If confirmed, remove:**
   ```bash
   find . -type d -name "__pycache__" -not -path "./.venv/*" -exec rm -rf {} + 2>/dev/null
   # ... etc for each type
   ```

6. **Report results.** Show what was removed and space freed.

## Rules

- ALWAYS dry-run first — show before delete
- NEVER touch .venv/ — user manages virtual environment
- NEVER touch node_modules/ — reinstall takes too long
- NEVER delete without explicit user confirmation
- If unsure about a file type: ASK, don't delete

---

## Public Release

Prepare a sanitized copy of the repo for public distribution (no commit history, no secrets).

### Output

`../RAG-framework-public/` — a clean directory with a fresh git repo and one initial commit.

### Step 1: Copy codebase (exclude large/sensitive artifacts)

```bash
DEST="../RAG-framework-public"

# Safety check: warn if destination already exists
if [ -d "$DEST" ]; then
  echo "WARNING: $DEST already exists and will be deleted!"
  echo "Contents: $(find "$DEST" -type f | wc -l | tr -d ' ') files, $(du -sh "$DEST" | cut -f1)"
fi
# Ask for confirmation BEFORE deleting (handled by Claude confirmation checkpoint)

rm -rf "$DEST"
mkdir -p "$DEST"

rsync -a --progress \
  --exclude='.git/' \
  --exclude='.venv/' \
  --exclude='.env*' \
  --exclude='node_modules/' \
  --exclude='.claude/' \
  --exclude='CLAUDE.md' \
  --exclude='data/vector_store/' \
  --exclude='data/processed/enrichment_cache/' \
  --exclude='data/processed/backup/' \
  --exclude='data/evals/runs/' \
  --exclude='runs/' \
  --exclude='__pycache__/' \
  --exclude='.pytest_cache/' \
  --exclude='.mypy_cache/' \
  --exclude='*.pyc' \
  --exclude='.DS_Store' \
  --exclude='htmlcov/' \
  --exclude='.coverage' \
  --exclude='linkedin_drafts*' \
  --exclude='phone_pitch*' \
  --exclude='data/processed/vector_store/' \
  --exclude='data/vectorstore/' \
  --exclude='docs/PRODUCT_REVIEW.md' \
  --exclude='docs/PENDING_Feature_*' \
  --exclude='docs/DONE_Feature_*' \
  --exclude='docs/INPROGRESS_Feature_*' \
  --exclude='docs/INPROGRESS_Plan_*' \
  --exclude='setup-commands.sh' \
  --exclude='*.tsbuildinfo' \
  --exclude='vite.config.d.ts' \
  --exclude='.vscode/' \
  ./ "$DEST/"
```

### Step 2: Sanitize local paths and .gitignore

Strip absolute filesystem paths that leak username/machine info:

```bash
# Fix source_path in chunk metadata files (replaces /Users/.../data/raw/ → data/raw/)
find "$DEST/data/processed" -name "*_chunks.jsonl" -exec \
  sed -i '' 's|/Users/[^"]*/data/raw/|data/raw/|g' {} +

# Fix absolute path in COMMANDS.md
sed -i '' 's|/Users/[^)]*)|./)|g' "$DEST/COMMANDS.md"
```

Strip private-workflow entries from `.gitignore` (patterns that only exist in the private repo):

```bash
# Remove private-workflow lines from .gitignore
sed -i '' '/linkedin_drafts/d; /phone_pitch/d' "$DEST/.gitignore"
sed -i '' '/PLAN_\*\.md/d; /IMPLEMENTATION_PLAN\.md/d; /\*_PLAN\.md/d; /\*_IMPLEMENTATION_PLAN\.md/d' "$DEST/.gitignore"
sed -i '' '/INTERNAL_WALKTHROUGH/d' "$DEST/.gitignore"
sed -i '' '/archive\/legacy_eval/d' "$DEST/.gitignore"
sed -i '' '/ui\/\.streamlit/d; /ui\/\.cache/d; /ui\/exports/d; /ui\/output/d' "$DEST/.gitignore"
sed -i '' '/post_promo_evidence/d' "$DEST/.gitignore"
# Clean up empty comment-only sections (comment followed by blank line)
sed -i '' '/^# Personal drafts/d; /^# Plan files/d; /^# Implementation plans/d; /^# Archive artifacts/d; /^# Failure debug/d; /^# UI local artifacts/d; /^# Raw source documents/d' "$DEST/.gitignore"
```

### Step 3: Create `.env.example`

Write this file to `$DEST/.env.example`:
```
TOKENIZERS_PARALLELISM=false
OMP_NUM_THREADS=1
MKL_NUM_THREADS=1
VECLIB_MAXIMUM_THREADS=1
OPENBLAS_NUM_THREADS=1

# Get your key at https://platform.openai.com/api-keys
OPENAI_API_KEY=sk-your-key-here
```

### Step 4: Strip permissions from settings.json

Create `$DEST/.claude/` (excluded by rsync) and write a minimal `settings.json` with empty permissions (contributors add their own):
```bash
mkdir -p "$DEST/.claude"
```
```json
{
  "permissions": {
    "allow": []
  }
}
```

### Step 5: Initialize fresh git repo

```bash
cd "$DEST"
git init
git add -A
git commit -m "Initial release"
```

### Step 6: Report

Show summary:
```bash
echo "=== Public release ready ==="
echo "Location: $DEST"
echo "Files: $(find "$DEST" -type f | wc -l | tr -d ' ')"
echo "Size: $(du -sh "$DEST" | cut -f1)"
```

### Step 7: Create GitHub repo and push

Ask the user for confirmation: `[push / stop]`

If confirmed:
```bash
cd "$DEST"
gh repo create <repo-name> --public --description "<project description>" --source . --push
```

Report the URL:
```bash
gh repo view --web
```

### Public Release Rules

- ALWAYS show the rsync command and ask for confirmation before copying
- NEVER include `.env` with real API keys
- NEVER include commit history (no `.git/` in copy)
- Verify no secrets leaked: `grep -r "sk-proj-\|sk-ant-\|password" "$DEST/" --include="*.py" --include="*.json" --include="*.yaml" --include="*.env*" --include="*.md" --include="*.ts" --include="*.tsx" --include="*.html"`
- If secrets found: **STOP** and warn the user
