use rand::RngCore;
use rand_core::OsRng;

/// Generates `len` cryptographically secure random bytes.
pub fn random_bytes(len: usize) -> Vec<u8> {
    let mut buf = vec![0u8; len];
    OsRng.fill_bytes(&mut buf);
    buf
}

/// Generates a fixed-size array of cryptographically secure random bytes.
pub fn random_bytes_fixed<const N: usize>() -> [u8; N] {
    let mut buf = [0u8; N];
    OsRng.fill_bytes(&mut buf);
    buf
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn random_bytes_correct_length() {
        assert_eq!(random_bytes(0).len(), 0);
        assert_eq!(random_bytes(1).len(), 1);
        assert_eq!(random_bytes(32).len(), 32);
        assert_eq!(random_bytes(1024).len(), 1024);
    }

    #[test]
    fn random_bytes_are_not_all_zero() {
        let bytes = random_bytes(64);
        // Probability of 64 random bytes all being zero is negligible (2^-512).
        assert!(bytes.iter().any(|&b| b != 0));
    }

    #[test]
    fn random_bytes_differ_between_calls() {
        let a = random_bytes(32);
        let b = random_bytes(32);
        assert_ne!(a, b, "two random 32-byte outputs should differ");
    }

    #[test]
    fn random_bytes_fixed_correct_size() {
        let buf: [u8; 16] = random_bytes_fixed();
        assert_eq!(buf.len(), 16);

        let buf: [u8; 32] = random_bytes_fixed();
        assert_eq!(buf.len(), 32);

        let buf: [u8; 64] = random_bytes_fixed();
        assert_eq!(buf.len(), 64);
    }

    #[test]
    fn random_bytes_fixed_not_all_zero() {
        let buf: [u8; 32] = random_bytes_fixed();
        assert!(buf.iter().any(|&b| b != 0));
    }

    #[test]
    fn random_bytes_fixed_differ_between_calls() {
        let a: [u8; 32] = random_bytes_fixed();
        let b: [u8; 32] = random_bytes_fixed();
        assert_ne!(a, b);
    }

    #[test]
    fn random_bytes_zero_length() {
        let bytes = random_bytes(0);
        assert!(bytes.is_empty());
    }

    #[test]
    fn random_bytes_fixed_single_byte() {
        // Just ensure it doesn't panic.
        let _b: [u8; 1] = random_bytes_fixed();
    }
}
