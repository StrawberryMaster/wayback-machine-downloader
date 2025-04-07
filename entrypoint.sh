#!/bin/bash

if [ "$ENVIRONMENT" == "development" ]; then
  echo "Running in development mode. Starting rerun..."
  exec rerun --dir /build --ignore "websites/*" -- /build/bin/wayback_machine_downloader "$@"
else
  echo "Not in development mode. Skipping rerun."
  exec /build/bin/wayback_machine_downloader "$@"
fi