package codeux.design.filepicker.file_picker_writable

/**
 * The leaf-name rule (tree-writes-plan §4): one path component, never
 * empty, `.`, `..`, or containing `/` or NUL. Names starting with `.` are
 * ordinary names.
 */
fun isLeafName(name: String): Boolean =
  name.isNotEmpty() && name != "." && name != ".." &&
    !name.contains('/') && !name.contains('\u0000')
