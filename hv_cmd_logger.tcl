#=============================================================================
#  hv_cmd_logger.tcl
#  HyperView 2022 - live "what did I just click?" command logger.
#
#  WHAT IT DOES
#    While you work in the HyperView GUI, HyperView writes the command it
#    performs into its own command file: that is exactly what its Command
#    Window shows.  This tool watches that file and mirrors every new line
#    into a log window of its own, in real time.  Selecting entities, turning
#    the model, applying a contour, loading a loadcase, measuring, hiding
#    parts - every action shows up as the Tcl / hwi command it consists of.
#    The same lines are written into a replayable *.tcl script (plus a raw
#    *.raw.cmf mirror), so a clicked-together session becomes a macro.
#
#  HOW TO START (inside HyperView, Tcl console / command line)
#      source hv_cmd_logger.tcl
#      ::HvCmdLog::Show         ;# opens the log window (also: hvlogShow)
#      ::HvCmdLog::Start        ;# console only, no window
#      ::HvCmdLog::Stop         ;# stop filling the log
#
#  WHERE THE COMMANDS COME FROM (three taps, each one can be switched off)
#    1. THE HYPERVIEW COMMAND FILE (*.cmf) - this is the GUI stream.  The path
#       is auto-detected (V1) and may be typed or browsed in the window.  The
#       file is read incrementally (byte offset), so nothing is read twice; a
#       rewritten / truncated file is detected and read from the start again.
#    2. THE HYPERVIEW RECORDER API - probed once at 'Start' (V2).  If the build
#       has a session method that switches the command file on (and / or one
#       that reports its path), it is used; a refused candidate is only
#       reported, never fatal.
#    3. THE BUILT-IN 'hwi' TCL COMMAND - renamed and wrapped (V3).  Every
#       'hwi ...' call from a script or from the console is logged too, and it
#       is still evaluated in the CALLER's frame, so handles created by e.g.
#       'hwi GetSessionHandle sess' stay visible to the caller as before.
#
#  LAYERS (single file, clearly separated - same layout as hv_model_loader.tcl)
#     SECTION 0  BOOTSTRAP         - what this interpreter offers (hwtk? hwi?)
#     SECTION 1  STATE / LOGIC     - pure Tcl, no hwi, no file I/O, no hwtk
#     SECTION 2  HYPERVIEW ADAPTER - the ONLY place that calls hwi and the only
#                                    place that touches the file system
#     SECTION 3  CORE              - poll loop + the one exit of a logged line
#     SECTION 4  UI                - hwtk widgets, calls core / logic / adapter
#     SECTION 5  PUBLIC ENTRY      - Start / Stop / Show + the hvlog* commands
#
#  DEBUG  : set ::HvCmdLog::debug 1  -> every adapter step is printed to the
#           Tcl console.
#
#  --- hwi commands used ------------------------------------------------------
#     OpenStack, CloseStack, GetSessionHandle
#     <session>  the probe candidates of Logic::ProbeCandidates:
#                GetCommandFileName, SetCommandFileStatus 1, SetCommandFileStatus 2,
#                CaptureCommandsOn, CaptureCommands 1, SetCommandFile <path>
#                (every single one inside catch - V2)
#     The logger NEVER drives a view / result / contour object: it is a
#     read-only observer of the command stream.
#
#  --- "# VERIFY:" list (each item degrades instead of failing) --------------
#     V1  the command file: NAME and LOCATION.  HyperWorks writes 'command.cmf'
#         into the working directory; the logger therefore searches
#         <cwd>, $TEMP, $TMP, $HOME, $USERPROFILE for '*.cmf' and picks the
#         newest 'command.cmf', else the newest '*.cmf', else the first possible
#         place (which is then only watched until it appears).  A build that
#         uses another name / folder is handled by typing or browsing the file
#         in the window - discovery is a convenience, never a requirement.
#     V2  the recorder API method names.  Not one of them could be confirmed
#         for 2022, so they are PROBED: 'GetCommandFileName' first (it delivers
#         the path), then the switches.  An unknown method is refused by
#         HyperView and reported as 'refused'; the console mode keeps working
#         with the file / 'hwi' taps alone.
#     V3  'rename ::hwi ::HvCmdLog::hwiReal' + a 'proc hwi'.  Standard Tcl; if
#         a build refuses the rename the tap is skipped ('not available') and
#         nothing else changes.  'Stop' puts the original command back.
#     V4  real-time appending: the file is polled (default 400 ms).  A build
#         that buffers the command file shows the lines later - lower the poll
#         interval, or save the session (both is safe, the offset prevents
#         duplicates).
#     V5  hwtk::toplevel.  If the build has no hwtk::toplevel (or it refuses
#         '-title') the window falls back to a plain Tk toplevel - the only
#         place a plain toplevel is used.
#     V6  the command language of the command file: HyperView writes hwi / Tcl
#         commands into it (that is what its Command Window shows).  A build
#         that writes its own command language instead is still mirrored - the
#         log simply shows that language, and replay then needs the same build.
#
#  --- no external dependency -------------------------------------------------
#     Plain Tcl + Tk + hwtk.  This single file is all the tool needs.
#=============================================================================

#=============================================================================
# SECTION 0 - BOOTSTRAP
#=============================================================================
namespace eval ::HvCmdLog {
    # Master debug switch: exactly the requested ::HvCmdLog::debug
    variable debug 0
    # 'after' id of the poll loop (see SchedulePoll / Stop)
    variable pollToken ""
    # 1 = the hwtk widgets the log window needs are all there
    variable hasHwtk 0
}
# Debug logger - silent unless ::HvCmdLog::debug is set to 1.
proc ::HvCmdLog::Log {msg} {
    if {![info exists ::HvCmdLog::debug] || !$::HvCmdLog::debug} { return }
    catch { puts "\[HvCmdLog\] $msg" }
    catch { flush stdout }
    return
}
# Checks what the interpreter really offers.  Never throws: the console mode
# (Start / Stop) needs no widget at all, only Show does.
proc ::HvCmdLog::Bootstrap {} {
    foreach pkg {hwt hwtk} {
        if {[catch {package require $pkg} msg]} {
            ::HvCmdLog::Log "NOTE: 'package require $pkg' failed: $msg"
        }
    }
    # NOTE: the check must use the FULLY QUALIFIED name (::hwtk::...), a plain
    # 'hwtk::frame' pattern is resolved against the current namespace (here
    # ::HvCmdLog) and would report every command as missing.
    set missing {}
    # 'combobox' is NOT required: the poll interval control falls back to an
    # entry of its own (see UI::MakePollChooser), so the window can be built
    # with the five widgets every hwtk build has.
    foreach cmd {frame label button entry checkbutton labelframe} {
        if {[llength [info commands ::hwtk::$cmd]] == 0} { lappend missing hwtk::$cmd }
    }
    set ::HvCmdLog::hasHwtk [expr {[llength $missing] == 0}]
    if {!$::HvCmdLog::hasHwtk} {
        ::HvCmdLog::Log "NOTE: hwtk is incomplete ($missing) - the log window needs it,\
 the console mode (Start / Stop) does not."
    }
    if {[llength [info commands ::hwtk::combobox]] == 0} {
        ::HvCmdLog::Log "NOTE: no hwtk::combobox - the poll interval becomes a plain entry."
    }
    if {[llength [info commands ::hwtk::toplevel]] == 0} {
        # V5 - VERIFY: hwtk::toplevel is used when it exists, otherwise UI
        #     falls back to a plain Tk toplevel.
        ::HvCmdLog::Log "NOTE: no hwtk::toplevel - the window falls back to plain Tk."
    }
    return $::HvCmdLog::hasHwtk
}

#=============================================================================
# SECTION 1 - STATE / LOGIC LAYER  (pure Tcl - NO hwi, NO file I/O, NO hwtk)
#   Every value the tool keeps, plus every decision that can be decided on
#   plain data (candidate paths, read plans, line splitting, noise filter,
#   script text).  Because nothing here touches HyperView or the disk, the
#   pure selftest can exercise all of it in a normal interpreter.
#=============================================================================
namespace eval ::HvCmdLog::State {
    # The command file that is watched ("" = not known yet, autodetect runs).
    variable commandFile ""
    # Where the path came from: user | hwi-api | auto | auto-pending (V1/V2)
    variable commandFileSource ""
    # Bytes already read from commandFile + the trailing incomplete line
    variable offset 0
    variable partial ""
    # Captured command lines (what the log window shows) + the counters
    variable lines {}
    variable countRaw 0
    variable countHidden 0
    # Poll loop
    variable polling 0
    variable pollInterval 400
    # Switches, mirrored by the checkboxes of the window
    variable hideNoise 1
    variable echoConsole 0
    variable tapHwi 1
    variable writeScript 1
    variable stampLines 0
    # The two files the tool writes
    variable scriptDir ""
    variable scriptFile ""
    variable rawFile ""
    variable maxLines 5000
    # Status / error reporting
    variable lastError ""
    variable status ""
    variable probeReport {}
    # 1 = the "nothing to watch yet" note is already in the log.  The poll runs
    # every few hundred ms, so the note about a missing file must be written
    # ONCE and not once per poll.
    variable waitReported 0
    # 1 while the tool itself talks to hwi -> the 'hwi' tap stays quiet then
    variable inToolCall 0
    # 1 while the built-in 'hwi' command is renamed away (V3)
    variable tapInstalled 0
}
#--------------------------------------------------------------- command file --
proc ::HvCmdLog::State::SetCommandFile {path {source {}}} {
    set ::HvCmdLog::State::commandFile $path
    if {$source ne ""} { set ::HvCmdLog::State::commandFileSource $source }
    return $path
}
proc ::HvCmdLog::State::GetCommandFile {} { return $::HvCmdLog::State::commandFile }
proc ::HvCmdLog::State::GetCommandFileSource {} {
    return $::HvCmdLog::State::commandFileSource
}
proc ::HvCmdLog::State::SetOffset {v} { set ::HvCmdLog::State::offset $v ; return $v }
proc ::HvCmdLog::State::GetOffset {} { return $::HvCmdLog::State::offset }
proc ::HvCmdLog::State::SetPartial {v} { set ::HvCmdLog::State::partial $v ; return $v }
proc ::HvCmdLog::State::GetPartial {} { return $::HvCmdLog::State::partial }
# Used when the watched file disappeared or the user picks another one: the
# next read starts at the beginning of the new file.
proc ::HvCmdLog::State::ForgetFile {} {
    set ::HvCmdLog::State::commandFile ""
    set ::HvCmdLog::State::commandFileSource ""
    set ::HvCmdLog::State::offset 0
    set ::HvCmdLog::State::partial ""
    # The next search may find nothing again - that note is worth repeating.
    set ::HvCmdLog::State::waitReported 0
    return
}
#------------------------------------------------------------------- buffer ----
proc ::HvCmdLog::State::SetLines {v} { set ::HvCmdLog::State::lines $v ; return }
proc ::HvCmdLog::State::GetLines {} { return $::HvCmdLog::State::lines }
proc ::HvCmdLog::State::AddLines {newLines} {
    set ::HvCmdLog::State::lines [::HvCmdLog::Logic::AppendBounded \
        $::HvCmdLog::State::lines $newLines $::HvCmdLog::State::maxLines]
    return $::HvCmdLog::State::lines
}
proc ::HvCmdLog::State::ClearLines {} { set ::HvCmdLog::State::lines {} ; return }
proc ::HvCmdLog::State::AddCounts {raw hidden} {
    incr ::HvCmdLog::State::countRaw $raw
    incr ::HvCmdLog::State::countHidden $hidden
    return
}
proc ::HvCmdLog::State::ResetCounts {} {
    set ::HvCmdLog::State::countRaw 0
    set ::HvCmdLog::State::countHidden 0
    return
}
proc ::HvCmdLog::State::GetCountRaw {} { return $::HvCmdLog::State::countRaw }
proc ::HvCmdLog::State::GetCountHidden {} { return $::HvCmdLog::State::countHidden }
proc ::HvCmdLog::State::GetCountCaptured {} {
    return [expr {$::HvCmdLog::State::countRaw - $::HvCmdLog::State::countHidden}]
}
#------------------------------------------------------------------ switches ---
proc ::HvCmdLog::State::SetPolling {v} { set ::HvCmdLog::State::polling $v ; return $v }
proc ::HvCmdLog::State::GetPolling {} { return $::HvCmdLog::State::polling }
proc ::HvCmdLog::State::SetPollInterval {v} {
    set ::HvCmdLog::State::pollInterval $v ; return $v
}
proc ::HvCmdLog::State::GetPollInterval {} { return $::HvCmdLog::State::pollInterval }
proc ::HvCmdLog::State::SetHideNoise {v} { set ::HvCmdLog::State::hideNoise $v ; return }
proc ::HvCmdLog::State::GetHideNoise {} { return $::HvCmdLog::State::hideNoise }
proc ::HvCmdLog::State::SetEchoConsole {v} { set ::HvCmdLog::State::echoConsole $v ; return }
proc ::HvCmdLog::State::GetEchoConsole {} { return $::HvCmdLog::State::echoConsole }
proc ::HvCmdLog::State::SetTapHwi {v} { set ::HvCmdLog::State::tapHwi $v ; return }
proc ::HvCmdLog::State::GetTapHwi {} { return $::HvCmdLog::State::tapHwi }
proc ::HvCmdLog::State::SetWriteScript {v} { set ::HvCmdLog::State::writeScript $v ; return }
proc ::HvCmdLog::State::GetWriteScript {} { return $::HvCmdLog::State::writeScript }
proc ::HvCmdLog::State::SetStampLines {v} { set ::HvCmdLog::State::stampLines $v ; return }
proc ::HvCmdLog::State::GetStampLines {} { return $::HvCmdLog::State::stampLines }
proc ::HvCmdLog::State::SetMaxLines {v} { set ::HvCmdLog::State::maxLines $v ; return }
proc ::HvCmdLog::State::GetMaxLines {} { return $::HvCmdLog::State::maxLines }
#---------------------------------------------------------------- the files ----
proc ::HvCmdLog::State::SetScriptDir {v} { set ::HvCmdLog::State::scriptDir $v ; return }
proc ::HvCmdLog::State::GetScriptDir {} { return $::HvCmdLog::State::scriptDir }
proc ::HvCmdLog::State::SetScriptFile {v} { set ::HvCmdLog::State::scriptFile $v ; return }
proc ::HvCmdLog::State::GetScriptFile {} { return $::HvCmdLog::State::scriptFile }
proc ::HvCmdLog::State::SetRawFile {v} { set ::HvCmdLog::State::rawFile $v ; return }
proc ::HvCmdLog::State::GetRawFile {} { return $::HvCmdLog::State::rawFile }
#---------------------------------------------------------------- reporting ----
proc ::HvCmdLog::State::SetLastError {msg} { set ::HvCmdLog::State::lastError $msg ; return }
proc ::HvCmdLog::State::GetLastError {} { return $::HvCmdLog::State::lastError }
proc ::HvCmdLog::State::ClearLastError {} { set ::HvCmdLog::State::lastError "" ; return }
proc ::HvCmdLog::State::SetStatus {text} { set ::HvCmdLog::State::status $text ; return }
proc ::HvCmdLog::State::GetStatus {} { return $::HvCmdLog::State::status }
proc ::HvCmdLog::State::SetProbeReport {lines} { set ::HvCmdLog::State::probeReport $lines ; return }
proc ::HvCmdLog::State::GetProbeReport {} { return $::HvCmdLog::State::probeReport }
proc ::HvCmdLog::State::SetWaitReported {v} { set ::HvCmdLog::State::waitReported $v ; return }
proc ::HvCmdLog::State::GetWaitReported {} { return $::HvCmdLog::State::waitReported }
#---------------------------------------------------------------- tap guard ----
proc ::HvCmdLog::State::SetInToolCall {v} { set ::HvCmdLog::State::inToolCall $v ; return }
proc ::HvCmdLog::State::GetInToolCall {} { return $::HvCmdLog::State::inToolCall }
proc ::HvCmdLog::State::SetTapInstalled {v} { set ::HvCmdLog::State::tapInstalled $v ; return }
proc ::HvCmdLog::State::GetTapInstalled {} { return $::HvCmdLog::State::tapInstalled }

#=============================================================================
# SECTION 1b - LOGIC  (pure decisions, no side effect at all)
#=============================================================================
namespace eval ::HvCmdLog::Logic {
    # V1 - VERIFY: the name a HyperWorks command file has.  'command.cmf' is the
    #     one HyperMesh / HyperView write; it is searched first, a newer '*.cmf'
    #     of another name is only a fallback (the file can always be chosen by
    #     hand in the window).
    variable commandFileNames {command.cmf}
    # The directories that are searched, in this order (see State::commandFile).
    variable envKeys {cwd temp tmp home profile}
    # V1 - VERIFY: markers a command file may carry around the real commands.
    #     They are not commands and would only pollute the log and a replay.
    variable noisePatterns {
        {^\*(begin|end)(\s|$)}
        {^\*commandfile\w*}
        {^\*(codestart|codeend)(\s|$)}
    }
    # The script that is written while recording.
    variable scriptPrefix hv_cmdlog
    # The line that is shown when the file is rewritten while it is being read.
    variable truncateMarker "# --- command file was rewritten - reading it from the start again ---"
    # What to check when there is nothing to watch yet.
    variable noFileHintLines {
        {# hv_cmd_logger: no command file found yet - what to check:}
        {#   1. do something in the HyperView GUI (turn the model, pick an entity,}
        {#      change a contour) - HyperView writes the command into its command}
        {#      file as soon as it performs it;}
        {#   2. if HyperView keeps its command file somewhere else, type or Browse}
        {#      the path into the 'Command file' field above;}
        {#   3. the Tcl tap keeps logging every 'hwi ...' call of a script anyway.}
    }
}
#--------------------------------------------- file names and locations -------
# The names a command file can have in this tool (offered by the Browse button
# as well).
proc ::HvCmdLog::Logic::CommandFileNames {} {
    return $::HvCmdLog::Logic::commandFileNames
}
# Builds the environment dict the search works on.  Kept pure on purpose: the
# adapter reads the real variables and hands them over, a test hands over
# anything it likes.
proc ::HvCmdLog::Logic::EnvFrom {cwd temp tmp home profile} {
    return [dict create cwd $cwd temp $temp tmp $tmp home $home profile $profile]
}
# The directories of the search, in order, normalised to '/' and free of
# duplicates.  Empty entries are dropped.
proc ::HvCmdLog::Logic::CommandFileDirs {env} {
    set out {}
    foreach key $::HvCmdLog::Logic::envKeys {
        if {![dict exists $env $key]} { continue }
        set d [string trim [dict get $env $key]]
        if {$d eq ""} { continue }
        set d [string map [list "\\" "/"] $d]
        if {[lsearch -exact $out $d] < 0} { lappend out $d }
    }
    return $out
}
# Every plausible path, in the order of CommandFileDirs.
proc ::HvCmdLog::Logic::CommandFileCandidates {env} {
    set out {}
    foreach d [::HvCmdLog::Logic::CommandFileDirs $env] {
        set base [string trimright $d "/"]
        foreach name $::HvCmdLog::Logic::commandFileNames {
            lappend out "${base}/$name"
        }
    }
    return $out
}
# Is this file tail the command file HyperView writes (V1)?
proc ::HvCmdLog::Logic::IsCommandFileName {tail} {
    return [expr {[lsearch -exact $::HvCmdLog::Logic::commandFileNames \
        [string tolower $tail]] >= 0 ? 1 : 0}]
}
# Picks the file to watch out of the probed candidates.
#   entries : list of dicts, each with the keys
#             path       - the full path
#             mtime      - 'file mtime' or -1 when the file does not exist
#             exact      - 1 when the tail is one of CommandFileNames
#             dirExists  - 1 when the folder of the path exists
# Order of preference (V1):
#   1. the newest EXISTING command file,
#   2. the newest EXISTING '*.cmf' of any name,
#   3. the first possible location of the command file (which is then only
#      watched until it appears),
#   4. nothing -> "".
proc ::HvCmdLog::Logic::PickCommandFile {entries} {
    set bestExact ""
    set bestAny ""
    set firstPossible ""
    foreach e $entries {
        if {![dict exists $e path]} { continue }
        set path [dict get $e path]
        set mtime [expr {[dict exists $e mtime] ? [dict get $e mtime] : -1}]
        if {$mtime >= 0} {
            if {$bestAny eq "" || $mtime > [dict get $bestAny mtime]} {
                set bestAny [dict create path $path mtime $mtime]
            }
            if {[dict exists $e exact] && [dict get $e exact]} {
                if {$bestExact eq "" || $mtime > [dict get $bestExact mtime]} {
                    set bestExact [dict create path $path mtime $mtime]
                }
            }
        } elseif {$firstPossible eq "" && [dict exists $e exact] && \
                [dict exists $e dirExists] && [dict get $e dirExists]} {
            set firstPossible $path
        }
    }
    if {$bestExact ne ""} { return [dict get $bestExact path] }
    if {$bestAny ne ""} { return [dict get $bestAny path] }
    return $firstPossible
}
#--------------------------------------------- incremental reading -------------
# What to read next, decided on two numbers only.
#   action none  - nothing new
#   action reset - the file is SHORTER than what was read: it was rewritten or
#                  truncated, start over at byte 0
#   action read  - read 'length' bytes from 'start'
proc ::HvCmdLog::Logic::ReadPlan {offset size} {
    if {$size < 0} { return [dict create action none start 0 length 0] }
    if {$size < $offset} {
        return [dict create action reset start 0 length $size]
    }
    if {$size == $offset} {
        return [dict create action none start $offset length 0]
    }
    return [dict create action read start $offset length [expr {$size - $offset}]]
}
# Turns a chunk of file text into complete lines.  'partial' is the tail of the
# previous chunk, the returned 'rest' is the tail of this one (handed back next
# time).  A CRLF that is split between two chunks is joined before the split,
# so a chunk boundary never produces a line of its own.
proc ::HvCmdLog::Logic::Feed {partial chunk} {
    set data "$partial$chunk"
    regsub -all {\r\n} $data "\n" data
    set parts [split $data "\n"]
    set rest [lindex $parts end]
    set out {}
    foreach line [lrange $parts 0 end-1] {
        lappend out [string map [list "\r" ""] $line]
    }
    return [dict create lines $out rest $rest]
}
proc ::HvCmdLog::Logic::TruncateMarker {} {
    return $::HvCmdLog::Logic::truncateMarker
}
#--------------------------------------------- noise filter -------------------
# V1 - VERIFY: a line that is not a command (blank, a *begin / *end marker, a
#     '*commandfile...' switch).  Only the DISPLAY and the script are filtered,
#     the raw mirror keeps everything.
proc ::HvCmdLog::Logic::IsNoise {line} {
    set t [string trim $line]
    if {$t eq ""} { return 1 }
    foreach pat $::HvCmdLog::Logic::noisePatterns {
        if {[regexp $pat $t]} { return 1 }
    }
    return 0
}
# Splits lines into the ones to show plus a counter of the hidden ones.
proc ::HvCmdLog::Logic::FilterLines {lines hideNoise} {
    set kept {}
    set hidden 0
    foreach line $lines {
        if {$hideNoise && [::HvCmdLog::Logic::IsNoise $line]} {
            incr hidden
            continue
        }
        lappend kept $line
    }
    return [dict create kept $kept hidden $hidden]
}
# Appends to a bounded buffer: only the newest 'max' lines are kept (max <= 0
# means no limit).
proc ::HvCmdLog::Logic::AppendBounded {old newLines max} {
    set out [concat $old $newLines]
    if {$max > 0 && [llength $out] > $max} {
        set first [expr {[llength $out] - $max}]
        set out [lrange $out $first end]
    }
    return $out
}
#--------------------------------------------- small helpers ------------------
# The poll interval the window offers.  Anything that is not a plausible number
# of milliseconds falls back to the default instead of hammering the file.
proc ::HvCmdLog::Logic::ValidInterval {value {default 400}} {
    set v [string trim $value]
    if {![string is integer -strict $v]} { return $default }
    if {$v < 50} { return $default }
    return $v
}
proc ::HvCmdLog::Logic::PollIntervals {} {
    return [list 100 200 400 1000 2000]
}
proc ::HvCmdLog::Logic::NoFileHint {} {
    return $::HvCmdLog::Logic::noFileHintLines
}
proc ::HvCmdLog::Logic::WaitingStatus {file} {
    if {$file eq ""} { return "no command file found yet - see the hints in the log" }
    return "waiting for $file to appear"
}
# The status line: line counters plus how far the file has been read.
proc ::HvCmdLog::Logic::SummaryLine {file captured hidden offset} {
    if {$file eq ""} { return "no command file found yet - see the hints in the log" }
    set text "$captured lines captured"
    if {$hidden > 0} { append text " ($hidden hidden as noise)" }
    return "$text  |  read up to byte $offset of $file"
}
#--------------------------------------------- time stamps --------------------
proc ::HvCmdLog::Logic::ShortTime {clockSeconds} {
    return [clock format $clockSeconds -format "%H:%M:%S"]
}
proc ::HvCmdLog::Logic::TimeStamp {clockSeconds} {
    return [clock format $clockSeconds -format "%Y-%m-%d %H:%M:%S"]
}
# File safe stamp, e.g. 20261015_140321
proc ::HvCmdLog::Logic::StampName {clockSeconds} {
    return [clock format $clockSeconds -format "%Y%m%d_%H%M%S"]
}
#--------------------------------------------- the replay script --------------
proc ::HvCmdLog::Logic::ScriptName {stamp} {
    return "${::HvCmdLog::Logic::scriptPrefix}_${stamp}.tcl"
}
proc ::HvCmdLog::Logic::RawName {stamp} {
    return "${::HvCmdLog::Logic::scriptPrefix}_${stamp}.raw.cmf"
}
# Where the script is written when the user did not say.  The directory test is
# passed in as a command ('file isdirectory' by default) so the function stays
# free of side effects and can be tested with plain data.
proc ::HvCmdLog::Logic::DefaultScriptDir {cwd temp {isDirCmd {file isdirectory}}} {
    foreach d [list [string trim $cwd] [string trim $temp]] {
        if {$d eq ""} { continue }
        if {[catch {$isDirCmd $d} ok]} { continue }
        if {$ok} { return $d }
    }
    return "."
}
# The comment block the script starts with.  It explains what the lines are and
# how to replay them; the captured lines are NOT wrapped into 'hwi OpenStack' /
# 'hwi CloseStack' because a command file normally brings its own pair.
proc ::HvCmdLog::Logic::ScriptHeader {commandFile stamp} {
    if {$commandFile eq ""} {
        set where "(command file unknown)"
    } else {
        set where $commandFile
    }
    return [list \
        "#=============================================================================" \
        "# hv_cmd_logger.tcl - captured HyperView command log" \
        "# source     : $where" \
        "# started at : $stamp" \
        "#" \
        "# The lines below are what HyperView wrote into its command file (blank" \
        "# lines and *begin / *end markers filtered out).  Replay them inside" \
        "# HyperView with:" \
        "#     source <this file>          ;# Tcl console" \
        "# A command file normally carries its own 'hwi OpenStack' / 'hwi CloseStack'" \
        "# pair - if this one does not, wrap the replay in that pair yourself." \
        "#============================================================================="]
}
# Header lines + captured lines as one text block.
proc ::HvCmdLog::Logic::WrapScript {lines commandFile stamp} {
    set out [::HvCmdLog::Logic::ScriptHeader $commandFile $stamp]
    foreach line $lines { lappend out $line }
    return [join $out "\n"]
}
#--------------------------------------------- the 'hwi' tap ------------------
# One Tcl command line built from already split words, quoted only where Tcl
# needs it ("hwi GetSessionHandle sess" stays readable, a path with a space
# becomes {C:/my dir/x.cmf}).  The result is valid Tcl AND printable as is.
proc ::HvCmdLog::Logic::QuotedLine {words} {
    return [list {*}$words]
}
#--------------------------------------------- the recorder probe (V2) --------
# label / method / args.  Called on the session handle of a temporary
# OpenStack; '__FILE__' is replaced by the command file that was found, and a
# candidate that needs that file is skipped while it is still unknown.
proc ::HvCmdLog::Logic::ProbeCandidates {} {
    return [list \
        [list "session GetCommandFileName"     GetCommandFileName     {}] \
        [list "session SetCommandFileStatus 1" SetCommandFileStatus   {1}] \
        [list "session SetCommandFileStatus 2" SetCommandFileStatus   {2}] \
        [list "session CaptureCommandsOn"      CaptureCommandsOn      {}] \
        [list "session CaptureCommands 1"      CaptureCommands       {1}] \
        [list "session SetCommandFile <file>"  SetCommandFile        {__FILE__}]]
}
proc ::HvCmdLog::Logic::NeedsFileArg {argList} {
    return [expr {[lsearch -exact $argList __FILE__] >= 0 ? 1 : 0}]
}
proc ::HvCmdLog::Logic::SubstituteFileArg {argList file} {
    if {$file eq ""} { return $argList }
    return [string map [list __FILE__ $file] $argList]
}

#=============================================================================
# SECTION 2 - HYPERVIEW ADAPTER
#   The ONLY layer that speaks to hwi, that touches the disk and that keeps the
#   file channels.  Nothing here builds a widget, nothing here decides what is
#   noise.  Every hwi call the tool makes is wrapped by ToolRun / TryCall, which
#   switch the 'hwi' tap off for the duration, so the tool's own housekeeping
#   can never appear in the log it produces.
#=============================================================================
namespace eval ::HvCmdLog::Adapter {
    # Handle name of the temporary OpenStack used by the probe (V2).  Fixed, so
    # a half finished probe can always be released again.
    variable probeHandle hvclSess
    # Channels of the two files the tool writes ("" = not open).
    variable scriptChan ""
    variable rawChan ""
    variable scriptStamp ""
}
#--------------------------------------------- talking to hwi -----------------
# Runs one hwi call for the tool itself.  Returns 1 on failure (the caller may
# continue - nothing the logger does is allowed to be fatal).
proc ::HvCmdLog::Adapter::ToolRun {label script} {
    set prev [::HvCmdLog::State::GetInToolCall]
    ::HvCmdLog::State::SetInToolCall 1
    set code [catch {uplevel 1 $script} result]
    ::HvCmdLog::State::SetInToolCall $prev
    if {$code} {
        ::HvCmdLog::State::SetLastError "$label: $result"
        ::HvCmdLog::Log "$label failed: $result"
    } else {
        ::HvCmdLog::State::ClearLastError
        ::HvCmdLog::Log "$label ok"
    }
    return $code
}
# Same, but the RETURN VALUE of the call matters (the probe needs it, e.g. for
# GetCommandFileName).  Returns a dict: ok / value / error.
proc ::HvCmdLog::Adapter::TryCall {label script} {
    set prev [::HvCmdLog::State::GetInToolCall]
    ::HvCmdLog::State::SetInToolCall 1
    set code [catch {uplevel 1 $script} value]
    ::HvCmdLog::State::SetInToolCall $prev
    if {$code} {
        ::HvCmdLog::Log "$label refused: $value"
        return [dict create ok 0 value "" error $value]
    }
    ::HvCmdLog::Log "$label accepted -> '$value'"
    return [dict create ok 1 value $value error ""]
}
#--------------------------------------------- the file system -----------------
proc ::HvCmdLog::Adapter::EnvVar {name} {
    if {[info exists ::env($name)]} { return $::env($name) }
    return ""
}
# 'file mtime' or -1 when the file is not there (that is how Logic tells an
# existing candidate from a possible one).
proc ::HvCmdLog::Adapter::FileMTime {path} {
    if {[catch {file mtime $path} m]} { return -1 }
    return $m
}
proc ::HvCmdLog::Adapter::GlobCmf {dir} {
    if {[catch {glob -nocomplain -directory $dir -types f *.cmf} files]} {
        return {}
    }
    return $files
}
# The environment the file search works on (V1).
proc ::HvCmdLog::Adapter::EnvNow {} {
    return [::HvCmdLog::Logic::EnvFrom [pwd] \
        [::HvCmdLog::Adapter::EnvVar TEMP] [::HvCmdLog::Adapter::EnvVar TMP] \
        [::HvCmdLog::Adapter::EnvVar HOME] [::HvCmdLog::Adapter::EnvVar USERPROFILE]]
}
# Looks for the command file on disk (V1).  Sets State::commandFile and, for a
# file that is picked for the first time, starts reading at its END: what is
# already in the file is another session, the log is about what happens now.
# ('Read from start' in the window / State::SetOffset 0 dumps the whole file.)
proc ::HvCmdLog::Adapter::DiscoverOnce {} {
    set env [::HvCmdLog::Adapter::EnvNow]
    set entries {}
    set paths {}
    foreach path [::HvCmdLog::Logic::CommandFileCandidates $env] {
        lappend paths $path
        lappend entries [dict create path $path \
            mtime [::HvCmdLog::Adapter::FileMTime $path] \
            exact [::HvCmdLog::Logic::IsCommandFileName [file tail $path]] \
            dirExists [file isdirectory [file dirname $path]]]
    }
    foreach dir [::HvCmdLog::Logic::CommandFileDirs $env] {
        if {![file isdirectory $dir]} { continue }
        foreach f [::HvCmdLog::Adapter::GlobCmf $dir] {
            if {[lsearch -exact $paths $f] >= 0} { continue }
            lappend paths $f
            lappend entries [dict create path $f \
                mtime [::HvCmdLog::Adapter::FileMTime $f] \
                exact [::HvCmdLog::Logic::IsCommandFileName [file tail $f]] \
                dirExists 1]
        }
    }
    set pick [::HvCmdLog::Logic::PickCommandFile $entries]
    if {$pick eq ""} {
        ::HvCmdLog::Log "no command file candidate found"
        return ""
    }
    set previous [::HvCmdLog::State::GetCommandFile]
    set size 0
    if {[file exists $pick]} {
        catch { set size [file size $pick] }
        ::HvCmdLog::State::SetCommandFile $pick "auto"
    } else {
        ::HvCmdLog::State::SetCommandFile $pick "auto-pending"
    }
    if {$pick ne $previous} {
        ::HvCmdLog::State::SetOffset $size
        ::HvCmdLog::State::SetPartial ""
        # A different file is worth a fresh note about it.
        ::HvCmdLog::State::SetWaitReported 0
    }
    ::HvCmdLog::Log "command file: $pick ([::HvCmdLog::State::GetCommandFileSource])\
, reading from byte [::HvCmdLog::State::GetOffset]"
    return $pick
}
#--------------------------------------------- reading the command file -------
# Reads 'length' bytes from 'file' starting at 'offset'.  The channel is set to
# binary for the read, so the offset really is a byte offset; the chunk is then
# decoded as UTF-8 (paths and entity names may contain non ASCII characters).
proc ::HvCmdLog::Adapter::ReadChunk {file offset length} {
    if {$length <= 0} { return "" }
    if {[catch {open $file r} fh]} {
        ::HvCmdLog::State::SetLastError "cannot open $file: $fh"
        ::HvCmdLog::Log "cannot open $file: $fh"
        return ""
    }
    set data ""
    set code [catch {
        fconfigure $fh -translation binary -encoding binary
        seek $fh $offset start
        set data [read $fh $length]
    } err]
    catch { close $fh }
    if {$code} {
        ::HvCmdLog::State::SetLastError "cannot read $file: $err"
        return ""
    }
    ::HvCmdLog::State::ClearLastError
    if {[catch {set data [encoding convertfrom utf-8 $data]} decErr]} {
        # Not valid UTF-8 - keep the raw bytes rather than lose the lines.
        ::HvCmdLog::Log "chunk is not valid UTF-8 ($decErr) - keeping it raw"
    }
    return $data
}
#--------------------------------------------- the two output files -----------
proc ::HvCmdLog::Adapter::ScriptDirNow {} {
    set dir [::HvCmdLog::State::GetScriptDir]
    if {$dir eq ""} {
        set dir [::HvCmdLog::Logic::DefaultScriptDir [pwd] \
            [::HvCmdLog::Adapter::EnvVar TEMP]]
        ::HvCmdLog::State::SetScriptDir $dir
    }
    return $dir
}
# Opens '<scriptDir>/hv_cmdlog_<stamp>.tcl' (the replayable script) and the
# matching '*.raw.cmf' mirror (everything, without the noise filter).  Returns
# 1 on success.  Called from 'Start' and lazily from the first captured line.
proc ::HvCmdLog::Adapter::OpenLogFiles {} {
    if {$::HvCmdLog::Adapter::scriptChan ne ""} { return 1 }
    set dir [::HvCmdLog::Adapter::ScriptDirNow]
    if {![file isdirectory $dir]} {
        if {[catch {file mkdir $dir} err]} {
            ::HvCmdLog::State::SetLastError "cannot create $dir: $err"
            ::HvCmdLog::Log "cannot create $dir: $err"
            return 0
        }
    }
    set stamp  [::HvCmdLog::Logic::StampName [clock seconds]]
    set script [file join $dir [::HvCmdLog::Logic::ScriptName $stamp]]
    set raw    [file join $dir [::HvCmdLog::Logic::RawName $stamp]]
    if {[catch {open $script w} c1]} {
        ::HvCmdLog::State::SetLastError "cannot write $script: $c1"
        ::HvCmdLog::Log "cannot write $script: $c1"
        return 0
    }
    if {[catch {open $raw w} c2]} {
        catch { close $c1 }
        ::HvCmdLog::State::SetLastError "cannot write $raw: $c2"
        ::HvCmdLog::Log "cannot write $raw: $c2"
        return 0
    }
    # LF only: the script is meant to be sourced on any platform.
    catch { fconfigure $c1 -translation lf }
    catch { fconfigure $c2 -translation lf }
    foreach line [::HvCmdLog::Logic::ScriptHeader \
            [::HvCmdLog::State::GetCommandFile] $stamp] {
        catch { puts $c1 $line }
    }
    catch { flush $c1 }
    set ::HvCmdLog::Adapter::scriptChan  $c1
    set ::HvCmdLog::Adapter::rawChan     $c2
    set ::HvCmdLog::Adapter::scriptStamp $stamp
    ::HvCmdLog::State::SetScriptFile $script
    ::HvCmdLog::State::SetRawFile $raw
    ::HvCmdLog::Log "script: $script   raw: $raw"
    return 1
}
# Appends what has just been read.  The script gets the filtered lines (that is
# what a replay should run), the mirror gets every line that was in the file.
proc ::HvCmdLog::Adapter::AppendToFiles {rawLines keptLines} {
    if {![::HvCmdLog::State::GetWriteScript]} { return }
    if {$::HvCmdLog::Adapter::scriptChan eq ""} {
        if {![::HvCmdLog::Adapter::OpenLogFiles]} { return }
    }
    foreach line $rawLines {
        catch { puts $::HvCmdLog::Adapter::rawChan $line }
    }
    foreach line $keptLines {
        catch { puts $::HvCmdLog::Adapter::scriptChan $line }
    }
    catch { flush $::HvCmdLog::Adapter::rawChan }
    catch { flush $::HvCmdLog::Adapter::scriptChan }
    return
}
proc ::HvCmdLog::Adapter::CloseLogFiles {} {
    if {$::HvCmdLog::Adapter::scriptChan ne ""} {
        catch { close $::HvCmdLog::Adapter::scriptChan }
        set ::HvCmdLog::Adapter::scriptChan ""
    }
    if {$::HvCmdLog::Adapter::rawChan ne ""} {
        catch { close $::HvCmdLog::Adapter::rawChan }
        set ::HvCmdLog::Adapter::rawChan ""
    }
    return
}
# 'Save as...' - writes the current buffer as a standalone replay script.
proc ::HvCmdLog::Adapter::SaveScriptAs {path} {
    set stamp [::HvCmdLog::Logic::TimeStamp [clock seconds]]
    set text [::HvCmdLog::Logic::WrapScript [::HvCmdLog::State::GetLines] \
        [::HvCmdLog::State::GetCommandFile] $stamp]
    if {[catch {open $path w} fh]} {
        ::HvCmdLog::State::SetLastError "cannot write $path: $fh"
        return [dict create ok 0 message "cannot write $path: $fh"]
    }
    set code [catch {
        catch { fconfigure $fh -translation lf }
        puts $fh $text
        flush $fh
    } err]
    catch { close $fh }
    if {$code} {
        ::HvCmdLog::State::SetLastError "cannot write $path: $err"
        return [dict create ok 0 message "cannot write $path: $err"]
    }
    return [dict create ok 1 message "saved [llength [::HvCmdLog::State::GetLines]] lines to $path"]
}
#--------------------------------------------- replay -------------------------
# Sources a captured script.  Polling is switched off and the 'hwi' tap is muted
# while it runs, so a replay never logs itself (the log stays a record of what
# the user did, not of what was replayed).
proc ::HvCmdLog::Adapter::ReplayScript {path} {
    if {![file exists $path]} {
        return [dict create ok 0 message "file not found: $path"]
    }
    set wasPolling [::HvCmdLog::State::GetPolling]
    set wasInTool  [::HvCmdLog::State::GetInToolCall]
    ::HvCmdLog::State::SetPolling 0
    ::HvCmdLog::State::SetInToolCall 1
    set code [catch {uplevel #0 [list source $path]} result]
    ::HvCmdLog::State::SetInToolCall $wasInTool
    ::HvCmdLog::State::SetPolling $wasPolling
    # A 'vwait' inside the replayed script may have consumed the pending poll.
    if {$wasPolling} { ::HvCmdLog::SchedulePoll }
    if {$code} {
        ::HvCmdLog::State::SetLastError "replay stopped: $result"
        return [dict create ok 0 message "replay stopped: $result"]
    }
    return [dict create ok 1 message "replayed $path"]
}
#--------------------------------------------- one poll -----------------------
# Reads everything that is new in the command file, filters it, writes it to the
# two output files and hands the lines to show back to the caller.
# Returns a dict:  lines <lines to display>  status <status text>
# It never throws: a missing file, a locked file, a rewritten file are all
# normal states of a file that another program writes.
proc ::HvCmdLog::Adapter::PumpOnce {} {
    set out {}
    set known [::HvCmdLog::State::GetCommandFile]
    set file $known
    if {$file eq ""} {
        ::HvCmdLog::Adapter::DiscoverOnce
        set file [::HvCmdLog::State::GetCommandFile]
    }
    if {$file eq "" || ![file exists $file]} {
        # Nothing to read (yet).  A poll runs every few hundred ms, so the note
        # about it is written ONCE - a wall of the same text at 400 ms would
        # make the log unreadable and the script worthless.
        if {![::HvCmdLog::State::GetWaitReported]} {
            if {$file ne ""} {
                lappend out "# waiting for $file to appear\
 ([::HvCmdLog::State::GetCommandFileSource])"
            }
            foreach line [::HvCmdLog::Logic::NoFileHint] { lappend out $line }
            ::HvCmdLog::State::SetWaitReported 1
        }
        # Only a file that really WAS there is searched again: an 'auto-pending'
        # candidate is simply watched, and a path the user typed is kept even
        # while HyperView has not created it yet.
        if {[lsearch -exact {auto hwi-api} \
                [::HvCmdLog::State::GetCommandFileSource]] >= 0} {
            lappend out "# $file is gone - looking for a command file again"
            ::HvCmdLog::State::ForgetFile
        }
        return [dict create lines $out status [::HvCmdLog::Logic::WaitingStatus ""]]
    }
    # The file is there - a note about the next wait is worth writing again.
    ::HvCmdLog::State::SetWaitReported 0
    if {$known eq ""} {
        lappend out "# command file: $file ([::HvCmdLog::State::GetCommandFileSource])\
 - new commands are appended below"
    }
    set size 0
    if {[catch {file size $file} size]} {
        ::HvCmdLog::State::SetLastError "cannot stat $file: $size"
        return [dict create lines $out status [::HvCmdLog::Logic::WaitingStatus $file]]
    }
    set plan [::HvCmdLog::Logic::ReadPlan [::HvCmdLog::State::GetOffset] $size]
    set chunk ""
    switch -- [dict get $plan action] {
        none { }
        reset {
            # Shorter than what was read -> the file was rewritten (V1/V4).
            lappend out [::HvCmdLog::Logic::TruncateMarker]
            set chunk [::HvCmdLog::Adapter::ReadChunk $file 0 [dict get $plan length]]
        }
        read {
            set chunk [::HvCmdLog::Adapter::ReadChunk $file \
                [dict get $plan start] [dict get $plan length]]
        }
    }
    if {$chunk ne ""} {
        set fed [::HvCmdLog::Logic::Feed [::HvCmdLog::State::GetPartial] $chunk]
        ::HvCmdLog::State::SetPartial [dict get $fed rest]
        set raw  [dict get $fed lines]
        set filt [::HvCmdLog::Logic::FilterLines $raw [::HvCmdLog::State::GetHideNoise]]
        set kept [dict get $filt kept]
        ::HvCmdLog::State::AddCounts [llength $raw] [dict get $filt hidden]
        ::HvCmdLog::Adapter::AppendToFiles $raw $kept
        ::HvCmdLog::State::AddLines $kept
        foreach line $kept { lappend out $line }
    }
    # none  -> offset + 0       read -> offset + length       reset -> 0 + size
    ::HvCmdLog::State::SetOffset [expr {[dict get $plan start] + [dict get $plan length]}]
    set status [::HvCmdLog::Logic::SummaryLine $file \
        [::HvCmdLog::State::GetCountCaptured] [::HvCmdLog::State::GetCountHidden] \
        [::HvCmdLog::State::GetOffset]]
    ::HvCmdLog::State::SetStatus $status
    return [dict create lines $out status $status]
}
#--------------------------------------------- the 'hwi' tap (V3) -------------
# Wraps the built-in 'hwi' command so that every hwi call of a script or of the
# console is logged as well.  The wrapper notes the line and then calls the
# original command with 'uplevel 1', i.e. in the frame of ITS caller - this is
# what keeps handles where the caller expects them ('hwi GetSessionHandle sess'
# leaves 'sess' in the caller's frame, exactly as without the tap).
# The command is rebuilt with [list ...] instead of a plain word list, so an
# argument that contains a space survives the 'uplevel'.
proc ::HvCmdLog::Adapter::InstallHwiTap {} {
    if {[llength [info commands ::HvCmdLog::hwiReal]] > 0} {
        ::HvCmdLog::State::SetTapInstalled 1
        return 1
    }
    if {[llength [info commands ::hwi]] == 0} {
        ::HvCmdLog::Log "no 'hwi' command in this interpreter - tap skipped"
        return 0
    }
    if {[catch {rename ::hwi ::HvCmdLog::hwiReal} err]} {
        ::HvCmdLog::Log "cannot rename 'hwi': $err - tap skipped"
        return 0
    }
    proc ::hwi {args} {
        # The 'hwi' word itself is not passed on to NoteHwiCall: it puts it in
        # front of the line again, so the log reads 'hwi GetSessionHandle sess'.
        ::HvCmdLog::Adapter::NoteHwiCall {*}$args
        return [uplevel 1 [list ::HvCmdLog::hwiReal {*}$args]]
    }
    ::HvCmdLog::State::SetTapInstalled 1
    ::HvCmdLog::Log "hwi tap installed"
    return 1
}
# Puts the original 'hwi' command back in place.
proc ::HvCmdLog::Adapter::RemoveHwiTap {} {
    if {[llength [info commands ::HvCmdLog::hwiReal]] == 0} {
        ::HvCmdLog::State::SetTapInstalled 0
        return 1
    }
    # Drop our wrapper first (it may already be gone), then restore the original
    # name - the reverse order of InstallHwiTap.
    catch { rename ::hwi {} }
    if {[catch {rename ::HvCmdLog::hwiReal ::hwi} err]} {
        ::HvCmdLog::Log "cannot restore 'hwi': $err"
        return 0
    }
    ::HvCmdLog::State::SetTapInstalled 0
    ::HvCmdLog::Log "hwi tap removed"
    return 1
}
# One logged hwi call.  The tool's own calls (inToolCall) are ignored, so the
# probe and the housekeeping never appear in the log.
proc ::HvCmdLog::Adapter::NoteHwiCall {args} {
    if {[::HvCmdLog::State::GetInToolCall]} { return }
    set line [::HvCmdLog::Logic::QuotedLine [linsert $args 0 hwi]]
    ::HvCmdLog::Emit $line
    ::HvCmdLog::State::AddLines [list $line]
    ::HvCmdLog::State::AddCounts 1 0
    if {[::HvCmdLog::State::GetWriteScript]} {
        ::HvCmdLog::Adapter::AppendToFiles [list $line] [list $line]
    }
    return
}
#--------------------------------------------- the recorder probe (V2) --------
# Asks HyperView whether it has a method that writes the command file (and one
# that reports its name).  EVERY candidate is inside catch and the whole probe
# runs on a temporary OpenStack that is closed again, so a build that knows none
# of these names loses nothing but a line of text in the log.
# Returns: dict path <file reported by HyperView> accepted <list> lines <report>
proc ::HvCmdLog::Adapter::ProbeRecorderApi {} {
    set handle $::HvCmdLog::Adapter::probeHandle
    set userPicked [expr {[::HvCmdLog::State::GetCommandFileSource] eq "user" ? 1 : 0}]
    # Never retarget HyperView into a file the user only wants to read.
    if {$userPicked} {
        set file ""
    } else {
        set file [::HvCmdLog::State::GetCommandFile]
    }
    set lines {}
    set accepted {}
    set path ""
    if {[llength [info commands ::hwi]] == 0} {
        # NOTE: 'lines' must be a LIST of lines.  A bare {...} would hand Tcl one
        # element too, but the readers loop over the value with 'foreach', so a
        # message with spaces would be split into a dozen "lines" and printed
        # word by word - hence the explicit [list ...].
        return [dict create path "" accepted {} lines \
            [list {# recorder API: no 'hwi' command in this interpreter - probe skipped}]]
    }
    if {[::HvCmdLog::Adapter::ToolRun "probe OpenStack" {hwi OpenStack}]} {
        return [dict create path "" accepted {} lines \
            [list {# recorder API: 'hwi OpenStack' failed - probe skipped}]]
    }
    if {[::HvCmdLog::Adapter::ToolRun "probe GetSessionHandle" \
            [list hwi GetSessionHandle $handle]]} {
        ::HvCmdLog::Adapter::ToolRun "probe CloseStack" {hwi CloseStack}
        return [dict create path "" accepted {} lines \
            [list {# recorder API: no session handle - probe skipped}]]
    }
    foreach cand [::HvCmdLog::Logic::ProbeCandidates] {
        lassign $cand label method cargs
        if {[::HvCmdLog::Logic::NeedsFileArg $cargs] && $file eq ""} {
            lappend lines "# recorder API: $label skipped (command file unknown)"
            continue
        }
        set cargs [::HvCmdLog::Logic::SubstituteFileArg $cargs $file]
        # NOTE: the script handed to TryCall MUST start with 'hwi' - the probe
        # calls '<handle> <method> ...', and only the 'hwi' in front makes that
        # a HyperView command (this is the difference between a probe that can
        # succeed and one that is refused in every build).
        set res [::HvCmdLog::Adapter::TryCall "recorder API: $label" \
            [list hwi $handle $method {*}$cargs]]
        if {![dict get $res ok]} {
            lappend lines "# recorder API: $label -> refused ([dict get $res error])"
            continue
        }
        lappend accepted $method
        lappend lines "# recorder API: $label -> accepted"
        if {$method eq "GetCommandFileName"} {
            set value [string trim [dict get $res value]]
            if {$value ne ""} {
                set path $value
                lappend lines "# recorder API: HyperView writes into $value"
            }
        }
    }
    ::HvCmdLog::Adapter::ToolRun "probe ReleaseHandle" [list hwi $handle ReleaseHandle]
    ::HvCmdLog::Adapter::ToolRun "probe CloseStack" {hwi CloseStack}
    ::HvCmdLog::State::SetProbeReport $lines
    return [dict create lines $lines path $path accepted $accepted]
}
#--------------------------------------------- start up report ---------------
# What 'Start' tells the user: which file is watched, what the recorder API can
# do, how many lines were written where.  Returns dict lines <report> ok 0|1
proc ::HvCmdLog::Adapter::DiscoverAndProbe {} {
    set lines {}
    set userPicked [expr {[::HvCmdLog::State::GetCommandFileSource] eq "user" ? 1 : 0}]
    if {[::HvCmdLog::State::GetCommandFile] eq ""} {
        ::HvCmdLog::Adapter::DiscoverOnce
    }
    set file [::HvCmdLog::State::GetCommandFile]
    if {$file ne ""} {
        lappend lines "# command file: $file ([::HvCmdLog::State::GetCommandFileSource])\
 - new commands are appended below"
    }
    set probe [::HvCmdLog::Adapter::ProbeRecorderApi]
    foreach line [dict get $probe lines] { lappend lines $line }
    set reported [dict get $probe path]
    if {$reported ne "" && !$userPicked && $reported ne $file} {
        # HyperView told us exactly which file it writes - that beats the guess.
        ::HvCmdLog::State::SetCommandFile $reported "hwi-api"
        ::HvCmdLog::State::SetOffset 0
        ::HvCmdLog::State::SetPartial ""
        set file $reported
        lappend lines "# command file: $reported (reported by HyperView - reading it)"
    } elseif {$reported ne "" && $userPicked} {
        lappend lines "# note: HyperView writes $reported - the file you chose is kept"
    }
    if {[llength [dict get $probe accepted]] == 0} {
        lappend lines "# recorder API: no candidate was accepted - the command file and\
 the 'hwi' tap are the log sources then"
    }
    if {$file eq ""} {
        foreach line [::HvCmdLog::Logic::NoFileHint] { lappend lines $line }
    } elseif {[::HvCmdLog::State::GetWriteScript]} {
        lappend lines "# script folder: [::HvCmdLog::Adapter::ScriptDirNow]"
    }
    return [dict create lines $lines ok [expr {$file ne "" ? 1 : 0}]]
}

#=============================================================================
# SECTION 3 - CORE: the poll loop and the single place a captured line leaves
#   the tool (the log window when it is open, the Tcl console otherwise).
#=============================================================================
# Starts recording.  Both taps are put in place (the recorder probe and the
# 'hwi' wrapper), the output files are opened and the poll loop is started.
# Returns 1 - there is no way to fail hard here: whatever is not available is
# reported in the log and the rest keeps working.
proc ::HvCmdLog::Start {{interval {}}} {
    if {$interval ne ""} {
        ::HvCmdLog::State::SetPollInterval [::HvCmdLog::Logic::ValidInterval $interval]
    }
    if {[::HvCmdLog::State::GetPolling]} { return 1 }
    set report {}
    if {[::HvCmdLog::State::GetTapHwi]} {
        if {[::HvCmdLog::Adapter::InstallHwiTap]} {
            lappend report "# hwi tap: installed - every 'hwi ...' call is logged too"
        } else {
            lappend report "# hwi tap: not available in this interpreter"
        }
    }
    # The command file first, the output files after it: the header of the
    # script names the file HyperView really writes (the probe may have found
    # it), so a captured script can be traced back.
    set probe [::HvCmdLog::Adapter::DiscoverAndProbe]
    foreach line [dict get $probe lines] { lappend report $line }
    if {[::HvCmdLog::State::GetWriteScript]} {
        if {[::HvCmdLog::Adapter::OpenLogFiles]} {
            lappend report "# script: [::HvCmdLog::State::GetScriptFile]"
        } else {
            lappend report "# script: cannot be written - [::HvCmdLog::State::GetLastError]"
        }
    }
    ::HvCmdLog::State::SetPolling 1
    ::HvCmdLog::UI::SyncRecording
    # The automatic search (V1) may have just found the file: show it right away,
    # without waiting for the first poll.
    ::HvCmdLog::UI::SyncCmdFile
    foreach line $report { ::HvCmdLog::Emit $line }
    ::HvCmdLog::SchedulePoll
    ::HvCmdLog::SetStatus [::HvCmdLog::Logic::SummaryLine \
        [::HvCmdLog::State::GetCommandFile] [::HvCmdLog::State::GetCountCaptured] \
        [::HvCmdLog::State::GetCountHidden] [::HvCmdLog::State::GetOffset]]
    return 1
}
# Stops recording: one last look at the file, then the taps are removed, the
# output files are closed and the original 'hwi' command is restored.
proc ::HvCmdLog::Stop {} {
    set wasPolling [::HvCmdLog::State::GetPolling]
    ::HvCmdLog::State::SetPolling 0
    ::HvCmdLog::UI::SyncRecording
    if {$::HvCmdLog::pollToken ne ""} {
        catch { after cancel $::HvCmdLog::pollToken }
        set ::HvCmdLog::pollToken ""
    }
    if {$wasPolling} {
        # Whatever HyperView wrote since the last poll is still picked up.
        set report [::HvCmdLog::Adapter::PumpOnce]
        foreach line [dict get $report lines] { ::HvCmdLog::Emit $line }
    }
    if {[::HvCmdLog::State::GetTapInstalled]} { ::HvCmdLog::Adapter::RemoveHwiTap }
    ::HvCmdLog::Adapter::CloseLogFiles
    set status [::HvCmdLog::Logic::SummaryLine [::HvCmdLog::State::GetCommandFile] \
        [::HvCmdLog::State::GetCountCaptured] [::HvCmdLog::State::GetCountHidden] \
        [::HvCmdLog::State::GetOffset]]
    ::HvCmdLog::Emit "# recording stopped"
    ::HvCmdLog::SetStatus $status
    return 1
}
# Queues the next poll.  The delay comes from State::pollInterval, so the window
# can change the pace of a running loop.
proc ::HvCmdLog::SchedulePoll {} {
    if {[llength [info commands after]] == 0} { return }
    if {$::HvCmdLog::pollToken ne ""} {
        catch { after cancel $::HvCmdLog::pollToken }
    }
    set interval [::HvCmdLog::State::GetPollInterval]
    if {$interval < 50} { set interval 50 }
    set ::HvCmdLog::pollToken [after $interval ::HvCmdLog::Pump]
    return
}
# One turn of the loop: read, hand the lines over, queue the next turn.
proc ::HvCmdLog::Pump {} {
    set ::HvCmdLog::pollToken ""
    if {![::HvCmdLog::State::GetPolling]} { return }
    set report [::HvCmdLog::Adapter::PumpOnce]
    ::HvCmdLog::UI::SyncCmdFile
    foreach line [dict get $report lines] { ::HvCmdLog::Emit $line }
    ::HvCmdLog::SetStatus [dict get $report status]
    ::HvCmdLog::SchedulePoll
    return
}
# The one exit for a captured line: the log window when it is open, the Tcl
# console otherwise - or both, when 'echo to console' is switched on.
proc ::HvCmdLog::Emit {line} {
    set shown 0
    if {[::HvCmdLog::UI::Available]} {
        ::HvCmdLog::UI::AppendLine $line
        set shown 1
    }
    if {!$shown || [::HvCmdLog::State::GetEchoConsole]} {
        catch { puts $line }
        catch { flush stdout }
    }
    return
}
proc ::HvCmdLog::SetStatus {text} {
    ::HvCmdLog::State::SetStatus $text
    if {[::HvCmdLog::UI::Available]} { ::HvCmdLog::UI::ShowStatus $text }
    return
}
# Empties the window and the buffer.  The output files keep what was already
# written - they are the record, this is the view.
proc ::HvCmdLog::Clear {} {
    ::HvCmdLog::State::ClearLines
    ::HvCmdLog::State::ResetCounts
    ::HvCmdLog::UI::ClearText
    ::HvCmdLog::Log "buffer cleared (the output files keep what was written)"
    return
}
# Forgets how far the command file has been read: the next poll dumps the whole
# file into the log (useful to see what a session consisted of).
proc ::HvCmdLog::ReadFromStart {} {
    ::HvCmdLog::State::SetOffset 0
    ::HvCmdLog::State::SetPartial ""
    ::HvCmdLog::Emit "# reading the command file from the start on the next poll"
    return
}
# The user pinned a command file by hand (typed or browsed).  'startAt' is the
# byte offset to start with: 0 dumps the file, a negative value starts at its
# end, i.e. only what happens from now on is logged.
proc ::HvCmdLog::UseCommandFile {path {startAt -1}} {
    if {$path eq ""} { return 0 }
    if {![file exists $path]} {
        # Not fatal: it may be the file HyperView is about to create.
        ::HvCmdLog::Log "$path does not exist yet - it is watched until it appears"
    }
    ::HvCmdLog::State::SetCommandFile $path "user"
    set offset $startAt
    if {$startAt < 0} {
        set offset 0
        if {[file exists $path]} { catch { set offset [file size $path] } }
    }
    ::HvCmdLog::State::SetOffset $offset
    ::HvCmdLog::State::SetPartial ""
    # A new choice deserves a new note, even if the last one was already written.
    ::HvCmdLog::State::SetWaitReported 0
    ::HvCmdLog::Emit "# watching $path (chosen by the user, reading from byte $offset)"
    return 1
}

#=============================================================================
# SECTION 4 - UI LAYER (hwtk everywhere, plus one plain Tk text widget)
#   The window only calls the core (Start / Stop / Clear / ...) and the adapter
#   for the file dialogs.  It never touches hwi itself.
#=============================================================================
namespace eval ::HvCmdLog::UI {
    # The window and the widgets that are touched after they are built.
    variable gui ""
    variable wText ""
    variable wStatus ""
    # Number of lines currently in the text widget (used by the trim).
    variable textLines 0
    # Values bound to the controls.
    variable varRecording 0
    variable varHideNoise 1
    variable varTap 1
    variable varScript 1
    variable varStamp 0
    variable varEcho 0
    variable varPoll 400
    variable varCmdFile ""
    variable varScriptDir ""
}
# 1 when the log window is open and usable (used by Emit / SetStatus / Clear).
proc ::HvCmdLog::UI::Available {} {
    if {$::HvCmdLog::UI::gui eq ""} { return 0 }
    # 'winfo' only exists when Tk is loaded - in a plain tclsh the catch keeps
    # the tool from breaking (V5).
    if {[catch {expr {[winfo exists $::HvCmdLog::UI::gui] ? 1 : 0}} ok]} { return 0 }
    return $ok
}
# Creates the toplevel.  hwtk::toplevel is preferred - it gives the window
# HyperWorks' look - and '-title' is tried first because a build without it
# would refuse the whole call (V5).
proc ::HvCmdLog::UI::CreateWindow {path title} {
    if {[winfo exists $path]} { catch { destroy $path } }
    set created 0
    if {[llength [info commands ::hwtk::toplevel]] > 0} {
        if {![catch { ::hwtk::toplevel $path -title $title }]} { set created 1 }
    }
    if {!$created} {
        # PLAIN TK: no hwtk::toplevel in this build, or it refused '-title'.
        toplevel $path
        wm title $path $title
    }
    catch { wm geometry $path 980x560 }
    catch { wm minsize $path 640 320 }
    return $path
}
# Builds the whole window.  Every handler it calls exists in this section.
proc ::HvCmdLog::UI::Build {} {
    variable gui
    variable wText
    variable wStatus
    set gui .hvCmdLogGUI
    ::HvCmdLog::UI::CreateWindow $gui "HyperView command log - hv_cmd_logger"

    hwtk::frame $gui.box
    pack $gui.box -side top -fill both -expand 1

    #------------------------------------------------- row 1: record + actions
    hwtk::frame $gui.box.top
    pack $gui.box.top -side top -fill x -padx 6 -pady {6 2}
    hwtk::checkbutton $gui.box.top.rec -text "Record" \
        -variable ::HvCmdLog::UI::varRecording \
        -command ::HvCmdLog::UI::OnToggleRecord
    pack $gui.box.top.rec -side left -padx {0 10}
    foreach {name text cmd} {
        clear  "Clear"           {::HvCmdLog::Clear}
        save   "Save as..."      {::HvCmdLog::UI::OnSaveAs}
        copy   "Copy"            {::HvCmdLog::UI::OnCopy}
        replay "Replay file..."  {::HvCmdLog::UI::OnReplay}
        first  "Read from start" {::HvCmdLog::ReadFromStart}
        reload "Reload file"     {::HvCmdLog::UI::OnReload}
        close  "Close"           {::HvCmdLog::UI::OnClose}
    } {
        hwtk::button $gui.box.top.$name -text $text -command $cmd
        pack $gui.box.top.$name -side left -padx 2
    }

    #------------------------------------------------- row 2: sources/options
    hwtk::labelframe $gui.box.opts -text "Sources and options"
    pack $gui.box.opts -side top -fill x -padx 6 -pady 2

    hwtk::frame $gui.box.opts.sw
    pack $gui.box.opts.sw -side top -fill x -pady 2
    foreach {name text var} {
        noise  "Hide noise lines"    ::HvCmdLog::UI::varHideNoise
        tap    "Tap built-in hwi"    ::HvCmdLog::UI::varTap
        script "Write .tcl script"   ::HvCmdLog::UI::varScript
        stamp  "Time stamps"         ::HvCmdLog::UI::varStamp
        echo   "Echo to Tcl console" ::HvCmdLog::UI::varEcho
    } {
        hwtk::checkbutton $gui.box.opts.sw.$name -text $text -variable $var \
            -command ::HvCmdLog::UI::OnSwitches
        pack $gui.box.opts.sw.$name -side left -padx {0 8}
    }
    hwtk::label $gui.box.opts.sw.plab -text "Poll (ms):"
    pack $gui.box.opts.sw.plab -side left -padx {12 4}
    ::HvCmdLog::UI::MakePollChooser $gui.box.opts.sw.poll

    #------------------------------------------------- row 3: command file
    hwtk::frame $gui.box.opts.cf
    pack $gui.box.opts.cf -side top -fill x -pady 2
    hwtk::label $gui.box.opts.cf.lab -text "Command file:"
    pack $gui.box.opts.cf.lab -side left
    hwtk::entry $gui.box.opts.cf.ent -textvariable ::HvCmdLog::UI::varCmdFile -width 62
    pack $gui.box.opts.cf.ent -side left -fill x -expand 1 -padx 4
    hwtk::button $gui.box.opts.cf.browse -text "Browse..." \
        -command ::HvCmdLog::UI::OnBrowseCmdFile
    pack $gui.box.opts.cf.browse -side left -padx 2
    hwtk::button $gui.box.opts.cf.use -text "Watch this file" \
        -command ::HvCmdLog::UI::OnUseCmdFile
    pack $gui.box.opts.cf.use -side left
    bind $gui.box.opts.cf.ent <Return> ::HvCmdLog::UI::OnUseCmdFile

    #------------------------------------------------- row 4: script folder
    hwtk::frame $gui.box.opts.sd
    pack $gui.box.opts.sd -side top -fill x -pady 2
    hwtk::label $gui.box.opts.sd.lab -text "Script folder:"
    pack $gui.box.opts.sd.lab -side left
    hwtk::entry $gui.box.opts.sd.ent -textvariable ::HvCmdLog::UI::varScriptDir -width 62
    pack $gui.box.opts.sd.ent -side left -fill x -expand 1 -padx 4
    hwtk::button $gui.box.opts.sd.browse -text "Browse..." \
        -command ::HvCmdLog::UI::OnBrowseScriptDir
    pack $gui.box.opts.sd.browse -side left -padx 2
    hwtk::button $gui.box.opts.sd.open -text "Use this folder" \
        -command ::HvCmdLog::UI::OnUseScriptDir
    pack $gui.box.opts.sd.open -side left
    bind $gui.box.opts.sd.ent <Return> ::HvCmdLog::UI::OnUseScriptDir

    #------------------------------------------------- the log itself
    hwtk::frame $gui.box.log
    pack $gui.box.log -side top -fill both -expand 1 -padx 6 -pady 4
    # PLAIN TK: a text widget with a scrollbar - hwtk has no log/text widget,
    # so the one widget that is not hwtk is this one (it is also the only one
    # that carries a lot of text).
    text $gui.box.log.text -wrap none -height 18 -width 120 -state disabled \
        -background white -foreground black -font TkFixedFont
    scrollbar $gui.box.log.sb -orient vertical -command "$gui.box.log.text yview"
    $gui.box.log.text configure -yscrollcommand "$gui.box.log.sb set"
    pack $gui.box.log.sb -side right -fill y
    pack $gui.box.log.text -side left -fill both -expand 1
    set wText $gui.box.log.text

    hwtk::label $gui.box.status -text "ready" -anchor w
    pack $gui.box.status -side top -fill x -padx 8 -pady {0 6}
    set wStatus $gui.box.status

    ::HvCmdLog::UI::SyncFromState
    ::HvCmdLog::UI::FillFromState
    catch { wm protocol $gui WM_DELETE_WINDOW ::HvCmdLog::UI::OnClose }
    return $gui
}
#----------------------------------------------------------------- helpers ----
# The poll interval control.  hwtk::combobox is the usual HyperWorks widget; a
# build without it gets an entry that takes the same numbers (V5).
proc ::HvCmdLog::UI::MakePollChooser {path} {
    if {[llength [info commands ::hwtk::combobox]] > 0} {
        if {![catch { ::hwtk::combobox $path -textvariable ::HvCmdLog::UI::varPoll \
                -values [::HvCmdLog::Logic::PollIntervals] -state readonly -width 6 }]} {
            pack $path -side left
            bind $path <<ComboboxSelected>> ::HvCmdLog::UI::OnPollChanged
            bind $path <Return> ::HvCmdLog::UI::OnPollChanged
            return $path
        }
    }
    hwtk::entry $path -textvariable ::HvCmdLog::UI::varPoll -width 7
    pack $path -side left
    bind $path <Return> ::HvCmdLog::UI::OnPollChanged
    bind $path <FocusOut> ::HvCmdLog::UI::OnPollChanged
    return $path
}
# Copies the current switches into the controls, so the window opens in the
# state the tool is really in (also after a restart of the window).
proc ::HvCmdLog::UI::SyncFromState {} {
    ::HvCmdLog::UI::SyncRecording
    set ::HvCmdLog::UI::varHideNoise [::HvCmdLog::State::GetHideNoise]
    set ::HvCmdLog::UI::varTap       [::HvCmdLog::State::GetTapHwi]
    set ::HvCmdLog::UI::varScript    [::HvCmdLog::State::GetWriteScript]
    set ::HvCmdLog::UI::varStamp     [::HvCmdLog::State::GetStampLines]
    set ::HvCmdLog::UI::varEcho      [::HvCmdLog::State::GetEchoConsole]
    set ::HvCmdLog::UI::varPoll      [::HvCmdLog::State::GetPollInterval]
    set ::HvCmdLog::UI::varCmdFile   [::HvCmdLog::State::GetCommandFile]
    set ::HvCmdLog::UI::varScriptDir [::HvCmdLog::Adapter::ScriptDirNow]
    return
}
# The Record box follows what the tool really does, however recording was
# switched.  SyncFromState does the whole set when the window opens; this one is
# called by Start / Stop as well, so a 'hvlogStop' typed in the console cannot
# leave a ticked box (and a recording that is off) behind.
proc ::HvCmdLog::UI::SyncRecording {} {
    set ::HvCmdLog::UI::varRecording [::HvCmdLog::State::GetPolling]
    return
}
# The entry next to 'Watch this file' mirrors the file the automatic search (V1)
# ended up watching.  Only an EMPTY entry is filled in: whatever the user typed
# or browsed stays exactly as it is, and without a window there is nothing to
# fill.
proc ::HvCmdLog::UI::SyncCmdFile {} {
    if {$::HvCmdLog::UI::gui eq ""} { return }
    if {$::HvCmdLog::UI::varCmdFile ne ""} { return }
    set file [::HvCmdLog::State::GetCommandFile]
    if {$file eq ""} { return }
    set ::HvCmdLog::UI::varCmdFile $file
    return
}
# Shows what is already in the buffer: the window may be opened while recording
# is running (or after it stopped), and the lines captured so far belong there.
proc ::HvCmdLog::UI::FillFromState {} {
    ::HvCmdLog::UI::ClearText
    foreach line [::HvCmdLog::State::GetLines] { ::HvCmdLog::UI::AppendLineRaw $line }
    ::HvCmdLog::UI::ShowStatus [::HvCmdLog::State::GetStatus]
    return
}
#----------------------------------------------------------------- the text ----
# One line into the log.  A time stamp is added by the DISPLAY only - the line
# in the buffer and in the script files stays exactly what HyperView wrote.
proc ::HvCmdLog::UI::AppendLine {line} {
    if {$::HvCmdLog::UI::varStamp} {
        return [::HvCmdLog::UI::AppendLineRaw \
            "[::HvCmdLog::Logic::ShortTime [clock seconds]]  $line"]
    }
    return [::HvCmdLog::UI::AppendLineRaw $line]
}
proc ::HvCmdLog::UI::AppendLineRaw {line} {
    variable wText
    variable textLines
    if {![::HvCmdLog::UI::Available]} { return 0 }
    if {$wText eq "" || ![winfo exists $wText]} { return 0 }
    set ok [catch {
        $wText configure -state normal
        $wText insert end "$line\n"
        incr textLines
        set max [::HvCmdLog::State::GetMaxLines]
        if {$max > 0 && $textLines > $max} {
            # Only the view is bounded: the oldest lines scroll out of the
            # window, the two output files keep everything.
            set over [expr {$textLines - $max}]
            $wText delete 1.0 [expr {$over + 1}].0
            set textLines [expr {$textLines - $over}]
        }
        $wText see end
        $wText configure -state disabled
    }]
    return [expr {$ok ? 1 : 0}]
}
proc ::HvCmdLog::UI::ShowStatus {text} {
    variable wStatus
    if {![::HvCmdLog::UI::Available]} { return }
    if {$wStatus ne "" && [winfo exists $wStatus]} {
        catch { $wStatus configure -text $text }
    }
    return
}
proc ::HvCmdLog::UI::ClearText {} {
    variable wText
    variable textLines
    set textLines 0
    if {![::HvCmdLog::UI::Available]} { return }
    if {$wText eq "" || ![winfo exists $wText]} { return }
    catch {
        $wText configure -state normal
        $wText delete 1.0 end
        $wText configure -state disabled
    }
    return
}
#----------------------------------------------------------------- handlers ---
# 'Record' - the one control that starts and stops everything.
proc ::HvCmdLog::UI::OnToggleRecord {} {
    if {$::HvCmdLog::UI::varRecording} {
        ::HvCmdLog::Start
    } else {
        ::HvCmdLog::Stop
    }
    return
}
# Any checkbox: the switch that was flipped is stored and the taps react at
# once, so nothing needs to be restarted.
proc ::HvCmdLog::UI::OnSwitches {} {
    ::HvCmdLog::State::SetHideNoise   $::HvCmdLog::UI::varHideNoise
    ::HvCmdLog::State::SetEchoConsole $::HvCmdLog::UI::varEcho
    ::HvCmdLog::State::SetStampLines  $::HvCmdLog::UI::varStamp
    if {$::HvCmdLog::UI::varScript != [::HvCmdLog::State::GetWriteScript]} {
        ::HvCmdLog::State::SetWriteScript $::HvCmdLog::UI::varScript
        if {$::HvCmdLog::UI::varScript} {
            if {[::HvCmdLog::Adapter::OpenLogFiles]} {
                ::HvCmdLog::Emit "# script: [::HvCmdLog::State::GetScriptFile]"
            } else {
                ::HvCmdLog::Emit "# script: cannot be written - \
[::HvCmdLog::State::GetLastError]"
            }
        } else {
            ::HvCmdLog::Adapter::CloseLogFiles
            ::HvCmdLog::Emit "# writing the script is switched off (the log window keeps\
 the commands)"
        }
    }
    if {$::HvCmdLog::UI::varTap != [::HvCmdLog::State::GetTapHwi]} {
        ::HvCmdLog::State::SetTapHwi $::HvCmdLog::UI::varTap
        if {$::HvCmdLog::UI::varTap} {
            if {[::HvCmdLog::Adapter::InstallHwiTap]} {
                ::HvCmdLog::Emit "# hwi tap: installed"
            } else {
                ::HvCmdLog::Emit "# hwi tap: not available in this interpreter"
            }
        } else {
            ::HvCmdLog::Adapter::RemoveHwiTap
            ::HvCmdLog::Emit "# hwi tap: removed"
        }
    }
    return
}
# Poll pace - applied to the running loop, effective on the next turn.
proc ::HvCmdLog::UI::OnPollChanged {} {
    set chosen [::HvCmdLog::Logic::ValidInterval $::HvCmdLog::UI::varPoll]
    set ::HvCmdLog::UI::varPoll $chosen
    ::HvCmdLog::State::SetPollInterval $chosen
    if {[::HvCmdLog::State::GetPolling]} { ::HvCmdLog::SchedulePoll }
    return
}
#----------------------------------------------------------- file dialogs -----
# V6 - VERIFY: HyperView always has Tk, so these dialogs are available; they are
#     wrapped anyway, so a missing dialog only costs the Browse button - the path
#     can still be typed into the entry.
proc ::HvCmdLog::UI::AskOpenFile {title initial types} {
    set path ""
    catch { set path [tk_getOpenFile -title $title -initialdir $initial -filetypes $types] }
    return $path
}
proc ::HvCmdLog::UI::AskSaveFile {title initial name types} {
    set path ""
    catch {
        set path [tk_getSaveFile -title $title -initialdir $initial -initialfile $name \
            -defaultextension .tcl -filetypes $types]
    }
    return $path
}
proc ::HvCmdLog::UI::AskDir {title initial} {
    set dir ""
    catch { set dir [tk_chooseDirectory -title $title -initialdir $initial] }
    return $dir
}
proc ::HvCmdLog::UI::Confirm {title message} {
    set answer ""
    catch { set answer [tk_messageBox -title $title -message $message \
        -type yesno -icon question] }
    if {$answer eq "yes"} { return 1 }
    if {[string is integer -strict $answer] && $answer == 1} { return 1 }
    return 0
}
#----------------------------------------------------------- file buttons -----
# Browse for the HyperView command file and watch it from its start (the user
# asked for that file, so its content is what they want to see).
proc ::HvCmdLog::UI::OnBrowseCmdFile {} {
    set initial ""
    set current [::HvCmdLog::State::GetCommandFile]
    if {$current ne ""} { set initial [file dirname $current] }
    if {$initial eq "" || ![file isdirectory $initial]} { set initial [pwd] }
    set path [::HvCmdLog::UI::AskOpenFile "HyperView command file" $initial \
        {{"Command files" {.cmf .tcl .txt}} {"All files" *}}]
    if {$path eq ""} { return }
    set ::HvCmdLog::UI::varCmdFile $path
    ::HvCmdLog::UseCommandFile $path 0
    return
}
# The entry next to the buttons: whatever is in it becomes the watched file
# (this is the way out when the file has a name / folder the auto-detection
# cannot guess - V1).
proc ::HvCmdLog::UI::OnUseCmdFile {} {
    set path [string trim $::HvCmdLog::UI::varCmdFile]
    if {$path eq ""} {
        ::HvCmdLog::Emit "# no command file given - type a path or use Browse..."
        return
    }
    ::HvCmdLog::UseCommandFile $path 0
    return
}
proc ::HvCmdLog::UI::OnBrowseScriptDir {} {
    set dir [::HvCmdLog::UI::AskDir "Folder for the captured scripts" \
        [::HvCmdLog::Adapter::ScriptDirNow]]
    if {$dir eq ""} { return }
    set ::HvCmdLog::UI::varScriptDir $dir
    ::HvCmdLog::UI::OnUseScriptDir
    return
}
proc ::HvCmdLog::UI::OnUseScriptDir {} {
    set dir [string trim $::HvCmdLog::UI::varScriptDir]
    if {$dir eq ""} { return }
    ::HvCmdLog::State::SetScriptDir $dir
    ::HvCmdLog::Emit "# script folder: $dir (takes effect with the next script file)"
    return
}
#----------------------------------------------------------- action buttons ---
# 'Save as...' - the buffer becomes a standalone, replayable Tcl script.
proc ::HvCmdLog::UI::OnSaveAs {} {
    set dir [::HvCmdLog::Adapter::ScriptDirNow]
    set name [::HvCmdLog::Logic::ScriptName \
        [::HvCmdLog::Logic::StampName [clock seconds]]]
    set path [::HvCmdLog::UI::AskSaveFile \
        "Save the captured commands as a Tcl script" $dir $name \
        {{"Tcl script" {.tcl}} {"All files" *}}]
    if {$path eq ""} { return }
    set res [::HvCmdLog::Adapter::SaveScriptAs $path]
    # Both outcomes are reported the same way - the message says which one it was.
    ::HvCmdLog::Emit "# [dict get $res message]"
    return
}
# 'Copy' - the buffer as text (handy to paste a few lines into the console and
# fix them there before running them).
proc ::HvCmdLog::UI::OnCopy {} {
    set lines [::HvCmdLog::State::GetLines]
    if {[llength $lines] == 0} {
        ::HvCmdLog::Emit "# nothing captured yet - nothing to copy"
        return
    }
    set copied 0
    if {![catch { clipboard clear }]} {
        if {![catch { clipboard append [join $lines "\n"] }]} { set copied 1 }
    }
    if {$copied} {
        ::HvCmdLog::Emit "# [llength $lines] lines copied to the clipboard"
    } else {
        ::HvCmdLog::Emit "# the clipboard is not available in this interpreter"
    }
    return
}
# 'Replay file...' - runs a captured script again.  Asking first, because every
# command in it really is executed in the running HyperView.
proc ::HvCmdLog::UI::OnReplay {} {
    set dir [::HvCmdLog::State::GetScriptDir]
    if {$dir eq "" || ![file isdirectory $dir]} { set dir [pwd] }
    set path [::HvCmdLog::UI::AskOpenFile "Replay a captured Tcl script" $dir \
        {{"Tcl script" {.tcl}} {"Command file" {.cmf}} {"All files" *}}]
    if {$path eq ""} { return }
    if {![::HvCmdLog::UI::Confirm "Replay [file tail $path] ?" \
            "Every command in the file is executed again in HyperView."]} {
        ::HvCmdLog::Emit "# replay cancelled"
        return
    }
    set res [::HvCmdLog::Adapter::ReplayScript $path]
    ::HvCmdLog::Emit "# [dict get $res message]"
    return
}
# 'Reload file' - forget the remembered file and search again (useful when
# HyperView starts writing a new command file in a new folder - V1).
proc ::HvCmdLog::UI::OnReload {} {
    ::HvCmdLog::State::ForgetFile
    ::HvCmdLog::Adapter::DiscoverOnce
    set file [::HvCmdLog::State::GetCommandFile]
    set ::HvCmdLog::UI::varCmdFile $file
    if {$file eq ""} {
        ::HvCmdLog::Emit "# no command file found - the hints in the log say where\
 to look, or type the path and press 'Watch this file'"
    } else {
        ::HvCmdLog::Emit "# command file: $file ([::HvCmdLog::State::GetCommandFileSource])"
    }
    return
}
# Closing the window stops the recording first: an open window is the only thing
# that can show it, and the poll loop would otherwise keep running unseen.
proc ::HvCmdLog::UI::OnClose {} {
    if {[::HvCmdLog::State::GetPolling]} { ::HvCmdLog::Stop }
    set ::HvCmdLog::UI::varRecording 0
    if {[::HvCmdLog::UI::Available]} { catch { destroy $::HvCmdLog::UI::gui } }
    set ::HvCmdLog::UI::gui ""
    set ::HvCmdLog::UI::wText ""
    set ::HvCmdLog::UI::wStatus ""
    return
}


#=============================================================================
# SECTION 5 - PUBLIC ENTRY
#   What the user types in the HyperView Tcl console.  Not one of these throws,
#   whatever this particular HyperView build offers: everything that is missing
#   is written into the log as a note instead.
#=============================================================================
# Opens the log window - and switches recording on, because a window that shows
# nothing while the user clicks would be misleading.  Returns 1 when the window
# is up (0 when this build has no hwtk: Start / Stop keep working then).
proc ::HvCmdLog::Show {} {
    ::HvCmdLog::Bootstrap
    if {!$::HvCmdLog::hasHwtk} {
        catch {
            puts "hv_cmd_logger: the hwtk widgets are missing in this interpreter."
            puts "  Use ::HvCmdLog::Start - the commands appear in the Tcl console."
        }
        return 0
    }
    if {[::HvCmdLog::UI::Available]} {
        catch { raise $::HvCmdLog::UI::gui }
        return 1
    }
    ::HvCmdLog::UI::Build
    if {![::HvCmdLog::State::GetPolling]} { ::HvCmdLog::Start }
    return 1
}
# The short commands for the HyperView console, next to the namespace versions.
proc ::hvlogShow {} { return [::HvCmdLog::Show] }
proc ::hvlogStart {} { return [::HvCmdLog::Start] }
proc ::hvlogStop {} { return [::HvCmdLog::Stop] }
proc ::hvlogClear {} { return [::HvCmdLog::Clear] }
# Writes the current buffer to a path the user gives - the same thing the
# 'Save as...' button does, without a dialog.
proc ::hvlogSave {path} { return [::HvCmdLog::Adapter::SaveScriptAs $path] }
# Runs an already captured script again (the 'Replay file...' button).
proc ::hvlogReplay {path} { return [::HvCmdLog::Adapter::ReplayScript $path] }

