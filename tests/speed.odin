package tests

import "core:encoding/cbor"
import "core:encoding/json"
import "core:testing"
import "core:log"
import "core:time"
import hs ".."
import "core:mem"

RUN_SPEED_TESTS :: false


@test
speed :: proc(t: ^testing.T){
    if !RUN_SPEED_TESTS do return

    /*
    hot serializer does very well with large amount of identical data.
    this test on my laptop had these results:

        json took   7.2262959999999996s
        cbor took   1.4223448s
        hs took     0.0035487s
        memcpy took 0.001469s

    the performance is worse when modifying a lot of fields, but usually still much better than cbor.

    when hot reloading, the typical case is small amounts of type modification per iteration cycle,
    so here hs shines.

    use cbor if you want serialization of dynamically allocated structures, such as maps, dynamic arrays, and slices.
    hs doesnt support these.
    */

    Feature :: enum {
        Explodable,
        Cargo,
        Character,
        Sprite,
        Physics,
        Particle_Emitter,
    }

    PhysicsState :: struct {
        position, velocity: [2]f32,
        angle, angular_velocity: f32,
        mass: f32
    }

    CharacterState :: enum {
        Idle, Moving, Climbing
    }

    Entity :: struct {
        id: int,
        features: bit_set[Feature],

        physics_state: PhysicsState,
        character_state: CharacterState,
    }

    ENTITY_COUNT :: 100_000

    GameState :: struct {
        entities: [ENTITY_COUNT]Entity
    }

    gamestate := new(GameState, context.temp_allocator)
    for &entity, i in gamestate.entities {
        entity = {
            id = i,
            features = { .Cargo, .Physics, .Character },
            physics_state = {
                position = { f32(i), f32(i + 1) },
                velocity = { f32(i + 1), f32(i + 2) },
                mass = 5,
            },
            character_state = .Climbing,
        }
    }
    log.info("--identical--")

    // json
    {
        gamestate_new := new(GameState, context.temp_allocator)
        {
            time_section("json")

            data, err := json.marshal(gamestate^)
            testing.expect(t, err == nil)

            defer delete(data)

            json.unmarshal(data, gamestate_new)
        }
        testing.expect(t, gamestate_new^ == gamestate^)
    }

    // cbor
    {
        gamestate_new := new(GameState, context.temp_allocator)
        {
            time_section("cbor")

            data, err := cbor.marshal(gamestate^)
            defer delete(data)
            testing.expectf(t, err == nil, "{}", err)

            cbor.unmarshal(string(data), gamestate_new)
        }
        testing.expect(t, gamestate_new^ == gamestate^)
    }

    // hs
    {
        gamestate_new := new(GameState, context.temp_allocator)
        {
            time_section("hs")
            data := hs.serialize(gamestate)
            defer delete(data)
            hs.deserialize(gamestate_new, data)
        }

        testing.expect(t, gamestate_new^ == gamestate^)
    }

    // just for fun we can see how this compares to a raw memcpy
    {
        gamestate_new := new(GameState, context.temp_allocator)
        {
            time_section("memcpy")
            mem.copy(gamestate_new, gamestate, size_of(GameState))
        }
        testing.expect(t, gamestate_new^ == gamestate^)
    }


    /*
    now trying non identical here are the results:

    json took   7.2846051s
    cbor took   1.4436787s
    hs took     0.2223966s

    As you can see, both json and cbor exhibit similar performance as before, whilst hs is slower.
    However hs is still faster than both.

    The more 'non identical' the data becomes, the more work hs has to do and therefore the slower it becomes.
    */

    // non identical
    {
        PhysicsState2 :: struct {
            mass: f32,
            angle, angular_velocity: f32,
            friction_coefficient: f32,
            position, velocity: [2]f32,
        }

        Entity2 :: struct {
            id: int,
            features: bit_set[Feature],

            health: f32,
            damage: f32,

            name: [10]u8,

            physics_state: PhysicsState2,
            character_state: CharacterState,
        }
        GameState2 :: struct {
            entities: [ENTITY_COUNT]Entity2,
        }

        log.info("--non identical--")

        // json
        {
            gamestate_new := new(GameState2, context.temp_allocator)
            {
                time_section("json")

                data, err := json.marshal(gamestate^)
                testing.expect(t, err == nil)

                defer delete(data)

                json.unmarshal(data, gamestate_new)
            }
        }

        // cbor
        {
            gamestate_new := new(GameState2, context.temp_allocator)
            {
                time_section("cbor")

                data, err := cbor.marshal(gamestate^)
                defer delete(data)
                testing.expectf(t, err == nil, "{}", err)

                cbor.unmarshal(string(data), gamestate_new)
            }
        }

        // hs
        {
            gamestate_new := new(GameState2, context.temp_allocator)
            {
                time_section("hs")
                data := hs.serialize(gamestate)
                defer delete(data)
                hs.deserialize(gamestate_new, data)
            }
        }
    }
}

@test
dynamic_speed :: proc(t: ^testing.T){
    if !RUN_SPEED_TESTS do return
    Car :: struct {
        wheels: int,
        id: int,
        speed: f32,
        name: string
    }

    context.allocator = context.temp_allocator

    cars: [dynamic]Car
    for i in 0..<100_000 {
        append(&cars, Car {
            1, 2, 3, "ferrari"
        })
    }

    {
        time_section("hs dynamic")
        options := bit_set[hs.Option]{ .Dynamics }
        data := hs.serialize(&cars, options = options)

        new_cars: [dynamic]Car
        hs.deserialize(&new_cars, data, options = options)

        testing.expect(t, len(new_cars) == 100_000)
    }
    {
        time_section("cbor dynamic")

        data, err := cbor.marshal(cars)
        new_cars: [dynamic]Car
        cbor.unmarshal(string(data), &new_cars)
    }

}


time_section_end :: proc(name: string, start: time.Time){
    duration := time.duration_seconds(time.since(start))
    log.infof("{} took {}s", name, duration)
}

@(deferred_in_out = time_section_end)
time_section :: proc(name: string) -> time.Time {
    return time.now()
}