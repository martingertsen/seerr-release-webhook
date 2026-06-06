#!/usr/bin/env bash
set -euo pipefail

DELETE_BACKUP=false
MEDIA_ROOTS=(
  "/mnt/nas/Media/Movies"
  "/mnt/nas/Media/TV"
)
LOG_FILE="/mnt/nas/Media/plex-subs-cleanup.log"

print_usage() {
  echo "Usage:"
  echo "  $0 scan [--skip N]"
  echo "  $0 dry-run [--limit N] [--skip N] [--path PATH]"
  echo "  $0 fix [--limit N] [--skip N] [--sample N] [--path PATH] [--delete-backup]"
  echo "  $0 restore [--limit N] [--path PATH]"
  echo "  $0 purge-backups [--limit N] [--path PATH]"
}

if [[ $# -eq 0 ]]; then
  print_usage
  exit 0
fi

MODE="$1"
shift

LIMIT=0
SKIP=0
TARGET_PATH=""
SAMPLE=0
REMUXED_FILES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --limit)
      LIMIT="$2"
      shift 2
      ;;
    --sample)
      SAMPLE="$2"
      shift 2
      ;;
    --skip)
      SKIP="$2"
      shift 2
      ;;
    --path)
      TARGET_PATH="$2"
      shift 2
      ;;
    --delete-backup)
      DELETE_BACKUP=true
      shift
      ;;
    *)
      echo "Unknown argument: $1"
	  echo
	  print_usage
      exit 1
      ;;
  esac
done

require_tools() {
  for tool in ffprobe mkvmerge jq numfmt; do
    command -v "$tool" >/dev/null 2>&1 || {
      echo "Missing required tool: $tool"
      exit 1
    }
  done
}

find_files() {
  if [[ -n "$TARGET_PATH" ]]; then
    if [[ -f "$TARGET_PATH" ]]; then
      printf '%s\n' "$TARGET_PATH"
    else
      find "$TARGET_PATH" -type f -iname "*.mkv"
    fi
  else
    for root in "${MEDIA_ROOTS[@]}"; do
      if [[ -d "$root" ]]; then
        find "$root" -type f -iname "*.mkv"
      fi
    done
  fi
}

get_problem_subtitle_tracks_json() {
  local file="$1"
  local json

  if ! json="$(mkvmerge -J "$file" 2>/dev/null)"; then
    echo "mkvmerge could not read file, skipping:" >&2
    echo "  $file" >&2
    return 1
  fi

  echo "$json" | jq -c '
    if (.tracks | type) != "array" then
      []
    else
      [
        .tracks[]
        | select(.type == "subtitles")
        | select(.codec | test("ASS|SSA|SubStation|HDMV PGS|VobSub"; "i"))
        | {
            id: .id,
            codec: .codec,
            language: (
              .properties.language_ietf //
              .properties.language //
              "und"
            ),
            default: (.properties.default_track // false),
            forced: (.properties.forced_track // false),
            name: (.properties.track_name // "")
          }
      ]
    end
  '
}

has_mpeg2_video() {
  local file="$1"

  mkvmerge -J "$file" | jq -e '
    any(.tracks[]; .type == "video" and (.codec | test("MPEG-1|MPEG-2|MPEG-1/2"; "i")))
  ' >/dev/null
}

find_backup_files() {
  if [[ -n "$TARGET_PATH" ]]; then
    if [[ -f "$TARGET_PATH" ]]; then
      if [[ "$TARGET_PATH" == *.mkv.before-subs-cleanup ]]; then
        printf '%s\n' "$TARGET_PATH"
      elif [[ -f "${TARGET_PATH}.before-subs-cleanup" ]]; then
        printf '%s\n' "${TARGET_PATH}.before-subs-cleanup"
      fi
    else
      find "$TARGET_PATH" -type f -name "*.mkv.before-subs-cleanup"
    fi
  else
    for root in "${MEDIA_ROOTS[@]}"; do
      if [[ -d "$root" ]]; then
        find "$root" -type f -name "*.mkv.before-subs-cleanup"
      fi
    done
  fi
}

print_sample_files() {
  if [[ "$SAMPLE" -le 0 ]]; then
    return 0
  fi

  local count="${#REMUXED_FILES[@]}"

  if [[ "$count" -eq 0 ]]; then
    echo
    echo "No remuxed files available for sampling."
    return 0
  fi

  echo
  echo "Random sample for validation:"

  printf '%s\n' "${REMUXED_FILES[@]}" \
    | shuf -n "$SAMPLE" \
    | sed 's/^/  /'
}

process_file() {
  local file="$1"
  local tracks_json
  if ! tracks_json="$(get_problem_subtitle_tracks_json "$file")"; then
    return 1
  fi

  local count
  count="$(echo "$tracks_json" | jq 'length')"

  if [[ "$count" -eq 0 ]]; then
    return 1
  fi

  if has_mpeg2_video "$file"; then
    if [[ "$MODE" != "scan" ]]; then
      echo
      echo "Skipping MPEG-1/2 video file:"
      echo "$file"
    fi
  
    return 1
  fi

  echo
  echo "$file"

  if [[ "$MODE" != "scan" ]]; then
    echo "$tracks_json" | jq -r '.[] | "  track_id=\(.id), lang=\(.language), default=\(.default), forced=\(.forced), codec=\(.codec), name=\(.name)"'
  fi
  
  if [[ "$MODE" == "scan" || "$MODE" == "dry-run" ]]; then
    return 0
  fi

  local dir base stem tmpdir out_tmp backup ids_csv
  dir="$(dirname "$file")"
  base="$(basename "$file")"
  stem="${base%.*}"
  tmpdir="${dir}/.subs-cleanup-tmp-${stem}"
  out_tmp="${tmpdir}/${base}"
  backup="${file}.before-subs-cleanup"

  if [[ -e "$backup" ]]; then
    echo "Backup already exists, refusing to process:"
    echo "  $backup"
    return 2
  fi

  mkdir -p "$tmpdir" || {
    echo "Failed to create temp directory, skipping:"
    echo "  $tmpdir"
    return 3
  }

  ids_csv="$(echo "$tracks_json" | jq -r 'map(.id | tostring) | join(",")')"

  local size_bytes size_human
  size_bytes="$(stat -c%s "$file")"
  size_human="$(numfmt --to=iec-i --suffix=B "$size_bytes")"

  echo "Remuxing without embedded subtitles, file size: $size_human"
  mkvmerge -o "$out_tmp" --subtitle-tracks "!${ids_csv}" "$file" || {
    echo "Remux failed:"
    echo "  $file"
    rm -rf "$tmpdir"
    return 4
  }

  if [[ ! -f "$out_tmp" ]]; then
    echo "Remux failed, output file was not created:"
    echo "  $out_tmp"
    rm -rf "$tmpdir"
    return 4
  fi

  echo "Validating output..."
  ffprobe -v error "$out_tmp" >/dev/null || {
    echo "Validation failed:"
    echo "  $out_tmp"
    rm -rf "$tmpdir"
    return 5
  }

  mv "$file" "$backup"
  mv "$out_tmp" "$file"

  chmod 777 "$file"

  if [[ "$DELETE_BACKUP" == "true" ]]; then
    rm -f "$backup"
    backup="[deleted]"
  fi

  printf '%s\t%s\tremoved_subtitle_track_ids=%s\tbackup=%s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" \
    "$file" \
    "$ids_csv" \
    "$backup" >> "$LOG_FILE"

  rm -rf "$tmpdir"

  echo "Done:"
  echo "  Removed embedded subtitle track IDs: $ids_csv"
  echo "  Original backup: $backup"
  echo "  Cleaned file:    $file"

  REMUXED_FILES+=("$file")
  
  return 0
}

restore_file() {
  local backup="$1"
  local file="${backup%.before-subs-cleanup}"

  if [[ ! -f "$backup" ]]; then
    return 1
  fi

  if [[ ! -f "$file" ]]; then
    echo "Matching cleaned file not found, skipping:"
    echo "  $file"
    return 1
  fi

  echo
  echo "Restoring:"
  echo "  Backup:  $backup"
  echo "  Current: $file"

  if [[ "$MODE" == "dry-run" ]]; then
    return 0
  fi

  rm "$file"
  mv "$backup" "$file"
  chmod 777 "$file"

  printf '%s\t%s\trestored_from=%s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" \
    "$file" \
    "$backup" >> "$LOG_FILE"

  echo "Done:"
  echo "  Restored file: $file"

  return 0
}

purge_backup_file() {
  local backup="$1"

  if [[ ! -f "$backup" ]]; then
    return 1
  fi

  echo
  echo "Deleting backup: $backup"

  rm "$backup"

  printf '%s\tpurged_backup=%s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" \
    "$backup" >> "$LOG_FILE"

  return 0
}

run_restore() {
  local restored=0
  local scanned_backups=0

  while IFS= read -r backup; do
    scanned_backups=$((scanned_backups + 1))
  if restore_file "$backup"; then
    restored=$((restored + 1))
  
    if [[ "$LIMIT" -gt 0 ]]; then
      echo "Restore progress: $restored of $LIMIT"
    fi
  
    if [[ "$LIMIT" -gt 0 && "$restored" -ge "$LIMIT" ]]; then
      break
    fi
  fi  
  done < <(find_backup_files)

  echo
  echo "Finished. Scanned $scanned_backups backup files, restored $restored files."
}

run_purge_backups() {
  local purged=0
  local scanned_backups=0

  while IFS= read -r backup; do
    scanned_backups=$((scanned_backups + 1))

    if purge_backup_file "$backup"; then
      purged=$((purged + 1))

      if [[ "$LIMIT" -gt 0 ]]; then
        echo "Purge progress: $purged of $LIMIT"
      fi

      if [[ "$LIMIT" -gt 0 && "$purged" -ge "$LIMIT" ]]; then
        break
      fi
    fi
  done < <(find_backup_files)

  echo
  echo "Finished. Scanned $scanned_backups backup files, purged $purged backups."
}

run_scan_or_fix() {
  local processed=0
  local scanned=0
  local skipped=0
  local start_time
  start_time="$(date +%s)"
  
  while IFS= read -r file; do
    scanned=$((scanned + 1))

    if [[ "$SKIP" -gt 0 && "$skipped" -lt "$SKIP" ]]; then
      skipped=$((skipped + 1))

      if (( skipped % 100 == 0 )); then
        echo "Skipped $skipped of $SKIP MKV files..."
      fi

      continue
    fi

    if (( scanned % 100 == 0 )); then
      echo "Scanned $scanned MKV files, found $processed with subtitles so far..."
    fi

    if process_file "$file"; then
      processed=$((processed + 1))

      if [[ "$LIMIT" -gt 0 ]]; then
        echo "Progress: $processed of $LIMIT"
      fi

      if [[ "$MODE" != "scan" && "$LIMIT" -gt 0 && "$processed" -ge "$LIMIT" ]]; then
        break
      fi
    fi
  done < <(find_files)

  if [[ "$MODE" == "fix" ]]; then
    print_sample_files
  fi

  local end_time elapsed
  end_time="$(date +%s)"
  elapsed=$((end_time - start_time))

  echo
  echo "Finished. Skipped $skipped MKV files, scanned $scanned MKV files, found $processed with subtitles. Elapsed time: ${elapsed}s."
}

main() {
  require_tools

  case "$MODE" in
    scan|dry-run|fix|restore|purge-backups) ;;
    *)
      print_usage
      exit 1
      ;;
  esac

  if [[ "$DELETE_BACKUP" == "true" && "$MODE" != "fix" ]]; then
    echo "--delete-backup can only be used with fix mode."
    exit 1
  fi

  case "$MODE" in
    restore)
      run_restore
      ;;
    purge-backups)
      run_purge_backups
      ;;
    scan|dry-run|fix)
      run_scan_or_fix
      ;;
  esac
}

main
