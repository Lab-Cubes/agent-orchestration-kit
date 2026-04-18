#!/usr/bin/env bash
# Discord plugin — task-failed hook. Delegates to _post.sh.
exec "$(dirname "$0")/_post.sh" task_failed
