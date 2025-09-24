ReputaStack is a **Clarity smart contract** for the **Stacks blockchain** that implements a decentralized reputation and credentialing system.  
It allows users to request attestations, verifiers to resolve them, and community members to **vouch** with STX stakes. Accepted attestations award **reputation points** and issue **soulbound NFTs** as credentials.

---

## ✨ Features

- **Admin & Governance**
  - Admin role with ability to add/remove verifiers
  - Contract pause/resume functionality
  - Treasury to collect slashed stakes  

- **Reputation System**
  - Reputation score tracked per user
  - Configurable base reputation rewards per accepted attestation  

- **Credential NFTs**
  - Non-transferable (soulbound) NFTs issued as verifiable credentials  
  - Each accepted attestation mints a new credential  

- **Attestations & Vouching**
  - Users request attestations with claims + evidence hash
  - Verifiers resolve attestations (accept/reject)
  - Community can **vouch** with STX stakes:
    - Accepted → stake returned  
    - Rejected → stake slashed to treasury  

- **Transparency & Auditability**
  - Append-only audit logs for all key actions  
  - Full traceability of attestations, vouches, and resolutions  

---

## 🛠️ Error Codes

| Code  | Meaning               |
|-------|------------------------|
| `u100` | Unauthorized          |
| `u101` | Contract paused       |
| `u102` | Not found             |
| `u103` | Bad amount            |
| `u104` | Already resolved      |
| `u105` | Not a verifier        |
| `u106` | Incomplete action     |
| `u107` | Insufficient funds    |
| `u108` | Already vouched       |
| `u109` | Bad parameter         |
| `u110` | No stake              |

---

## 📦 Contract Structure

- **Admin & Roles**
  - `set-admin`, `set-paused`, `verifier-add`, `verifier-remove`  
- **Reputation & NFTs**
  - `reputation` (map) – per-user scores  
  - `credential-nft` – non-fungible credentials  
- **Attestations**
  - `request-attestation` – create new attestation  
  - `resolve-attestation` – verifier accepts/rejects  
- **Vouches**
  - `vouch` – stake support on an attestation  
  - `claim-vouch` – reclaim stake after acceptance  
  - `withdraw-slashed` – admin collects rejected stakes  
- **Logs**
  - Append-only `logs` map for traceability  

   clarinet check
   clarinet test
Deploy to the Stacks testnet or mainnet via Stacks CLI.

📖 Example Usage
clarity
Copy code
;; Request an attestation
(contract-call? .reputa-stack request-attestation
  'SP123...456
  "Skilled Solidity Developer"
  0xabcdef1234567890abcdef1234567890abcdef12)

;; Vouch with 100 STX
(contract-call? .reputa-stack vouch u1 u100000000)

;; Verifier accepts attestation
(contract-call? .reputa-stack resolve-attestation u1 true)
