package codeux.design.filepicker.file_picker_writable

import io.flutter.plugin.common.MethodChannel
import java.io.FileNotFoundException

/** Error kinds shared by the experimental verbs (scope-registry-plan §6). */
object ErrorKind {
  const val PERMISSION_LOST = "permission-lost"
  const val NOT_FOUND = "not-found"
  const val SCOPE_CLOSED = "scope-closed"
  const val NOT_A_DIRECTORY = "not-a-directory"
  const val NOT_A_FILE = "not-a-file"
  const val INVALID_NAME = "invalid-name"
}

/**
 * A failure that belongs to the taxonomy, raised as [kind], with [details]
 * (e.g. a `reason`) added to the error's details map.
 */
class TaxonomyException(
  val kind: String,
  message: String,
  cause: Throwable? = null,
  val details: Map<String, Any?> = emptyMap()
) : Exception(message, cause)

/**
 * Reports [e] for an experimental verb: taxonomy kinds as the code, with
 * the native domain and code in details. Anything outside the taxonomy
 * stays loud under its own exception class, never coerced into a kind.
 *
 * Two coercions are deliberate: a `SecurityException` is a refused grant
 * (`permission-lost`), and a `FileNotFoundException` a missing document
 * (`not-found`). Both are the platform's own statement of that kind.
 */
fun MethodChannel.Result.taxonomyError(e: Throwable) {
  // A TaxonomyException raised by the plugin itself has no native code.
  val native = if (e is TaxonomyException) e.cause else e
  val details = (e as? TaxonomyException)?.details.orEmpty() + (native?.let {
    mapOf(
      "domain" to "java",
      "code" to it.javaClass.name,
      "message" to it.message
    )
  } ?: emptyMap())
  val code = when (e) {
    is TaxonomyException -> e.kind
    is SecurityException -> ErrorKind.PERMISSION_LOST
    is FileNotFoundException -> ErrorKind.NOT_FOUND
    else -> e.javaClass.name
  }
  error(code, e.message ?: e.toString(), details)
}
