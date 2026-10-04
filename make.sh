#!/bin/sh
set -e

VERBOSE=0
FORCE=0
OVERWRITE=0
SOURCE_YML=""
DIST_CONF=""

show_usage() {
    printf "Usage: %s [options] <source.yml> <dist.conf>\n\n" "$0"
    printf "Options:\n"
    printf "  -v, --verbose        Show progress log without timestamps\n"
    printf "  -f, --force          Skip interactive confirmation prompt\n"
    printf "  -w, --overwrite      Allow overwriting existing output file\n"
    printf "  -h, --help           Show usage instructions\n"
}

# Parse options and option stacking (e.g. -vfw)
while [ $# -gt 0 ]; do
    case "$1" in
        --verbose) VERBOSE=1; shift ;;
        --force) FORCE=1; shift ;;
        --overwrite) OVERWRITE=1; shift ;;
        --help) show_usage; exit 0 ;;
        --*)
            printf "Error: Unknown option '%s'\n" "$1" >&2
            exit 1
            ;;
        -[!-]* )
            opts="${1#-}"
            shift
            while [ -n "$opts" ]; do
                opt=$(printf "%.1s" "$opts")
                opts="${opts#?}"
                case "$opt" in
                    v) VERBOSE=1 ;;
                    f) FORCE=1 ;;
                    w|o) OVERWRITE=1 ;;
                    h) show_usage; exit 0 ;;
                    *)
                        printf "Error: Unknown flag '-%s'\n" "$opt" >&2
                        exit 1
                        ;;
                esac
            done
            ;;
        *)
            if [ -z "$SOURCE_YML" ]; then
                SOURCE_YML="$1"
            elif [ -z "$DIST_CONF" ]; then
                DIST_CONF="$1"
            else
                printf "Error: Unexpected argument '%s'\n" "$1" >&2
                exit 1
            fi
            shift
            ;;
    esac
done

# Validate input parameters
if [ -z "$SOURCE_YML" ] || [ -z "$DIST_CONF" ]; then
    printf "Error: Missing required arguments.\n\n" >&2
    show_usage
    exit 1
fi

if [ ! -f "$SOURCE_YML" ]; then
    printf "Error: Source YAML file '%s' does not exist.\n" "$SOURCE_YML" >&2
    exit 1
fi

if [ -f "$DIST_CONF" ] && [ "$OVERWRITE" -eq 0 ]; then
    printf "Error: Destination file '%s' already exists. Use -w or --overwrite to overwrite.\n" "$DIST_CONF" >&2
    exit 1
fi

# Pre-execution Notice
printf "+================================================+\n"
printf "|        Fontconfig Configuration Generator      |\n"
printf "+================================================+\n"
printf " Source YAML      : %s\n" "$SOURCE_YML"
printf " Destination XML  : %s\n" "$DIST_CONF"
printf " Overwrite Mode   : %s\n" "$([ "$OVERWRITE" -eq 1 ] && echo "YES" || echo "NO")"
printf " Verbose Output   : %s\n" "$([ "$VERBOSE" -eq 1 ] && echo "YES" || echo "NO")"
printf "+================================================+\n"

# Interactive Prompt (unless force flag is provided)
if [ "$FORCE" -eq 0 ]; then
    printf "Do you want to start processing? [y/N]: "
    read answer
    case "$answer" in
        [yY]|[yY][eE][sS])
            printf "Starting process...\n"
            ;;
        *)
            printf "Operation cancelled by user.\n"
            exit 0
            ;;
    esac
fi

# Create temporary working file
TEMP_FILE="$(mktemp 2>/dev/null || echo "/tmp/fc_gen_$$")"

# Core Generator using POSIX AWK
awk -v verbose="$VERBOSE" '
BEGIN {
    section = ""
    curr_group = ""
    num_groups = 0
}

function log_status(pct, status) {
    if (verbose == 1) {
        printf "[LOG %3d%%] %s\n", pct, status > "/dev/stderr"
    } else {
        printf "\rProgress: %3d%% | Status: %-50s", pct, status > "/dev/stderr"
    }
}

# Recursive helper function to output family items (supports ---[[group]] expansion)
function print_val_items(grp,   v, item, ref_grp) {
    for (v = 1; v <= val_count[grp]; v++) {
        item = val_items[grp, v]
        if (item ~ /^---\[\[.*\]\]$/) {
            ref_grp = item
            sub(/^---\[\[/, "", ref_grp)
            sub(/\]\]$/, "", ref_grp)
            print_val_items(ref_grp)
        } else {
            print "      <family>" item "</family>"
        }
    }
}

{
    gsub(/\r/, "")
    
    # Skip empty lines and comments
    if ($0 ~ /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/) {
        next
    }

    # Detect section headers (allowing optional trailing colon)
    if ($0 ~ /---val---/) {
        section = "val"
        curr_group = ""
        next
    }
    if ($0 ~ /---key---/) {
        section = "key"
        curr_group = ""
        next
    }

    # Group header: e.g. "  - my-sans:"
    if ($0 ~ /:[[:space:]]*$/) {
        line = $0
        sub(/^[[:space:]]*-[[:space:]]*/, "", line)
        sub(/:[[:space:]]*$/, "", line)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
        gsub(/^["\047]|["\047]$/, "", line)
        
        curr_group = line
        if (curr_group != "" && !(curr_group in group_seen)) {
            group_seen[curr_group] = 1
            num_groups++
            group_list[num_groups] = curr_group
        }
        next
    }

    # List items: e.g. "    - Noto Sans" or "    - ---[[my-sans]]"
    if ($0 ~ /^[[:space:]]*-[[:space:]]+/) {
        line = $0
        sub(/^[[:space:]]*-[[:space:]]+/, "", line)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
        gsub(/^["\047]|["\047]$/, "", line)

        if (curr_group != "" && line != "") {
            if (section == "val") {
                val_count[curr_group]++
                val_items[curr_group, val_count[curr_group]] = line
            } else if (section == "key") {
                key_count[curr_group]++
                key_items[curr_group, key_count[curr_group]] = line
            }
        }
    }
}

END {
    # Calculate total target font aliases for progress calculation
    total_targets = 0
    for (g = 1; g <= num_groups; g++) {
        grp = group_list[g]
        total_targets += key_count[grp]
    }
    if (total_targets == 0) total_targets = 1

    log_status(0, "Initializing parser...")

    print "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
    print "<!DOCTYPE fontconfig SYSTEM \"fonts.dtd\">"
    print "<!-- -->"
    print "<fontconfig>"
    print "  <!-- Generic name aliasing -->"

    processed = 0

    for (g = 1; g <= num_groups; g++) {
        grp = group_list[g]
        k_cnt = key_count[grp]

        for (k = 1; k <= k_cnt; k++) {
            target_font = key_items[grp, k]
            processed++
            pct = int((processed / total_targets) * 100)
            if (pct > 100) pct = 100

            log_status(pct, "Processing alias: " target_font)

            print "  <alias>"
            print "    <family>" target_font "</family>"
            print "    <prefer>"

            # Output values and expand any embedded references recursively
            print_val_items(grp)

            print "    </prefer>"
            print "  </alias>"
        }
    }

    print "</fontconfig>"

    log_status(100, "Processing complete!")
    if (verbose != 1) {
        printf "\n" > "/dev/stderr"
    }
}
' "$SOURCE_YML" > "$TEMP_FILE"

mv "$TEMP_FILE" "$DIST_CONF"
printf "Done: Config generated successfully at '%s'.\n" "$DIST_CONF"
