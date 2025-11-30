package shp

import "core:fmt"
import "core:strings"
import "core:slice"
import "core:strconv"
import "core:os"

kMaxNameLen :: 50

@(private)
WktNode :: struct {
    name : string,
    parent: ^WktNode,
    children : [dynamic]WktNode,
}

@(private)
PrjData :: struct {
    data :string,
    root :WktNode,
    staticData :bool,   // false if read from a file
}


@(private)
PrjInitNode :: proc( node :^WktNode, parent : ^WktNode = nil)
{
    node.name = ""
    node.parent = parent
    clear( &node.children)
}

@(private)
PrjSetNodeName :: proc( node: ^WktNode, sb :^strings.Builder) -> bool
{
    if strings.builder_len( sb^) > 0 {
        node.name = strings.clone_from_bytes( sb.buf[:])
        strings.builder_reset( sb)
        return true
    }
    return false
}

@(private)
PrjAppendChild :: proc (parent :^WktNode) -> ^WktNode
{
    newNode : WktNode
    newNode.parent = parent
    append( &parent.children, newNode)
    return slice.last_ptr(parent.children[:])
}

@(private)
PrjAppendSibling :: proc (sibling :^WktNode) -> ^WktNode
{
    newNode : WktNode
    newNode.parent = sibling.parent
    append( &sibling.parent.children, newNode)
    return slice.last_ptr(sibling.parent.children[:])
}


@(private)
PrjParseWkt :: proc( wktData :string, docTree: ^WktNode) -> bool
{
    inQuotedString := false
    sb : strings.Builder
    defer strings.builder_destroy( &sb)

    currentNode := docTree
    newNode : WktNode

    level := 0
    for rune in wktData {
        if inQuotedString && rune != '\"' {
            strings.write_rune( &sb, rune)
            continue
        }
        switch rune {
            case '\"':
                inQuotedString := !inQuotedString
            case '[':
                PrjSetNodeName( currentNode, &sb)
                currentNode = PrjAppendChild( currentNode)
                level += 1
            case ']':
                PrjSetNodeName( currentNode, &sb)
                level -= 1
                currentNode = currentNode.parent
            case ',':
                PrjSetNodeName( currentNode, &sb)
                currentNode = PrjAppendSibling( currentNode)
            case:
                strings.write_rune( &sb, rune)
        }
    }
    return currentNode.parent == nil
}

/*
    This is a debugging function, just to test the parsing
*/

@(private)
PrjPrintWktTree :: proc( node: ^WktNode, level : int = 0)
{
    indentation := strings.repeat("  ",  level)
    defer delete( indentation)

    fmt.printfln( "%s%s", indentation, node.name)
    if len(node.children) > 0 {
        fmt.printfln( "%s{{", indentation)
        for &child in node.children {
            PrjPrintWktTree( &child, level+1)
        }
        fmt.printfln( "%s}}", indentation)
    } 
}

@(private)
PrjPrintWkt :: proc( node: ^WktNode, out :os.Handle)
{
    if len(node.children) > 0 {
        fmt.fprint(out, node.name)
        fmt.fprint(out, "[")
        lastIndex := len(node.children) - 1
        for &child, i in node.children {
            PrjPrintWkt(&child, out)
            if i<lastIndex {
                fmt.fprint(out, ",")
            }
        }
        fmt.fprint(out, "]")
    }
    else {
        // check if the string converts into a number
        _, ok := strconv.parse_f64( node.name)
        if ok {
            fmt.fprint(out, node.name)
        }
        else {
            fmt.fprint(out, "\"%s\"", node.name)
        }
    }
}

@(private)
PrjReadFile :: proc( filePath :string, prj :^PrjData) -> os.Error
{
    wktData, err := os.read_entire_file_from_filename_or_err( filePath)
    if (err != nil) {
        return err
    }
    prj.data = string(wktData)

    PrjParseWkt(prj.data,&prj.root)
    prj.staticData = true
    return nil
}

@(private)
PrjWriteFile :: proc( filePath : string, prj :^PrjData) -> os.Error
{
    out, err := os.open( filePath, os.O_WRONLY | os.O_CREATE)
    defer os.close( out)
    if (err != nil) {
        return err
    }

    fmt.fprintln( out, prj.data)
    // PrjPrintWkt( &prj.root, out)
    return nil
}

@(private)
PrjFindNode :: proc( node: ^WktNode, name: string) -> ^WktNode
{
    // do not return leaf nodes
    if len(node.children) == 0 {
        return nil
    }
    if node.name == name {
        return node;
    } 

    for &child in node.children {
        result := PrjFindNode( &child, name)
        if result != nil {
            return result
        }
    }
    return nil
}

@(private)
PrjFindEpsgCode :: proc (prj :^PrjData) -> (string, bool)
{
    // first, try to find the EPSG-code in the current WKT-data
    node := PrjFindNode( &prj.root, "AUTHORITY")
    if node != nil {
        sb : strings.Builder
        result := fmt.sbprintf( &sb, "%s:%s", node.children[0].name, node.children[1].name)
        return strings.to_string( sb), true
    }
    // try use the name og the current wkt-data
    fstChild := prj.root.children[0]
    crsName := fstChild.name
    _, epsg, found := FindCrsByName( crsName)
    if found {
        return epsg, true
    }
    return "", false
}

@(private)
PrjGet :: proc(epsgCode : string, prj :^PrjData) -> bool
{
    wktString, ok := FindCrsByEpsg( epsgCode)
    if (!ok) {
        return false
    }
    prj.data = wktString
    prj.staticData = true
    return PrjParseWkt( wktString, &prj.root)
}

@(private)
PrjDisposeNode :: proc( node: ^WktNode)
{
    if len(node.children) > 0 {
        for &child in node.children {
            PrjDisposeNode( &child)
        }
    }
    delete( node.name)
    delete( node.children)
}

@(private)
PrjDispose :: proc( prj :^PrjData)
{
    PrjDisposeNode( &prj.root)
    if (!prj.staticData) {
        delete( prj.data)
    }
}

