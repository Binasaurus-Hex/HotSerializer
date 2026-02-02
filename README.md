# HotSerializer
Hot Serializer is a fast serializer/deserializer for odin, that works well for use cases such as hot reloading, where:
- we need it to be really fast, for large amounts of data
- we dont need a human readable or widely compatible format
- we do minimal type changes per iteration (data is mostly identical)

## Speed (linear scale)
<img width="600" height="390" alt="bar-graph" src="https://github.com/user-attachments/assets/d962f320-ce7a-48d6-90ac-82b76140b093" />

## Speed( logarithmic scale)
<img width="600" height="390" alt="bar-graph (1)" src="https://github.com/user-attachments/assets/6525e81f-4dbc-4afd-a202-f0d7b18555ff" />

## Basic Example
```odin
package main
import hs "HotSerializer"

main :: proc(){
    A :: struct {
        position: [2]f32,
        velocity: [2]f32
    }

    a := A {
        position = { 1, 2 },
        velocity = { 3, 4 }
    }

    data: []byte = hs.serialize(&a)

    B :: struct {
        position: [2]f32,
        health: f32,
        velocity: [2]f32
    }

    b: B

    hs.deserialize(&b, data)

    assert(a.position == b.position)
    assert(a.velocity == b.velocity)
    assert(b.health == 0)
}
```

## Renaming / Excluding
you can use struct field tags to change how hs works.
```odin
    package main
    import hs "HotSerializer"

    main :: proc(){
        A :: struct {
            position: [2]f32,
            grid_index: int,

            temp_value: int,
        }

        B :: struct {
            position: [2]f32,
            grid_location: int  `hs:"grid_index,grid_id"`,

            temp_value: int     `hs:"-"`,
        }
    }
```
- `grid_location` has two aliases: `grid_index` and `grid_id`. hs will look for these field names when deserializing.
- `temp_value` has a value of `-`. This tells hs to ignore the field.

## Features / Limitations
### Enum, BitSet, Enumerated-Array support
Enums and their derivatives: bit_sets and enumerated_arrays, are handled properly.
Meaning you can reorder, add, or remove enum fields, and as long as names stay consistent, hs will match them up.

This is something currently neither cbor nor json support properly.
### Struct + BitField support
Structs and bit_fields similarly can have fields added / removed / modified, and allow for tag features (above)
### Union support
Unions will match on named values first, i.e `Name :: struct`, and then will default to matching based on `typeid`. For more robust union matching across revisions, it is recommended that you use named values. For primitive types you can do this with `distinct`.

### Dynamic Types
Currently, the supported dynamic types are as follows:
`[dynamic]T`,
`[]T`,
`string`,
`cstring`.

By default, these types are not serialized. However you can enable this feature with the `.Dynamics` option.

```odin
package main
import hs "HotSerializer"

main :: proc(){
    Car :: struct {
        top_speed: f32,
        acceleration: f32
    }

    cars: [dynamic]Car
    append(&cars, Car { 1, 2 })
    append(&cars, Car { 3, 4 })

    options := bit_set[hs.Option]{ .Dynamics }

    data := hs.serialize(&cars, options = options)

    saved_cars: [dynamic]Car

    hs.deserialize(&saved_cars, data, options = options)
}
```
the following dynamic types are not currently supported:
`map`,
`^T`

### Limited support for primitive type conversion
currently there is some limited support for primitive type casting. Below is a list of all primitives that can cast between each other:

`f16`,
`f32`,
`f64`,

`u8`,
`u16`,
`u32`,
`u64`,
`uint`,

`i8`,
`ì16`,
`i32`,
`i64`,
`int`,

`b8`,
`b16`,
`b32`,
`b64`,
`bool`,

## Serialization / Deserialization relative speed
<img width="600" height="390" alt="bar-graph (3)" src="https://github.com/user-attachments/assets/1b005b7d-22be-40fb-92be-d071c76517e5" />
<img width="600" height="390" alt="bar-graph (4)" src="https://github.com/user-attachments/assets/c3e0bb06-0f23-47c5-be9c-8c9aca53b6ff" />

- hs serialization is always very fast, regardless of the structure of the data.
- hs deserialization can be arbitrarily slower depending on exactly how different the data is.

# More Examples
check out the `tests/` directory for more examples on usage.
