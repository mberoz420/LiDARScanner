# Claude Code Instructions

## On Every New Session Start

**IMMEDIATELY** read these files before doing anything else:

1. `C:\Users\mbero\Documents\Claude Interaction\session_log.md` — what happened last session, where to continue from
2. `C:\Users\mbero\Documents\Claude Interaction\task_tracker.md` — active and pending tasks
3. `C:\Users\mbero\Documents\Claude Interaction\important_locations.md` — key paths, URLs, credentials

Summarize the continuation point to the user so they know you're caught up.

## During Every Session

- Update `C:\Users\mbero\Documents\Claude Interaction\session_log.md` after completing major tasks
- Update `C:\Users\mbero\Documents\Claude Interaction\task_tracker.md` when tasks change status
- Log architectural decisions to `C:\Users\mbero\Documents\Claude Interaction\decisions_log.md`
- Update `C:\Users\mbero\Documents\Claude Interaction\eva_status.md` when Eva changes

## After Code Changes

1. Update `Default responsibilities.md` if file responsibilities changed
2. Copy PointCloudLabeler.html to both `tools/` and `tools/upload_to_server/`
3. Commit to git with descriptive message
4. Push to origin master (auto-triggers Codemagic build for Swift changes)
5. Don't trigger builds for server-only changes (no Swift file changes)

## Project Reference

- See `Default responsibilities.md` for full architecture
- User: Masud Beroz (mberoz61@gmail.com)
- Eva AI: central brain at scanwizard.robo-wizard.com/api/eva.php
- Ollama: localhost:11434 (Llama 3.1 8B)
