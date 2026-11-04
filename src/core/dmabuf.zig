//! One linear RGB plane shared between capture and the encoder.
pub const xrgb8888: u32 = 0x34325258;
pub const argb8888: u32 = 0x34325241;

pub const Frame = struct {
    /// Allocation identity, independent of the recyclable file descriptor number.
    id: u64 = 0,
    fd: i32,
    width: u32,
    height: u32,
    stride: u32,
    format: u32,
    size: u32,
};
