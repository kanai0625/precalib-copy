#!/bin/bash

# SSH settings for remote target (sukap / hkpd)
SSH_USER="hkpd"
SSH_HOST="10.220.11.100" 
SSH_PORT="22"

# 1. Check if required commands are installed
if ! command -v zenity &> /dev/null; then
    echo "zenity not found. Please install zenity before running this script."
    exit 1
fi

if ! command -v sshpass &> /dev/null; then
    zenity --error --title="Missing Dependency" \
        --text="sshpass is not installed.\nPlease install it using: sudo apt install sshpass" \
        --width=500 --height=180
    exit 1
fi

# 2. GUI for input parameters with empty fields and password entry
INPUTS=$(zenity --forms --title="ROOT File rsync Transfer Tool (AUS -> sukap)" \
    --width=750 --height=580 \
    --text="Enter parameters (leave blank to use default values shown in brackets):" \
    --add-entry="Source Directory [default: /media/precalib/rawdata/aus/commissioning]" \
    --add-entry="Date (yyyymmdd) [default: 20260928]" \
    --add-entry="Time (hhmmss) [default: 231031]" \
    --add-entry="PMT Label [default: EL7370-A]" \
    --add-entry="Theta(deg) [default: 0,10,20,30,40,50,60,70,80]" \
    --add-entry="Phi(deg) [default: 0,90,180,270]" \
    --add-entry="Target Base Directory [default: /disk03/hk04/precalib/commissioning/aus]" \
    --add-entry="Electronics [caendigi or hkelec, default: caendigi]" \
    --add-password="Password for ${SSH_USER}@${SSH_HOST}" \
    --separator="|")

# Check if the user canceled the input form
if [ $? -ne 0 ] || [ -z "$INPUTS" ]; then
    echo "Processing cancelled."
    exit 0
fi

# 3. Parse inputs and set default values if fields are left empty
IFS='|' read -r SRC_DIR DATE TIME PMT_LABEL THETA PHI TARGET_BASE_DIR ELECTRONICS SSH_PASS <<< "$INPUTS"

SRC_DIR=${SRC_DIR:-/media/precalib/rawdata/aus/commissioning}
DATE=${DATE:-20260928}
TIME=${TIME:-231031}
PMT_LABEL=${PMT_LABEL:-EL7370-A}
THETA=${THETA:-0,10,20,30,40,50,60,70,80}
PHI=${PHI:-0,90,180,270}
TARGET_BASE_DIR=${TARGET_BASE_DIR:-/disk03/hk04/precalib/commissioning/aus}
ELECTRONICS=${ELECTRONICS:-caendigi}

# Check if password was entered
if [ -z "$SSH_PASS" ]; then
    zenity --error --title="Error" --text="Password cannot be empty." --width=400 --height=150
    exit 1
fi

# Remove trailing/leading slashes and build final target directory
SRC_DIR=$(echo "$SRC_DIR" | sed 's|/$||')
TARGET_BASE_DIR=$(echo "$TARGET_BASE_DIR" | sed 's|/$||')
ELECTRONICS=$(echo "$ELECTRONICS" | sed 's|^/||;s|/$||')

TARGET_DIR="${TARGET_BASE_DIR}/${ELECTRONICS}"

# Parse Theta and Phi into arrays
IFS=',' read -r -a THETA_ARRAY <<< "$THETA"
IFS=',' read -r -a PHI_ARRAY <<< "$PHI"
WAVE_ARRAY=(0 1 3 7)

if [ ${#THETA_ARRAY[@]} -eq 0 ] || [ ${#PHI_ARRAY[@]} -eq 0 ]; then
    zenity --error --title="Error" --text="Theta or Phi is not specified correctly." --width=500 --height=180
    exit 1
fi

TOTAL_FILES=$(( ${#THETA_ARRAY[@]} * ${#PHI_ARRAY[@]} * ${#WAVE_ARRAY[@]} ))

# Build list of local file paths and check their existence
LOCAL_PATHS=()
MISSING_FILES=()

for theta in "${THETA_ARRAY[@]}"; do
    for phi in "${PHI_ARRAY[@]}"; do
        for i in "${WAVE_ARRAY[@]}"; do
            if [ -n "$PMT_LABEL" ]; then
                REL_PATH="scan_${DATE}_${TIME}/$PMT_LABEL/wavesave_theta${theta}_phi${phi}/wave${i}.dat"
            else
                REL_PATH="scan_${DATE}_${TIME}/wavesave_theta${theta}_phi${phi}/wave${i}.dat"
            fi
            FILE_PATH="$SRC_DIR/$REL_PATH"
            if [ -f "$FILE_PATH" ]; then
                LOCAL_PATHS+=("$FILE_PATH")
            else
                MISSING_FILES+=("$REL_PATH")
            fi
        done
    done
done

# Check if any local file is missing
if [ ${#MISSING_FILES[@]} -gt 0 ]; then
    zenity --error --title="File Not Found" \
        --text="The following local file(s) could not be found:\n\n${MISSING_FILES[0]} (and others)\n\nPlease check the Source Directory, Date, Time, and Angle settings." \
        --width=600 --height=250
    exit 1
fi

# Calculate total size of local files
TOTAL_BYTES=$(wc -c "${LOCAL_PATHS[@]}" 2>/dev/null | tail -n 1 | awk '{print $1}')

# Format total size into human-readable format
TOTAL_SIZE_STR=$(awk -v b="$TOTAL_BYTES" '
    BEGIN {
        if (b >= 1099511627776) printf "%.1f TB", b / 1099511627776;
        else if (b >= 1073741824) printf "%.1f GB", b / 1073741824;
        else if (b >= 1048576) printf "%.1f MB", b / 1048576;
        else if (b >= 1024) printf "%.1f KB", b / 1024;
        else printf "%d B", b;
    }
')

# Check available space on the remote destination
REMOTE_AVAIL_RAW=$(sshpass -p "$SSH_PASS" ssh -p "$SSH_PORT" -o StrictHostKeyChecking=no "$SSH_USER@$SSH_HOST" "mkdir -p '$TARGET_DIR' && df -h '$TARGET_DIR' | tail -n 1 | awk '{print \$4}'" 2>/dev/null)

if [ $? -ne 0 ] || [ -z "$REMOTE_AVAIL_RAW" ]; then
    zenity --error --title="SSH Connection Error" \
        --text="Failed to connect to remote server ($SSH_USER@$SSH_HOST).\nPlease check your password and network connection." \
        --width=550 --height=200
    exit 1
fi

REMOTE_AVAIL_STR=$(echo "$REMOTE_AVAIL_RAW" | sed -E 's/([0-9.]+)([A-Za-z]+)/\1 \2B/')

# 4. Confirmation dialog
CONFIRM_TEXT="Are you sure you want to transfer files to sukap ($SSH_HOST) with the following settings?\n\n"
CONFIRM_TEXT+="・Source Dir   : $SRC_DIR\n"
CONFIRM_TEXT+="・Date         : $DATE\n"
CONFIRM_TEXT+="・Time         : $TIME\n"
CONFIRM_TEXT+="・PMT Label    : $PMT_LABEL\n"
CONFIRM_TEXT+="・Theta        : $THETA\n"
CONFIRM_TEXT+="・Phi          : $PHI\n"
CONFIRM_TEXT+="・Electronics  : $ELECTRONICS\n"
CONFIRM_TEXT+="・Target Dir   : sukap:$TARGET_DIR (available: $REMOTE_AVAIL_STR)\n"
CONFIRM_TEXT+="・Total Files  : $TOTAL_FILES files\n"
CONFIRM_TEXT+="・Total Size   : $TOTAL_SIZE_STR\n\n"

zenity --question --title="Input Content Confirmation" --text="$CONFIRM_TEXT" --width=680 --height=430
if [ $? -ne 0 ]; then
    echo "Processing cancelled by user."
    exit 0
fi

# 5. Perform rsync transfer with real-time progress bar
export SSHPASS="$SSH_PASS"

(
    CURRENT=0
    SUCCESS=0
    FAIL=0
    PREV_BYTES=0

    for theta in "${THETA_ARRAY[@]}"; do
        for phi in "${PHI_ARRAY[@]}"; do
            for i in "${WAVE_ARRAY[@]}"; do
                CURRENT=$((CURRENT + 1))
                
                if [ -n "$PMT_LABEL" ]; then
                    REL_PATH="scan_${DATE}_${TIME}/$PMT_LABEL/wavesave_theta${theta}_phi${phi}/wave${i}.dat"
                else
                    REL_PATH="scan_${DATE}_${TIME}/wavesave_theta${theta}_phi${phi}/wave${i}.dat"
                fi
                
                LOCAL_PATH="$SRC_DIR/$REL_PATH"

                INIT_COMP_STR=$(awk -v b="$PREV_BYTES" 'BEGIN {
                    if (b >= 1099511627776) printf "%.1f TB", b / 1099511627776;
                    else if (b >= 1073741824) printf "%.1f GB", b / 1073741824;
                    else if (b >= 1048576) printf "%.1f MB", b / 1048576;
                    else if (b >= 1024) printf "%.1f KB", b / 1024;
                    else printf "%d B", b;
                }')
                INIT_PCT=$((TOTAL_BYTES > 0 ? PREV_BYTES * 100 / TOTAL_BYTES : 0))

                echo "# Transferring ($CURRENT/$TOTAL_FILES):\n Local: $LOCAL_PATH\n Remote: $SSH_USER@$SSH_HOST:$TARGET_DIR/$REL_PATH\n completed $INIT_COMP_STR / total $TOTAL_SIZE_STR\n transfer speed 0.0 MB/s\n estimated remaining time : --h --m --sec"
                echo "$INIT_PCT"

                # Execute rsync maintaining relative path structure (-R)
                (cd "$SRC_DIR" && rsync --progress -R -e "sshpass -e ssh -p $SSH_PORT -o StrictHostKeyChecking=no" "$REL_PATH" "$SSH_USER@$SSH_HOST:$TARGET_DIR/") 2>&1 \
                | stdbuf -oL tr '\r' '\n' \
                | stdbuf -oL awk \
                      -v current_idx="$CURRENT" \
                      -v total_files="$TOTAL_FILES" \
                      -v local_path="$LOCAL_PATH" \
                      -v target_dir="$TARGET_DIR/$REL_PATH" \
                      -v avail_space="$REMOTE_AVAIL_STR" \
                      -v prev_bytes="$PREV_BYTES" \
                      -v total_bytes="$TOTAL_BYTES" \
                      -v total_size_str="$TOTAL_SIZE_STR" \
                      -v remote_host="$SSH_HOST" '
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
                                  " Local: " local_path "\n" \
                                  " Remote: " remote_host ":" target_dir "\n" \
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

                # Update PREV_BYTES for the next file using local file size
                XFER_SIZE=$(wc -c < "$LOCAL_PATH" 2>/dev/null | tr -d ' ')
                if [[ "$XFER_SIZE" =~ ^[0-9]+$ ]]; then
                    PREV_BYTES=$((PREV_BYTES + XFER_SIZE))
                fi
            done
        done
    done

    echo "# Processing Completed: Success $SUCCESS / Failure $FAIL"
    echo "100"
    sleep 1

) | zenity --progress \
    --title="rsync Transfer Progress (AUS -> sukap)" \
    --width=700 \
    --height=320 \
    --percentage=0 \
    --auto-close \
    --no-cancel

# Clear password environment variable
unset SSHPASS

# 6. Completion notification
zenity --info --title="Processing Completed" \
    --text="rsync transfer completed.\nSuccess: $SUCCESS files\nFailure: $FAIL files\n\nTarget directory: sukap:$TARGET_DIR" \
    --width=500 --height=180