# App Store Submission Notes

## Prerequisites

### Apple Developer Program
- Enroll as **organization** (not individual) — required for crypto wallets
- Need D-U-N-S number (5 business days to obtain)
- Need legal entity registration
- $99/year program fee
- **Start this process immediately** — takes 1-3 weeks

### App Store Guidelines Compliance
Crypto wallets have ~40% rejection rate. Mitigations:

1. **Guideline 3.1.1 (In-App Purchase)**: We don't sell crypto, only manage it. No IAP needed.
2. **Guideline 5.2.1 (Legal)**: Include Terms of Service with crypto risk disclosures.
3. **Guideline 2.3.1 (Functionality)**: App must be fully functional at review time.

## Privacy Nutrition Labels

Select "Data Not Collected" for all categories:
- No analytics
- No crash reporting
- No user tracking
- No third-party SDKs that collect data

## App Store Review Notes

Include with submission:

> This app is a self-custody cryptocurrency wallet. It does not facilitate buying,
> selling, or exchanging cryptocurrency. It allows users to:
>
> 1. Generate and securely store cryptographic keys on-device
> 2. Send and receive cryptocurrency using standard blockchain protocols
> 3. Connect to decentralized applications via WalletConnect
>
> Security measures:
> - All private keys are encrypted with AES-256-GCM and stored in the iOS Keychain
> - Additional encryption layer using Secure Enclave P-256 key
> - Biometric authentication required for all transactions
> - No data is collected or transmitted to any server
> - All blockchain interactions are direct RPC calls to public nodes
>
> Test account: A test mnemonic phrase will be provided if needed.

## Required Legal Documents

1. **Terms of Service** — Must include:
   - Crypto is volatile, user accepts risk
   - Self-custody means user is responsible for backup
   - No recovery if mnemonic is lost
   - Not financial advice

2. **Privacy Policy** — Must state:
   - No personal data collected
   - No analytics or tracking
   - Only network connections: blockchain RPC nodes, price API
   - All data stored locally on device

## TestFlight Beta

Before submission:
1. Internal testing (1-5 team members)
2. External beta (10-25 testers) — requires App Review
3. Collect feedback for 1-2 weeks
4. Fix issues, submit to App Store

## Checklist

- [ ] Apple Developer organization enrollment complete
- [ ] D-U-N-S number obtained
- [ ] App icon (1024x1024) designed
- [ ] Launch screen created
- [ ] App Store screenshots (6.7", 6.5", 5.5")
- [ ] App description written
- [ ] Terms of Service URL hosted
- [ ] Privacy Policy URL hosted
- [ ] Privacy Nutrition Labels configured
- [ ] TestFlight beta tested
- [ ] App Review notes prepared
- [ ] Export compliance documentation (uses encryption)
