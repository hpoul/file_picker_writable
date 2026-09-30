package codeux.design.filepicker.file_picker_writable

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class ScopeTokensTest {

  @Test
  fun eachAcquireGetsItsOwnToken() {
    val tokens = ScopeTokens()
    val (a, _) = tokens.add("s1", "id")
    val (b, _) = tokens.add("s1", "id")
    assertNotEquals(a, b)
    assertEquals(2, tokens.size)
  }

  @Test
  fun releaseIsIdempotentPerToken() {
    val tokens = ScopeTokens()
    val (a, _) = tokens.add("s1", "id")
    assertTrue(tokens.release(a))
    assertFalse(tokens.release(a))
    assertFalse(tokens.release("never-issued"))
    assertEquals(0, tokens.size)
  }

  @Test
  fun aNewSessionDropsTheOldSessionsTokens() {
    val tokens = ScopeTokens()
    val (old, _) = tokens.add("before-hot-restart", "id")
    tokens.add("before-hot-restart", "id")
    val (fresh, dropped) = tokens.add("after-hot-restart", "id")
    assertEquals(2, dropped)
    assertEquals(1, tokens.size)
    // An old token is gone: releasing it is the idempotent no-op.
    assertFalse(tokens.release(old))
    assertTrue(tokens.release(fresh))
  }

  @Test
  fun concurrentAcquireAndReleaseBalance() {
    val tokens = ScopeTokens()
    val pool = Executors.newFixedThreadPool(8)
    try {
      val futures = (0 until 1000).map {
        pool.submit {
          val (token, _) = tokens.add("s1", "id-${it % 7}")
          check(tokens.release(token))
        }
      }
      futures.forEach { it.get(10, TimeUnit.SECONDS) }
    } finally {
      pool.shutdownNow()
    }
    assertEquals(0, tokens.size)
  }
}
