/*

Hot Serializer is designed primarily for fast serialization / deserialization of large amounts of data,
whilst avoiding many of the pitfalls of a straight memory copy.

for example:
    - modifying struct fields
    - modifying enum fields
    - modifying union variants

what Hot Serializer does NOT guarantee:
    - correct casting when modifying primitive types (e.g u64 -> f16)
    - any sort of serialization of dynamically allocated structures
        - maps
        - strings
        - dynamic arrays
        - slices
        - pointers

** Basic Example **
`
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

        hs.serialize(&b, data)

        assert(a.position == b.position)
        assert(a.velocity == b.velocity)
        assert(b.health == 0)
    }
`
In this example we serialize to a slice of bytes, on the default allocator, and then deserialize into a new struct with 'health' added.

** Renaming / Excluding **
you can use struct field tags to change how hs works.
`
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
`
- the grid_location has two aliases: "grid_index" and "grid_id". hs will look for these field names when deserializing.
- the temp_value has a value of "-". This tells hs to ignore the field.

** Supported Types **

    struct
    enum
    array
    enumerated_array
    bitset
    union

    primitives (casting):
        f32,
        f64,
        f16

    enum bases:
        i8,
        i16,
        i32,
        i64,
        int

everything else will be mem copied.
this will mean that changes between sizes of ints will still work.

*/
package hot_serializer
