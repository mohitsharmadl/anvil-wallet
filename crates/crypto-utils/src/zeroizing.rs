use std::ops::Deref;

use zeroize::{Zeroize, ZeroizeOnDrop};

/// A `Vec<u8>` wrapper that is zeroed when dropped.
///
/// Use this for any sensitive byte data (keys, seeds, plaintext) that must not
/// linger in memory after use.
#[derive(Clone, Zeroize, ZeroizeOnDrop)]
pub struct ZeroizingBytes(Vec<u8>);

impl ZeroizingBytes {
    /// Creates a new `ZeroizingBytes` from raw bytes.
    pub fn new(data: Vec<u8>) -> Self {
        Self(data)
    }

    /// Returns the length of the inner byte slice.
    pub fn len(&self) -> usize {
        self.0.len()
    }

    /// Returns `true` if the inner byte slice is empty.
    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
}

impl Deref for ZeroizingBytes {
    type Target = [u8];

    fn deref(&self) -> &[u8] {
        &self.0
    }
}

impl From<Vec<u8>> for ZeroizingBytes {
    fn from(data: Vec<u8>) -> Self {
        Self::new(data)
    }
}

impl From<&[u8]> for ZeroizingBytes {
    fn from(data: &[u8]) -> Self {
        Self::new(data.to_vec())
    }
}

/// A `String` wrapper that is zeroed when dropped.
///
/// Use this for sensitive string data (passwords, mnemonic phrases) that must
/// not linger in memory after use.
#[derive(Clone, Zeroize, ZeroizeOnDrop)]
pub struct ZeroizingString(String);

impl ZeroizingString {
    /// Creates a new `ZeroizingString` from a `String`.
    pub fn new(data: String) -> Self {
        Self(data)
    }

    /// Returns the length of the inner string in bytes.
    pub fn len(&self) -> usize {
        self.0.len()
    }

    /// Returns `true` if the inner string is empty.
    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
}

impl Deref for ZeroizingString {
    type Target = str;

    fn deref(&self) -> &str {
        &self.0
    }
}

impl From<String> for ZeroizingString {
    fn from(data: String) -> Self {
        Self::new(data)
    }
}

impl From<&str> for ZeroizingString {
    fn from(data: &str) -> Self {
        Self::new(data.to_owned())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zeroizing_bytes_deref() {
        let data = vec![1u8, 2, 3, 4, 5];
        let zb = ZeroizingBytes::new(data.clone());
        assert_eq!(&*zb, &data[..]);
    }

    #[test]
    fn zeroizing_bytes_len_and_is_empty() {
        let zb = ZeroizingBytes::new(vec![10, 20]);
        assert_eq!(zb.len(), 2);
        assert!(!zb.is_empty());

        let empty = ZeroizingBytes::new(vec![]);
        assert_eq!(empty.len(), 0);
        assert!(empty.is_empty());
    }

    #[test]
    fn zeroizing_bytes_from_vec() {
        let zb: ZeroizingBytes = vec![0xFFu8; 8].into();
        assert_eq!(zb.len(), 8);
    }

    #[test]
    fn zeroizing_bytes_from_slice() {
        let data = [1u8, 2, 3];
        let zb: ZeroizingBytes = data.as_slice().into();
        assert_eq!(&*zb, &data);
    }

    #[test]
    fn zeroizing_bytes_clone() {
        let original = ZeroizingBytes::new(vec![42u8; 16]);
        let cloned = original.clone();
        assert_eq!(&*original, &*cloned);
    }

    #[test]
    fn zeroizing_string_deref() {
        let zs = ZeroizingString::new("secret mnemonic".to_string());
        assert_eq!(&*zs, "secret mnemonic");
    }

    #[test]
    fn zeroizing_string_len_and_is_empty() {
        let zs = ZeroizingString::new("hello".into());
        assert_eq!(zs.len(), 5);
        assert!(!zs.is_empty());

        let empty = ZeroizingString::new(String::new());
        assert!(empty.is_empty());
    }

    #[test]
    fn zeroizing_string_from_string() {
        let zs: ZeroizingString = String::from("password").into();
        assert_eq!(&*zs, "password");
    }

    #[test]
    fn zeroizing_string_from_str() {
        let zs: ZeroizingString = "wallet-phrase".into();
        assert_eq!(&*zs, "wallet-phrase");
    }

    #[test]
    fn zeroizing_string_clone() {
        let original = ZeroizingString::new("abandon abandon abandon".into());
        let cloned = original.clone();
        assert_eq!(&*original, &*cloned);
    }

    #[test]
    fn zeroizing_bytes_drop_zeroes_memory() {
        // We cannot directly observe zeroing after drop, but we can verify
        // that manual zeroize works, which ZeroizeOnDrop calls automatically.
        let mut zb = ZeroizingBytes::new(vec![0xAA; 32]);
        zb.zeroize();
        // After zeroize, the inner Vec is cleared.
        assert!(zb.is_empty());
    }

    #[test]
    fn zeroizing_string_manual_zeroize() {
        let mut zs = ZeroizingString::new("sensitive".into());
        zs.zeroize();
        assert!(zs.is_empty());
    }

    #[test]
    fn zeroizing_bytes_can_index() {
        let zb = ZeroizingBytes::new(vec![10, 20, 30]);
        assert_eq!(zb[0], 10);
        assert_eq!(zb[2], 30);
    }

    #[test]
    fn zeroizing_string_str_methods() {
        let zs = ZeroizingString::new("Hello World".into());
        assert!(zs.contains("World"));
        assert!(zs.starts_with("Hello"));
    }
}
