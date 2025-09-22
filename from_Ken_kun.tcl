proc check_intersection { nodeList1 nodeList2 } {
    set len1 [ llength [ concat [ lsort -integer -unique $nodeList1 ] [ lsort -integer -unique $nodeList2 ] ] ]
    set len2 [ llength [ lsort -integer -unique [ concat $nodeList1 $nodeList2 ] ] ]
    if { [ expr abs( $len1 - $len2 ) ] == [ lindex [ lsort -integer [ list [ llength $nodeList1 ] [ llength $nodeList2 ] ] ] 0 ] } {
        set ans 1
    } else {
        set ans 0
    }
    return $ans
}
proc get_nodelist { nodeList vindexList } {
    set ans {}
    foreach vindex $vindexList {
        lappend ans [ lindex $nodeList $vindex ]
    }
    return $ans
}
proc get_faceid { solidElemId faceNodeList } {
    set ans      {}
    set nodeList [ hm_nodelist $solidElemId ]
    set faceid 0
    switch [ hm_getvalue elems id=$solidElemId dataname=config ] {
        {208} {
            foreach vindexList [ list [ list 0 1 2 3 ] [ list 4 5 6 7 ] [ list 0 1 5 4 ] [ list 1 2 6 5 ] [ list 2 3 7 6 ] [ list 0 4 7 3 ] ] {
                if { [ check_intersection [ get_nodelist $nodeList $vindexList ] $faceNodeList ] } {
                    lappend ans $faceid
                }
                incr faceid
            }
        }
        {206} {
            foreach vindexList [ list [ list 0 1 2 ] [ list 3 4 5 ] [ list 0 1 4 3 ] [ list 1 2 5 4 ] [ list 0 3 5 2 ] ] {
                if { [ check_intersection [ get_nodelist $nodeList $vindexList ] $faceNodeList ] } {
                    lappend ans $faceid
                }
                incr faceid
            }
        }
        {204} {
            foreach vindexList [ list [ list 0 1 2 ] [ list 0 1 3 ] [ list 1 2 3 ] [ list 0 3 2 ] ] {
                if { [ check_intersection [ get_nodelist $nodeList $vindexList ] $faceNodeList ] } {
                    lappend ans $faceid
                }
                incr faceid
            }
        }
    }
    return $ans
}
proc get_setid { setSegmentName } {
    set ans -1
    foreach setId [ hm_entitylist sets id ] {
        if { [ hm_getvalue sets id=$setId dataname=solvername ] == "$setSegmentName" } {
            set ans $setId
        }
    }
    return $ans
}
proc make_setSegment { setSegmentName } {
    set cardimage "SURFACE_ELEMENT"
    set setId [ get_setid "$setSegmentName" ]
    if { $setId > 0 } {
        # pass
        if { [ hm_getvalue sets id=$setId dataname=cardimage ] != "$cardimage" ] } {
            *setvalue sets id=$setId cardimage="$cardimage"
        }
    } elseif { [ hm_entityinfo exist sets "$setSegmentName" ] } {
        *setvalue sets id=$setId internalname=[ hm_getvalue sets id=$setId dataname=solvername ]
        *createentity sets cardimage=$cardimage includeid=0 name="$setSegmentName"
        set setId [ get_setid "$setSegmentName" ]
    } else {
        *createentity sets cardimage=$cardimage includeid=0 name="$setSegmentName"
        set setId [ get_setid "$setSegmentName" ]
    }
    return $setId
}
proc sel_solidface { setSegmentName } {
    #
    # need "Abaqus" template
    #
    if { [ string length [ string trim "$setSegmentName" ] ] > 0 } {
        #
        set setId [ make_setSegment "$setSegmentName" ]
        #
        *createmarkpanel nodes 1 "select Solid face nodes"
        if { [ hm_marklength nodes 1 ] > 0 } {
            *appendmark nodes 1 "by face"
            set faceNodeIds [ hm_getmark nodes 1 ]
            # *findmark nodes 1 257 1 elements 0 2
            *findmark nodes 1 1 1 elements 0 2
            hm_createmark elements 1 "by config" [ list hex8 penta6 tetra4 ]
            *markintersection elements 2 elements 1
            set solidElemIds [ hm_getmark elements 2 ]
            hm_markclear elements 1
            hm_markclear elements 2
            hm_markclear nodes 1
            if { [ llength $solidElemIds ] > 0 && [ llength $faceNodeIds ] >= 3 } {
                set faceElemIds {}
                set faceids     {}
                foreach solidElemId $solidElemIds {
                    foreach faceid [ get_faceid $solidElemId $faceNodeIds ] {
                        lappend faceElemIds $solidElemId
                        lappend faceids     $faceid
                    }
                }
                if { [ llength $faceElemIds ] > 0 && [ llength $faceids ] > 0 } {
                    *addedgesorfaces sets id=$setId reversenormal=1 user_ids=[ format "{%s}" $faceElemIds ] face_indices=[ format "{{%s}}" [ join $faceids "\} \{" ] ]
                }
            }
        }
    }
}
sel_solidface [ hm_getstring " setSegmentName = " "Enter SetSegmentName" ]