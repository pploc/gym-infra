#!/bin/sh
set -eu

printf '%s\n' 'G10 business fixture is unavailable until final digest lock is explicitly authorized.' >&2
exit 1
