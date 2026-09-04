#!/bin/bash

# SSH settings
SSH_USER="precalib"
SSH_HOST="100.120.120.108"
SSH_PORT="22"

# 1. zenity confirmation 
if ! command -v zenity &> /dev/null; then
    echo "zenity not found. Please install zenity before running this script."
    exit 1
fi

# 2. GUI for input parameters with zenity forms 
INPUTS=$(zenity --forms --title="PMT ROOT File rsync Transfer Tool" \
    --width=600 --height=350 \
    --text="input parameters" \
    --add-entry="Input Folder [initial: data]" \
    --add-entry="Date [initial: 250901]" \
    --add-entry="Run Numbers [e.g., 0 1 2 3 or 0,1,2]" \
    --add-entry="Save Dir [initial: /rawdata/250901]" \
    --separator="|")

# Check if the user canceled the input form
if [ $? -ne 0 ] || [ -z "$INPUTS" ]; then
    echo "Processing cancelled."
    exit 0
fi

# 3. Parse and fill default values
IFS='|' read -r INPUT_FOLDER DATE RUN_INPUT SAVE_DIR <<< "$INPUTS"

INPUT_FOLDER=${INPUT_FOLDER:-data}
DATE=${DATE:-250901}
RUN_INPUT=${RUN_INPUT:-0 1 2 3}
SAVE_DIR=${SAVE_DIR:-/rawdata/$DATE}

# Remove leading and trailing slashes from INPUT_FOLDER
INPUT_FOLDER=$(echo "$INPUT_FOLDER" | sed 's|^/||;s|/$||')
RUN_NUMBERS=$(echo "$RUN_INPUT" | tr ',' ' ')
read -r -a RUN_ARRAY <<< "$RUN_NUMBERS"

if [ ${#RUN_ARRAY[@]} -eq 0 ]; then
    zenity --error --title="Error" --text="Run Number is not specified. Please enter at least one run number." --width=450 --height=150
    exit 1
fi

TOTAL_FILES=$((${#RUN_ARRAY[@]} * 3))

# ---------------------------------------------------------
# 事前計算: 保存先の空き容量 & リモートファイルの合計サイズ取得
# ---------------------------------------------------------
mkdir -p "$SAVE_DIR"

# get the available space in the save directory
LOCAL_AVAIL_RAW=$(df -h "$SAVE_DIR" | tail -n 1 | awk '{print $4}')
LOCAL_AVAIL_STR=$(echo "$LOCAL_AVAIL_RAW" | sed -E 's/([0-9.]+)([A-Za-z]+)/\1 \2B/')

# list of remote paths to be transferred
REMOTE_PATHS=()
for j in "${RUN_ARRAY[@]}"; do
    for i in 0 1 2; do
        REMOTE_PATHS+=("/$INPUT_FOLDER/$DATE/PMT$i/run$j.root")
    done
done

# get the total size of the files to be transferred from the remote server
TOTAL_BYTES=$(ssh -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" "wc -c ${REMOTE_PATHS[*]} 2>/dev/null | tail -n 1 | awk '{print \$1}'")
if [ -z "$TOTAL_BYTES" ] || [ "$TOTAL_BYTES" -eq 0 ]; then
    TOTAL_BYTES=1
fi

# display the total size in a human-readable format
TOTAL_SIZE_STR=$(awk -v b="$TOTAL_BYTES" '
    BEGIN {
        if (b >= 1099511627776) printf "%.1f TB", b / 1099511627776;
        else if (b >= 1073741824) printf "%.1f GB", b / 1073741824;
        else if (b >= 1048576) printf "%.1f MB", b / 1048576;
        else if (b >= 1024) printf "%.1f KB", b / 1024;
        else printf "%d B", b;
    }
')

# 4. Confirmation dialog with zenity 
CONFIRM_TEXT="Are you sure you want to start the rsync transfer with the following settings?\n\n"
CONFIRM_TEXT+="・Input Folder : $INPUT_FOLDER\n"
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

# 5. rsync transfer with progress bar 
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

            REMOTE_PATH="/$INPUT_FOLDER/$DATE/PMT$i/run$j.root"

            # ファイル開始時の初期画面テキスト
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

            # rsync 実行と進捗リアルタイム解析
            rsync --progress -e "ssh -p $SSH_PORT" "$SSH_USER@$SSH_HOST:$REMOTE_PATH" "$TARGET_DIR/" 2>&1 \
            | tr '\r' '\n' \
            | awk -v current_idx="$CURRENT" \
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

            # 送信完了ファイルの容量を加算
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

# 6. Completion Notification 
zenity --info --title="Processing Completed" --text="rsync transfer completed.\nSave directory: $SAVE_DIR" --width=450 --height=150