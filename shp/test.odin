package shp

import "core:testing"
import "core:fmt"
import "core:time"

//main :: proc()
/* @(test)
prjtest :: proc(_: ^testing.T) 
{
    prj : PrjData
    ok := PrjGet( "EPSG:32632", &prj)     // WGS84 / UTM32N
    defer PrjDispose(&prj)
    
    if !ok {
        fmt.printf( "Not Found")
    }
    PrjPrintWktTree( &prj.root)
} */


// main :: proc()

@(test)
CreateFileTest :: proc(_: ^testing.T)
{
    fmt.println( "HELLO")  

    handle, err := create_files( "testfile.shp", ShpType.point, "EPSG:4326")
    defer close_and_dispose( &handle)

    fmt.println( "ERR=", err)  
    assert( err == nil)

    fmt.println( "HAS CRS:", handle.hasCrs)
    fmt.println( "WKT:", handle.prjData.data)

    fmt.println( "defining fields")
    add_field( handle, "id", dbfNumberAttribute, 5)
    add_field( handle, "name", dbfStringAttribute, 12)
    add_field( handle, "area", dbfNumberAttribute, 15, 2)
    add_field( handle, "date", dbfDateAttribute)

    obj := create_obj( ShpType.point)
    defer dispose_obj( &obj)
    assert(obj != nil)

    fmt.println( "adding field values")
    add_int_value( obj, 123)                // id
    add_string_value( obj, "Trondheim")     // name
    add_float_value( obj, 342.2)            // area (sq.km)
    add_date_value( obj, time.now())        // date

    set_point_xy( obj, 10.395916, 63.433412)  // only for point features
    // add_part(...) for other types.
    // add_hole(...) to add holes in polygon
    fmt.println( "write object:")

    err = write_obj( handle, obj)
    fmt.println( "ERR=", err)
    assert( err == nil)
}