package hot_serializer

import "core:reflect"
import "core:mem"
import "core:strings"
import "core:slice"
import rt "base:runtime"

TAG :: "hs"
CAST_PRIMITIVES :: #config(CAST_PRIMITIVES, true)

/*
-- High level overview --

serialize
- recurses the type information of what you pass in,
  and saves out the the information into our own structures that mirror odin's.

- then dumps this information, followed by the binary of the value you are serializing,
  into a slice of bytes.

- for dynamic structures: maps, dynamic arrays, slices, ...
    we recurse the actual data,
    append the dynamic contents to the end of the data
    'dehydrate' the pointer inside, into an offset relative to the start of the data

deserialize
- unpacks the type information from the bytes, and then the bytes of the value

- recurses over the type information of the current value we are deserializing into,
  and attempts to write from the source value to the destination value

- each recursive call returns whether or not that value was identical between our saved type info,
  and odin's current info

- this allows us to skip future cases of deserializing identical types, we instead just skip to the fallback option,
  which is a mem copy (faster).

- for dynamic types:
    'rehydrate' the pointer inside, and fetch our source data
    allocate the amount of destintion data we need on the heap
    recurse into this data
*/

Option :: enum {
    Dynamics
}

serialize :: proc(t: ^$T, allocator := context.allocator, options := bit_set[Option]{}) -> []byte {

    SerializationCtx :: struct {
        types:          [dynamic]TypeInfo,
        struct_fields:  [dynamic]Struct_Field,
        bit_fields:     [dynamic]Bit_Field,
        enum_fields:    [dynamic]Enum_Field,
        handles:        [dynamic]TypeInfo_Handle,
        arena:          [dynamic]byte,

        check_dynamics: bool,
    }
    ctx := SerializationCtx {}
    context.allocator = context.temp_allocator

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

        case rt.Type_Info_Bit_Field:
            save_bit_field := TypeInfo_Bit_Field {}
            save_bit_field.backing_type = save_type(ctx, v.backing_type.id)

            actual_fields := reflect.bit_fields_zipped(type)
            save_bit_field.fields = append_slice(&ctx.bit_fields, len(actual_fields))
            for i in 0..<save_bit_field.fields.length {
                field := actual_fields[i]

                field_name := to_index_string(&ctx.arena, field.name)
                field_type := save_type(ctx, field.type.id)

                ctx.bit_fields[i + save_bit_field.fields.index] = {
                    name = field_name,
                    type = field_type,
                    bit_size = field.size,
                    bit_offset = field.offset
                }
            }
            save_info.variant = save_bit_field

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

        // experimental
        case rt.Type_Info_Dynamic_Array:
            ctx.check_dynamics = true

            elem := save_type(ctx, v.elem.id)

            save_info.variant = TypeInfo_Dynamic_Array {
                elem = elem,
                elem_size = v.elem_size
            }

        case rt.Type_Info_Slice:
            ctx.check_dynamics = true

            elem := save_type(ctx, v.elem.id)

            save_info.variant = TypeInfo_Slice {
                elem = elem,
                elem_size = v.elem_size
            }

        case rt.Type_Info_String:
            ctx.check_dynamics = true
            save_info.variant = TypeInfo_String {
                is_cstring = v.is_cstring
            }
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


    header.types =          ctx.types[:]
    header.struct_fields =  ctx.struct_fields[:]
    header.bit_fields =     ctx.bit_fields[:]
    header.enum_fields =    ctx.enum_fields[:]
    header.handles =        ctx.handles[:]
    header.arena =          ctx.arena[:]
    header.options =        options

    bytes := make([dynamic]byte, allocator)

    append(&bytes, ..mem.ptr_to_bytes(&header))
    append(&bytes, ..mem.slice_to_bytes(header.types))
    append(&bytes, ..mem.slice_to_bytes(header.struct_fields))
    append(&bytes, ..mem.slice_to_bytes(header.bit_fields))
    append(&bytes, ..mem.slice_to_bytes(header.enum_fields))
    append(&bytes, ..mem.slice_to_bytes(header.handles))
    append(&bytes, ..mem.slice_to_bytes(header.arena))

    header_length := len(bytes)
    append(&bytes, ..mem.ptr_to_bytes(t))

    if ctx.check_dynamics && .Dynamics in options {
        munch(&bytes, header_length, header_length, type_info_of(T))
    }

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

get_typeinfo_ptr :: proc(header: ^SaveHeader, handle: TypeInfo_Handle) -> (ptr: ^TypeInfo, ok: bool) #no_bounds_check {
    index := int(handle) - 1
    return &header.types[index], true
}

deserialize :: proc(t: ^$T, data: []byte, options := bit_set[Option]{}) {

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
    extract_slice(&header.bit_fields,   &data)
    extract_slice(&header.enum_fields,  &data)
    extract_slice(&header.handles,      &data)
    extract_slice(&header.arena,        &data)

    body := data[:]

    start, ok := get_typeinfo_ptr(header, header.stored_type)
    assert(ok)

    header.data_base = uintptr(&body[0])
    header.options &= options

    identical := deserialize_raw(header, uintptr(&body[0]), uintptr(t), header.stored_type, type_info_of(T))
}

find_matching_field_index :: proc(header: ^SaveHeader, fields: []$T, name: string) -> (index: int, found: bool) {
    for &field, i in fields {
        if resolve_to_string(header.arena, field.name) != name do continue
        return i, true
    }
    return -1, false
}

fully_match_field :: proc(header: ^SaveHeader, fields: []$T, name: string, tag: string) -> (index: int, found: bool){

    tag_values := []string {}

    if t, ok := reflect.struct_tag_lookup(reflect.Struct_Tag(tag), TAG); ok {
        tag_values = strings.split(t, ",", context.temp_allocator)
    }

    // ignore this field
    if slice.contains(tag_values, "-") {
        return
    }

    index, found = find_matching_field_index(header, fields, name)
    if found do return


    for alias in tag_values {
        index, found  = find_matching_field_index(header, fields, alias)
        if found do return
    }
    return
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

deserialize_raw :: proc(header: ^SaveHeader, src, dst: uintptr, src_type: TypeInfo_Handle, dst_type: ^rt.Type_Info) -> (identical: bool) #no_bounds_check {
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

            saved_fields := to_slice(header.struct_fields, saved_struct.fields)

            for field in fields {

                field_index := fully_match_field(header, saved_fields, field.name, string(field.tag)) or_continue
                saved_field := saved_fields[field_index]

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
                value, valid = any_get_i64(a)
                return
            }

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

        case rt.Type_Info_Bit_Field:
            saved_bit_field := (&saved_type.variant.(TypeInfo_Bit_Field)) or_break
            fields := reflect.bit_fields_zipped(dst_type.id)

            saved_fields := to_slice(header.bit_fields, saved_bit_field.fields)

            matching_fields: int
            for field in fields {

                field_index := fully_match_field(header, saved_fields, field.name, string(field.tag)) or_continue

                matching_field: Bit_Field = saved_fields[field_index]

                source_bits :u64 = read_bits(cast([^]byte)src, matching_field.bit_offset, matching_field.bit_size)
                temporary_destination: u64
                field_identical := deserialize_raw(header, uintptr(&source_bits), uintptr(&temporary_destination), matching_field.type, field.type)

                write_bits(cast([^]byte)dst, field.offset, field.size, temporary_destination)
                if field_identical && matching_field.bit_offset == field.offset {
                    matching_fields += 1
                }
            }
            saved_type.identical = matching_fields == len(fields)
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

            src_tag := mem.make_any(rawptr(src + saved_union.tag_offset), tag_type.id)
            dst_tag := mem.make_any(rawptr(dst + v.tag_offset), v.tag_type.id)

            local_src_tag := any_get_i64(src_tag) or_break
            if local_src_tag == 0 do break

            src_variant := saved_variants[local_src_tag - 1]
            src_name, has_src_name := get_name(header, src_variant)

            src_variant_id: typeid
            if !has_src_name {
                source_typeinfo, found_info := get_typeinfo_ptr(header, src_variant)
                assert(found_info)
                src_variant_id = source_typeinfo.id
            }

            local_dst_tag: i64

            for variant, i in actual_variants {
                if has_src_name {
                    name := get_name_info_ptr(variant) or_continue
                    if name != src_name do continue
                }
                else {
                    if variant.id != src_variant_id do continue
                }
                local_dst_tag = i64(i + 1)
                break
            }

            // if we couldnt find the tag, just leave the union zeroed out
            if local_dst_tag == 0 {
                return saved_type.identical
            }

            dst_variant := actual_variants[local_dst_tag - 1]
            any_assign_i64(dst_tag, local_dst_tag)

            deserialize_raw(header, src, dst, src_variant, dst_variant)

            return saved_type.identical

        case rt.Type_Info_Dynamic_Array:

            if .Dynamics not_in header.options {
                saved_type.identical = false
                return saved_type.identical
            }

            saved_dynamic_array := (&saved_type.variant.(TypeInfo_Dynamic_Array)) or_break

            raw_src := transmute(^mem.Raw_Dynamic_Array)src
            raw_src.data = rawptr(uintptr(raw_src.data) + header.data_base)
            raw_src.cap = raw_src.len

            copy := make([]byte, raw_src.len * saved_dynamic_array.elem_size)

            raw_dst := transmute(^mem.Raw_Dynamic_Array)dst
            raw_dst.data = &copy[0]
            raw_dst.len = raw_src.len
            raw_dst.cap = raw_src.cap

            for i in 0..<raw_src.len {
                elem_src := uintptr(raw_src.data) + uintptr(i * saved_dynamic_array.elem_size)
                elem_dst := uintptr(raw_dst.data) + uintptr(i * v.elem_size)
                deserialize_raw(header, elem_src, elem_dst, saved_dynamic_array.elem, v.elem)
            }

            saved_type.identical = false
            return saved_type.identical

        case rt.Type_Info_String:

            if .Dynamics not_in header.options {
                saved_type.identical = false
                return saved_type.identical
            }

            saved_string := (&saved_type.variant.(TypeInfo_String)) or_break

            raw_src := transmute(^mem.Raw_String)src
            raw_src.data = transmute([^]byte)(uintptr(raw_src.data) + header.data_base)
            src_len := raw_src.len
            if saved_string.is_cstring {
                src_len = len(cstring(raw_src.data))
            }

            source_data := raw_src.data[:src_len]

            output_size: int = src_len
            if v.is_cstring {
                output_size += 1
            }

            output := make([]byte, output_size)

            copy(output, source_data)

            raw_dst := transmute(^mem.Raw_String)dst
            raw_dst.data = &output[0]

            raw_dst.len = raw_src.len

            saved_type.identical = false
            return saved_type.identical

        case rt.Type_Info_Slice:

            if .Dynamics not_in header.options {
                saved_type.identical = false
                return saved_type.identical
            }

            saved_slice := (&saved_type.variant.(TypeInfo_Slice)) or_break
            raw_src := transmute(^mem.Raw_Slice)src
            raw_src.data = rawptr(uintptr(raw_src.data) + header.data_base)

            copy := make([]byte, raw_src.len * saved_slice.elem_size)

            raw_dst := transmute(^mem.Raw_Slice)dst
            raw_dst.data = &copy[0]
            raw_dst.len = raw_src.len

            for i in 0..<raw_src.len {
                elem_src := uintptr(raw_src.data) + uintptr(i * saved_slice.elem_size)
                elem_dst := uintptr(raw_dst.data) + uintptr(i * v.elem_size)
                deserialize_raw(header, elem_src, elem_dst, saved_slice.elem, v.elem)
            }

            saved_type.identical = false
            return saved_type.identical


        // ignored pointer types
        case rt.Type_Info_Pointer, rt.Type_Info_Map:
            saved_type.identical = false
            return saved_type.identical
        }
    }

    // specified small types that dont automatically transmute
    when CAST_PRIMITIVES {

        if saved_type.id != dst_type.id {

            a := mem.make_any(rawptr(src), saved_type.id)
            b := mem.make_any(rawptr(dst), dst_type.id)

            if any_to_any(a, b){
                return false
            }
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

Bit_Field :: struct {
    name: IndexString,
    bit_size, bit_offset: uintptr,
    type: TypeInfo_Handle,
}

TypeInfo_Bit_Field :: struct {
    backing_type: TypeInfo_Handle,
    fields: IndexSlice(Bit_Field),
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

// dynamic stuff

TypeInfo_Dynamic_Array :: struct {
    elem: TypeInfo_Handle,
    elem_size: int
}

TypeInfo_Slice :: struct {
    elem: TypeInfo_Handle,
    elem_size: int
}

TypeInfo_String :: struct {
    is_cstring: bool
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
        TypeInfo_Union,
        TypeInfo_Bit_Field,
        TypeInfo_Dynamic_Array,
        TypeInfo_Slice,
        TypeInfo_String
    },

    // deserialization info
    identical: bool,
    identical_id: typeid,
}

SaveHeader :: struct {
    types:          []TypeInfo,
    struct_fields:  []Struct_Field,
    bit_fields:     []Bit_Field,
    enum_fields:    []Enum_Field,
    handles:        []TypeInfo_Handle,
    arena:          []byte,

    options: bit_set[Option],

    stored_type: TypeInfo_Handle,

    data_base: uintptr // used when deserializing to know where the memory starts
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

to_slice :: proc(buffer: []$T, is: IndexSlice(T)) -> []T #no_bounds_check {
    return buffer[is.index: is.index + is.length]
}

resolve_to_slice :: proc(buffer: []byte, is: IndexSlice($T)) -> []T {
    return slice.reinterpret([]T, buffer[is.index: is.index + is.length * size_of(T)])
}

resolve_to_string :: proc(buffer: []byte, is: IndexString) -> string #no_bounds_check {
    return string(buffer[is.index: is.index + is.length])
}

IndexSlice :: struct($T: typeid) {
    index, length: int,
}

IndexString :: distinct IndexSlice(byte)

any_get_f64 :: proc(a: any) -> (value: f64, valid: bool) {
    valid = true
    info := type_info_of(a.id)
    #partial switch info in info.variant {
    case rt.Type_Info_Float:
        switch v in a {
        case f16: value = f64(v)
        case f32: value = f64(v)
        case f64: value = v
        case: valid = false
        }
    case rt.Type_Info_Integer:
        int_value: i64
        int_value, valid = any_get_i64(a)
        if valid do value = f64(int_value)
        return
    }
    return
}

any_get_bool :: proc(a: any) -> (value: bool, valid: bool) {
    valid = true
    info := type_info_of(a.id)
    #partial switch info in info.variant {
    case rt.Type_Info_Boolean:
        switch v in a {
        case b8: value = bool(v)
        case b16: value = bool(v)
        case b32: value = bool(v)
        case b64: value = bool(v)
        case bool: value = v
        case: valid = false
        }
    case rt.Type_Info_Integer, rt.Type_Info_Float:
        int_value :u64
        int_value, valid = any_get_u64(a)
        if valid do value = bool(int_value)
    case:
        valid = false
    }
    return
}

any_get_u64 :: proc(a: any) -> (value: u64, valid: bool) {
    valid = true
    info := type_info_of(a.id)

    #partial switch info in info.variant {
    case rt.Type_Info_Integer:
        if info.signed {
            signed_value: i64
            signed_value, valid = any_get_i64(a)
            if valid do value = u64(signed_value)
            return
        }
        switch v in a {
        case u8:    value = u64(v)
        case u16:   value = u64(v)
        case u32:   value = u64(v)
        case u64:   value = v
        case uint:  value = u64(v)
        case: valid = false
        }
    case rt.Type_Info_Float:
        float_value: f64
        float_value, valid = any_get_f64(a)
        if valid do value = u64(float_value)
        return
    case rt.Type_Info_Boolean:
        bool_value: bool
        bool_value, valid = any_get_bool(a)
        if valid do value = u64(bool_value)
    case:
        valid = false
    }
    return
}

any_get_i64 :: proc(a: any) -> (value: i64, valid: bool) {
    valid = true
    info := type_info_of(a.id)

    #partial switch info in info.variant {
    case rt.Type_Info_Integer:
        if !info.signed {
            unsigned_value: u64
            unsigned_value, valid = any_get_u64(a)
            if valid do value = i64(unsigned_value)
            return
        }
        switch v in a {
        case i8:  value = i64(v)
        case i16: value = i64(v)
        case i32: value = i64(v)
        case i64: value = v
        case int: value = i64(v)
        case: valid = false
        }

    case rt.Type_Info_Float:
        float_value: f64
        float_value, valid = any_get_f64(a)
        if valid do value = i64(float_value)
        return
    case rt.Type_Info_Boolean:
        bool_value: bool
        bool_value, valid = any_get_bool(a)
        if valid do value = i64(bool_value)
    case:
        valid = false
    }
    return
}

any_to_any :: proc(a: any, b: any) -> (valid: bool) {
    info_b := type_info_of(b.id)
    #partial switch info in info_b.variant {
    case rt.Type_Info_Integer:
        if info.signed {
            if value, valid := any_get_i64(a); valid {
                any_assign_i64(b, value)
                return true
            }
        }
        else {
            if value, valid := any_get_u64(a); valid {
                any_assign_u64(b, value)
                return true
            }
        }
    case rt.Type_Info_Float:
        if value, valid := any_get_f64(a); valid {
            any_assign_f64(b, value)
            return true
        }
    case rt.Type_Info_Boolean:
        if value, valid := any_get_bool(a); valid {
            any_assign_bool(b, value)
            return true
        }
    }
    return false
}

any_assign_bool :: proc(a: any, value: bool){
    switch &v in a {
    case b8: v = b8(value)
    case b16: v = b16(value)
    case b32: v = b32(value)
    case b64: v = b64(value)
    case bool: v = value
    }
}

any_assign_f64 :: proc(a: any, value: f64){
    switch &v in a {
    case f16: v = f16(value)
    case f32: v = f32(value)
    case f64: v = value
    }
}

any_assign_u64 :: proc(a: any, value: u64){
    switch &v in a {
    case u8:  v = u8(value)
    case u16: v = u16(value)
    case u32: v = u32(value)
    case u64: v = value
    case uint: v = uint(value)
    }
}

any_assign_i64 :: proc(a: any, value: i64){
    switch &v in a {
    case i8: v = i8(value)
    case i16: v = i16(value)
    case i32: v = i32(value)
    case i64: v = value
    case int: v = int(value)

    case u8:  v = u8(value)
    case u16: v = u16(value)
    case u32: v = u32(value)
    case u64: v = u64(value)
    case uint: v = uint(value)
    }
}

read_bits :: proc(ptr: [^]byte, offset, size: uintptr) -> (res: u64) {
	for i in 0..<size {
		j := i+offset
		B := ptr[j/8]
		k := j&7
		if B & (u8(1)<<k) != 0 {
			res |= u64(1)<<u64(i)
		}
	}
	return
}

write_bits :: proc(dst: [^]byte, offset, size: uintptr, value: u64) {
    for i in 0..<size {
        j := i + offset
        B := &dst[j/8]
        k := j & 7
        if value & (u64(1) << i) != 0 {
            B^ |= u8(1) << k
        }
    }
}
