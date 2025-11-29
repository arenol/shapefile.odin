package shp

import "core:os"
import "core:time"
import "core:fmt"
import "core:strconv"

// just to make the code more clear when points are declared as [2]f64
@(private) X :: 0
@(private) Y :: 1

ShpValState :: enum {
    ok,
    null,           // the attribute is nill
    incompatible    // e.g. if you request an int from an attribute that is string
}

ShpPoint :: struct {
	x : f64le,
	y : f64le
}

ShpObject :: struct #packed {
	shpType		: i32le,
	box			: [4]f64le,
	numParts	: i32le,
	numPoints	: i32le,
	parts 		: [dynamic]i32le,
	coords		: [dynamic]ShpPoint,	// points
	attrs		: [dynamic]DbfValue
}

@(private)
ShpDir :: enum {
    clockWise,
    counterClockWise
}

add_string_value :: proc ( obj :^ShpObject, strValue : string)
{
    val : DbfValue = strValue
    append(&obj.attrs, val)
}

get_string_value :: proc( obj :^ShpObject, attrIndex : int) -> (string, ShpValState)
{
    switch v in obj.attrs[attrIndex] {
        case bool:
            return "", ShpValState.null
        case string:
            return v, ShpValState.ok
        case int:
            return fmt.aprintf("%d", v), ShpValState.ok
        case f64:
            return fmt.aprintf("%f", v), ShpValState.ok
    }
    // unreachable code:
    return "", ShpValState.ok

}

add_int_value :: proc ( obj :^ShpObject, intValue : int)
{
    val : DbfValue = intValue
    append(&obj.attrs, val)
}

get_int_value :: proc( obj :^ShpObject, attrIndex : int) -> (int, ShpValState)
{
    switch v in obj.attrs[attrIndex] {
        case bool:
            return 0, ShpValState.null
        case string:
            i, ok := strconv.parse_int(v)
            return i, ok ? ShpValState.ok : ShpValState.incompatible
        case int:
            return v, ShpValState.ok
        case f64:
            i := int(v)
            state := (f64(i) == v) ? ShpValState.ok : ShpValState.incompatible
            return i, state
    }
    // unreachable code:
    return 0, ShpValState.incompatible
}



add_float_value :: proc ( obj :^ShpObject, floatVal : f64)
{
    val : DbfValue = floatVal
    append(&obj.attrs, val)
}

get_float_value :: proc( obj :^ShpObject, attrIndex : int) -> (f64, ShpValState)
{
    switch v in obj.attrs[attrIndex] {
        case bool:
            return 0, ShpValState.null
        case string:
            f, ok := strconv.parse_f64( v)
            return f, ok? ShpValState.ok : ShpValState.incompatible
        case int:
            return f64(v), ShpValState.ok
        case f64:
            return v, ShpValState.ok
    }
    // unreachable code:
    return 0.0, ShpValState.incompatible
}

add_date_value :: proc( obj :^ShpObject, date : time.Time)
{
    year, month, day := time.date( date)
    val : DbfValue = fmt.aprintf("%4d%2d%2d", year, month, day)
    append(&obj.attrs, val)
}


get_date_value :: proc( obj :^ShpObject, attrIndex : int) -> (time.Time, ShpValState)
{
    #partial switch v in obj.attrs[attrIndex] {
        case bool:
            return time.Time{0}, ShpValState.null
        case string:
            y, oky := strconv.parse_int(v[:4])
            m, okm := strconv.parse_int(v[4:6])
            d, okd := strconv.parse_int(v[6:])

            if oky && okm && okd {
                t,ok := time.components_to_time(y,m,d,0,0,0)
                return t, ok ? ShpValState.ok : ShpValState.incompatible
            }
    }
 
    return time.Time{0}, ShpValState.incompatible
}

add_null_value :: proc ( obj :^ShpObject)
{
    val : DbfValue = true
    append(&obj.attrs, val)
}

is_null_value :: proc( obj :^ShpObject, attrIndex : int) -> bool
{
    #partial switch v in obj.attrs[attrIndex] {
        case bool:
            return true
    }
    return false
}


create_obj :: proc ( shpType : ShpType) -> ^ShpObject
{
    obj := new( ShpObject)
    if (obj != nil) {
        obj.shpType = i32le( shpType)
        obj.numParts = 0
        obj.numPoints = 0
        obj.box = {0.0, 0.0, 0.0, 0.0}
    }
    return obj
}

set_point_xy :: proc( obj: ^ShpObject, x, y: f64)
{
    using obj
    assert( ShpType(shpType) == ShpType.point)

    p : ShpPoint = { f64le(x), f64le(y)}
    resize( &coords, 1)
    coords[0] = p

    box = {p.x, p.y, p.x, p.y}
    numPoints = 1
}


@(private)
ShpUpdateBox :: proc( obj: ^ShpObject, p :ShpPoint)
{
    using obj
    // set an initial bounding box for the first part
    if len(coords) == 0 {
        // this is called BEFORE appending the point
        box[0] = p.x
        box[1] = p.y
        box[2] = p.x
        box[3] = p.y
        return
    }


    box[0] = min(box[0], p.x)
    box[1] = min(box[1], p.y)
    box[2] = max(box[2], p.x)
    box[3] = max(box[3], p.y)
}

@(private)
ShpAppendCoords :: proc( obj: ^ShpObject, xyData :[][2]f64)
{
    // xyData points to memory with alternate x's and y's


    using obj
    
    // reserve space for more coordinates
    count := len( xyData)
    numPoints += i32le(count)
    reserve( &coords, count+1)


    // copy coordinates into the dynamic array
    p : ShpPoint
    
    for coord in xyData {
        p.x = f64le(coord[X])
        p.y = f64le(coord[Y])

        ShpUpdateBox( obj, p)
        append( &coords, p)
    }

    // make sure that parts of area shapes are closed
    if ShpType(obj.shpType) == ShpType.area && xyData[0] != xyData[count-1] {
        append( &coords, coords[0])
    }

}

@(private)
ShpAppendReverseCoords :: proc( obj: ^ShpObject, xyData :[][2]f64)
{
    // xyData points to memory with alternate x's and y's


    using obj
    
    // reserve space for more coordinates
    count := len( xyData)
    numPoints += i32le(count)
    reserve( &coords, count+1)


    // copy coordinates into the dynamic array
    p : ShpPoint   
    #reverse for coord in xyData {
            p.x = f64le(coord[X])
            p.y = f64le(coord[Y])
            ShpUpdateBox( obj, p)
            append( &coords, p)
    }

    // make sure that parts of area shapes are closed
    if ShpType(obj.shpType) == ShpType.area && xyData[0] != xyData[count-1] {
        append( &coords, coords[0])
    }

}


add_part :: proc( obj: ^ShpObject, xyData :[][2]f64)
{
    using obj

    // cannot add parts to point object:
    assert( ShpType(shpType % 10) != ShpType.point)

    // cannot add more than one part to multi-point objects:
    assert( !((ShpType(shpType % 10) == ShpType.multiPoint) && (numParts ==0) ))

    append( &parts, numPoints)
    numParts += 1

    if (ShpType(obj.shpType) == ShpType.area) {
        // for area features, make sure that outer rings are clockWise,
        dir :=  CalcLineDirection( xyData) 

        if dir == ShpDir.clockWise {
            ShpAppendCoords( obj, xyData)
        }
        else {
            ShpAppendReverseCoords( obj, xyData)
        }
    } else {
        ShpAppendCoords( obj, xyData)
    }
}

add_hole :: proc( obj: ^ShpObject, xyData :[][2]f64)
{
    using obj

    // cannot only append objects to area features
    assert( ShpType(shpType % 10) == ShpType.area)
    
    // Cannot add hole as the first part
    assert( obj.numParts > 0)

    append( &parts, numPoints)
    numParts += 1

    // for area features, make sure that outer ring is clockWise,
    // and inner rings are counter clockvise, thus holes will
    // be counter clockvise
    dir :=  CalcLineDirection( xyData) 
    if dir == ShpDir.counterClockWise {
        ShpAppendCoords( obj, xyData)
    }
    else {
        ShpAppendReverseCoords( obj, xyData)
    }
}


@(private)
ShpDisposeObjMembers :: proc( obj : ^ShpObject)
{

	using obj
	if parts != nil || len(parts) > 0 { delete( parts) }
	if coords != nil || len(coords) > 0 { delete( coords) } 
	if attrs != nil || len(attrs)  > 0 { 

        // the string attributees are dynamically allocated, so delete them.
        for attr in attrs {
            #partial switch v in attr {
                case string:
                    delete( v)
            }
        }
        delete( attrs) 
    }

}

dispose_obj :: proc( obj : ^^ShpObject)
{
	ptr := obj^
    if ptr == nil {
        return
    }
	ShpDisposeObjMembers( ptr)
	free( ptr)
	obj^ = nil
}

@(private)
CalcLineDirection :: proc( p :[][2]f64) -> ShpDir
{
    signedArea := 0.0
    count := len(p)

    for i in 0..<count {
        j := (i+1) % count
        dx := p[j][X] - p[i][X]
        avgy := (p[j][Y] + p[i][Y]) * 0.5
        signedArea += (dx * avgy)
    }
    return signedArea > 0 ? ShpDir.clockWise : ShpDir.counterClockWise
}

@(private)
ShpCalcLineDirection :: proc( p :[]ShpPoint) -> ShpDir
{
    signedArea : f64le = 0.0
    count := len(p)

    for i in 0..<count {
        j := (i+1) % count
        dx := p[j].x - p[i].x
        avgy := (p[j].y + p[i].y) * 0.5
        signedArea += (dx * avgy)
    }
    return signedArea > 0 ? ShpDir.clockWise : ShpDir.counterClockWise
}



@(private)
ShpRevertCoordSlice :: proc( p :[]ShpPoint)
{
    count := len(p)
    n := count / 2
    last := count - 1
    for i in 0..<n {
        p[i], p[last-i] = p[last-i], p[i]
    }
}