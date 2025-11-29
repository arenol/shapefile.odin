package shp

import "core:fmt"
import "core:os"
import "core:time"
import fname "core:path/filepath"
import "core:strings"

@(private)
ShpFileMode :: enum {
    read,
    write
}

ShpHandle :: struct {
    fileMode  : ShpFileMode,
    shpHandle : os.Handle,
    shxHandle : os.Handle,
    dbfHandle : os.Handle,

    fieldDefs : [dynamic]Dbf3FieldDescriptor,
    shpHeader : ShpFileHeader,
    dbfHeader : Dbf3Header,
    numFeatures : int,

    hasCrs : bool,
    prjData : PrjData
}


@(private)
BuildFileName :: proc ( filePath : string, fileExt : string) -> string
{
    fileDir := fname.dir( filePath)
    baseName := fname.short_stem( filePath)

    fnb : strings.Builder   // file name builder
    defer strings.builder_destroy( &fnb);
    
    strings.write_string( &fnb, fileDir)
    if filePath != "" {
        strings.write_string( &fnb, "/")
    }
    strings.write_string( &fnb, baseName)
    strings.write_string( &fnb, fileExt)

    result := strings.clone_from_bytes( fnb.buf[:])
    return result
}

@(private)
ShpOpenFiles :: proc( handle :^ShpHandle, fileName: string) -> os.Error
{
    using handle

    // create file names for input files
    shpFileName := BuildFileName( fileName, ".shp")
    shxFileName := BuildFileName( fileName, ".shx")
    dbfFileName := BuildFileName( fileName, ".dbf")

    defer delete( shpFileName)
    defer delete( shxFileName)
    defer delete( dbfFileName)

    mode := os.O_RDONLY
    if fileMode == ShpFileMode.write {
        mode = os.O_WRONLY | os.O_CREATE | os.O_TRUNC
    }

    // try to open them all
    errp, errx, errd : os.Error
    shpHandle, errp = os.open( shpFileName, mode)
    shxHandle, errx = os.open( shxFileName, mode)
    dbfHandle, errd = os.open( dbfFileName, mode)


    // if any of them failed, clean up and return nil
    if (errp != nil) || (errx != nil) || (errd != nil) {
        if errp == nil { os.close( shpHandle) }
        if errx == nil { os.close( shxHandle) }
        if errd == nil { os.close( dbfHandle) }

        if errp == nil {
            if errx == nil { return errd } 
            else { return errx }
        } else { return errp }
    }
    return nil
}

@(private)
ShpUpdateFileBox :: proc( header :^ShpFileHeader, box:[]f64le)
{
    using header
    xmin = min(xmin, box[0])
    ymin = min(ymin, box[1])
    xmax = max(xmax, box[2])
    ymax = max(ymax, box[3])
}


open_files :: proc( fileName : string) -> (^ShpHandle, os.Error)
{
    handle := new( ShpHandle)
    using handle

    handle.fileMode = ShpFileMode.read
    err := ShpOpenFiles( handle, fileName)
    if err != nil { return nil, err }

    // read the header from the DBF file
    err = DbfReadHeader( handle)
    if err != nil { return nil, err }

    ShxReadHeader( handle)

    // calculate the number of features
    numFeatures = (int(handle.shpHeader.fileLen) * 2 - size_of(handle.shpHeader)) / 
                    size_of(ShxIndex )

    // read in the prj.file
    prjFileName := BuildFileName( fileName, ".prj")
    err = PrjReadFile( prjFileName, &prjData)
    hasCrs = (err == nil)

    return handle, nil
}

create_files :: proc( fileName : string, shpType :ShpType, epsgCode: string = "") -> (^ShpHandle, os.Error)
{
    handle := new( ShpHandle)
    using handle
    fileMode = ShpFileMode.write

    // support only XY shapes
    assert(int(shpType) < 10)


    // initialize the shape file header
    shpHeader.fileCode = 9994
    shpHeader.version = 1000
    shpHeader.shpType = i32le(shpType)

    // initialize the database header
    today := time.now()
    dbfHeader.fileDate[0] = u8( time.year(today) - 1900)
    dbfHeader.fileDate[1] = u8( time.month(today))
    dbfHeader.fileDate[2] = u8( time.day(today))

    numFeatures = 0
    

    prjFileName := BuildFileName( fileName, ".prj")
    defer delete( prjFileName)
    if (epsgCode != "") {
        hasCrs = PrjGet( epsgCode, &prjData )
        PrjWriteFile( prjFileName, &prjData)
    } 
    else {
        hasCrs = false
    }

    err := ShpOpenFiles( handle, fileName)

    return handle, err
}

add_field :: proc( handle :^ShpHandle,
                    aName : string, 
                    aType : u8,  // dbf... constants
                    aWidth : u8 = 0, 
                    aDecimals : u8 = 0)
{
    // can only do this before we have added any features to the files
    assert( handle.numFeatures == 0)

    fd: Dbf3FieldDescriptor
    DbfSetAttrName( &fd.name, aName)
    fd.type = aType
    fd.width = aWidth
    fd.decimals = aDecimals

    if aType == dbfDateAttribute {
        fd.width = 8
        fd.decimals = 0
    }

    append(&handle.fieldDefs, fd)
}

get_field_count :: proc( handle :^ShpHandle) -> int
{
    return len(handle.fieldDefs)
}

get_field_name :: proc( handle :^ShpHandle, index :int) ->string
{
    assert( index>=0 && index<len(handle.fieldDefs))

    return fmt.aprintf("%s", handle.fieldDefs[index].name)
}

get_field_type :: proc( handle :^ShpHandle, index :int) ->u8
{
    assert( index>=0 && index<len(handle.fieldDefs))

    return handle.fieldDefs[index].type
}

get_field_size :: proc( handle :^ShpHandle, index :int) ->(u8, u8)
{
    assert( index>=0 && index<len(handle.fieldDefs))

    fieldDef := handle.fieldDefs[index]
    return fieldDef.width, fieldDef.decimals
}

get_field_definition :: proc( handle :^ShpHandle, index :int) ->(string, u8, u8, u8)
{
    assert( index>=0 && index<len(handle.fieldDefs))

    fieldDef := handle.fieldDefs[index]

    fName := fmt.aprintf("%s", fieldDef.name)
    return fName, fieldDef.type, fieldDef.width, fieldDef.decimals
}

get_shape_type :: proc( handle :^ShpHandle) -> ShpType
{
    return ShpType(handle.shpHeader.shpType)
}

close_and_dispose :: proc (handle : ^^ShpHandle)
{
    ptr := handle^
    if ptr == nil {
        return
    }

    // Need to write the correct headers before closing
    if ptr.fileMode == ShpFileMode.write {

        err := DbfWriteHeader( ptr)
        assert( err == nil)
        err = ShpWriteHeader( ptr)
        assert( err == nil)

        err = ShxWriteHeader( ptr)
        assert( err == nil)
    }

    os.close(ptr.shpHandle)
    os.close(ptr.shxHandle)
    os.close(ptr.dbfHandle)

    if (ptr.hasCrs) {
        PrjDispose( &ptr.prjData)
    }

    delete( ptr.fieldDefs)
    free( ptr)
    
    handle^ = nil
}


read_next_obj :: proc( handle :^ShpHandle) -> (^ShpObject, os.Error)
{
    using handle

    obj := new( ShpObject)

    // read the next index entry from the shape file
    shpIndex : ShxIndex

    _, err := os.read_ptr( shxHandle, rawptr(&shpIndex), size_of(shpIndex))
    if (err != nil) { return nil, err }

    // read the geometry
    os.seek( shpHandle, i64(shpIndex.offset * 2), 0)
    type := int( shpHeader.shpType % 10)

    #partial switch ShpType(type) {
        case .point, .multiPoint:
            err := ShpReadPointFeature( shpHandle, obj);
            if (err != nil) { return nil, err }
        case .area, .line:
            err := ShpReadLineFeature( shpHandle, obj)
            if (err != nil) { return nil, err }
    }

    // read the attributes
    obj.attrs, _ = DbfReadNextRecord( handle)
    
    if (err != nil) { return nil, err }

    return obj, nil
}

read_obj :: proc( handle :^ShpHandle, index : int) -> (^ShpObject, os.Error)
{
    using handle
    shxOffset := i64( size_of(shpHeader) + index * size_of(ShxIndex))
    os.seek(shxHandle, shxOffset, 0)

    dbfOffset := int(dbfHeader.headerSize) + index * int(dbfHeader.recSize)
    os.seek( dbfHandle, i64(dbfOffset), 0)
    return read_next_obj( handle)
}

read_first_obj :: proc( handle :^ShpHandle) -> (^ShpObject, os.Error)
{
    return read_obj( handle, 0)
}

write_obj :: proc( handle :^ShpHandle, obj: ^ShpObject)  -> os.Error
{
    assert( handle.shpHeader.shpType == obj.shpType)
    using handle

    // before we write the first record, we must write an initial header
    if numFeatures == 0 {
        shpHeader.xmin = obj.box[0]
        shpHeader.ymin = obj.box[1]
        shpHeader.xmax = obj.box[2]
        shpHeader.ymax = obj.box[3]

        err := DbfWriteHeader( handle)
        if err != nil  { return err }

        err = ShpWriteHeader( handle)
        if err != nil  { return err }

        err = ShxWriteHeader( handle)
        if err != nil  { return err }
    } else {
        ShpUpdateFileBox( &shpHeader, obj.box[:])
    }

    // find out file position of shp file
    startPos, _ := os.seek( shpHandle, 0, os.SEEK_CUR)

    #partial switch ShpType(shpHeader.shpType) {
        case .point, .multiPoint:
            err := ShpWritePointFeature( shpHandle, obj, numFeatures)
            if err != nil  { return err }
        case .line, .area:
            err := ShpWriteLineFeature( shpHandle, obj, numFeatures)
            if err != nil  { return err }
    }

    // calculate record length from the new file position
    endPos, _ := os.seek( handle.shpHandle, 0, os.SEEK_CUR)

    // and then finally, write a record to the index file.
    shx : ShxIndex
    shx.offset = i32be(startPos / 2)            // recall, offset and len is in 16-bit words
    shx.len = i32be( (endPos - startPos) / 2) 
    _, err := os.write_ptr( shxHandle, rawptr(&shx), size_of( shx))
    if (err != nil) { return err }

    handle.numFeatures += 1
    return DbfWriteRecord( handle, obj.attrs[:])
}

get_epsg_code :: proc( handle :^ShpHandle) -> (string, bool)
{
    using handle
    if !hasCrs {
        return "", false
    }

    return PrjFindEpsgCode( &prjData)

}