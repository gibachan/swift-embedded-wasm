(module
    (import "env" "print_string" (func $print_string (param i32 i32)))
    (import "env" "print_value" (func $print_value(param i32)))
    (import "env" "buffer" (memory 1))

    (data (i32.const 0) "Fizz")
    (data (i32.const 31) "Buzz")
    (data (i32.const 63) "FizzBuzz")

    (func (export "fizzbuzz") (param $n i32)
        (local $i i32)
        (local.set $i (i32.const 1))

        (loop $continue (block $break
            local.get $i
            i32.const 15
            i32.rem_u
            i32.const 0
            i32.eq
            if
                (call $print_string (i32.const 63) (i32.const 8))
            else
                local.get $i
                i32.const 3
                i32.rem_u
                i32.const 0
                i32.eq
                if
                    (call $print_string (i32.const 0) (i32.const 4))
                else
                    local.get $i
                    i32.const 5
                    i32.rem_u
                    i32.const 0
                    i32.eq
                    if
                        (call $print_string (i32.const 31) (i32.const 4))
                    else
                        (call $print_value (local.get $i))
                    end
                end
            end

            (local.set $i
                (i32.add (local.get $i) (i32.const 1))
            )
            (br_if $break
                (i32.eq (local.get $i) (local.get $n))
            )
            br $continue
        ))
    )
)
