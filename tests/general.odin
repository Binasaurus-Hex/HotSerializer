package tests

import "core:testing"
import "core:fmt"
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
union_modification :: proc(t: ^testing.T){
    Circle :: struct {
        centre: [2]f32,
        radius: f32
    }
    Rectangle :: struct {
        origin, size: [2]f32,
    }

    ShapeA :: union {
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

