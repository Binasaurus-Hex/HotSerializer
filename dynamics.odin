package hot_serializer

import "core:reflect"
import rt "base:runtime"
import "core:mem"

munch :: proc(bytes: ^[dynamic]byte, bytes_start: int, index: int, type: ^rt.Type_Info){

    ptr := uintptr(&bytes[index])

    info_base := rt.type_info_base(type)

    #partial switch info in info_base.variant {
    case rt.Type_Info_Struct:
        for offset, i in info.offsets[:info.field_count] {
            munch(bytes, bytes_start, index + int(offset), info.types[i])
        }
    case rt.Type_Info_String:
        raw := transmute(^mem.Raw_String)ptr

        mark := len(bytes)
        raw_local := raw^
        raw.data = transmute([^]byte)(mark - bytes_start)
        append(bytes, ..raw_local.data[:raw_local.len])

    case rt.Type_Info_Enumerated_Array:
        for i in 0..<info.count {
            munch(bytes, bytes_start, index + i * info.elem_size, info.elem)
        }
    case rt.Type_Info_Array:
        for i in 0..<info.count {
            munch(bytes, bytes_start, index + i * info.elem_size, info.elem)
        }
    case rt.Type_Info_Slice:

        raw := transmute(^rt.Raw_Slice)ptr
        size := raw.len * info.elem_size

        if size == 0 do break

        mark := len(bytes)
        raw_local := raw^
        raw.data = transmute(rawptr)(mark - bytes_start)
        append(bytes, ..mem.byte_slice(raw_local.data, size))


        for i in 0..<raw_local.len {
            munch(bytes, bytes_start, mark + info.elem_size * i, info.elem)
        }

    case rt.Type_Info_Dynamic_Array:
        raw := transmute(^rt.Raw_Dynamic_Array)ptr
        size := raw.len * info.elem_size

        if size == 0 do break

        mark := len(bytes)
        raw_local := raw^
        raw.data = transmute(rawptr)(mark - bytes_start)
        append(bytes, ..mem.byte_slice(raw_local.data, size))

        for i in 0..<raw_local.len {
            munch(bytes, bytes_start, mark + info.elem_size * i, info.elem)
        }
    }
}