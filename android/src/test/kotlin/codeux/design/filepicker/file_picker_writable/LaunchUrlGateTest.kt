package codeux.design.filepicker.file_picker_writable

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.util.ArrayDeque
import java.util.Random
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * `init` and `onNewIntent` must not interleave (review-4 F3): a launch URL
 * is handled exactly once, never dropped and never twice.
 */
class LaunchUrlGateTest {

  private fun unconfined() = LaunchUrlGate<String> {}

  @Test
  fun urlsBeforeInitWaitAndAreHandedOverOnceInOrder() {
    val gate = unconfined()
    assertFalse(gate.offer("a"))
    assertFalse(gate.offer("b"))
    assertEquals(listOf("a", "b"), gate.open())
  }

  @Test
  fun urlsAfterInitAreHandledImmediately() {
    val gate = unconfined()
    gate.open()
    assertTrue(gate.offer("c"))
  }

  @Test
  fun secondInitHandsOverNothing() {
    // A hot restart calls init again; the first init already took the queue.
    val gate = unconfined()
    gate.offer("a")
    assertEquals(listOf("a"), gate.open())
    assertEquals(emptyList<String>(), gate.open())
  }

  @Test
  fun offTheConfiningThreadIsLoud() {
    val owner = Thread.currentThread()
    val gate = LaunchUrlGate<String> {
      check(Thread.currentThread() === owner) { "confined" }
    }
    gate.offer("a")
    val executor = Executors.newSingleThreadExecutor()
    try {
      for (call in listOf<() -> Unit>({ gate.open() }, { gate.offer("b") })) {
        val outcome = executor.submit<Throwable?> {
          try {
            call()
            null
          } catch (e: IllegalStateException) {
            e
          }
        }.get(5, TimeUnit.SECONDS)
        if (outcome == null) {
          fail("An off-thread call must throw, not touch the queue.")
        }
      }
    } finally {
      executor.shutdownNow()
    }
    // Nothing leaked through the rejected calls.
    assertEquals(listOf("a"), gate.open())
  }

  /**
   * Models the main looper as a task queue. `init` is a coroutine that
   * suspends after taking the queue (each handleUri hops to IO), and
   * intents arrive as main-looper tasks in between. Every interleaving
   * must deliver each URL exactly once.
   */
  @Test
  fun everyInterleavingDeliversEachUrlExactlyOnce() {
    repeat(2000) { seed ->
      val random = Random(seed.toLong())
      val gate = unconfined()
      val looper = ArrayDeque<() -> Unit>()
      val handled = mutableListOf<String>()
      val urls = (0 until 1 + random.nextInt(6)).map { "url-$it" }

      // Some intents arrive before init is even posted (cold launch).
      val early = random.nextInt(urls.size + 1)
      urls.take(early).forEach { url ->
        if (gate.offer(url)) {
          handled += url
        }
      }
      val arrivals = urls.drop(early).map { url ->
        {
          if (gate.offer(url)) {
            // onNewIntent launches a coroutine; it runs as a later task.
            looper.add { handled += url }
          }
        }
      }.toMutableList()
      val initTask: () -> Unit = {
        for (url in gate.open()) {
          // handleUri suspends: resume as a later main-looper task.
          looper.add { handled += url }
        }
      }
      val posted = (arrivals + initTask).shuffled(random)
      looper.addAll(posted)
      while (looper.isNotEmpty()) {
        looper.poll()!!.invoke()
      }

      assertEquals("seed $seed", urls.sorted(), handled.sorted())
    }
  }
}
