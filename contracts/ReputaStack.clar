;; =================================================================================
;; Contract: ReputaStack
;; Purpose : On-chain Reputation & Credential System for Stacks (STX / Clarity)
;; License : MIT
;; =================================================================================

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Errors
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(define-constant ERR-UNAUTHORIZED    (err u100))
(define-constant ERR-PAUSED          (err u101))
(define-constant ERR-NOT-FOUND      (err u102))
(define-constant ERR-BAD-AMOUNT      (err u103))
(define-constant ERR-ALREADY_RESOLV  (err u104))
(define-constant ERR-NOT-VERIFIER    (err u105))
(define-constant ERR-INCOMPLETE      (err u106))
(define-constant ERR-INSUFFICIENT    (err u107))
(define-constant ERR-ALREADY_VOUCHED (err u108))
(define-constant ERR-BAD_PARAM       (err u109))
(define-constant ERR-NO-STAKE        (err u110))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Admin / Roles / Pause
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(define-data-var admin principal tx-sender)
(define-data-var paused bool false)

(define-map verifiers
  principal
  bool)

;; Ensure that only the admin can call certain functions
(define-private (require-admin)
  (begin
    (asserts! (is-eq tx-sender (var-get admin)) ERR-UNAUTHORIZED)
    (ok true)))


;; Ensure that the contract is not paused
(define-private (require-not-paused)
  (begin
    (asserts! (is-eq (var-get paused) false) ERR-PAUSED)
    (ok true)))

(define-private (is-verifier (who principal))
  (default-to false (map-get? verifiers who)))

(define-public (set-admin (who principal))
  (begin 
    (try! (require-admin))
    (var-set admin who)
    (ok who)))

(define-public (set-paused (p bool))
  (begin (try! (require-admin)) (var-set paused p) (ok p)))

(define-public (verifier-add (who principal))
  (begin
    (try! (require-admin))
    (map-set verifiers who true)
    (ok true)))

(define-public (verifier-remove (who principal))
  (begin
    (try! (require-admin))
    (map-delete verifiers who)
    (ok true)))

(define-read-only (is-verifier? (who principal)) (is-verifier who))
(define-read-only (is-paused) (var-get paused))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Reputation Storage
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; reputation per principal
(define-map reputation
  principal
  uint)

;; config: base reputation awarded per accepted attestation
(define-data-var base-rep-accept uint u10) ;; 10 points by default

;; badge NFT for credentials (soulbound by default)
(define-non-fungible-token credential-nft uint)
(define-data-var next-credential-id uint u1)
(define-data-var nft-transfer-enabled bool false) ;; toggled by admin

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Attestations & Vouches
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Attestation structure
;; status: 0 = pending, 1 = accepted, 2 = rejected
(define-data-var next-attest-id uint u1)

(define-map attestations
  uint
  {
    requester: principal,       ;; who requested attestation (usually subject or representative)
    subject: principal,         ;; target principal whose rep will be affected
    claim: (string-ascii 140),  ;; textual claim
    evidence: (buff 32),        ;; off-chain evidence hash
    requested-block: uint,
    resolver: (optional principal), ;; who resolved (verifier)
    status: uint,               ;; 0 pending,1 accepted,2 rejected
    resolved-block: (optional uint)
  })

;; vouches: map keyed by {attest-id, voucher}
(define-map vouches
  { attest-id: uint, voucher: principal }
  uint ;; amount staked (in microSTX)
)

;; total vouch amount per attestation (used in decisions, etc.)
(define-map attest-vouch-total
  uint
  uint)

;; treasury for slashed funds
(define-data-var treasury (optional principal) none)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Audit logs (append-only)
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(define-data-var next-log-id uint u1)
(define-map logs
  uint
  {
    actor: principal,
    action: (string-ascii 40),
    ref: uint,
    note: (string-ascii 120),
    block: uint
  })

(define-private (log! (action (string-ascii 40)) (ref uint) (note (string-ascii 120)))
  (let ((lid (var-get next-log-id)))
    (map-set logs lid { actor: tx-sender, action: action, ref: ref, note: note, block: stacks-block-height })
    (var-set next-log-id (+ lid u1))
    true))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Helpers: safe math, pay/collect
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(define-private (safe-add (a uint) (b uint))
  (let ((c (+ a b))) 
    (asserts! (>= c a) ERR-BAD_PARAM)
    (ok c)))

(define-private (safe-sub (a uint) (b uint))
  (begin 
    (asserts! (>= a b) ERR-INSUFFICIENT)
    (ok (- a b))))

;; Collect STX from a user into the contract
(define-private (collect (from principal) (amt uint))
  (if (> amt u0)
    (begin 
      (try! (stx-transfer? amt from (as-contract tx-sender)))
      (ok true))
    (ok true)))



(define-private (pay (to principal) (amt uint))
  (if (> amt u0)
    (begin
      (try! (stx-transfer? amt (as-contract tx-sender) to))
      (ok true))
    (ok true)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; PUBLIC API: Attestations
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Anyone (or a subject agent) can request an attestation
(define-public (request-attestation (subject principal) (claim (string-ascii 140)) (evidence (buff 32)))
  (begin
    (try! (require-not-paused))
    (let ((aid (var-get next-attest-id)))
      (map-set attestations aid {
        requester: tx-sender,
        subject: subject,
        claim: claim,
        evidence: evidence,
        requested-block: stacks-block-height,
        resolver: none,
        status: u0,
        resolved-block: none
      })
      (var-set next-attest-id (+ aid u1))
      (log! "request" aid "attestation requested")
      (ok aid))))

;; Backers can vouch (stake STX) on an attestation to support it.
;; Stakes are returned on acceptance; slashed to treasury on rejection.
(define-public (vouch (attest-id uint) (amount uint))
  (begin
    (try! (require-not-paused))
    (asserts! (> amount u0) ERR-BAD-AMOUNT)
    (let ((att (map-get? attestations attest-id)))
      (match att
        a
          (begin
            (asserts! (is-eq (get status a) u0) ERR-ALREADY_RESOLV)
            ;; prevent double vouch from same voucher
            (asserts! (is-none (map-get? vouches {attest-id: attest-id, voucher: tx-sender})) ERR-ALREADY_VOUCHED)
            ;; collect stake from voucher
            (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
            ;; record stake
            (map-set vouches {attest-id: attest-id, voucher: tx-sender} amount)
            (let ((prev (default-to u0 (map-get? attest-vouch-total attest-id))))
              (map-set attest-vouch-total attest-id (+ prev amount)))
            (log! "vouch" attest-id "vouch staked")
            (ok true))
        ERR-NOT-FOUND))))

;; Verifier resolves attestation (accept/reject)
;; On accept: increase subject reputation by base + proportional to vouch total
;; On reject: slash vouches to treasury
;; --- New map to mark slashed processed so vouchers cannot later claim
(define-map attest-slashed-processed
  uint
  bool)

;; --- Claim vouch (called by voucher) to withdraw stake after attestation accepted
(define-public (claim-vouch (attest-id uint))
  (begin
    (try! (require-not-paused))
    (let ((att (unwrap! (map-get? attestations attest-id) ERR-NOT-FOUND)))
      ;; attestation must be accepted
      (asserts! (is-eq (get status att) u1) ERR-ALREADY_RESOLV)
      (let ((stake (default-to u0 (map-get? vouches {attest-id: attest-id, voucher: tx-sender}))))
        (asserts! (> stake u0) ERR-NO-STAKE)
        ;; delete vouch record & reduce total
        (map-delete vouches {attest-id: attest-id, voucher: tx-sender})
        (let ((total (default-to u0 (map-get? attest-vouch-total attest-id))))
          (map-set attest-vouch-total attest-id (if (>= total stake) (- total stake) u0)))
        ;; transfer stake back to voucher
        (try! (stx-transfer? stake (as-contract tx-sender) tx-sender))
        (log! "claim-vouch" attest-id "voucher claimed stake")
        (ok stake)))))

;; --- Admin withdraw slashed (if you prefer admin to pull instead of immediate auto-transfer)
(define-public (withdraw-slashed (attest-id uint))
  (begin
    (try! (require-not-paused))
    (try! (require-admin))
    (let ((att (unwrap! (map-get? attestations attest-id) ERR-NOT-FOUND)))
      ;; attestation must be rejected
      (asserts! (is-eq (get status att) u2) ERR-ALREADY_RESOLV)
      ;; ensure not already processed
      (asserts! (not (default-to false (map-get? attest-slashed-processed attest-id))) ERR-ALREADY_RESOLV)
      (let ((total (default-to u0 (map-get? attest-vouch-total attest-id))))
        (asserts! (> total u0) ERR-NO-STAKE)
        ;; determine treasury target (treasury optional else admin)
        (let ((tre (default-to (var-get admin) (var-get treasury))))
          ;; transfer total to treasury/admin
          (try! (stx-transfer? total (as-contract tx-sender) tre))
          ;; zero out attest total & mark processed
          (map-set attest-vouch-total attest-id u0)
          (map-set attest-slashed-processed attest-id true)
          (log! "withdraw-slashed" attest-id "slashed collected by admin/treasury")
          (ok total))))))

;; --- Fixed resolve-attestation
(define-public (resolve-attestation (attest-id uint) (accept bool))
  (begin
    (try! (require-not-paused))
    (asserts! (is-verifier tx-sender) ERR-NOT-VERIFIER)
    (let 
      ((att (unwrap! (map-get? attestations attest-id) ERR-NOT-FOUND))
       (total-vouch (default-to u0 (map-get? attest-vouch-total attest-id))))
      (asserts! (is-eq (get status att) u0) ERR-ALREADY_RESOLV)
      ;; Both branches will return (response uint)
    (if accept
      (let ((base (var-get base-rep-accept))
            (bonus (if (> total-vouch u0) (/ total-vouch u1000000) u0))
            (subject (get subject att)))
        (let ((gain (+ base bonus))
              (old (default-to u0 (map-get? reputation subject))))
          ;; Update reputation
          (map-set reputation subject (+ old gain))
          ;; Mint NFT
          (let ((cid (var-get next-credential-id)))
            (try! (nft-mint? credential-nft cid subject))
            (var-set next-credential-id (+ cid u1))
            ;; Update attestation status
            (map-set attestations attest-id
              (merge att {
                status: u1,
                resolver: (some tx-sender),
                resolved-block: (some stacks-block-height)
              }))
            (log! "resolve-accept" attest-id "attestation accepted")
            (ok gain))))
      (let ((tre (default-to (var-get admin) (var-get treasury))))
        ;; Handle rejection - returns uint u0 for consistency
        (begin
          (if (> total-vouch u0)
            (begin
              (try! (stx-transfer? total-vouch (as-contract tx-sender) tre))
              (map-set attest-vouch-total attest-id u0))
            true)
          (map-set attest-slashed-processed attest-id true)
          (map-set attestations attest-id
            (merge att {
              status: u2,
              resolver: (some tx-sender),
              resolved-block: (some stacks-block-height)
            }))
          (log! "resolve-reject" attest-id "attestation rejected")
          (ok u0)))))))
