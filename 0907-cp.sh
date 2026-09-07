#!/bin/bash

# SSH settings
SSH_USER="precalkor"
SSH_HOST="192.168.0.104"
SSH_PORT="4280"

# 1. Check if Zenity is installed
if ! command -v zenity &> /dev/null; then
    echo "zenity not found. Please install zenity before running this script."
    exit 1
fi

# 2. GUI for input parameters with Zenity forms
INPUTS=$(zenity --forms --title="PMT ROOT File rsync Transfer Tool" \
    --width=600 --height=350 \
    --text="input parameters" \
    --add-entry="Input Folder [initial: copytest]" \
    --add-entry="Date [initial: 250901]" \
    --add-entry="Run Numbers [initial: 0 1 2 3 4 5 6]" \
    --add-entry="Save Dir [initial: /rawdata/250901]" \
    --separator="|")

# Check if the user canceled the input form
if [ $? -ne 0 ] || [ -z "$INPUTS" ]; then
    echo "Processing cancelled."
    exit 0
fi

# 3. Parse inputs and fill default values
IFS='|' read -r INPUT_FOLDER DATE RUN_INPUT SAVE_DIR <<< "$INPUTS"

INPUT_FOLDER=${INPUT_FOLDER:-copytest}
DATE=${DATE:-250901}
RUN_INPUT=${RUN_INPUT:-0 1 2 3 4 5 6}
SAVE_DIR=${SAVE_DIR:-/rawdata/$DATE}

# Remove trailing slash (keep leading slash to distinguish absolute vs relative paths)
RAW_FOLDER=$(echo "$INPUT_FOLDER" | sed 's|/$||')

RUN_NUMBERS=$(echo "$RUN_INPUT" | tr ',' ' ')
read -r -a RUN_ARRAY <<< "$RUN_NUMBERS"

if [ ${#RUN_ARRAY[@]} -eq 0 ]; then
    zenity --error --title="Error" --text="Run Number is not specified. Please enter at least one run number." --width=450 --height=150
    exit 1
fi

TOTAL_FILES=$((${#RUN_ARRAY[@]} * 3))

mkdir -p "$SAVE_DIR"

# Get available disk space in the save directory
LOCAL_AVAIL_RAW=$(df -h "$SAVE_DIR" | tail -n 1 | awk '{print $4}')
LOCAL_AVAIL_STR=$(echo "$LOCAL_AVAIL_RAW" | sed -E 's/([0-9.]+)([A-Za-z]+)/\1 \2B/')

# List of remote paths to be transferred
REMOTE_PATHS=()
for j in "${RUN_ARRAY[@]}"; do
    for i in 0 1 2; do
        REMOTE_PATHS+=("$RAW_FOLDER/$DATE/PMT$i/run$j.root")
    done
done

# Get total size of files to be transferred from the remote server
TOTAL_BYTES=$(ssh -p "$SSH_PORT" -o BatchMode=yes "$SSH_USER@$SSH_HOST" "wc -c ${REMOTE_PATHS[*]} 2>/dev/null | tail -n 1 | awk '{print \$1}'")

# Check if remote files exist
if [ -z "$TOTAL_BYTES" ] || [ "$TOTAL_BYTES" -eq 0 ]; then
    zenity --error --title="File Not Found" \
        --text="Remote files could not be found.\n\nChecked Path Example:\n$RAW_FOLDER/$DATE/PMT0/run${RUN_ARRAY[0]}.root\n\nPlease check your Input Folder entry ('copytest' or '/home/precalkor/copytest')." \
        --width=550 --height=220
    exit 1
fi

# Display total size in a human-readable format
TOTAL_SIZE_STR=$(awk -v b="$TOTAL_BYTES" '
    BEGIN {
        if (b >= 1099511627776) printf "%.1f TB", b / 1099511627776;
        else if (b >= 1073741824) printf "%.1f GB", b / 1073741824;
        else if (b >= 1048576) printf "%.1f MB", b / 1048576;
        else if (b >= 1024) printf "%.1f KB", b / 1024;
        else printf "%d B", b;
    }
')

# 4. Confirmation dialog with Zenity
CONFIRM_TEXT="Are you sure you want to start the rsync transfer with the following settings?\n\n"
CONFIRM_TEXT+="・Input Folder : $RAW_FOLDER\n"
CONFIRM_TEXT+="・Date         : $DATE\n"
CONFIRM_TEXT+="・Run Numbers  : ${RUN_ARRAY[*]}\n"
CONFIRM_TEXT+="・Save Dir     : $SAVE_DIR (available : $LOCAL_AVAIL_STR)\n"
CONFIRM_TEXT+="・Total Files  : $TOTAL_FILES files (3 PMTs per run)\n"
CONFIRM_TEXT+="・Total Size   : $TOTAL_SIZE_STR\n\n"

zenity --question --title="Input Content Confirmation" --text="$CONFIRM_TEXT" --width=520 --height=300
if [ $? -ne 0 ]; then
    echo "Processing cancelled by user."
    exit 0
fi

# 5. Perform rsync transfer with real-time progress bar
(
    CURRENT=0
    SUCCESS=0
    FAIL=0
    PREV_BYTES=0

    for j in "${RUN_ARRAY[@]}"; do
        for i in 0 1 2; do
            CURRENT=$((CURRENT + 1))
            TARGET_DIR="$SAVE_DIR/PMT$i"
            mkdir -p "$TARGET_DIR"

            REMOTE_PATH="$RAW_FOLDER/$DATE/PMT$i/run$j.root"

            INIT_COMP_STR=$(awk -v b="$PREV_BYTES" 'BEGIN {
                if (b >= 1099511627776) printf "%.1f TB", b / 1099511627776;
                else if (b >= 1073741824) printf "%.1f GB", b / 1073741824;
                else if (b >= 1048576) printf "%.1f MB", b / 1048576;
                else if (b >= 1024) printf "%.1f KB", b / 1024;
                else printf "%d B", b;
            }')
            INIT_PCT=$((PREV_BYTES * 100 / TOTAL_BYTES))

            echo "# Transferring ($CURRENT/$TOTAL_FILES):\n Remote: $REMOTE_PATH\n Local: $TARGET_DIR/ (available : $LOCAL_AVAIL_STR)\n completed $INIT_COMP_STR / total $TOTAL_SIZE_STR\n transfer speed 0.0 MB/s\n estimated remaining time : --h --m --sec"
            echo "$INIT_PCT"

            # Use stdbuf -oL to force line buffering and prevent pipeline stalls
            rsync --progress -e "ssh -p $SSH_PORT -o BatchMode=yes" "$SSH_USER@$SSH_HOST:$REMOTE_PATH" "$TARGET_DIR/" 2>&1 \
            | stdbuf -oL tr '\r' '\n' \
            | stdbuf -oL awk \
                  -v current_idx="$CURRENT" \
                  -v total_files="$TOTAL_FILES" \
                  -v remote_path="$REMOTE_PATH" \
                  -v target_dir="$TARGET_DIR" \
                  -v avail_space="$LOCAL_AVAIL_STR" \
                  -v prev_bytes="$PREV_BYTES" \
                  -v total_bytes="$TOTAL_BYTES" \
                  -v total_size_str="$TOTAL_SIZE_STR" '
                function format_bytes(b) {
                    if (b >= 1099511627776) return sprintf("%.1f TB", b / 1099511627776);
                    if (b >= 1073741824) return sprintf("%.1f GB", b / 1073741824);
                    if (b >= 1048576) return sprintf("%.1f MB", b / 1048576);
                    if (b >= 1024) return sprintf("%.1f KB", b / 1024);
                    return sprintf("%d B", b);
                }
                function parse_speed_bytes(s,   num, unit, val) {
                    num = s; gsub(/[^0-9.]/, "", num);
                    unit = tolower(s); gsub(/[^a-z\/]/, "", unit);
                    val = num + 0;
                    if (unit ~ /gb\/s/) return val * 1073741824;
                    if (unit ~ /mb\/s/) return val * 1048576;
                    if (unit ~ /kb\/s/) return val * 1024;
                    if (unit ~ /b\/s/) return val;
                    return 0;
                }
                function format_speed(speed_bytes) {
                    if (speed_bytes <= 0) return "0.0 MB/s";
                    return sprintf("%.1f MB/s", speed_bytes / 1048576);
                }
                function calc_eta(rem_bytes, speed_bytes,   sec, h, m, s) {
                    if (speed_bytes <= 0) return "--h --m --sec";
                    sec = int(rem_bytes / speed_bytes);
                    h = int(sec / 3600);
                    m = int((sec % 3600) / 60);
                    s = sec % 60;
                    return sprintf("%02dh %02dm %02dsec", h, m, s);
                }
                /\%/ {
                    p_idx = 0;
                    for (k = 1; k <= NF; k++) {
                        if ($k ~ /\%$/) {
                            p_idx = k;
                            break;
                        }
                    }
                    if (p_idx > 1) {
                        b_str = $(p_idx - 1);
                        gsub(/,/, "", b_str);
                        bytes_curr = b_str + 0;
                        speed_raw = $(p_idx + 1);

                        total_curr = prev_bytes + bytes_curr;
                        rem_bytes = total_bytes - total_curr;
                        if (rem_bytes < 0) rem_bytes = 0;

                        pct = (total_bytes > 0) ? int(total_curr * 100 / total_bytes) : int(current_idx * 100 / total_files);
                        if (pct > 100) pct = 100;

                        comp_str = format_bytes(total_curr);
                        speed_b = parse_speed_bytes(speed_raw);
                        speed_str = format_speed(speed_b);
                        eta_str = calc_eta(rem_bytes, speed_b);

                        print "# Transferring (" current_idx "/" total_files "):\n" \
                              " Remote: " remote_path "\n" \
                              " Local: " target_dir "/ (available : " avail_space ")\n" \
                              " completed " comp_str " / total " total_size_str "\n" \
                              " transfer speed " speed_str "\n" \
                              " estimated remaining time : " eta_str;
                        print pct;
                        fflush();
                    }
                }
            '
            RSYNC_STATUS=${PIPESTATUS[0]}

            if [ $RSYNC_STATUS -eq 0 ]; then
                SUCCESS=$((SUCCESS + 1))
            else
                FAIL=$((FAIL + 1))
            fi

            # Update PREV_BYTES after each file transfer
            XFER_SIZE=$(wc -c < "$TARGET_DIR/run$j.root" 2>/dev/null | tr -d ' ')
            if [[ "$XFER_SIZE" =~ ^[0-9]+$ ]]; then
                PREV_BYTES=$((PREV_BYTES + XFER_SIZE))
            fi
        done
    done

    echo "# Processing Completed: Success $SUCCESS / Failure $FAIL"
    echo "100"
    sleep 1

) | zenity --progress \
    --title="rsync Transfer Progress" \
    --width=650 \
    --height=280 \
    --percentage=0 \
    --auto-close \
    --no-cancel

# 6. Completion notification
zenity --info --title="Processing Completed" --text="rsync transfer completed.\nSave directory: $SAVE_DIR" --width=450 --height=150