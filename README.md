# HotSerializer
Hot Serializer is a fast serializer/deserializer for odin, that works well for use cases such as hot reloading, where:
- we need it to be really fast, for large amounts of data
- we dont need a human readable or widely compatible format
- we do minimal type changes per iteration (data is mostly identical)

## Speed (linear scale) (HS is there, just too small to be visible on the graph)
<img width="600" height="390" alt="bar-graph" src="https://github.com/user-attachments/assets/d962f320-ce7a-48d6-90ac-82b76140b093" />

## Speed( logarithmic scale) ( you can see it now )
<img width="600" height="390" alt="bar-graph (1)" src="https://github.com/user-attachments/assets/6525e81f-4dbc-4afd-a202-f0d7b18555ff" />

## Basic Example
```odin
import hs "hot_serializer"

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
    import hs "hot_serializer"

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
- the grid_location has two aliases: "grid_index" and "grid_id". hs will look for these field names when deserializing.
- the temp_value has a value of "-". This tells hs to ignore the field.
## Further Info
for more info, check out doc.odin, or look through the tests
