(module
  (func $loop (export "loop_test") 
    (local $i i32)

    ;; $i = 0
    (local.set $i (i32.const 0))

    (loop $continue (block $break
      ;; $i++
      (local.set $i
        (i32.add (local.get $i) (i32.const 1))
      )

      (br_if $break
        ;; break if $i == 5
        (i32.eq (local.get $i) (i32.const 5))
      )
      
      br $continue ;; jump back to the top of the loop
    ))
  )
)
