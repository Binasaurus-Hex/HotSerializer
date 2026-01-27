package hot_serializer

import "core:reflect"
import "core:mem"
import "core:strings"
import "core:slice"
import rt "base:runtime"

TAG :: "hs"
CAST_PRIMITIVES :: #config(CAST_PRIMITIVES, true)

serialize :: proc(t: ^$T, allocator := context.allocator) -> []byte {

    SerializationCtx :: struct {
        types:          [dynamic]TypeInfo,
        struct_fields:  [dynamic]Struct_Field,
        enum_fields:    [dynamic]Enum_Field,
        handles:        [dynamic]TypeInfo_Handle,
        arena:          [dynamic]byte,
    }
    ctx := SerializationCtx {}

    ctx.types.allocator = context.temp_allocator
    ctx.struct_fields.allocator = context.temp_allocator
    ctx.enum_fields.allocator = context.temp_allocator
    ctx.handles.allocator = context.temp_allocator
    ctx.arena.allocator = context.temp_allocator

    save_type :: proc(ctx: ^SerializationCtx, type: typeid) -> TypeInfo_Handle {

        append_slice :: proc(array: ^[dynamic]$T, n: int) -> IndexSlice(T) {
            index: int = len(array^)
            for i in 0..<n {
                append(array, T{})
            }
            return {index, n}
        }

        for info, i in ctx.types {
            if info.id != type do continue
            return TypeInfo_Handle(i + 1)
        }

        info := type_info_of(type)
        save_info := TypeInfo {
            size = info.size,
            id = type
        }
        #partial switch v in info.variant {
        case rt.Type_Info_Named:
            named_type := save_type(ctx, v.base.id)
            save_info.variant = TypeInfo_Named {
                name = to_index_string(&ctx.arena, v.name),
                type = named_type
            }

        case rt.Type_Info_Struct:
            save_struct := TypeInfo_Struct {}

            actual_fields := reflect.struct_fields_zipped(type)

            save_struct.fields = append_slice(&ctx.struct_fields, len(actual_fields))

            for i in 0..<len(actual_fields){
                field := actual_fields[i]
                field_type := save_type(ctx, field.type.id)
                ctx.struct_fields[save_struct.fields.index + i] = Struct_Field {
                    name = to_index_string(&ctx.arena, field.name),
                    offset = field.offset,
                    type = field_type,
                }
            }

            save_info.variant = save_struct

        case rt.Type_Info_Array:
            elem := save_type(ctx, v.elem.id)
            save_info.variant = TypeInfo_Array {
                elem = elem,
                elem_size = v.elem_size,
                count = v.count
            }

        case rt.Type_Info_Enum:
            save_enum := TypeInfo_Enum {}
            actual_fields := reflect.enum_fields_zipped(type)

            save_enum.base = save_type(ctx, v.base.id)
            save_enum.fields = append_slice(&ctx.enum_fields, len(actual_fields))

            for i in 0..<save_enum.fields.length {
                field := actual_fields[i]
                ctx.enum_fields[i + save_enum.fields.index] = {
                    name = to_index_string(&ctx.arena, field.name),
                    value = i64(field.value)
                }
            }

            save_info.variant = save_enum

        case rt.Type_Info_Enumerated_Array:

            elem := save_type(ctx, v.elem.id)
            index := save_type(ctx, v.index.id)

            save_info.variant = TypeInfo_Enumerated_Array {
                elem_size = v.elem_size,
                count = v.count,
                elem = elem,
                index = index
            }

        case rt.Type_Info_Bit_Set:
            elem := save_type(ctx, v.elem.id)
            save_info.variant = TypeInfo_Bit_Set {
                elem = elem
            }

        case rt.Type_Info_Union:

            tag_type := save_type(ctx, v.tag_type.id)

            save_union := TypeInfo_Union {
                tag_offset = v.tag_offset,
                tag_type = tag_type
            }

            save_union.variants = append_slice(&ctx.handles, len(v.variants))
            for i in 0..<save_union.variants.length {
                ctx.handles[i + save_union.variants.index] = save_type(ctx, v.variants[i].id)
            }

            save_info.variant = save_union
        }
        append(&ctx.types, save_info)
        return TypeInfo_Handle(len(ctx.types))
    }

    save_type(&ctx, T)

    header := SaveHeader {}

    for info, i in ctx.types {
        if info.id != T do continue
        header.stored_type = TypeInfo_Handle(i + 1)
    }


    header.types = ctx.types[:]
    header.struct_fields = ctx.struct_fields[:]
    header.enum_fields = ctx.enum_fields[:]
    header.handles = ctx.handles[:]
    header.arena = ctx.arena[:]

    bytes := make([dynamic]byte, allocator)

    append(&bytes, ..mem.ptr_to_bytes(&header))
    append(&bytes, ..mem.slice_to_bytes(header.types))
    append(&bytes, ..mem.slice_to_bytes(header.struct_fields))
    append(&bytes, ..mem.slice_to_bytes(header.enum_fields))
    append(&bytes, ..mem.slice_to_bytes(header.handles))
    append(&bytes, ..mem.slice_to_bytes(header.arena))
    append(&bytes, ..mem.ptr_to_bytes(t))

    return bytes[:]
}

get_typeinfo_base :: proc(header: ^SaveHeader, handle: TypeInfo_Handle) -> (base: ^TypeInfo, ok: bool){
    handle := handle
    for {
        base = get_typeinfo_ptr(header, handle) or_return
        named := base.variant.(TypeInfo_Named) or_break
        handle = named.type
    }
    return base, true
}

get_typeinfo_ptr :: proc(header: ^SaveHeader, handle: TypeInfo_Handle) -> (ptr: ^TypeInfo, ok: bool) {
    index := int(handle) - 1
    return &header.types[index], true
}

deserialize :: proc(t: ^$T, data: []byte) {

    split_ref :: proc(s: ^[]$T, index: int) -> []T {
        a, b := slice.split_at(s^, index)
        s^ = b
        return a
    }

    extract_slice :: proc(dst: ^[]$T, data: ^[]byte) {
        dst^ = slice.reinterpret([]T, split_ref(data, len(dst^) * size_of(T)))
    }

    data := data

    header := transmute(^SaveHeader)(&split_ref(&data, size_of(SaveHeader))[0])

    extract_slice(&header.types,        &data)
    extract_slice(&header.struct_fields,&data)
    extract_slice(&header.enum_fields,  &data)
    extract_slice(&header.handles,      &data)
    extract_slice(&header.arena,        &data)

    body := data[:]

    start, ok := get_typeinfo_ptr(header, header.stored_type)
    assert(ok)

    identical := deserialize_raw(header, uintptr(&body[0]), uintptr(t), header.stored_type, type_info_of(T))
}

find_matching_field :: proc(header: ^SaveHeader, struct_info: ^TypeInfo_Struct, name: string) -> (^Struct_Field, bool) {
    for &field in to_slice(header.struct_fields, struct_info.fields) {
        if resolve_to_string(header.arena, field.name) != name do continue
        return &field, true
    }
    return nil, false
}

enum_identical :: proc(header: ^SaveHeader, a: ^TypeInfo, b: ^rt.Type_Info) -> bool {
    a := (&a.variant.(TypeInfo_Enum)) or_return
    a_fields := to_slice(header.enum_fields, a.fields)
    b_fields := reflect.enum_fields_zipped(b.id)

    if len(a_fields) != len(b_fields) do return false
    for a_field, i in a_fields {
        b_field := b_fields[i]
        if a_field.value != i64(b_field.value) do return false
        a_name := resolve_to_string(header.arena, a_field.name)
        if a_name != b_field.name do return false
    }
    return true
}

get_name :: proc(header: ^SaveHeader, handle: TypeInfo_Handle) -> (s: string, ok: bool) {
    info := get_typeinfo_ptr(header, handle) or_return
    named := (&info.variant.(TypeInfo_Named)) or_return
    s = resolve_to_string(header.arena, named.name)
    return s, true
}

get_name_info_ptr :: proc(t: ^rt.Type_Info) -> (s: string, ok: bool) {
    named := (&t.variant.(rt.Type_Info_Named)) or_return
    return named.name, true
}

deserialize_raw :: proc(header: ^SaveHeader, src, dst: uintptr, src_type: TypeInfo_Handle, dst_type: ^rt.Type_Info) -> (identical: bool){
    saved_type, found_saved := get_typeinfo_base(header, src_type)
    assert(found_saved)

    dst_type := rt.type_info_base(dst_type)

    defer {
        if saved_type.identical {
            saved_type.identical_id = dst_type.id
        }
    }

    if !saved_type.identical {

        saved_type.identical = true

        #partial switch v in dst_type.variant {
        case rt.Type_Info_Struct:
            saved_struct := (&saved_type.variant.(TypeInfo_Struct)) or_break

            fields := reflect.struct_fields_zipped(dst_type.id)
            identical_fields: int

            for field in fields {

                tag_values: []string = {}

                if tag, ok := reflect.struct_tag_lookup(field.tag, TAG); ok {
                    tag_values = strings.split(tag, ",", context.temp_allocator)

                    // ignore this field
                    if slice.contains(tag_values, "-") {
                        continue
                    }
                }

                saved_field, field_found := find_matching_field(header, saved_struct, field.name)

                // check aliases
                if !field_found {
                    for alias in tag_values {
                        saved_field = find_matching_field(header, saved_struct, alias) or_continue
                        field_found = true
                    }

                    if !field_found {
                        continue
                    }
                }

                if saved_field.offset != field.offset do saved_type.identical = false
                field_src := src + saved_field.offset
                field_dst := dst + field.offset
                if deserialize_raw(header, field_src, field_dst, saved_field.type, field.type){
                    identical_fields += 1
                }
            }
            if identical_fields != len(fields) do saved_type.identical = false

            return saved_type.identical

        case rt.Type_Info_Array:
            saved_array := (&saved_type.variant.(TypeInfo_Array)) or_break
            count := min(saved_array.count, v.count)
            elem_identical: bool
            for i in 0..<count {
                elem_src := src + uintptr(i * saved_array.elem_size)
                elem_dst := dst + uintptr(i * v.elem_size)

                elem_identical = deserialize_raw(header, elem_src, elem_dst, saved_array.elem, v.elem)
                if elem_identical {
                    break
                }
                else {
                    saved_type.identical = false
                }
            }
            if elem_identical do break
            return saved_type.identical

        case rt.Type_Info_Enum:
            saved_enum := (&saved_type.variant.(TypeInfo_Enum)) or_break

            enum_get_value :: proc(header: ^SaveHeader, e: ^TypeInfo_Enum, src: rawptr) -> (value: i64, valid: bool) {
                base := get_typeinfo_base(header, e.base) or_return
                a := mem.make_any(src, base.id)
                valid = true
                switch v in a {
                case i8:  value = i64(v)
                case i16: value = i64(v)
                case i32: value = i64(v)
                case i64: value = v
                case int: value = i64(v)
                case:
                    valid = false
                }
                return
            }

            any_assign_i64 :: proc(a: any, value: i64){
                switch &v in a {
                case i8: v = i8(value)
                case i16: v = i16(value)
                case i32: v = i32(value)
                case i64: v = value
                case int: v = int(value)
                }
            }

            if saved_type.size != size_of(i64) do break
            if dst_type.size != size_of(i64) do break

            src_value :i64 = enum_get_value(header, saved_enum, rawptr(src)) or_break

            saved_fields := to_slice(header.enum_fields, saved_enum.fields)
            actual_fields := reflect.enum_fields_zipped(dst_type.id)

            // identical check
            if enum_identical(header, saved_type, dst_type) {
                break
            }

            // otherwise assumed to be a known, non identical enum, do the correct copy operation
            saved_type.identical = false

            saved_field: ^Enum_Field
            for &field in saved_fields {
                if field.value != src_value do continue
                saved_field = &field
                break
            }

            saved_name: string = resolve_to_string(header.arena, saved_field.name)
            for field in actual_fields {
                if field.name != saved_name do continue
                any_assign_i64(mem.make_any(rawptr(dst), v.base.id), i64(field.value))
                return saved_type.identical
            }

        case rt.Type_Info_Enumerated_Array:
            saved_array := (&saved_type.variant.(TypeInfo_Enumerated_Array)) or_break

            saved_index := get_typeinfo_base(header, saved_array.index) or_break

            if enum_identical(header, saved_index, v.index) {
                saved_index.identical = true
            }

            saved_elem := get_typeinfo_base(header, saved_array.elem) or_break
            if saved_index.identical && saved_elem.identical do break

            saved_type.identical = false

            saved_enum := (&saved_index.variant.(TypeInfo_Enum)) or_break
            saved_enum_fields := to_slice(header.enum_fields, saved_enum.fields)
            count := min(len(saved_enum_fields), v.count)

            for &saved_field in saved_enum_fields {
                saved_name := resolve_to_string(header.arena, saved_field.name)
                for actual_field in reflect.enum_fields_zipped(v.index.id){
                    if saved_name != actual_field.name do continue
                    elem_src := src + uintptr(int(saved_field.value) * saved_elem.size)
                    elem_dst := dst + uintptr(int(actual_field.value) * v.elem_size)
                    if !deserialize_raw(header, elem_src, elem_dst, saved_array.elem, v.elem){
                        saved_type.identical = false
                    }
                }
            }
            return saved_type.identical

        case rt.Type_Info_Bit_Set:
            saved_bitset := (&saved_type.variant.(TypeInfo_Bit_Set)) or_break
            saved_enum_base := get_typeinfo_base(header, saved_bitset.elem) or_break

            if enum_identical(header, saved_enum_base, v.elem) {
                saved_enum_base.identical = true
            }

            if saved_enum_base.identical && saved_type.size == dst_type.size do break

            saved_enum := (&saved_enum_base.variant.(TypeInfo_Enum)) or_break

            src_bytes := mem.byte_slice(rawptr(src), saved_type.size)
            dst_bytes := mem.byte_slice(rawptr(dst), dst_type.size)

            for &saved_field in to_slice(header.enum_fields, saved_enum.fields){
                byte_index: u64 = u64(saved_field.value / 8)
                bit_index: u64 = u64(saved_field.value % 8)

                src_byte := src_bytes[byte_index]
                is_set: bool = ((byte(1) << bit_index) & src_byte) > 0

                saved_name := resolve_to_string(header.arena, saved_field.name)

                for &actual_field in reflect.enum_fields_zipped(v.elem.id){
                    if actual_field.name != saved_name do continue

                    byte_index_actual := u64(actual_field.value / 8)
                    bit_index_actual := u64(actual_field.value % 8)

                    if is_set {
                        dst_bytes[byte_index_actual] |= 1 << bit_index_actual
                    }
                    else {
                        dst_bytes[byte_index_actual] &= ~(1 << bit_index_actual)
                    }
                }
            }
            saved_type.identical = false

            return saved_type.identical

        case rt.Type_Info_Union:
            saved_union := (&saved_type.variant.(TypeInfo_Union)) or_break


            saved_variants := to_slice(header.handles, saved_union.variants)
            actual_variants := v.variants

            check: {
                if len(saved_variants) != len(actual_variants) do break check

                for variant_handle, i in saved_variants {
                    saved_variant, found := get_typeinfo_base(header, variant_handle)
                    assert(found)
                    if !saved_variant.identical do break check
                    if saved_variant.identical_id != actual_variants[i].id do break check
                }
                break
            }
            saved_type.identical = false

            tag_type, found_tag_type := get_typeinfo_base(header, saved_union.tag_type)
            assert(found_tag_type)

            assert(tag_type.id == u32)
            assert(v.tag_type.id == u32)

            src_tag := cast(^u32)(src + saved_union.tag_offset)
            dst_tag := cast(^u32)(dst + v.tag_offset)

            if src_tag^ == 0 do break

            src_variant := saved_variants[src_tag^ - 1]
            src_name, has_src_name := get_name(header, src_variant)
            assert(has_src_name)

            for variant, i in actual_variants {
                name, ok := get_name_info_ptr(variant)
                assert(ok, "union variants must be structs or 'distinct' types")
                if name != src_name do continue
                dst_tag^ = u32(i + 1)
                break
            }

            // if we couldnt find the tag, just leave the union zeroed out
            if dst_tag^ == 0 {
                return saved_type.identical
            }

            dst_variant := actual_variants[dst_tag^ - 1]

            deserialize_raw(header, src, dst, src_variant, dst_variant)

            return saved_type.identical

        // ignored pointer types
        case rt.Type_Info_Pointer, rt.Type_Info_Map, rt.Type_Info_Dynamic_Array, rt.Type_Info_String:
            saved_type.identical = false
            return saved_type.identical
        }
    }

    // specified small types that dont automatically transmute
    when CAST_PRIMITIVES {
        try_cast :: proc(a, b: typeid, $A: typeid, $B: typeid, src, dst: uintptr) -> (casted: bool) {
            if a == b do return
            if a != A do return
            if b != B do return
            a_val: A = (transmute(^A)src)^
            b_ptr: ^B = transmute(^B)dst
            b_ptr^ = B(a_val)
            return true
        }
        try_cast_symmetric :: proc(a, b: typeid, $A: typeid, $B: typeid, src, dst: uintptr) -> (casted: bool) {
            if try_cast(a, b, A, B, src, dst) do return true
            if try_cast(a, b, B, A, src, dst) do return true
            return false
        }


        if try_cast_symmetric(saved_type.id, dst_type.id, f32, f64, src, dst){
            return false
        }
        if try_cast_symmetric(saved_type.id, dst_type.id, f32, f16, src, dst){
            return false
        }
        if try_cast_symmetric(saved_type.id, dst_type.id, f64, f16, src, dst){
            return false
        }
    }

    // fallback option
    if saved_type.size != dst_type.size do saved_type.identical = false
    size := min(saved_type.size, dst_type.size)
    mem.copy(rawptr(dst), rawptr(src), size)
    return saved_type.identical
}

// TYPE INFO

TypeInfo_Handle :: distinct int

Struct_Field :: struct {
    name: IndexString,
    offset: uintptr,
    type: TypeInfo_Handle,
}

TypeInfo_Struct :: struct {
    fields: IndexSlice(Struct_Field)
}

Enum_Field :: struct {
    name: IndexString,
    value: i64
}

TypeInfo_Enum :: struct {
    base: TypeInfo_Handle,
    fields: IndexSlice(Enum_Field)
}

TypeInfo_Array :: struct {
    elem: TypeInfo_Handle,
    elem_size: int,
    count: int
}

TypeInfo_Enumerated_Array :: struct {
    elem: TypeInfo_Handle,
    index: TypeInfo_Handle,
    elem_size: int,
    count: int,
}

TypeInfo_Bit_Set :: struct {
    elem: TypeInfo_Handle,
    underlying: TypeInfo_Handle,
    lower: i64,
    upper: i64,
}

TypeInfo_Union :: struct {
    variants: IndexSlice(TypeInfo_Handle),
    tag_offset: uintptr,
    tag_type: TypeInfo_Handle,
}

TypeInfo_Named :: struct {
    name: IndexString,
    type: TypeInfo_Handle
}

TypeInfo :: struct {
    size: int,
    id: typeid,
    variant: union {
        TypeInfo_Named,
        TypeInfo_Struct,
        TypeInfo_Enum,
        TypeInfo_Array,
        TypeInfo_Enumerated_Array,
        TypeInfo_Bit_Set,
        TypeInfo_Union
    },

    // deserialization info
    identical: bool,
    identical_id: typeid,
}

SaveHeader :: struct {
    types: []TypeInfo,
    struct_fields: []Struct_Field,
    enum_fields: []Enum_Field,
    handles: []TypeInfo_Handle,
    arena: []byte,

    stored_type: TypeInfo_Handle,
}

// string stuff

to_index_slice :: proc(buffer: ^[dynamic]byte, s: []$T) -> IndexSlice(T) {
    index := len(buffer)
    length := len(s)
    append(buffer, ..mem.slice_to_bytes(s))
    return {
        index, length
    }
}

to_index_string :: proc(buffer: ^[dynamic]byte, s: string) -> IndexString {
    return IndexString(to_index_slice(buffer, transmute([]byte)s))
}

to_slice :: proc(buffer: []$T, is: IndexSlice(T)) -> []T {
    return buffer[is.index: is.index + is.length]
}

resolve_to_slice :: proc(buffer: []byte, is: IndexSlice($T)) -> []T {
    return slice.reinterpret([]T, buffer[is.index: is.index + is.length * size_of(T)])
}

resolve_to_string :: proc(buffer: []byte, is: IndexString) -> string {
    return string(buffer[is.index: is.index + is.length])
}

IndexSlice :: struct($T: typeid) {
    index, length: int,
}

IndexString :: distinct IndexSlice(byte)