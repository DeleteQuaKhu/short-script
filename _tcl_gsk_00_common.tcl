# _tcl_gsk_00_common.tcl
# Shared helpers for the GSK workflow. Pure Tcl 8.5, no packages.
# Namespace: ::gsk::common   (every proc is defined exactly once)
#
# Notes:
#  - write_log   (workflow section) gates the workflow log FILE only.
#  - write_status (workflow section) gates workflow_status AND run_status_csv.
#  - log_sink: optional command prefix called with the formatted log line
#    (used by the GUI to mirror log lines). Empty = no sink.

namespace eval ::gsk::common {
    variable log_sink
    variable last_completed
    if {![info exists log_sink]} {
        set log_sink {}
    }
    if {![info exists last_completed]} {
        set last_completed {}
    }
}

# ---------------------------------------------------------------- config

# load_config {root}
# Reads <root>/00_config/gsk_workflow_config.ini into a nested dict:
#   root <root> config_file <file> <section> {<key> <value> ...} ...
proc ::gsk::common::load_config {root} {
    if {[string trim $root] eq ""} {
        error "load_config: working root folder is empty"
    }
    set root [file normalize $root]
    set file [file join $root 00_config gsk_workflow_config.ini]
    if {![file isfile $file]} {
        error "Config file not found: $file"
    }
    if {[catch {open $file r} fh]} {
        error "Cannot open config file: $file ($fh)"
    }
    set rc [catch {
        fconfigure $fh -encoding utf-8
        read $fh
    } data]
    close $fh
    if {$rc} {
        error "Cannot read config file: $file ($data)"
    }
    if {[string index $data 0] eq "\uFEFF"} {
        set data [string range $data 1 end]
    }

    set cfg [dict create root $root config_file $file]
    set section {}
    set lineNo 0
    foreach rawLine [split $data "\n"] {
        incr lineNo
        set line [string trim $rawLine]
        if {$line eq ""} {
            continue
        }
        set first [string index $line 0]
        if {$first eq "#" || $first eq ";"} {
            continue
        }
        if {[regexp {^\[([^\]]+)\]$} $line -> name]} {
            set section [string tolower [string trim $name]]
            if {$section eq "" || $section eq "root" || $section eq "config_file"} {
                error "Invalid section name at line $lineNo in $file: $line"
            }
            if {![dict exists $cfg $section]} {
                dict set cfg $section [dict create]
            }
            continue
        }
        set eq [string first "=" $line]
        if {$eq < 1} {
            error "Invalid config line $lineNo in $file: $line"
        }
        if {$section eq ""} {
            error "Config record before any section at line $lineNo in $file: $line"
        }
        set key [string tolower [string trim [string range $line 0 [expr {$eq - 1}]]]]
        set value [string trim [string range $line [expr {$eq + 1}] end]]
        if {$key eq ""} {
            error "Empty key at line $lineNo in $file: $line"
        }
        if {[dict exists $cfg $section $key]} {
            error "Duplicate key $key in section $section at line $lineNo in $file"
        }
        dict set cfg $section $key $value
    }
    return $cfg
}

# get {cfg section key args}
# Optional single default via args. No default -> error when missing.
proc ::gsk::common::get {cfg section key args} {
    set section [string tolower $section]
    set key [string tolower $key]
    if {[dict exists $cfg $section $key]} {
        return [dict get $cfg $section $key]
    }
    if {[llength $args] == 1} {
        return [lindex $args 0]
    }
    if {[llength $args] > 1} {
        error "get: at most one default value allowed for $section $key"
    }
    error "Missing required config value: $section $key"
}

# get_bool {cfg section key args}  -> 0 or 1, error if not a boolean
proc ::gsk::common::get_bool {cfg section key args} {
    set value [get $cfg $section $key {*}$args]
    if {![string is boolean -strict $value]} {
        error "Config value is not a boolean: $section $key = $value"
    }
    return [expr {$value ? 1 : 0}]
}

# resolve_path {root path}
proc ::gsk::common::resolve_path {root path} {
    if {[string trim $path] eq ""} {
        error "resolve_path: path is empty (root: $root)"
    }
    if {[file pathtype $path] eq "absolute"} {
        return [file normalize $path]
    }
    return [file normalize [file join $root $path]]
}

# cfg_path {cfg section key}
proc ::gsk::common::cfg_path {cfg section key} {
    if {![dict exists $cfg root]} {
        error "Config dict has no root entry"
    }
    return [resolve_path [dict get $cfg root] [get $cfg $section $key]]
}

# ensure_directories {cfg}
proc ::gsk::common::ensure_directories {cfg} {
    if {![dict exists $cfg folders]} {
        error "Missing required config section: folders"
    }
    set dirs {}
    foreach key [dict keys [dict get $cfg folders] *_dir] {
        lappend dirs [cfg_path $cfg folders $key]
    }
    foreach key {workflow_log error_log run_status_csv workflow_status} {
        lappend dirs [file dirname [cfg_path $cfg working $key]]
    }
    foreach d $dirs {
        if {[file isdirectory $d]} {
            continue
        }
        if {[catch {file mkdir $d} err]} {
            error "Cannot create directory $d: $err"
        }
    }
    return
}

# ---------------------------------------------------------------- logging

# timestamp {}
proc ::gsk::common::timestamp {} {
    return [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]
}

# append_line {file text}   (internal helper)
proc ::gsk::common::append_line {file text} {
    if {[catch {open $file a} fh]} {
        error "Cannot open file for append: $file ($fh)"
    }
    set rc [catch {
        fconfigure $fh -encoding utf-8
        puts $fh $text
    } err]
    close $fh
    if {$rc} {
        error "Cannot write to file: $file ($err)"
    }
    return
}

# log {cfg level msg}
proc ::gsk::common::log {cfg level msg} {
    variable log_sink
    set line [format {%s | %-5s | %s} [timestamp] [string toupper $level] $msg]
    if {[get_bool $cfg workflow write_log true]} {
        append_line [cfg_path $cfg working workflow_log] $line
    }
    if {$log_sink ne ""} {
        if {[catch {$log_sink $line} sinkErr]} {
            error "Log sink failed ($log_sink): $sinkErr"
        }
    }
    return $line
}

# error_log {cfg msg}   (always written)
proc ::gsk::common::error_log {cfg msg} {
    set line [format {%s | ERROR | %s} [timestamp] $msg]
    append_line [cfg_path $cfg working error_log] $line
    return $line
}

# write_status {cfg runStatus completedStep errorStep errorMessage}
proc ::gsk::common::write_status {cfg runStatus completedStep errorStep errorMessage} {
    if {![get_bool $cfg workflow write_status true]} {
        return
    }
    set file [cfg_path $cfg working workflow_status]
    set clean [string map [list "\r" " " "\n" " "] $errorMessage]
    if {[catch {open $file w} fh]} {
        error "Cannot open status file: $file ($fh)"
    }
    set rc [catch {
        fconfigure $fh -encoding utf-8
        puts $fh [format {updated=%s} [timestamp]]
        puts $fh [format {run_status=%s} $runStatus]
        puts $fh [format {completed_step=%s} $completedStep]
        puts $fh [format {error_step=%s} $errorStep]
        puts $fh [format {error_message=%s} $clean]
    } err]
    close $fh
    if {$rc} {
        error "Cannot write status file: $file ($err)"
    }
    return
}

# quote_csv {text}
proc ::gsk::common::quote_csv {text} {
    set esc [string map [list \" \"\" "\r" {} "\n" { }] $text]
    return \"$esc\"
}

# append_run_status {cfg stepID stepName status message}
proc ::gsk::common::append_run_status {cfg stepID stepName status message} {
    if {![get_bool $cfg workflow write_status true]} {
        return
    }
    set file [cfg_path $cfg working run_status_csv]
    set needHeader 1
    if {[file exists $file] && [file size $file] > 0} {
        set needHeader 0
    }
    if {[catch {open $file a} fh]} {
        error "Cannot open run status CSV: $file ($fh)"
    }
    set rc [catch {
        fconfigure $fh -encoding utf-8
        if {$needHeader} {
            puts $fh {"timestamp","step_id","step_name","status","message"}
        }
        puts $fh [join [list \
            [quote_csv [timestamp]] \
            [quote_csv $stepID] \
            [quote_csv $stepName] \
            [quote_csv $status] \
            [quote_csv $message]] ,]
    } err]
    close $fh
    if {$rc} {
        error "Cannot write run status CSV: $file ($err)"
    }
    return
}

# require_file {label file}
proc ::gsk::common::require_file {label file} {
    if {![file isfile $file]} {
        error "Required file missing ($label): $file"
    }
    return $file
}

# run_step {cfg stepID stepName body}
# body is a script evaluated in the caller's frame.
proc ::gsk::common::run_step {cfg stepID stepName body} {
    variable last_completed
    set rc [catch {uplevel 1 $body} result]
    if {$rc == 0} {
        append_run_status $cfg $stepID $stepName PASSED {Step completed}
        write_status $cfg running $stepID {} {}
        set last_completed $stepID
        return $result
    }
    if {$rc == 1} {
        set msg $result
    } else {
        set msg [format {Step body ended with unexpected completion code %s} $rc]
    }
    set secondary {}
    if {[catch {error_log $cfg [format {Step %s (%s) FAILED: %s} $stepID $stepName $msg]} e1]} {
        lappend secondary "error_log: $e1"
    }
    if {[catch {append_run_status $cfg $stepID $stepName FAILED $msg} e2]} {
        lappend secondary "append_run_status: $e2"
    }
    if {[catch {write_status $cfg FAILED $last_completed $stepID $msg} e3]} {
        lappend secondary "write_status: $e3"
    }
    if {[llength $secondary] > 0} {
        append msg { (secondary failures: } [join $secondary {; }] {)}
    }
    return -code error -errorcode [list GSK STEP$stepID FAILED] $msg
}
