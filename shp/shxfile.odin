package shp

import "core:os"
import "core:fmt"

@(private)
ShxIndex :: struct {
    offset : i32be,
    len : i32be
}

@(private)
ShxReadHeader :: proc( handle :^ShpHandle) -> os.Error
{
    using handle
    _, err := os.read_ptr( shxHandle, rawptr(&shpHeader), size_of(shpHeader))
    return err
}

@(private)
ShxWriteHeader :: proc( handle :^ShpHandle) -> os.Error
{
	using handle

	assert( fileMode == ShpFileMode.write)


	fileSize, err := os.file_size( shxHandle)
	if err != nil { return err }
    
	shpHeader.fileLen = i32be(fileSize / 2)  // in 16-bit words

    curPos : i64
	curPos, err = os.seek( shxHandle, 0, os.SEEK_CUR)
	assert( err == nil)

	os.seek( shxHandle, 0, os.SEEK_SET)
	_, err = os.write_ptr( shxHandle, rawptr( &shpHeader), size_of(shpHeader))
    return err
}

