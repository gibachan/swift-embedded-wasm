(module
  ;; Host function: toggles LED on/off once (one blink)
  (import "env" "blink" (func $blink))

  ;; blink_loop(count: i32) — calls blink() count times
  (func (export "blink_loop") (param $count i32)
    (local $i i32)
    (local.set $i (i32.const 0))

    (loop $continue (block $break
      ;; break if $i >= $count
      (br_if $break
        (i32.ge_s (local.get $i) (local.get $count))
      )

      (call $blink)

      ;; $i++
      (local.set $i
        (i32.add (local.get $i) (i32.const 1))
      )

      br $continue
    ))
  )
)
