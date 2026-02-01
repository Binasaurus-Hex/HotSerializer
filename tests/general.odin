package tests

import "core:testing"
import "core:mem"
import "core:slice"
import hs ".."

// STRUCTS //
@test
field_reordering :: proc(t: ^testing.T){
    StructA :: struct {
        a: f32,
        b: int,
    }

    StructB :: struct {
        b: int,
        a: f32,
    }

    a := StructA{1, 2}
    b := StructB{}

    data := hs.serialize(&a)
    defer delete(data)

    hs.deserialize(&b, data)

    testing.expect(t, b.a == a.a)
    testing.expect(t, b.b == a.b)
}

@test
field_renaming :: proc(t: ^testing.T){
    A :: struct {
        position: [2]f32,
        grid_location: int
    }

    B :: struct {
        position: [2]f32,
        grid_index: int `hs:"grid_location"`
    }

    a := A {
        position = { 1, 2 },
        grid_location = 15
    }


    a_data := hs.serialize(&a)
    defer delete(a_data)

    // single alias
    b: B
    hs.deserialize(&b, a_data)
    testing.expectf(t, b.grid_index == a.grid_location, "grid index = {}", b.grid_index)


    // multiple aliases
    C :: struct {
        position: [2]f32,
        grid_coordinate: int `hs:"grid_location,grid_index"`
    }

    c_from_a: C
    hs.deserialize(&c_from_a, a_data)
    testing.expect(t, c_from_a.grid_coordinate == a.grid_location)

    c_from_b: C
    b_data := hs.serialize(&b)
    defer delete(b_data)
    hs.deserialize(&c_from_b, b_data)
    testing.expect(t, c_from_b.grid_coordinate == a.grid_location)
}

@test
field_ignoring :: proc(t: ^testing.T) {
    A :: struct {
        position: [2]f32,
        health: int `hs:"-"`,
        damage: f32
    }
    a := A {
        position = { 1, 2 },
        health = 3,
        damage = 4
    }

    data := hs.serialize(&a)
    defer delete(data)

    b: A
    hs.deserialize(&b, data)

    expected := A {
        position = { 1, 2 },
        health = 0,
        damage = 4
    }
    testing.expect(t, b == expected)
}

@test
sub_types_modified :: proc(t: ^testing.T){

    BallA :: struct {
        position: [2]f32,
        radius: f32,
    }

    GameA :: struct {
        level: int,
        balls: [3]BallA,
        health: f32
    }

    BallB :: struct {
        position: [2]f32,
        bounce_factor: int,
        radius: f32
    }

    GameB :: struct {
        level: int,
        balls: [3]BallB,
        health: f32
    }

    game_a := GameA {
        level = 3,
        health = 100
    }
    for &ball, i in game_a.balls {
        ball = BallA {
            position = [2]f32 { f32(i), f32(i * 2) },
            radius = f32(i) * .2
        }
    }

    data := hs.serialize(&game_a)
    defer delete(data)

    game_b: GameB

    hs.deserialize(&game_b, data)

    for &ball, i in game_b.balls {
        testing.expect(t, ball.position == [2]f32 { f32(i), f32(i * 2) })
        testing.expect(t, ball.radius == f32(i) * .2)
        testing.expect(t, ball.bounce_factor == 0) // new fields should be zeroed out
    }
}

// other types

@test
enum_modification :: proc(t: ^testing.T){
    HeightA :: enum {
        Ground, Low, Middle, High
    }
    HeightB :: enum {
        Underground, Ground, Floor, Low, Middle, High,
    }

    low_a := HeightA.Low
    data := hs.serialize(&low_a)
    defer delete(data)

    low_b: HeightB

    hs.deserialize(&low_b, data)

    testing.expect(t, low_b == .Low)
}

@test
enumerated_array_modification :: proc(t: ^testing.T){
    HeightA :: enum {
        Ground, Low, Middle, High
    }
    HeightB :: enum {
        Underground, Ground, Floor, Low, Middle, High,
    }

    BallA :: struct {
        position: [2]f32,
        radius: f32
    }
    BallB :: struct {
        position: [2]f32,
        mass: f32,
        radius: f32
    }

    array_a: [HeightA]BallA
    array_a[.Low] = BallA {
        position = {1, 2},
        radius = 3
    }
    array_a[.High] = BallA {
        position = {3, 4},
        radius = 5
    }

    data := hs.serialize(&array_a)
    defer delete(data)

    array_b: [HeightB]BallB
    hs.deserialize(&array_b, data)

    expected_low := BallB {
        position = { 1, 2 },
        radius = 3
    }

    expected_high := BallB {
        position = { 3, 4 },
        radius = 5
    }

    testing.expect(t, array_b[.Low] == expected_low)
    testing.expect(t, array_b[.High] == expected_high)
}

@test
union_primitives :: proc(t: ^testing.T){
    Value :: union {
        [2]f32,
        [2]i32,
        bool
    }

    v: Value = [2]f32 { 1, 2 }

    data := hs.serialize(&v)
    defer delete(data)

    Thing :: struct {
        blobs: [10]int
    }

    Value2 :: union {
        Thing,
        [3]f32,
        [2]i32,
        [2]f32,
        bool
    }

    v2: Value2
    hs.deserialize(&v2, data)

    coord, is_coord := v2.([2]f32)

    testing.expect(t, is_coord)
    testing.expect(t, coord == [2]f32 { 1, 2 })
}

@test
union_modification :: proc(t: ^testing.T){
    Circle :: struct {
        centre: [2]f32,
        radius: f32
    }
    Rectangle :: struct {
        origin, size: [2]f32,
    }

    ShapeA :: union{
        Circle, Rectangle
    }

    circle := Circle { {1, 2}, 3 }
    shape_a: ShapeA = circle
    data := hs.serialize(&shape_a)
    defer delete(data)

    // adding a variant and modifying existing variant
    {
        // important: union variants must be distinct types if they are not structs
        // this is so we can track the name between versions
        Triangle :: distinct [3][2]f32

        // redefining circle to mimick reloading into a new format
        // struct names inside a union must remain constant
        Circle :: struct {
            radius: f32,
            area: f32,
            centre: [2]f32,
        }

        ShapeB :: union {
            Rectangle, Triangle, Circle
        }

        shape_b: ShapeB
        hs.deserialize(&shape_b, data)

        circle_b, is_circle := shape_b.(Circle)
        testing.expect(t, is_circle)

        expected_circle := Circle {
            centre = circle.centre,
            radius = circle.radius,
            area = 0
        }

        testing.expect(t, circle_b == expected_circle)
    }


    // removing existing variant
    {
        Polygon :: distinct [10][2]f32
        ShapeB :: union {
            Rectangle, Polygon
        }

        shape_b: ShapeB
        hs.deserialize(&shape_b, data)

        testing.expect(t, shape_b == nil)
    }
}

@test
bitset_modification_addition :: proc(t: ^testing.T){

    // addition
    HeightA :: enum {
        Ground, Low, Middle, High
    }
    HeightB :: enum {
        Underground, Ground, Floor, Low, Middle, High,
    }

    set_a := bit_set[HeightA] { .Ground, .Low, .Middle }

    data := hs.serialize(&set_a)
    defer delete(data)

    set_b: bit_set[HeightB]
    hs.deserialize(&set_b, data)

    testing.expect(t, set_b == bit_set[HeightB] { .Ground, .Low, .Middle })
}

@test
bitset_modification_deletion :: proc(t: ^testing.T){

    // addition
    HeightA :: enum {
        Ground, Low, Middle, High
    }
    HeightB :: enum {
        Ground, Middle, High
    }

    set_a := bit_set[HeightA] { .Ground, .Low, .Middle }

    data := hs.serialize(&set_a)
    defer delete(data)

    set_b: bit_set[HeightB]
    hs.deserialize(&set_b, data)

    testing.expect(t, set_b == bit_set[HeightB] { .Ground, .Middle })
}

@test
array_length_modification :: proc(t: ^testing.T){
    Entity :: struct {
        position: [2]f32,
        velocity: [2]f32
    }

    make_entity :: proc(i: int) -> Entity {
        return {
            position = [2]f32 { f32(i), f32(i * 2) },
            velocity = { 9, 9 }
        }
    }
    entities: [1000]Entity
    for &entity, i in entities {
        entity = make_entity(i)
    }

    data := hs.serialize(&entities)
    defer delete(data)

    less_entities: [500]Entity
    hs.deserialize(&less_entities, data)

    for &entity, i in less_entities {
        testing.expect(t, entity == make_entity(i))
    }

    more_entities: [2000]Entity
    hs.deserialize(&more_entities, data)
    for &entity, i in more_entities {
        expected := make_entity(i)
        if i >= len(entities) {
            expected = {}
        }

        testing.expect(t, entity == expected)
    }
}

// @test
// pointer_types_ignored :: proc(t: ^testing.T){
//     Person :: struct {
//         age: int,
//         house: int
//     }
//     Car :: struct {
//         wheels: int,
//         weight: f32,
//     }

//     A :: struct {
//         people: map[string]Person,
//         cars: [dynamic]Car,
//         current_car: ^Car,
//         large_cars: []Car
//     }

//     context.allocator = context.temp_allocator
//     a: A
//     a.people["harry"] = {21, 99}

//     append(&a.cars, Car{4, 250})
//     a.current_car = &a.cars[0]

//     a.large_cars = a.cars[:]

//     data := hs.serialize(&a)

//     b: A
//     hs.deserialize(&b, data)

//     empty: A

//     testing.expect(t, slice.equal(mem.ptr_to_bytes(&b), mem.ptr_to_bytes(&empty)))
// }

@test
bit_fields :: proc(t: ^testing.T){

    Height :: enum {
        Low, Middle, High
    }

    A :: bit_field u64 {
        height: Height | 8,
        x: int | 3,
        y: int | 3,
        checked: bool | 1,
        interlaced: bool | 1
    }

    a := A {
        height = .Middle,
        x = -1,
        y = 2,
        checked = false,
        interlaced = true
    }

    NewHeight :: enum {
        Floor, Low, Middle, High
    }

    B :: bit_field u64 {
        checked: bool | 1,
        x: int | 3,
        y: int | 3,
        interlaced: bool | 1,
        height: NewHeight | 8,
    }

    data := hs.serialize(&a)
    defer delete(data)

    b: B
    hs.deserialize(&b, data)

    testing.expect(t, b.height == .Middle)
    testing.expect(t, a.x == b.x)
    testing.expect(t, a.y == b.y)
    testing.expect(t, a.checked == b.checked)
    testing.expect(t, a.interlaced == b.interlaced)
}

@test
primitive_casting :: proc(t: ^testing.T){
    A :: struct {
        x: f32,
        y: i64,
        z: u16,
        q: f32
    }

    a := A { 1, -2, 3, 1}

    data := hs.serialize(&a)
    defer delete(data)

    B :: struct {
        x: u16,
        y: f32,
        z: i64,
        q: b32
    }

    b: B

    hs.deserialize(&b, data)

    testing.expect(t, b.x == 1)
    testing.expect(t, b.y == -2)
    testing.expect(t, b.z == 3)
    testing.expect(t, b.q == true)
}