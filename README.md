# Odin ShapeLib 

### version (v1.1, Nov 2025)
This Odin library is written to support export and import from ESRI Shape files. Only two-dimensional features are supported in this version.

Map projections is supported, but limmited to EPSG-codes.

See also the [Shapefile C Library](http://shapelib.maptools.org)

### Changes
* v1.1 (Nov, 2025): Added support for .prj files.

## Importing the library

    import "shp"

Or the path to the library directory.

## Types
 
### ShpHandle

    ShpHandle :: struct {
        ...
    }

Keeps track of the files and read/write state.

### ShapeType


    ShpType :: enum {
        null = 0,
        point = 1,
        line = 3,       // same as polyline
        area = 5,       // same as polygon
        multiPoint = 8,

        // not supported:
        pointZ = 11,  
        lineZ = 	13,
        areaZ = 15,
        multiPointZ = 18,
        pointM = 21,
        lineM = 23,
        areaM = 25,
        multiPointM = 28,
        multiPatch = 31
    }

To get the shape type from a shape handle:

    get_shape_type :: proc( handle :^ShpHandle) -> ShpType


### ShpObject 
Holds a single object or feature:

    ShpObject :: struct #packed {
        shpType   : i32le,
        box       : [4]f64le,
        numParts  : i32le,
        numPoints : i32le,
        parts     : [dynamic]i32le,
        coords    : [dynamic]ShpPoint,	// points
        attrs     : [dynamic]DbfValue
    }

### ShpValState
Used to return a state when you request an attribute value from an object

    ShpValState :: enum {
        ok,
        null,           // the attribute is nill
        incompatible    // e.g. if you request an int from an attribute that is a string
    }


## Constants
Database field types

    dbfStringAttribute  :: u8('C')
    dbfNumberAttribute  :: u8('N')
    dbfDateAttribute    :: u8('D')
    dbfFloatAttribute   :: u8('F')
    
## Procedures

### Open Existing Files
Open for reading:

    open_files :: proc( filePath : string) -> (^ShpHandle, os.Error)

### Reading Objects

    read_first_obj :: proc( handle :^ShpHandle) -> (^ShpObject, os.Error)
    read_obj :: proc( handle :^ShpHandle, index : int) -> (^ShpObject, os.Error)
    read_next_obj :: proc( handle :^ShpHandle) -> (^ShpObject, os.Error)

### Get Object Coordinates

    get_point_xy :: proc ( obj :^ShpObject) -> (f64, f64)

Asserts that obj is of type ShpType.point

    get_parts ::proc( obj :^ShpObject) -> [dynamic][dynamic][2]f64
    delete_parts :: proc (parts :[dynamic][dynamic][2]f64)

Asserts that obj is NOT of type ShpType.point

### Get Attribute Defintions

    get_field_count :: proc( handle :ShpHandle) -> int
    get_field_name :: proc( handle :ShpHandle, index :int) ->string
    get_field_type :: proc( handle :ShpHandle, index :int) ->u8
    get_field_size :: proc( handle :ShpHandle, index :int) ->(u8, u8)
        // returns width, decimals
    get_field_definition :: proc( handle :ShpHandle, index :int) ->(string, u8, u8, u8)
        // returns name, type, width, decimals 


### Get Object Attribute Values

    get_string_value :: proc( obj :^ShpObject, attrIndex : int) -> (string, ShpValState)
    get_int_value :: proc( obj :^ShpObject, attrIndex : int) -> (int, ShpValState)
    get_float_value :: proc( obj :^ShpObject, attrIndex : int) -> (f64, ShpValState)
    get_date_value :: proc( obj :^ShpObject, attrIndex : int) -> (time.Time, ShpValState)
    is_null_value :: proc( obj :^ShpObject, attrIndex : int) -> bool

### Create new Files
Open for write, will always create new files, overwriting existing ones.

    create_files :: proc( filePath : string, shpType :ShpType, epsgCode: string = "") -> (^ShpHandle, os.Error)

Adding database fields:

    add_field :: proc( handle :^ShpHandle,
                       name : string, 
                       type : u8, // dbf... constants
                       width : u8 = 0, 
                       decimals : u8 = 0)
                       
This must be done before writing objects to the files

### Closing Files

    close_and_dispose :: proc (handle : ^^ShpHandle)

Closes the files, and frees the memory. Sets the handle to nil.

### Creating Objects

    create_obj :: proc ( shpType : ShpType) -> ^ShpObject

You must add all attributes to the record, the number of values added must be the same as the number of attribute fields added.

    add_string_value :: proc ( obj :^ShpObject, strValue : string)
    add_int_value :: proc ( obj :^ShpObject, intValue : int)
    add_float_value :: proc ( obj :^ShpObject, floatVal : f64)
    add_date_value :: proc ( obj :^ShpObject, date : time.Time)
    add_null_value :: proc ( obj :^ShpObject)

Setting coordinates of point object:

    set_point_xy :: proc( obj: ^ShpObject, x, y: f64)

Adding coordinates of other shape types

    add_part :: proc( obj: ^ShpObject, xyData :[][2]f64)
    add_hole :: proc( obj: ^ShpObject, xyData :[][2]f64)

You can only add holes to area shapes, and you cannot add a hole unless you've added a part first.

*xyData* is an array of x and y pairs.

### Dispose Objects

    dispose_obj :: proc( obj : ^^ShpObject)

To free memory of object and set *obj* to **nil**


### Write Objects

    write_obj :: proc( handle :^ShpHandle, obj: ^ShpObject) -> os.Error

### Get the Coordinate Reference System

    get_epsg_code :: proc( handle :^ShpHandle) -> (string, ok: bool)

If the .prj file contains an *AUTHORITY* element with the EPSG-code, returns the code with ```ok = true``` if exists, but ```ok = false``` if an EPSG-code is not found, despite the fact that there is a .prj-file.

## Examples

### Reading From a File

    import "<path to shp>"
    
    read_shape_file proc :: (filePath :string)
    {
        handle, err := shp.open_files( filePath)
        assert (err == nil)
        defer shp.close_and_dispose( &handle)

        obj : ^shp.ShpObject
        obj, err = shp.read_first_obj( handle)
        for err == nil {
            do_something( obj)
			shp.dispose_obj( &obj)
			  
            obj, err = shp.read_next_obj( handle)
        }
    }

### Writing to a new File

    import "<path to shp>"
    import "core:time"

    write_to_file proc :: (filePath :string)
    {
        handle, err := shp.create_files( filePath, shp.ShpType.point, "EPSG:4326")
        defer close_and_dispose( &handle)
        assert( err == nil)

        shp.add_field( handle, "id", shp.dbfNumberAttribute, 5)
        shp.add_field( handle, "name", shp.dbfStringAttribute, 12)
        shp.add_field( handle, "area", shp.dbfNumberAttribute, 15, 2)
        shp.add_field( handle, "date", shp.dbfDateAttribute)

        obj := shp.create_obj( shp.ShpType.point)
        defer shp.dispose_obj( &obj)
        assert(obj != nil)

        shp.add_int_value( obj, 123)                // id
        shp.add_string_value( obj, "Trondheim")     // name
        shp.add_float_value( obj, 342.2)            // area (sq.km)
        shp.add_date_value( obj, time.now())        // date

        shp.set_point_xy( obj, 10.395916, 63.433412)  // only for point features
        // shp.add_part(...) for other types.
        // shp.add_hole(...) to add holes in polygon

        err = shp.write_obj( handle, obj)
        assert( err == nil)
    }


### Author
Agnar Renolen <agnar.renolen@gmail.com>
