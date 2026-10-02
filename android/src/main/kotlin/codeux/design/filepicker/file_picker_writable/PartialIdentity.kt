package codeux.design.filepicker.file_picker_writable

/**
 * Whether the file under an aborted write session's name is still the one
 * the session created (doc/tree-writes-plan.md §5; #72 review M1), so that
 * an abort never deletes a file that took the partial's name since.
 *
 * SAF names documents by path, so identity comes from the descriptors: the
 * inode the create's write descriptor reported, against the inode a read
 * descriptor on the name reports now. Only the inode: the write descriptor
 * is on the lower file system and the read descriptor goes through FUSE,
 * whose device number differs, while FUSE reports the lower inode. On
 * ext4/f2fs an inode is stable but may be reused after a delete; on
 * vfat/exfat it is assigned when the file is loaded into memory, so the
 * same file can come back with a new one (a false refuse: the partial is
 * kept, never someone else's file deleted). The size and the modification
 * time narrow it further.
 */
object PartialIdentity {
  /** FAT stores modification times in 2-second steps. */
  const val MTIME_SLACK_MS = 2000L

  fun matches(
    recordedInode: Long,
    inodeNow: Long,
    sizeNow: Long?,
    bytesWritten: Long,
    modifiedNow: Long?,
    openedAt: Long
  ): Boolean =
    inodeNow == recordedInode &&
      (sizeNow == null || sizeNow == bytesWritten) &&
      (modifiedNow == null || modifiedNow >= openedAt - MTIME_SLACK_MS)
}
