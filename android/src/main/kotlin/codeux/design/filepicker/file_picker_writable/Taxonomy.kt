package codeux.design.filepicker.file_picker_writable

import io.flutter.plugin.common.MethodChannel
import java.io.FileNotFoundException

/** Error kinds shared by the experimental verbs (scope-registry-plan §6). */
object ErrorKind {
  const val PERMISSION_LOST = "permission-lost"
  const val NOT_FOUND = "not-found"
  const val SCOPE_CLOSED = "scope-closed"
}

/** A failure that belongs to the taxonomy, raised as [kind]. */
class TaxonomyException(
  val kind: String,
  message: String,
  cause: Throwable? = null
) : Exception(message, cause)

/**
 * Reports [e] for an experimental verb: taxonomy kinds as the code, with
 * the native domain and code in details. Anything outside the taxonomy
 * stays loud under its own exception class, never coerced into a kind.
 */
fun MethodChannel.Result.taxonomyError(e: Throwable) {
  val native = (e as? TaxonomyException)?.cause ?: e
  val details = mapOf(
    "domain" to "java",
    "code" to native.javaClass.name,
    "message" to native.message
  )
  val code = when (e) {
    is TaxonomyException -> e.kind
    is SecurityException -> ErrorKind.PERMISSION_LOST
    is FileNotFoundException -> ErrorKind.NOT_FOUND
    else -> e.javaClass.name
  }
  error(code, e.message ?: e.toString(), details)
}
