//! `HookType`: An enumeration of the available interception points
/// Each hook type represents a specific moment during data operations:
/// - `Before*` hooks run before an operation is performed, allowing for validation or modification
/// - `After*` hooks run after an operation completes, enabling post-processing or side effects
pub const HookType = enum {
    /// Triggered before retrieving a key's value
    BeforeGet,
    /// Triggered before saving a key-value pair
    BeforeSave,
    /// Triggered before deleting a key
    BeforeDelete,
    /// Triggered after retrieving a key's value
    AfterGet,
    /// Triggered after saving a key-value pair
    AfterSave,
    /// Triggered after deleting a key
    AfterDelete,
};
