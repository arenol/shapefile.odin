package shp

import "core:os"
import "core:fmt"

@(private)
ShpFileHeader :: struct #packed  {
	fileCode : i32be,
	unused1 : i32be,
	unused2 : i32be,
	unused3 : i32be,
	unused4 : i32be,
	unused5 : i32be,
	fileLen : i32be,
	version : i32le,
	shpType : i32le,
	xmin	: f64le,
	ymin	: f64le,
	xmax	: f64le,
	ymax	: f64le,
	zmin	: f64le,
	zmax	: f64le,
	mmin	: f64le,
	mmax	: f64le
}

ShpType :: enum {
	null = 0,
	point = 1,
	line = 3,
	area = 5,
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

@(private)
ShpRecordHeader :: struct #packed {
	index  : i32be,
	length : i32be
}

@(private)
ShpWriteHeader :: proc( handle :^ShpHandle) -> os.Error
{
	using handle

	assert( fileMode == ShpFileMode.write)

	fileSize, err := os.file_size( shpHandle)
	assert( err == nil)
	shpHeader.fileLen = i32be(fileSize / 2) // in 16-bit words

	curPos : i64
	curPos, err = os.seek( shpHandle, 0, os.SEEK_CUR)
    if err != nil  { return err }

	os.seek( shpHandle, 0, os.SEEK_SET)
	_, err = os.write_ptr( shpHandle, rawptr( &shpHeader), size_of(shpHeader))
	return err
}



@(private)
ShpReadCoords :: proc( file: os.Handle, coords: ^[dynamic]ShpPoint, count : int) -> os.Error
{
    resize( coords, count)
    bytes_to_read := count * size_of( ShpPoint)
    _, err := os.read_ptr( file, rawptr(&coords[0]), bytes_to_read)
	return err
}

@(private)
ShpWriteCoords :: proc( file: os.Handle, coords :[]ShpPoint) -> os.Error
{
	bytes_to_write := len(coords) * size_of( ShpPoint)
	_, err := os.write_ptr( file, rawptr(&coords[0]), bytes_to_write)
	return err
}


@(private)
ShpReadParts :: proc( file: os.Handle, parts: ^[dynamic]i32le, count : int) -> os.Error
{
	assert( count > 0)

	resize(parts, count)
	bytes_to_read := count * size_of(i32le)
	_, err := os.read_ptr( file, rawptr(&parts[0]), bytes_to_read)
	return err
}

@(private)
ShpWriteParts :: proc( file: os.Handle, parts :[]i32le) -> os.Error
{
	bytes_to_write := len(parts) * size_of(i32le)
	_, err := os.write_ptr( file, rawptr(&parts[0]), bytes_to_write)
	return err
}

/*
	Reads Polygon featrures and Polyline features
*/

@(private)
ShpReadLineFeature :: proc( file: os.Handle, obj: ^ShpObject) -> os.Error
{
	header : ShpRecordHeader
	br, err := os.read_ptr( file, rawptr(&header), size_of(header))
	if (err != nil) { return err }  // return if end of file

	// read first 44 bytes into record
	os.read_ptr( file, rawptr(obj), 44)
	if (err != nil) { return err }  // return if end of file

	// read parts
	if (obj.numParts > 0) {	
		err = ShpReadParts( file, &obj.parts, int(obj.numParts))
		if (err != nil) { return err }  // return if end of file
	}

	// read coords
    err = ShpReadCoords( file, &obj.coords, int(obj.numPoints))	
	if (err != nil) { return err }  // return if end of file

	return nil // success
}

@(private)
ShpWriteLineFeature :: proc( file :os.Handle, obj: ^ShpObject, index :int) -> os.Error
{
	header : ShpRecordHeader
	header.index = i32be(index)

	length := 44 + size_of( obj.parts[0]) * obj.numParts + size_of( obj.coords[0]) * obj.numPoints
	header.length = i32be( length / 2)	// recall, length is given in 16-bit words.

	_, err := os.write_ptr( file, rawptr(&header), size_of(header))
    if err != nil  { return err }

	_, err = os.write_ptr( file, rawptr(obj), 44)
    if err != nil  { return err }

	err = ShpWriteParts( file, obj.parts[:])
    if err != nil  { return err }

	return ShpWriteCoords( file, obj.coords[:])
}

/* 
	Read point features and multipoint features
*/

@(private)
ShpReadPointFeature :: proc( file : os.Handle, obj: ^ShpObject) -> os.Error
{
	header : ShpRecordHeader
	_, err := os.read_ptr( file, rawptr(&header), size_of(header))
	if (err != nil) { return err }

	_, err = os.read_ptr( file, rawptr(&obj.shpType), size_of(obj.shpType))
	if (err != nil) { return err }

	obj.numParts = 0

	fmt.println( obj)
	if ShpType(obj.shpType % 10) == ShpType.multiPoint {
		// read shape type and box
		_, err = os.read_ptr( file, rawptr(&obj.shpType), 32)
		if (err != nil) { return err }

		// read num points
		_, err = os.read_ptr( file, rawptr(&obj.numPoints), size_of(obj.numPoints))
		if (err != nil) { return err }

		err = ShpReadCoords( file, &obj.coords, int(obj.numPoints))
		if (err != nil) { return err }
	}
	else {
		obj.numPoints = 1
		err = ShpReadCoords( file, &obj.coords, int(obj.numPoints))

		// set the bounding box
		obj.box[0] = obj.coords[0].x
		obj.box[1] = obj.coords[0].y
		obj.box[2] = obj.coords[0].x
		obj.box[3] = obj.coords[0].y
	}
	return nil // success
}

get_point_xy :: proc ( obj :^ShpObject) -> (f64, f64)
{
	assert( ShpType(obj.shpType) == ShpType.point)

	using obj
	return f64(coords[0].x), f64(coords[0].y)
}

get_parts ::proc( obj :^ShpObject) -> [dynamic][dynamic][2]f64
{
	assert( ShpType(obj.shpType) != ShpType.point)

	result := make([dynamic][dynamic][2]f64, obj.numParts)

	newPart : [dynamic][2]f64 = nil
	p : [2]f64

	for pi in 0..<int(obj.numParts) {
		iStart := int(obj.parts[pi])
		iEnd := int(obj.numPoints)
		if (pi < int(obj.numParts - 1)) {
			iEnd = int(obj.parts[pi+1])
		}
		count := iEnd - iStart
		newPart := make([dynamic][2]f64, count)
		for i in iStart..<iEnd {
			p = {f64(obj.coords[i].x), f64(obj.coords[i].y)}
			newPart[i-iStart] = p
		}
		result[pi] = newPart

	}

	return result

}


delete_parts :: proc (parts :[dynamic][dynamic][2]f64)
{
	for p in parts {
		delete( p)
	}
	delete( parts)
}




@(private)
ShpWritePointFeature :: proc( file : os.Handle, obj: ^ShpObject, index : int) -> os.Error
{
	header : ShpRecordHeader
	header.index = i32be(index)
	err : os.Error

	if ShpType(obj.shpType) == ShpType.multiPoint {
		bytes := 32 + obj.numPoints * size_of(ShpPoint)
		header.length = i32be( bytes / 2)


		_, err = os.write_ptr( file, rawptr( &header), size_of( header))
		if (err != nil) { return err }

		_, err = os.write_ptr( file, rawptr( &obj.shpType), 32)
		if (err != nil) { return err }
		
		_, err = os.write_ptr( file, rawptr( &obj.numPoints), size_of(obj.numPoints))
		if (err != nil) { return err }
		
		err = ShpWriteCoords( file, obj.coords[:])
		if (err != nil) { return err }
		
	} 
	else if ShpType(obj.shpType) == ShpType.point {
		bytes := size_of(obj.shpType) + size_of( obj.coords[0])
		header.length = i32be(bytes / 2)

		_, err = os.write_ptr( file, rawptr( &obj.numPoints), size_of(obj.numPoints))
		if (err != nil) { return err }

		_, err = os.write_ptr( file, rawptr( &header), size_of( header))
		if (err != nil) { return err }

		_, err = os.write_ptr( file, rawptr( &obj.numPoints), size_of(obj.numPoints))
		if (err != nil) { return err }

		_, err = os.write_ptr( file, rawptr( &obj.shpType), size_of(obj.shpType))
		if (err != nil) { return err }

		_, err = os.write_ptr( file, rawptr( &obj.numPoints), size_of(obj.numPoints))
		if (err != nil) { return err }

		_, err = os.write_ptr( file, rawptr( &obj.coords[0]), size_of( obj.coords[0]))
		if (err != nil) { return err }

	}
	return nil
}


