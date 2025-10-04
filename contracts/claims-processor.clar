;; title: claims-processor
;; version: 1.0.0
;; summary: Automates claim validation using external data sources and IoT sensors
;; description: Advanced automated claim validation and processing system with oracle integration,
;;              fraud detection, community voting mechanisms, and dispute resolution

;; traits
;;

;; token definitions
;;

;; constants
;;
(define-constant ERR_UNAUTHORIZED (err u401))
(define-constant ERR_CLAIM_NOT_FOUND (err u404))
(define-constant ERR_INVALID_POLICY (err u402))
(define-constant ERR_POLICY_EXPIRED (err u403))
(define-constant ERR_CLAIM_ALREADY_EXISTS (err u405))
(define-constant ERR_INSUFFICIENT_RESERVES (err u406))
(define-constant ERR_INVALID_ORACLE_DATA (err u407))
(define-constant ERR_CLAIM_DISPUTED (err u408))
(define-constant ERR_VOTING_ENDED (err u409))
(define-constant ERR_ALREADY_VOTED (err u410))
(define-constant ERR_INVALID_EVIDENCE (err u411))
(define-constant ERR_PAYOUT_FAILED (err u412))

(define-constant CLAIM_SUBMITTED u0)
(define-constant CLAIM_UNDER_REVIEW u1)
(define-constant CLAIM_APPROVED u2)
(define-constant CLAIM_REJECTED u3)
(define-constant CLAIM_DISPUTED u4)
(define-constant CLAIM_PAID u5)

(define-constant DISPUTE_PENDING u0)
(define-constant DISPUTE_VOTING u1)
(define-constant DISPUTE_RESOLVED u2)

(define-constant EVIDENCE_WEATHER_DATA u0)
(define-constant EVIDENCE_IOT_SENSOR u1)
(define-constant EVIDENCE_GOVERNMENT_ALERT u2)
(define-constant EVIDENCE_THIRD_PARTY_VALIDATION u3)

(define-constant MAX_CLAIM_AMOUNT u100000000000) ;; 100,000 STX max claim
(define-constant DISPUTE_VOTING_PERIOD u2016) ;; 1 week in blocks
(define-constant MIN_VALIDATORS_REQUIRED u3)
(define-constant PARAMETRIC_THRESHOLD u75) ;; 75% confidence for automatic approval

;; data vars
;;
(define-data-var claim-counter uint u0)
(define-data-var dispute-counter uint u0)
(define-data-var oracle-operator principal tx-sender)
(define-data-var min-stake-for-validation uint u10000000) ;; 10 STX

;; data maps
;;
(define-map claims uint {
    policy-id: uint,
    claimant: principal,
    amount: uint,
    incident-date: uint,
    description: (string-ascii 200),
    status: uint,
    created-at: uint,
    processed-at: uint,
    evidence-hash: (buff 32),
    parametric-score: uint,
    validator-count: uint,
    payout-amount: uint
})

(define-map claim-evidence uint {
    evidence-type: uint,
    data-source: (string-ascii 100),
    confidence-score: uint,
    timestamp: uint,
    data-hash: (buff 32),
    validator: principal,
    verified: bool
})

(define-map disputes uint {
    claim-id: uint,
    disputer: principal,
    reason: (string-ascii 200),
    status: uint,
    created-at: uint,
    voting-deadline: uint,
    votes-approve: uint,
    votes-reject: uint,
    total-voting-power: uint,
    resolved-at: uint,
    resolution: uint
})

(define-map dispute-votes { dispute-id: uint, voter: principal } {
    vote: uint, ;; 0 = reject claim, 1 = approve claim
    voting-power: uint,
    timestamp: uint,
    rationale: (string-ascii 100)
})

(define-map validators principal {
    stake: uint,
    claims-validated: uint,
    accuracy-score: uint,
    reputation: uint,
    last-active: uint,
    rewards-earned: uint
})

(define-map oracle-feeds (string-ascii 50) {
    last-update: uint,
    data-hash: (buff 32),
    confidence: uint,
    provider: principal,
    active: bool
})

(define-map claim-payouts uint {
    amount: uint,
    recipient: principal,
    processed-at: uint,
    transaction-id: (buff 32)
})

;; public functions
;;

;; Submit a new insurance claim
(define-public (submit-claim (policy-id uint) (amount uint) (incident-date uint) 
                           (description (string-ascii 200)) (evidence-hash (buff 32)))
    (let ((claim-id (+ (var-get claim-counter) u1)))
        
        (asserts! (> amount u0) ERR_INVALID_POLICY)
        (asserts! (<= amount MAX_CLAIM_AMOUNT) ERR_INVALID_POLICY)
        (asserts! (is-none (map-get? claims claim-id)) ERR_CLAIM_ALREADY_EXISTS)
        
        ;; Create claim record
        (map-set claims claim-id {
            policy-id: policy-id,
            claimant: tx-sender,
            amount: amount,
            incident-date: incident-date,
            description: description,
            status: CLAIM_SUBMITTED,
            created-at: stacks-block-height,
            processed-at: u0,
            evidence-hash: evidence-hash,
            parametric-score: u0,
            validator-count: u0,
            payout-amount: u0
        })
        
        (var-set claim-counter claim-id)
        (ok claim-id)))

;; Submit evidence for a claim (can be called by oracles or validators)
(define-public (submit-evidence (claim-id uint) (evidence-type uint) (data-source (string-ascii 100)) 
                              (confidence-score uint) (data-hash (buff 32)))
    (let ((claim-info (unwrap! (map-get? claims claim-id) ERR_CLAIM_NOT_FOUND))
          (validator-info (default-to { stake: u0, claims-validated: u0, accuracy-score: u50, 
                                      reputation: u50, last-active: u0, rewards-earned: u0 }
                                     (map-get? validators tx-sender))))
        
        (asserts! (>= (get stake validator-info) (var-get min-stake-for-validation)) ERR_UNAUTHORIZED)
        (asserts! (< (get status claim-info) CLAIM_APPROVED) ERR_CLAIM_DISPUTED)
        (asserts! (<= confidence-score u100) ERR_INVALID_EVIDENCE)
        
        ;; Store evidence
        (map-set claim-evidence claim-id {
            evidence-type: evidence-type,
            data-source: data-source,
            confidence-score: confidence-score,
            timestamp: stacks-block-height,
            data-hash: data-hash,
            validator: tx-sender,
            verified: true
        })
        
        ;; Update claim with new parametric score
        (let ((new-score (calculate-parametric-score claim-id confidence-score))
              (new-validator-count (+ (get validator-count claim-info) u1)))
            (map-set claims claim-id (merge claim-info {
                parametric-score: new-score,
                validator-count: new-validator-count,
                status: (if (>= new-score PARAMETRIC_THRESHOLD) CLAIM_UNDER_REVIEW CLAIM_SUBMITTED)
            })))
        
        ;; Update validator stats
        (map-set validators tx-sender (merge validator-info {
            claims-validated: (+ (get claims-validated validator-info) u1),
            last-active: stacks-block-height
        }))
        
        (ok true)))

;; Process approved claims automatically
(define-public (process-claim (claim-id uint))
    (let ((claim-info (unwrap! (map-get? claims claim-id) ERR_CLAIM_NOT_FOUND)))
        
        (asserts! (>= (get parametric-score claim-info) PARAMETRIC_THRESHOLD) ERR_INVALID_EVIDENCE)
        (asserts! (>= (get validator-count claim-info) MIN_VALIDATORS_REQUIRED) ERR_INVALID_EVIDENCE)
        (asserts! (is-eq (get status claim-info) CLAIM_UNDER_REVIEW) ERR_CLAIM_DISPUTED)
        
        ;; Calculate final payout amount
        (let ((payout-amount (get amount claim-info)))
            
            ;; Update claim status
            (map-set claims claim-id (merge claim-info {
                status: CLAIM_APPROVED,
                processed-at: stacks-block-height,
                payout-amount: payout-amount
            }))
            
            ;; Execute payout
            (try! (execute-payout claim-id (get claimant claim-info) payout-amount))
            
            (ok payout-amount))))

;; Dispute a claim (community governance)
(define-public (dispute-claim (claim-id uint) (reason (string-ascii 200)))
    (let ((claim-info (unwrap! (map-get? claims claim-id) ERR_CLAIM_NOT_FOUND))
          (dispute-id (+ (var-get dispute-counter) u1)))
        
        (asserts! (is-eq (get status claim-info) CLAIM_APPROVED) ERR_CLAIM_DISPUTED)
        
        ;; Create dispute record
        (map-set disputes dispute-id {
            claim-id: claim-id,
            disputer: tx-sender,
            reason: reason,
            status: DISPUTE_VOTING,
            created-at: stacks-block-height,
            voting-deadline: (+ stacks-block-height DISPUTE_VOTING_PERIOD),
            votes-approve: u0,
            votes-reject: u0,
            total-voting-power: u0,
            resolved-at: u0,
            resolution: u0
        })
        
        ;; Update claim status to disputed
        (map-set claims claim-id (merge claim-info { status: CLAIM_DISPUTED }))
        
        (var-set dispute-counter dispute-id)
        (ok dispute-id)))

;; Vote on a disputed claim
(define-public (vote-on-dispute (dispute-id uint) (vote uint) (rationale (string-ascii 100)))
    (let ((dispute-info (unwrap! (map-get? disputes dispute-id) ERR_CLAIM_NOT_FOUND))
          (claim-info (unwrap! (map-get? claims (get claim-id dispute-info)) ERR_CLAIM_NOT_FOUND))
          (voting-power u100)) ;; Default voting power for community members
        (asserts! (> voting-power u0) ERR_UNAUTHORIZED)
        (asserts! (< stacks-block-height (get voting-deadline dispute-info)) ERR_VOTING_ENDED)
        (asserts! (is-eq (get status dispute-info) DISPUTE_VOTING) ERR_VOTING_ENDED)
        (asserts! (is-none (map-get? dispute-votes { dispute-id: dispute-id, voter: tx-sender })) ERR_ALREADY_VOTED)
        (asserts! (or (is-eq vote u0) (is-eq vote u1)) ERR_INVALID_EVIDENCE)
        
        ;; Record vote
        (map-set dispute-votes { dispute-id: dispute-id, voter: tx-sender } {
            vote: vote,
            voting-power: voting-power,
            timestamp: stacks-block-height,
            rationale: rationale
        })
        
        ;; Update dispute vote counts
        (let ((new-votes-approve (if (is-eq vote u1) 
                                   (+ (get votes-approve dispute-info) voting-power)
                                   (get votes-approve dispute-info)))
              (new-votes-reject (if (is-eq vote u0) 
                                  (+ (get votes-reject dispute-info) voting-power)
                                  (get votes-reject dispute-info)))
              (new-total-power (+ (get total-voting-power dispute-info) voting-power)))
            
            (map-set disputes dispute-id (merge dispute-info {
                votes-approve: new-votes-approve,
                votes-reject: new-votes-reject,
                total-voting-power: new-total-power
            })))
        
        (ok true)))

;; Resolve a dispute after voting period
(define-public (resolve-dispute (dispute-id uint))
    (let ((dispute-info (unwrap! (map-get? disputes dispute-id) ERR_CLAIM_NOT_FOUND))
          (claim-info (unwrap! (map-get? claims (get claim-id dispute-info)) ERR_CLAIM_NOT_FOUND)))
        
        (asserts! (>= stacks-block-height (get voting-deadline dispute-info)) ERR_VOTING_ENDED)
        (asserts! (is-eq (get status dispute-info) DISPUTE_VOTING) ERR_VOTING_ENDED)
        
        (let ((resolution (if (> (get votes-approve dispute-info) (get votes-reject dispute-info)) u1 u0)))
            
            ;; Update dispute status
            (map-set disputes dispute-id (merge dispute-info {
                status: DISPUTE_RESOLVED,
                resolved-at: stacks-block-height,
                resolution: resolution
            }))
            
            ;; Update claim based on resolution
            (if (is-eq resolution u1)
                ;; Claim approved - process payout
                (begin
                    (map-set claims (get claim-id dispute-info) (merge claim-info { status: CLAIM_APPROVED }))
                    (try! (process-claim (get claim-id dispute-info)))
                    true)
                ;; Claim rejected
                (begin
                    (map-set claims (get claim-id dispute-info) (merge claim-info { status: CLAIM_REJECTED }))
                    true))
            
            (ok resolution))))

;; read only functions
;;

(define-read-only (get-claim-info (claim-id uint))
    (map-get? claims claim-id))

(define-read-only (get-dispute-info (dispute-id uint))
    (map-get? disputes dispute-id))

(define-read-only (get-claim-evidence (claim-id uint))
    (map-get? claim-evidence claim-id))

(define-read-only (get-validator-info (validator principal))
    (map-get? validators validator))

(define-read-only (get-dispute-vote (dispute-id uint) (voter principal))
    (map-get? dispute-votes { dispute-id: dispute-id, voter: voter }))

(define-read-only (is-claim-eligible-for-payout (claim-id uint))
    (match (map-get? claims claim-id)
        claim-info (and (>= (get parametric-score claim-info) PARAMETRIC_THRESHOLD)
                       (>= (get validator-count claim-info) MIN_VALIDATORS_REQUIRED)
                       (is-eq (get status claim-info) CLAIM_UNDER_REVIEW))
        false))

;; private functions
;;

(define-private (calculate-parametric-score (claim-id uint) (new-evidence-score uint))
    (let ((claim-info (unwrap-panic (map-get? claims claim-id))))
        (if (is-eq (get parametric-score claim-info) u0)
            new-evidence-score
            (/ (+ (get parametric-score claim-info) new-evidence-score) u2))))

(define-private (calculate-payout-amount (claim-info { policy-id: uint, claimant: principal, amount: uint, 
                                                      incident-date: uint, description: (string-ascii 200), 
                                                      status: uint, created-at: uint, processed-at: uint, 
                                                      evidence-hash: (buff 32), parametric-score: uint, 
                                                      validator-count: uint, payout-amount: uint }))
    (let ((requested-amount (get amount claim-info))
          (confidence-factor (/ (get parametric-score claim-info) u100)))
        (/ (* requested-amount confidence-factor) u100)))

(define-private (execute-payout (claim-id uint) (recipient principal) (amount uint))
    (begin
        ;; Transfer payout from contract balance
        (try! (as-contract (stx-transfer? amount tx-sender recipient)))
        
        ;; Record payout
        (map-set claim-payouts claim-id {
            amount: amount,
            recipient: recipient,
            processed-at: stacks-block-height,
            transaction-id: (sha256 (concat (unwrap-panic (to-consensus-buff? claim-id)) 
                                          (unwrap-panic (to-consensus-buff? stacks-block-height))))
        })
        
        ;; Update claim status to paid
        (let ((claim-info (unwrap-panic (map-get? claims claim-id))))
            (map-set claims claim-id (merge claim-info { status: CLAIM_PAID })))
        
        (ok true)))
