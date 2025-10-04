;; title: insurance-pools
;; version: 1.0.0
;; summary: Manages community insurance pools with risk-based premium calculations
;; description: Core contract for creating and managing decentralized insurance pools
;;              with automated underwriting, policy lifecycle management, and community governance

;; traits
;;

;; token definitions
;;

;; constants
;;
(define-constant ERR_UNAUTHORIZED (err u401))
(define-constant ERR_POOL_NOT_FOUND (err u404))
(define-constant ERR_INSUFFICIENT_FUNDS (err u402))
(define-constant ERR_POOL_CLOSED (err u403))
(define-constant ERR_POLICY_NOT_FOUND (err u405))
(define-constant ERR_POLICY_EXPIRED (err u406))
(define-constant ERR_INVALID_DURATION (err u407))
(define-constant ERR_INVALID_AMOUNT (err u408))
(define-constant ERR_POOL_CAPACITY_EXCEEDED (err u409))
(define-constant ERR_MINIMUM_PREMIUM_NOT_MET (err u410))

(define-constant POOL_ACTIVE u0)
(define-constant POOL_SUSPENDED u1)
(define-constant POOL_CLOSED u2)

(define-constant POLICY_ACTIVE u0)
(define-constant POLICY_EXPIRED u1)
(define-constant POLICY_CLAIMED u2)
(define-constant POLICY_CANCELLED u3)

(define-constant MIN_POOL_RESERVE u1000000) ;; 1 STX minimum reserve
(define-constant MAX_COVERAGE_RATIO u80) ;; 80% max coverage ratio
(define-constant BASE_PREMIUM_RATE u100) ;; 1% base premium rate (100/10000)

;; data vars
;;
(define-data-var pool-counter uint u0)
(define-data-var policy-counter uint u0)
(define-data-var contract-owner principal tx-sender)

;; data maps
;;
(define-map pools uint {
    creator: principal,
    name: (string-ascii 50),
    description: (string-ascii 200),
    total-reserves: uint,
    total-coverage: uint,
    premium-rate: uint,
    max-coverage-per-policy: uint,
    min-premium: uint,
    created-at: uint,
    status: uint,
    governance-threshold: uint,
    risk-multiplier: uint
})

(define-map policies uint {
    pool-id: uint,
    holder: principal,
    coverage-amount: uint,
    premium-paid: uint,
    start-block: uint,
    duration-blocks: uint,
    status: uint,
    risk-score: uint,
    created-at: uint
})

(define-map pool-members { pool-id: uint, member: principal } {
    stake: uint,
    voting-power: uint,
    joined-at: uint,
    reputation-score: uint
})

(define-map policy-holders principal {
    active-policies: uint,
    total-premiums-paid: uint,
    claims-count: uint,
    reputation-score: uint
})

(define-map pool-governance { pool-id: uint, proposal-id: uint } {
    proposer: principal,
    proposal-type: uint,
    description: (string-ascii 100),
    votes-for: uint,
    votes-against: uint,
    voting-deadline: uint,
    executed: bool
})

;; public functions
;;

;; Create a new insurance pool
(define-public (create-pool (name (string-ascii 50)) (description (string-ascii 200)) 
                           (premium-rate uint) (max-coverage uint) (min-premium uint) 
                           (risk-multiplier uint) (initial-stake uint))
    (let ((pool-id (+ (var-get pool-counter) u1))
          (creator tx-sender))
        (asserts! (> initial-stake MIN_POOL_RESERVE) ERR_INSUFFICIENT_FUNDS)
        (asserts! (<= premium-rate u1000) ERR_INVALID_AMOUNT) ;; Max 10% premium rate
        (asserts! (> max-coverage u0) ERR_INVALID_AMOUNT)
        (asserts! (> risk-multiplier u0) ERR_INVALID_AMOUNT)
        
        ;; Transfer initial stake to contract
        (try! (stx-transfer? initial-stake creator (as-contract tx-sender)))
        
        ;; Create pool record
        (map-set pools pool-id {
            creator: creator,
            name: name,
            description: description,
            total-reserves: initial-stake,
            total-coverage: u0,
            premium-rate: premium-rate,
            max-coverage-per-policy: max-coverage,
            min-premium: min-premium,
            created-at: stacks-block-height,
            status: POOL_ACTIVE,
            governance-threshold: u51, ;; 51% for governance decisions
            risk-multiplier: risk-multiplier
        })
        
        ;; Add creator as first pool member
        (map-set pool-members { pool-id: pool-id, member: creator } {
            stake: initial-stake,
            voting-power: u100,
            joined-at: stacks-block-height,
            reputation-score: u100
        })
        
        (var-set pool-counter pool-id)
        (ok pool-id)))

;; Join an existing pool as a liquidity provider
(define-public (join-pool (pool-id uint) (stake-amount uint))
    (let ((pool-info (unwrap! (map-get? pools pool-id) ERR_POOL_NOT_FOUND))
          (member-info (default-to { stake: u0, voting-power: u0, joined-at: u0, reputation-score: u50 }
                                   (map-get? pool-members { pool-id: pool-id, member: tx-sender }))))
        
        (asserts! (is-eq (get status pool-info) POOL_ACTIVE) ERR_POOL_CLOSED)
        (asserts! (> stake-amount u0) ERR_INVALID_AMOUNT)
        
        ;; Transfer stake to contract
        (try! (stx-transfer? stake-amount tx-sender (as-contract tx-sender)))
        
        ;; Update pool reserves
        (map-set pools pool-id (merge pool-info {
            total-reserves: (+ (get total-reserves pool-info) stake-amount)
        }))
        
        ;; Update or create member record
        (map-set pool-members { pool-id: pool-id, member: tx-sender } {
            stake: (+ (get stake member-info) stake-amount),
            voting-power: (calculate-voting-power (+ (get stake member-info) stake-amount)),
            joined-at: (if (is-eq (get joined-at member-info) u0) stacks-block-height (get joined-at member-info)),
            reputation-score: (get reputation-score member-info)
        })
        
        (ok true)))

;; Purchase an insurance policy
(define-public (purchase-policy (pool-id uint) (coverage-amount uint) (duration-blocks uint))
    (let ((pool-info (unwrap! (map-get? pools pool-id) ERR_POOL_NOT_FOUND))
          (policy-id (+ (var-get policy-counter) u1))
          (risk-score (calculate-risk-score tx-sender coverage-amount))
          (premium (calculate-premium pool-info coverage-amount risk-score duration-blocks)))
        
        (asserts! (is-eq (get status pool-info) POOL_ACTIVE) ERR_POOL_CLOSED)
        (asserts! (<= coverage-amount (get max-coverage-per-policy pool-info)) ERR_POOL_CAPACITY_EXCEEDED)
        (asserts! (>= premium (get min-premium pool-info)) ERR_MINIMUM_PREMIUM_NOT_MET)
        (asserts! (> duration-blocks u0) ERR_INVALID_DURATION)
        (asserts! (<= (+ (get total-coverage pool-info) coverage-amount) 
                     (/ (* (get total-reserves pool-info) MAX_COVERAGE_RATIO) u100)) 
                 ERR_POOL_CAPACITY_EXCEEDED)
        
        ;; Transfer premium to contract
        (try! (stx-transfer? premium tx-sender (as-contract tx-sender)))
        
        ;; Create policy record
        (map-set policies policy-id {
            pool-id: pool-id,
            holder: tx-sender,
            coverage-amount: coverage-amount,
            premium-paid: premium,
            start-block: stacks-block-height,
            duration-blocks: duration-blocks,
            status: POLICY_ACTIVE,
            risk-score: risk-score,
            created-at: stacks-block-height
        })
        
        ;; Update pool coverage
        (map-set pools pool-id (merge pool-info {
            total-coverage: (+ (get total-coverage pool-info) coverage-amount),
            total-reserves: (+ (get total-reserves pool-info) premium)
        }))
        
        ;; Update policy holder record
        (let ((holder-info (default-to { active-policies: u0, total-premiums-paid: u0, 
                                       claims-count: u0, reputation-score: u100 }
                                      (map-get? policy-holders tx-sender))))
            (map-set policy-holders tx-sender {
                active-policies: (+ (get active-policies holder-info) u1),
                total-premiums-paid: (+ (get total-premiums-paid holder-info) premium),
                claims-count: (get claims-count holder-info),
                reputation-score: (get reputation-score holder-info)
            }))
        
        (var-set policy-counter policy-id)
        (ok policy-id)))

;; Cancel a policy (with partial premium refund)
(define-public (cancel-policy (policy-id uint))
    (let ((policy-info (unwrap! (map-get? policies policy-id) ERR_POLICY_NOT_FOUND))
          (pool-info (unwrap! (map-get? pools (get pool-id policy-info)) ERR_POOL_NOT_FOUND))
          (refund-amount (calculate-refund policy-info)))
        
        (asserts! (is-eq (get holder policy-info) tx-sender) ERR_UNAUTHORIZED)
        (asserts! (is-eq (get status policy-info) POLICY_ACTIVE) ERR_POLICY_EXPIRED)
        
        ;; Update policy status
        (map-set policies policy-id (merge policy-info { status: POLICY_CANCELLED }))
        
        ;; Update pool coverage and reserves
        (map-set pools (get pool-id policy-info) (merge pool-info {
            total-coverage: (- (get total-coverage pool-info) (get coverage-amount policy-info)),
            total-reserves: (- (get total-reserves pool-info) refund-amount)
        }))
        
        ;; Transfer refund if any
        (if (> refund-amount u0)
            (try! (as-contract (stx-transfer? refund-amount tx-sender (get holder policy-info))))
            true)
        
        (ok refund-amount)))

;; read only functions
;;

(define-read-only (get-pool-info (pool-id uint))
    (map-get? pools pool-id))

(define-read-only (get-policy-info (policy-id uint))
    (map-get? policies policy-id))

(define-read-only (get-pool-member-info (pool-id uint) (member principal))
    (map-get? pool-members { pool-id: pool-id, member: member }))

(define-read-only (get-policy-holder-info (holder principal))
    (map-get? policy-holders holder))

(define-read-only (is-policy-active (policy-id uint))
    (match (map-get? policies policy-id)
        policy-info (and (is-eq (get status policy-info) POLICY_ACTIVE)
                        (< stacks-block-height (+ (get start-block policy-info) (get duration-blocks policy-info))))
        false))

(define-read-only (get-pool-utilization (pool-id uint))
    (match (map-get? pools pool-id)
        pool-info (if (> (get total-reserves pool-info) u0)
                     (/ (* (get total-coverage pool-info) u100) (get total-reserves pool-info))
                     u0)
        u0))

;; private functions
;;

(define-private (calculate-voting-power (stake uint))
    (if (<= stake u1000000) ;; 1 STX
        u1
        (if (<= stake u10000000) ;; 10 STX
            u5
            (if (<= stake u100000000) ;; 100 STX
                u25
                u100))))

(define-private (calculate-risk-score (holder principal) (coverage-amount uint))
    (let ((holder-info (default-to { active-policies: u0, total-premiums-paid: u0, 
                                   claims-count: u0, reputation-score: u100 }
                                  (map-get? policy-holders holder))))
        (+ u50 ;; base risk score
           (if (> (get claims-count holder-info) u3) u30 u0) ;; high claims penalty
           (if (< (get reputation-score holder-info) u50) u20 u0) ;; low reputation penalty
           (/ coverage-amount u1000000)))) ;; coverage amount factor

(define-private (calculate-premium (pool-info { creator: principal, name: (string-ascii 50), 
                                              description: (string-ascii 200), total-reserves: uint, 
                                              total-coverage: uint, premium-rate: uint, 
                                              max-coverage-per-policy: uint, min-premium: uint, 
                                              created-at: uint, status: uint, 
                                              governance-threshold: uint, risk-multiplier: uint }) 
                                 (coverage-amount uint) (risk-score uint) (duration-blocks uint))
    (let ((base-premium (/ (* coverage-amount (get premium-rate pool-info)) u10000))
          (risk-adjustment (/ (* base-premium risk-score) u100))
          (duration-factor (/ duration-blocks u2016))) ;; blocks per week
        (+ base-premium risk-adjustment (* base-premium duration-factor))))

(define-private (calculate-refund (policy-info { pool-id: uint, holder: principal, coverage-amount: uint, 
                                               premium-paid: uint, start-block: uint, duration-blocks: uint, 
                                               status: uint, risk-score: uint, created-at: uint }))
    (let ((blocks-elapsed (- stacks-block-height (get start-block policy-info)))
          (total-duration (get duration-blocks policy-info)))
        (if (< blocks-elapsed (/ total-duration u4)) ;; If cancelled in first 25% of duration
            (/ (* (get premium-paid policy-info) u75) u100) ;; 75% refund
            (if (< blocks-elapsed (/ total-duration u2)) ;; If cancelled in first 50% of duration
                (/ (* (get premium-paid policy-info) u50) u100) ;; 50% refund
                u0)))) ;; No refund after 50% of duration
