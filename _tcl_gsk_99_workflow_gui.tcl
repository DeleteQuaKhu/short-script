# _tcl_gsk_99_workflow_gui.tcl
# Workflow GUI (Tk). Pure Tcl/Tk 8.5.
# Start with:  source <path>/_tcl_gsk_99_workflow_gui.tcl
# Namespace: ::gsk099::gui   (own state; every proc is defined exactly once)

if {[info script] eq ""} {
    error "_tcl_gsk_99_workflow_gui.tcl must be started with source (info script is empty)"
}

namespace eval ::gsk099::gui {
    variable scriptDir [file dirname [file normalize [info script]]]
    variable top .gsk099_workflow
    variable stepID {02}
    variable st
    variable logWidget {}
    variable btnLoad {}
}

set ::gsk099::gui::commonFile [file join $::gsk099::gui::scriptDir _tcl_gsk_00_common.tcl]
if {![file isfile $::gsk099::gui::commonFile]} {
    error "Common script not found: $::gsk099::gui::commonFile"
}
source $::gsk099::gui::commonFile

# ---------------------------------------------------------------- log / dialogs

# append_log {line}  -- also used as ::gsk::common::log_sink
proc ::gsk099::gui::append_log {line} {
    variable logWidget
    if {$logWidget eq "" || ![winfo exists $logWidget]} {
        return
    }
    $logWidget configure -state normal
    $logWidget insert end "$line\n"
    $logWidget see end
    $logWidget configure -state disabled
    update idletasks
    return
}

# gui_log {level msg}  -- GUI-only line (used when no cfg is loaded)
proc ::gsk099::gui::gui_log {level msg} {
    append_log [format {%s | %-5s | %s} [::gsk::common::timestamp] [string toupper $level] $msg]
    return
}

# safe_log {level msg}  -- file + window via common::log when cfg is loaded
proc ::gsk099::gui::safe_log {level msg} {
    variable st
    if {$st(loaded)} {
        if {[catch {::gsk::common::log $st(cfg) $level $msg} err]} {
            gui_log ERROR [format {Logging failed: %s (original message: %s)} $err $msg]
        }
    } else {
        gui_log $level $msg
    }
    return
}

# show_error {title msg}
proc ::gsk099::gui::show_error {title msg} {
    variable top
    tk_messageBox -parent $top -icon error -type ok -title $title -message $msg
    return
}

# report_error {title msg}  -- window log + dialog (no cfg-file logging)
proc ::gsk099::gui::report_error {title msg} {
    gui_log ERROR $msg
    show_error $title $msg
    return
}

# ---------------------------------------------------------------- config / step info

# step_info {cfg stepID}  -> dict file proc title (all from script_<id> in the ini)
proc ::gsk099::gui::step_info {cfg stepID} {
    set section [format {script_%s} $stepID]
    set order [::gsk::common::get $cfg workflow run_order]
    if {[lsearch -exact [string map [list , { }] $order] $stepID] < 0} {
        error "Step $stepID is not listed in config workflow run_order ($order)"
    }
    if {![::gsk::common::get_bool $cfg $section enabled]} {
        error "Step $stepID is disabled in config (section $section, key enabled)"
    }
    return [dict create \
        file [::gsk::common::get $cfg $section file] \
        proc [::gsk::common::get $cfg $section proc] \
        title [::gsk::common::get $cfg $section title]]
}

# reload_config {}
proc ::gsk099::gui::reload_config {} {
    variable st
    set st(loaded) 0
    set st(cfg) {}
    set root [string trim $st(root)]
    if {$root eq ""} {
        report_error {Reload Config} {Working folder is empty.}
        return
    }
    set failed [catch {
        set cfg [::gsk::common::load_config $root]
        ::gsk::common::ensure_directories $cfg
        set legend [::gsk::common::get $cfg format legend_file]
    } err]
    if {$failed} {
        report_error {Reload Config} [format {Config load failed for working folder %s: %s} $root $err]
        return
    }
    set st(cfg) $cfg
    set st(legend) $legend
    set st(loaded) 1
    safe_log INFO [format {Config loaded: %s} [dict get $cfg config_file]]
    return
}

# ---------------------------------------------------------------- actions

# browse_root {}
proc ::gsk099::gui::browse_root {} {
    variable st
    variable top
    set opts [list -parent $top -title {Select working root folder}]
    if {[file isdirectory $st(root)]} {
        lappend opts -initialdir $st(root)
    }
    set d [tk_chooseDirectory {*}$opts]
    if {$d ne ""} {
        set st(root) $d
    }
    return
}

# browse_legend {}  -- updates ONLY the in-memory override of cfg format legend_file
proc ::gsk099::gui::browse_legend {} {
    variable st
    variable top
    set opts [list -parent $top -title {Select Contact Pressure legend Tcl file} \
        -filetypes {{{Tcl files} {.tcl}} {{All files} *}}]
    set cur [string trim $st(legend)]
    if {$cur ne ""} {
        if {[file pathtype $cur] eq "absolute"} {
            set full $cur
        } else {
            set full [file join $st(root) $cur]
        }
        set dir [file dirname $full]
        if {[file isdirectory $dir]} {
            lappend opts -initialdir $dir
        }
    }
    set f [tk_getOpenFile {*}$opts]
    if {$f eq ""} {
        return
    }
    set st(legend) $f
    if {$st(loaded)} {
        dict set st(cfg) format legend_file $f
    }
    safe_log INFO [format {Legend override set (memory only, ini not modified): %s} $f]
    return
}

# on_load {}  -- "Load Legend" button
proc ::gsk099::gui::on_load {} {
    variable st
    variable stepID
    variable btnLoad

    if {!$st(loaded)} {
        report_error {Load Legend} {Config is not loaded. Click Reload Config first.}
        return
    }
    set legend [string trim $st(legend)]
    if {$legend eq ""} {
        report_error {Load Legend} {Legend file path is empty. Use Browse Legend or type a path.}
        return
    }
    dict set st(cfg) format legend_file $legend
    set cfg $st(cfg)
    set root [dict get $cfg root]
    set title $stepID

    $btnLoad state disabled
    set ::gsk::run_from_gui 1
    set failed [catch {
        ::gsk::common::ensure_directories $cfg
        set info [step_info $cfg $stepID]
        set title [dict get $info title]
        set procName [dict get $info proc]
        set stepFile [::gsk::common::require_file {step script} \
            [file join [::gsk::common::cfg_path $cfg folders script_dir] [dict get $info file]]]
        safe_log INFO [format {Step %s started: %s (legend: %s)} $stepID $title $legend]
        uplevel #0 [list source $stepFile]
        if {[llength [info commands $procName]] == 0} {
            error "Step proc not found after sourcing $stepFile: $procName"
        }
        ::gsk::common::run_step $cfg $stepID $title [list $procName $root $cfg]
    } err]
    unset -nocomplain ::gsk::run_from_gui
    $btnLoad state !disabled

    if {$failed} {
        safe_log ERROR [format {Step %s (%s) failed: %s} $stepID $title $err]
        show_error {Load Legend} $err
        return
    }
    safe_log INFO [format {Step %s finished: %s} $stepID $title]
    return
}

# on_destroy {w}
proc ::gsk099::gui::on_destroy {w} {
    variable top
    variable logWidget
    if {$w eq $top} {
        set ::gsk::common::log_sink {}
        set logWidget {}
    }
    return
}

# ---------------------------------------------------------------- launch

# launch {}  -- builds .gsk099_workflow; default root = parent of the scripts folder
proc ::gsk099::gui::launch {} {
    variable top
    variable st
    variable scriptDir
    variable logWidget
    variable btnLoad

    if {[winfo exists $top]} {
        destroy $top
    }
    array unset st
    array set st [list root [file dirname $scriptDir] legend {} loaded 0 cfg {}]

    toplevel $top
    wm title $top {GSK Workflow - Contact Pressure Legend}
    wm minsize $top 680 380
    set f $top.f
    ttk::frame $f -padding 8
    pack $f -fill both -expand 1

    ttk::label $f.lroot -text {Working folder:}
    ttk::entry $f.eroot -textvariable ::gsk099::gui::st(root)
    ttk::button $f.broot -text Browse -command ::gsk099::gui::browse_root
    ttk::button $f.breload -text {Reload Config} -command ::gsk099::gui::reload_config
    ttk::label $f.llegend -text {Legend file:}
    ttk::entry $f.elegend -textvariable ::gsk099::gui::st(legend)
    ttk::button $f.blegend -text {Browse Legend} -command ::gsk099::gui::browse_legend
    ttk::button $f.bload -text {Load Legend} -command ::gsk099::gui::on_load
    text $f.log -height 14 -wrap word -state disabled
    ttk::scrollbar $f.sb -orient vertical -command [list $f.log yview]
    $f.log configure -yscrollcommand [list $f.sb set]

    grid $f.lroot -row 0 -column 0 -sticky w -padx 2 -pady 2
    grid $f.eroot -row 0 -column 1 -sticky ew -padx 2 -pady 2
    grid $f.broot -row 0 -column 2 -padx 2 -pady 2
    grid $f.breload -row 0 -column 3 -padx 2 -pady 2
    grid $f.llegend -row 1 -column 0 -sticky w -padx 2 -pady 2
    grid $f.elegend -row 1 -column 1 -sticky ew -padx 2 -pady 2
    grid $f.blegend -row 1 -column 2 -columnspan 2 -sticky w -padx 2 -pady 2
    grid $f.bload -row 2 -column 1 -sticky w -padx 2 -pady 4
    grid $f.log -row 3 -column 0 -columnspan 4 -sticky nsew -padx 2 -pady 2
    grid $f.sb -row 3 -column 4 -sticky ns -pady 2
    grid columnconfigure $f 1 -weight 1
    grid rowconfigure $f 3 -weight 1

    set logWidget $f.log
    set btnLoad $f.bload
    set ::gsk::common::log_sink ::gsk099::gui::append_log
    bind $top <Destroy> {::gsk099::gui::on_destroy %W}

    update idletasks
    gui_log INFO [format {GUI started. Scripts folder: %s} $scriptDir]
    reload_config
    return
}

::gsk099::gui::launch
