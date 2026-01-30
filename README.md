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
- the grid_location has two aliases: `grid_index` and `grid_id`. hs will look for these field names when deserializing.
- the temp_value has a value of `-`. This tells hs to ignore the field.
## Features / Limitations
### Enum, BitSet, Enumerated-Array support
Enums and their derivatives: bit_sets and enumerated_arrays, are handled properly.
Meaning you can reorder, add, or remove enum fields, and as long as names stay consistent, hs will match them up.

This is something currently neither cbor nor json support properly.
### Struct + BitField support
Structs and bit_fields similarly can have fields added / removed / modified, and allow for tag features (above)
### Union support
Unions will be handled properly as long as the variants are named. This means if you want a primitive such as `[2]f32` you would need to make it distinct. eg. `Vec2 :: distinct [2]f32`.
This may be remedied in future versions, but generally speaking its more robust if the variants are explicitly named.
### No Support for dynamically allocated types
Types such as `string`, `map[K]V`, `[dynamic]T`, `[]T`, or `^T` do not contain the memory within the type itself, but rather contain a pointer to the memory.
These are currently not supported. If you include one of these in your data structure, they will be ignored.
### Limited support for primitive type conversion
Currently most primitive types are transmuted. meaning a `i32` which is modified to an `i64`, will simply be copied over without a proper cast. In many cases this works fine, but I wouldn't rely on it currently.
The types that currently are casted properly are as follows:
    
`f16`, `f32`, `f64`

## Serialization / Deserialization relative speed
<img width="600" height="390" alt="bar-graph (3)" src="https://github.com/user-attachments/assets/1b005b7d-22be-40fb-92be-d071c76517e5" />
<img width="600" height="390" alt="bar-graph (4)" src="https://github.com/user-attachments/assets/c3e0bb06-0f23-47c5-be9c-8c9aca53b6ff" />

- hs serialization is always very fast, regardless of the structure of the data.
- hs deserialization can be arbitrarily slower depending on exactly how different the data is.

## Further Info
for more info, check out doc.odin, or look through the tests
