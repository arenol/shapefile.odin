package shp

import "core:os"
import "core:fmt"
import "core:strings"
import "core:strconv"
import "core:mem"

kMaxAttrLen :: 11

@(private)
Dbf3Header :: struct #packed {
    fileDate : [3]u8,
    recCount : u32le,
    headerSize : u16le,
    recSize : u32le,
    reserved : [18]u8
}

@(private)
Dbf3FieldDescriptor :: struct  #packed {
    name : [kMaxAttrLen]u8,
    type : u8,
    address : i32le,
    width : u8,
    decimals :u8,
    reserved2 : [14]u8,
}

@(private)
DbfValue :: union  {
    bool,   // true if NILL
    int,
    f64,
    string,
}

dbfStringAttribute :: u8('C')
dbfNumberAttribute :: u8('N')
dbfDateAttribute :: u8('D')

@(private)
TrimValue :: proc(b: []u8) -> string {
    end, start : int
    for end=len(b); end > 0; end-=1 {
        c := b[end-1]
        if c != ' ' && c != 0 { break }
    }
    for start = 0; start < end; start+=1 {
        c := b[start]
        if (c != ' ') { break }
    }
    return string(b[start:end])
}

@(private)
DbfDecipherData :: proc( fieldDefs : []Dbf3FieldDescriptor, data : []u8 ) -> [dynamic]DbfValue
{
    valuesList : [dynamic]DbfValue

    dataLen := len( data)
    start := 1  // first byte = '*' if record is deleted -> not used
    for fd in fieldDefs {
        end := min(start + int(fd.width),dataLen)
        strval := TrimValue( data[start:end])
        value : DbfValue
        ok : bool

        // fmt.printfln( "%s:%c(%d,%d)", fd.name, fd.type, fd.width, fd.decimals)
        // fmt.printfln( "source(%d-%d) |%s|", start, end, string(data[start:end]))
        switch fd.type {
            case dbfStringAttribute:
                value = strval
            case dbfDateAttribute:
                if strval == "00000000" { value = true }
                else { value = strval}
            case dbfNumberAttribute:
                if strval[0] == '*' {
                    value = true
                } else if fd.decimals == 0 {
                    value, ok = strconv.parse_int( strval, 10)
                } else {
                    value, ok = strconv.parse_f64( strval)
                }
            case:
                value = strval
        }
        append(&valuesList, value)
        start = end
    }
    return valuesList
}


@(private)
DbfReadHeader :: proc (handle : ^ShpHandle) -> os.Error
{
    using handle
    headerByte : u8
    br, err := os.read_ptr( dbfHandle, rawptr(&headerByte), size_of(headerByte))
    if (err != nil) { return err }

    dbfVersion := headerByte & 0x03
    assert( dbfVersion == 3)

    br, err = os.read_ptr( dbfHandle, rawptr(&dbfHeader), size_of(dbfHeader))
    if (err != nil) { return err }

    // Calculate the number of fields
    fieldCount := (dbfHeader.headerSize - size_of(Dbf3Header)) / size_of(Dbf3FieldDescriptor)

    // Read field descriptions
    fieldDef : Dbf3FieldDescriptor
    for i in 0..<fieldCount {
        br, err = os.read_ptr( dbfHandle, rawptr(&fieldDef), size_of(fieldDef))
        if (err != nil) { return err }

        append( &fieldDefs, fieldDef)
    }

    // there is a 0x0d byte that marks the end of the field definition section
    endOfDefMarker : u8
    os.read_ptr( dbfHandle, rawptr(&endOfDefMarker), size_of( endOfDefMarker))
    assert(endOfDefMarker == 0x0d)

    return nil  // success
}


@(private)
DbfReadNextRecord :: proc (handle :^ShpHandle) -> ([dynamic]DbfValue, os.Error)
{
    using handle

    // allocate a buffer for the next attribute set
    dataSize := int(dbfHeader.recSize)
    data : [dynamic]u8;
    resize(&data, dataSize+1)
    defer delete( data)

    // read and decipher it
    _, err := os.read_ptr(dbfHandle, rawptr(&data[0]), dataSize)
    if (err != nil) { return nil, err }

    values := DbfDecipherData( fieldDefs[:], data[:])
    return values, nil
}

@(private)
DbfSetAttrName  :: proc( target : ^[kMaxAttrLen]u8, name: string, )
{
    aLen := len( name)
    for i in 0..<kMaxAttrLen {
        target[i] = i >= aLen ? u8(' ') : u8(name[i]) 
    }
}

@(private)
DbfAddNullString :: proc( sb :^strings.Builder, width : u8)
{
    for i in 0..<width {
        strings.write_rune( sb, '*')
    }
}

@(private)
DbfCreateRecord :: proc( fieldDefs : []Dbf3FieldDescriptor, values : []DbfValue)->string
{
    sb : strings.Builder
    defer strings.builder_destroy( &sb)

    strings.builder_init_none( &sb)
    strings.write_rune( &sb, ' ')   // '*' for deleted records

    /* this is a two step procedure
        1: create the <format> string do be used in printf
        2: create the actual string
    */
    assert( len(fieldDefs) == len(values))

    format : string
    for fd, i in fieldDefs {
        switch v in values[i] {
            case bool:
                // attribute is NULL
                switch fd.type {
                    case dbfStringAttribute:
                        format = fmt.aprintf("%%%-ds", fd.width)
                        strings.write_string(&sb, fmt.aprintf( format, ""))
                    case dbfNumberAttribute:
                        DbfAddNullString( &sb, fd.width)
                    case dbfDateAttribute:
                        strings.write_string(&sb, "00000000")
                }
            case int:
                format = fmt.aprintf("%% %dd", fd.width)
                strings.write_string(&sb, fmt.aprintf( format, v))
            case f64:
                format = fmt.aprintf("%% %d.%df", fd.width, fd.decimals)
                strings.write_string(&sb, fmt.aprintf( format, v))
            case string:
                format = fmt.aprintf( "%%-%ds", fd.width)
                strings.write_string(&sb, fmt.aprintf( format, v))
        }
        // fmt.printfln( "%s(%s) -> |%s|", fd.name, format, strings.to_string(sb))
    }
    return strings.to_string( sb)
    // fmt.printfln( "      -> |%s|", result)
    // return fmt.aprintf("%s", result)
}


@(private)
DbfCalcRecordSize :: proc (fieldDefs : []Dbf3FieldDescriptor) -> u32le
{
    total := 0
    for fd in fieldDefs {
        total += int(fd.width)
    }
    return u32le( total + 1) // add a byte for the deletion flag
}

@(private)
DbfCalcHeaderSize :: proc( fieldCount : int) -> u16le
{
    return u16le(size_of( Dbf3Header) + fieldCount * size_of(Dbf3FieldDescriptor) + 2)
}

@(private)
DbfWriteHeader :: proc( handle :^ShpHandle) -> os.Error
{
    using handle

    // calculate header size, record length and total number of records.
    dbfHeader.headerSize = DbfCalcHeaderSize( len( fieldDefs))
    dbfHeader.recSize = DbfCalcRecordSize( fieldDefs[:])
    dbfHeader.recCount = u32le(numFeatures)

    os.seek( dbfHandle, 0, os.SEEK_SET)

    _, err := os.write_byte( dbfHandle, 3)   // header byte
    if err != nil  { return err }

    _, err = os.write_ptr( dbfHandle, rawptr(&dbfHeader), size_of( dbfHeader))
    if err != nil  { return err }

    for fd, i in fieldDefs {
        _, err = os.write_ptr( dbfHandle, rawptr(&fieldDefs[i]), size_of( fd))
        if err != nil  { return err }
    }
    _, err = os.write_byte( dbfHandle, 0x0d) // end of fields marker
    return err
}

@(private)
DbfWriteRecord :: proc( handle :^ShpHandle, values :[]DbfValue ) -> os.Error
{
    recStr := DbfCreateRecord( handle.fieldDefs[:], values)
    _, err := os.write_string( handle.dbfHandle, recStr)
    return err
}

