package wake

import "core:sync"
import "core:testing"
import "core:thread"

@(private="file") _posts: int

@(private="file")
_count_post :: proc "c" () { sync.atomic_add(&_posts, 1) }

// # teste: wake_request é thread-safe e posta só na transição
@(test)
test_wake_request_concurrent :: proc(t: ^testing.T) {
	// No poster: only the flag.
	set_poster(nil)
	take()
	request()
	testing.expect(t, take())

	_posts = 0
	set_poster(_count_post)
	defer set_poster(nil)
	before := requests()

	N :: 8
	PER :: 2000
	threads: [N]^thread.Thread
	for i in 0 ..< N {
		threads[i] = thread.create_and_start(proc() {
			for _ in 0 ..< PER { request() }
		})
	}
	for th in threads { thread.join(th); thread.destroy(th) }

	testing.expect_value(t, requests() - before, u64(N * PER))
	testing.expect(t, peek())
	testing.expect(t, take())
	testing.expect(t, !take(), "take consumes the flag")
	// Flag stayed set from the first request until take → exactly one post.
	testing.expect_value(t, sync.atomic_load(&_posts), 1)

	request()
	testing.expect_value(t, sync.atomic_load(&_posts), 2)
	take()
}
