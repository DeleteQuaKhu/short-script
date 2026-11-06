# _tcl_gsk_02_apply_contact_pressure_legend.tcl
# Step 02: apply a Contact Pressure legend Tcl file to the active HyperView contour.
# Pure Tcl 8.5. Self-contained: works without _tcl_gsk_00_common.tcl loaded.
# Namespace: ::gsk::step02   (every proc is defined exactly once)

namespace eval ::gsk::step02 {
    variable clicks
    if {![info exists clicks]} {
        set clicks 0
    }
}

# next_handle {prefix}
# Unique handle name: <prefix>_<pid>_<clicks>
proc ::gsk::step02::next_handle {prefix} {
    variable clicks
    incr clicks
    return [format {%s_%s_%s} $prefix [pid] $clicks]
}

# log_common {cfg level msg}
# Logs through ::gsk::common::log only if it exists and cfg is not a standalone cfg.
proc ::gsk::step02::log_common {cfg level msg} {
    if {[dict exists $cfg standalone]} {
        return
    }
    if {[llength [info commands ::gsk::common::log]] == 0} {
        return
    }
    ::gsk::common::log $cfg $level $msg
    return
}

# refresh_active_post {}
# Redraws the active HyperView client. Stack and handle are released on every path.
proc ::gsk::step02::refresh_active_post {} {
    set handle [next_handle gsk_step02_post]
    set stackOpen 0
    set handleOpen 0
    set errMsg {}
    set failed [catch {
        hwi OpenStack
        set stackOpen 1
        hwi GetActiveClientHandle $handle
        set handleOpen 1
        $handle Draw
        update idletasks
    } errMsg]
    if {$handleOpen} {
        if {[catch {$handle ReleaseHandle} relErr]} {
            set failed 1
            append errMsg [format { | ReleaseHandle failed for %s: %s} $handle $relErr]
        }
    }
    if {$stackOpen} {
        if {[catch {hwi CloseStack} stackErr]} {
            set failed 1
            append errMsg [format { | CloseStack failed: %s} $stackErr]
        }
    }
    if {$failed} {
        error [format {refresh_active_post failed: %s} $errMsg]
    }
    return
}

# apply_via_settings {legendFile}
# Fallback: source the legend file, then call ::post::LoadSettings with a legend handle.
proc ::gsk::step02::apply_via_settings {legendFile} {
    set legendHandle [next_handle gsk_step02_legend]
    set handleOpen 0
    set errMsg {}
    set failed [catch {
        uplevel #0 [list source $legendFile]
        if {[llength [info commands ::post::LoadSettings]] == 0} {
            error "Legend file did not define ::post::LoadSettings: $legendFile"
        }
        ::hwp::GetContourLegend $legendHandle
        set handleOpen 1
        ::post::LoadSettings $legendHandle
    } errMsg]
    if {$handleOpen} {
        if {[catch {$legendHandle ReleaseHandle} relErr]} {
            set failed 1
            append errMsg [format { | ReleaseHandle failed for %s: %s} $legendHandle $relErr]
        }
    }
    if {$failed} {
        error $errMsg
    }
    return
}

# apply_file {legendFile}
proc ::gsk::step02::apply_file {legendFile} {
    if {[string trim $legendFile] eq ""} {
        error "apply_file: legend file path is empty"
    }
    if {![file isfile $legendFile]} {
        error "Legend file not found: $legendFile"
    }
    set primaryFailed [catch {hwc result scalar legend import $legendFile} primaryErr]
    if {!$primaryFailed} {
        refresh_active_post
        return $legendFile
    }
    if {[llength [info commands ::hwp::GetContourLegend]] == 0} {
        error [format {Cannot apply legend file %s. Primary method (hwc result scalar legend import) failed: %s. Fallback (::hwp::GetContourLegend) is not available in this session.} $legendFile $primaryErr]
    }
    set fallbackFailed [catch {apply_via_settings $legendFile} fallbackErr]
    if {$fallbackFailed} {
        error [format {Cannot apply legend file %s. Primary method (hwc result scalar legend import) failed: %s. Fallback (::hwp::GetContourLegend + ::post::LoadSettings) failed: %s} $legendFile $primaryErr $fallbackErr]
    }
    refresh_active_post
    return $legendFile
}

# run {root cfg}
# Called by the GUI (through common::run_step) or by the standalone footer.
proc ::gsk::step02::run {root cfg} {
    if {[string trim $root] eq ""} {
        error "step02 run: working root folder is empty"
    }
    if {![dict exists $cfg format legend_file]} {
        error "Missing required config value: format legend_file"
    }
    set raw [string trim [dict get $cfg format legend_file]]
    if {$raw eq ""} {
        error "Config value is empty: format legend_file"
    }
    if {[file pathtype $raw] eq "absolute"} {
        set legendFile [file normalize $raw]
    } else {
        set legendFile [file normalize [file join $root $raw]]
    }
    log_common $cfg INFO [format {Applying legend file: %s} $legendFile]
    apply_file $legendFile
    log_common $cfg INFO [format {Legend applied: %s} $legendFile]
    return $legendFile
}

# standalone_main {root}
# Standalone mode: ask for a legend file, apply it, report with tk_messageBox.
proc ::gsk::step02::standalone_main {root} {
    set f [tk_getOpenFile -title {Select Contact Pressure legend Tcl file} \
        -filetypes {{{Tcl files} {.tcl}} {{All files} *}}]
    if {$f eq ""} {
        return
    }
    set cfg [dict create root $root standalone 1 format [dict create legend_file $f]]
    if {[catch {run $root $cfg} err]} {
        tk_messageBox -icon error -type ok -title {Contact Pressure Legend} \
            -message "Failed to apply legend:\n$err"
        return
    }
    tk_messageBox -icon info -type ok -title {Contact Pressure Legend} \
        -message "Legend applied:\n$f"
    return
}

# Footer: standalone mode unless the GUI set ::gsk::run_from_gui.
if {![info exists ::gsk::run_from_gui]} {
    if {[info script] eq ""} {
        ::gsk::step02::standalone_main [pwd]
    } else {
        ::gsk::step02::standalone_main [file dirname [file dirname [file normalize [info script]]]]
    }
}
