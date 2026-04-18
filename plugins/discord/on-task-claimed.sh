#!/usr/bin/env bash
# Discord plugin — task-claimed hook. Delegates to _post.sh.
exec "$(dirname "$0")/_post.sh" task_claimed
