#!/bin/sh
# restore_helpers.sh — shared helpers for the BACKUP/RESTORE feature.
# Sourced by tg_bot.sh and by /usr/libexec/rpcd/gatekeeper (LuCI backend).
# Installed to /usr/lib/gatekeeper/restore_helpers.sh by the gatekeeper package.
#
# Functions:
#   mac_hostname <mac>            - resolve MAC to device name (or empty)
#   is_valid_backup <path>        - return 0 if file is a valid v1 backup
#   restore_parse_to_records <in> <out>
#                                  - awk parse backup file into TSV records
#   restore_build_plan <records> <plan> <preview>
#                                  - emit uci-command plan + preview text
#
# Constants:
#   RESTORE_FILE, RESTORE_PLAN, RESTORE_RECORDS, RESTORE_PREVIEW, RESTORE_PENDING
#
# Dependencies on the sourcing script: NAME_MAP and LOG_FILE must be set
# before any function is called (mac_hostname reads NAME_MAP; the build/parse
# functions don't reference LOG_FILE but the BACKUP/RESTORE handlers in
# tg_bot.sh that wrap them do). The rpcd backend defines both before sourcing.

# mac_hostname <mac> — emit best-known device name for a MAC, or empty.
# Mirrors STATUS handler's resolution chain. Used by RESTORE preview.
mac_hostname() {
    local m h
    m=$(echo "$1" | tr 'A-Z' 'a-z')
    [ -z "$m" ] && return
    h=$(grep -i "$m" "$NAME_MAP" 2>/dev/null | tail -n 1 | cut -d'=' -f2)
    [ -z "$h" ] && h=$(grep -i "$m" /tmp/dhcp.leases 2>/dev/null | awk '{print $4}')
    if [ -z "$h" ] || [ "$h" = "*" ]; then
        h=$(uci show dhcp 2>/dev/null | grep -i "$m" | cut -d. -f2 \
            | xargs -I {} uci -q get dhcp.{}.name 2>/dev/null | head -n 1)
    fi
    [ "$h" = "*" ] && h=""
    echo "$h"
}

# is_valid_backup <path> — returns 0 if path is a Gatekeeper v1 backup,
# 1 otherwise. Five-check validation gate.
is_valid_backup() {
    local p sz
    p="$1"
    [ -f "$p" ] || return 1
    sz=$(wc -c < "$p" 2>/dev/null)
    [ -z "$sz" ] && return 1
    [ "$sz" -gt 1048576 ] && return 1
    head -n 1 "$p" | grep -q '^# Gatekeeper backup$' || return 1
    grep -q '^# Schema:[[:space:]]*v1$' "$p" || return 1
    grep -q '^# === /etc/config/gatekeeper ===$' "$p" || return 1
    grep -q '^# === /etc/config/dhcp' "$p" || return 1
    grep -q '^package gatekeeper$' "$p" || return 1
    return 0
}

# restore_parse_to_records <input> <output-tsv>
# Awk parser → tab-separated records:
#   section <type> <name>
#   option <type> <name> <key> <value>
#   list <type> <name> <key> <value>
restore_parse_to_records() {
    awk '
        BEGIN { in_section = 0; cur_type = ""; cur_name = ""; OFS = "\t" }
        /^# === \/etc\/config\/gatekeeper ===/ { in_section = 1; next }
        /^# === \/etc\/config\/dhcp/ { in_section = 0; next }
        !in_section { next }
        /^[[:space:]]*$/ { next }
        /^#/ { next }
        /^package / { next }
        /^config / {
            cur_type = $2
            cur_name = ""
            if (NF >= 3) {
                n = $3
                gsub(/^['\''"]/, "", n); gsub(/['\''"]$/, "", n)
                cur_name = n
            }
            print "section", cur_type, cur_name
            next
        }
        /^[[:space:]]+(option|list) / {
            kind = $1
            key  = $2
            q1 = index($0, "'\''")
            if (q1 == 0) next
            q2 = length($0)
            while (q2 > q1 && substr($0, q2, 1) != "'\''") q2--
            if (q2 <= q1) next
            val = substr($0, q1+1, q2-q1-1)
            print kind, cur_type, cur_name, key, val
        }
    ' "$1" > "$2"
}

# restore_build_plan <records-tsv> <plan-out> <preview-out>
# Reads records, computes the additive merge against current UCI, writes
# the plan file (one uci command per line) and preview text. Returns 0
# if the plan has at least one mutation, 1 if everything is a no-op.
restore_build_plan() {
    records="$1"
    plan="$2"
    preview="$3"

    {
        echo "# Restore plan generated at $(date -Iseconds 2>/dev/null || date)"
    } > "$plan"
    : > "$preview"

    current_bl=$(uci show gatekeeper.blacklist 2>/dev/null \
        | grep -oE "([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}" \
        | tr 'A-Z' 'a-z' | sort -u)

    sec_type=""
    sec_name=""
    sec_skip=0
    schedule_started=0
    pending_sched_name=""
    pending_sched_mac=""
    pending_sched_days=""
    pending_sched_start=""
    pending_sched_stop=""

    pv_main=""
    pv_bl_added=""
    pv_bl_present=""
    pv_sched_added=""
    pv_sched_present=""

    plan_count=0
    main_count=0
    bl_added_count=0
    bl_present_count=0
    sched_added_count=0
    sched_present_count=0

    flush_pending_schedule() {
        if [ -n "$pending_sched_name" ]; then
            line="\n• \`${pending_sched_name}\` → \`${pending_sched_mac}\`"
            host=$(mac_hostname "$pending_sched_mac")
            [ -n "$host" ] && line="${line} (${host})"
            line="${line}\n  ${pending_sched_days} ${pending_sched_start}–${pending_sched_stop}"
            pv_sched_added="${pv_sched_added}${line}"
            sched_added_count=$((sched_added_count+1))
        fi
        pending_sched_name=""
        pending_sched_mac=""
        pending_sched_days=""
        pending_sched_start=""
        pending_sched_stop=""
    }

    TAB=$(printf '\t')
    while IFS="$TAB" read -r kind type name key val; do
        if [ "$kind" = "section" ]; then
            flush_pending_schedule
            sec_type="$type"
            sec_name="$name"
            sec_skip=0
            schedule_started=0
            if [ "$type" = "schedule" ]; then
                existing=$(uci -q get "gatekeeper.${name}")
                if [ "$existing" = "schedule" ]; then
                    sec_skip=1
                    pv_sched_present="${pv_sched_present}\n• \`${name}\`"
                    sched_present_count=$((sched_present_count+1))
                fi
            fi
            continue
        fi

        [ "$sec_skip" = "1" ] && continue

        case "$sec_type" in
            gatekeeper)
                if [ "$kind" = "option" ]; then
                    case "$key" in
                        token|chat_id) continue ;;
                    esac
                    [ -z "$val" ] && continue
                    cur=$(uci -q get "gatekeeper.main.${key}")
                    if [ "$cur" != "$val" ]; then
                        echo "uci set gatekeeper.main.${key}='${val}'" >> "$plan"
                        plan_count=$((plan_count+1))
                        main_count=$((main_count+1))
                        pv_main="${pv_main}\n• ${key}: \`${cur}\` → \`${val}\`"
                    fi
                fi
                ;;
            blacklist)
                if [ "$kind" = "list" ] && [ "$key" = "mac" ]; then
                    mac_lc=$(echo "$val" | tr 'A-Z' 'a-z')
                    if echo "$current_bl" | grep -qx "$mac_lc"; then
                        pv_bl_present="${pv_bl_present}\n• ${mac_lc}"
                        bl_present_count=$((bl_present_count+1))
                    else
                        # Seed the parent section idempotently on the first
                        # add_list — restore onto a fresh router (where
                        # gatekeeper_init / BLADD / BLON have never run) would
                        # otherwise hit "Entry not found" on add_list.
                        if [ "$bl_added_count" = "0" ]; then
                            echo "uci set gatekeeper.blacklist=blacklist" >> "$plan"
                            plan_count=$((plan_count+1))
                        fi
                        echo "uci add_list gatekeeper.blacklist.mac='${mac_lc}'" >> "$plan"
                        plan_count=$((plan_count+1))
                        bl_added_count=$((bl_added_count+1))
                        host=$(mac_hostname "$mac_lc")
                        if [ -n "$host" ]; then
                            pv_bl_added="${pv_bl_added}\n• ${mac_lc} (${host})"
                        else
                            pv_bl_added="${pv_bl_added}\n• ${mac_lc}"
                        fi
                    fi
                fi
                ;;
            schedule)
                if [ "$schedule_started" = "0" ]; then
                    echo "uci set gatekeeper.${sec_name}=schedule" >> "$plan"
                    plan_count=$((plan_count+1))
                    schedule_started=1
                    pending_sched_name="$sec_name"
                fi
                if [ "$kind" = "option" ]; then
                    echo "uci set gatekeeper.${sec_name}.${key}='${val}'" >> "$plan"
                    plan_count=$((plan_count+1))
                    case "$key" in
                        mac)   pending_sched_mac="$val" ;;
                        days)  pending_sched_days="$val" ;;
                        start) pending_sched_start="$val" ;;
                        stop)  pending_sched_stop="$val" ;;
                    esac
                fi
                ;;
        esac
    done < "$records"

    flush_pending_schedule

    {
        if [ "$main_count" -gt 0 ]; then
            printf '*Main options:*%b\n_(token / chat_id never touched.)_\n\n' "$pv_main"
        fi
        if [ "$bl_added_count" -gt 0 ]; then
            printf '*Blacklist additions* (%d new):%b\n\n' "$bl_added_count" "$pv_bl_added"
        fi
        if [ "$bl_present_count" -gt 0 ]; then
            printf '*Blacklist already present* (%d):%b\n\n' "$bl_present_count" "$pv_bl_present"
        fi
        if [ "$sched_added_count" -gt 0 ]; then
            printf '*Schedule additions* (%d new):%b\n\n' "$sched_added_count" "$pv_sched_added"
        fi
        if [ "$sched_present_count" -gt 0 ]; then
            printf '*Schedule already present* (%d):%b\n\n' "$sched_present_count" "$pv_sched_present"
        fi
    } > "$preview"

    [ "$plan_count" -gt 0 ]
}

# State files for the two-step restore flow
RESTORE_FILE="/tmp/restore_file.txt"
RESTORE_PLAN="/tmp/restore_plan.sh"
RESTORE_RECORDS="/tmp/restore_records.tsv"
RESTORE_PREVIEW="/tmp/restore_preview.txt"
RESTORE_PENDING="/tmp/restore_pending"
