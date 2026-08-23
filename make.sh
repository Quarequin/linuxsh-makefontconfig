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
    printf "  -v, --verbose    Show progress log without timestamps\n"
    printf "  -f, --force      Skip interactive confirmation prompt\n"
    printf "  -w, --overwrite  Allow overwriting existing output file\n"
    printf "  -h, --help       Show usage instructions\n"
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
        -[!-]*)
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
    print "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
    print "<!DOCTYPE fontconfig SYSTEM \"fonts.dtd\">"
    print "<!-- -->"
    print "<fontconfig>"
    print "  <!-- Generic name aliasing -->"
    total_sections = 0
}

function log_status(pct, status) {
    if (verbose == 1) {
        printf "[LOG %3d%%] %s\n", pct, status > "/dev/stderr"
    } else {
        printf "\rProgress: %3d%% | Status: %-50s", pct, status > "/dev/stderr"
    }
}

{
    gsub(/\r/, "")
    lines[NR] = $0
    if ($0 !~ /^[[:space:]]*#/ && $0 !~ /^[[:space:]]*$/) {
        if ($0 ~ /:[[:space:]]*$/ && $0 !~ /^[[:space:]]*-[[:space:]]+/) {
            total_sections++
        }
    }
}

END {
    if (total_sections == 0) total_sections = 1
    current_section = 0
    in_alias = 0

    log_status(0, "Initializing parser...")

    for (i = 1; i <= NR; i++) {
        line = lines[i]
        
        if (line ~ /^[[:space:]]*#/ || line ~ /^[[:space:]]*$/) continue;

        if (line ~ /^[[:space:]]*-[[:space:]]+/) {
            sub(/^[[:space:]]*-[[:space:]]+/, "", line)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
            gsub(/^["\047]|["\047]$/, "", line)

            if (in_alias == 1 && line != "") {
                print "      <family>" line "</family>"
            }
        }
        else if (line ~ /:[[:space:]]*$/) {
            sub(/^[[:space:]]*/, "", line)
            sub(/:[[:space:]]*$/, "", line)
            gsub(/^["\047]|["\047]$/, "", line)

            if (in_alias == 1) {
                print "    </prefer>"
                print "  </alias>"
            }

            current_section++
            pct = int((current_section / total_sections) * 100)
            if (pct > 100) pct = 100
            
            log_status(pct, "Processing family: " line)

            print "  <alias>"
            print "    <family>" line "</family>"
            print "    <prefer>"
            in_alias = 1
        }
    }

    if (in_alias == 1) {
        print "    </prefer>"
        print "  </alias>"
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
