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
INPUTS=$(zenity --forms --title="PMT ROOT File SCP Transfer Tool" \
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

# 4. Confirmation dialog with zenity 
CONFIRM_TEXT="Are you sure you want to start the copy with the following settings?\n\n"
CONFIRM_TEXT+="・Input Folder : $INPUT_FOLDER\n"
CONFIRM_TEXT+="・Date         : $DATE\n"
CONFIRM_TEXT+="・Run Numbers  : ${RUN_ARRAY[*]}\n"
CONFIRM_TEXT+="・Save Dir     : $SAVE_DIR\n"
CONFIRM_TEXT+="・Total Files  : $TOTAL_FILES files (3 PMTs per run)\n\n"

zenity --question --title="Input Content Confirmation" --text="$CONFIRM_TEXT" --width=500 --height=280
if [ $? -ne 0 ]; then
    echo "Processing cancelled by user."
    exit 0
fi

# 5. SCP transfer with progress bar 
(
    CURRENT=0
    SUCCESS=0
    FAIL=0

    for j in "${RUN_ARRAY[@]}"; do
        for i in 0 1 2; do
            CURRENT=$((CURRENT + 1))
            PERCENT=$((CURRENT * 100 / TOTAL_FILES))

            TARGET_DIR="$SAVE_DIR/PMT$i"
            mkdir -p "$TARGET_DIR"

            REMOTE_PATH="/$INPUT_FOLDER/$DATE/PMT$i/run$j.root"

            # Display progress in zenity
            echo "# Transferring ($CURRENT/$TOTAL_FILES):\n Remote: $REMOTE_PATH\n Local: $TARGET_DIR/"
            echo "$PERCENT"

            scp -P "$SSH_PORT" "$SSH_USER@$SSH_HOST:$REMOTE_PATH" "$TARGET_DIR/" &> /dev/null

            if [ $? -eq 0 ]; then
                SUCCESS=$((SUCCESS + 1))
            else
                FAIL=$((FAIL + 1))
            fi
        done
    done

    echo "# Processing Completed: Success $SUCCESS / Failure $FAIL"
    echo "100"
    sleep 1

) | zenity --progress \
    --title="SCP Transfer Progress" \
    --width=600 \
    --height=200 \
    --percentage=0 \
    --auto-close \
    --no-cancel

# 6. Completion Notification 
zenity --info --title="Processing Completed" --text="SCP transfer completed.\nSave directory: $SAVE_DIR" --width=450 --height=150