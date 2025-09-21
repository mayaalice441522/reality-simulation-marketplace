;; Reality Experience Distributor Contract
;; Facilitates access to simulated universes through immersive interfaces
;; Manages subscription models and revenue sharing for universe creators

;; Error codes
(define-constant ERR-UNAUTHORIZED (err u200))
(define-constant ERR-UNIVERSE-NOT-FOUND (err u201))
(define-constant ERR-INSUFFICIENT-FUNDS (err u202))
(define-constant ERR-SUBSCRIPTION-EXISTS (err u203))
(define-constant ERR-SUBSCRIPTION-NOT-FOUND (err u204))
(define-constant ERR-SUBSCRIPTION-EXPIRED (err u205))
(define-constant ERR-INVALID-RATING (err u206))
(define-constant ERR-ALREADY-RATED (err u207))
(define-constant ERR-ACCESS-DENIED (err u208))
(define-constant ERR-INVALID-PARAMETERS (err u209))

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant CREATOR-REVENUE-PERCENTAGE u85) ;; 85% goes to creator, 15% platform fee
(define-constant MIN-SUBSCRIPTION-DURATION u86400) ;; 1 day in seconds
(define-constant MAX-RATING u10) ;; Rating scale 1-10
(define-constant REPUTATION-BOOST-THRESHOLD u8) ;; Good rating threshold

;; Data variables
(define-data-var total-revenue uint u0)
(define-data-var total-subscriptions uint u0)
(define-data-var platform-revenue uint u0)

;; User access records
(define-map user-access
  { user: principal, universe-id: uint }
  {
    access-type: (string-ascii 20), ;; "one-time" or "subscription"
    purchased-at: uint,
    expires-at: uint,
    total-paid: uint,
    access-count: uint,
    is-active: bool
  }
)

;; Subscription management
(define-map subscriptions
  { subscription-id: uint }
  {
    user: principal,
    universe-id: uint,
    subscription-type: (string-ascii 20), ;; "monthly", "yearly", "lifetime"
    price-per-period: uint,
    started-at: uint,
    expires-at: uint,
    auto-renewal: bool,
    is-active: bool
  }
)

;; Universe ratings and reviews
(define-map universe-ratings
  { universe-id: uint }
  {
    total-ratings: uint,
    sum-ratings: uint,
    average-rating: uint,
    total-reviews: uint
  }
)

;; Individual user ratings
(define-map user-ratings
  { user: principal, universe-id: uint }
  {
    rating: uint,
    review: (string-ascii 256),
    rated-at: uint
  }
)

;; Revenue distribution tracking
(define-map creator-earnings
  { creator: principal }
  {
    total-earnings: uint,
    pending-withdrawal: uint,
    last-withdrawal: uint,
    withdrawal-count: uint
  }
)

;; Experience metrics
(define-map experience-metrics
  { universe-id: uint }
  {
    total-access-time: uint,
    unique-users: uint,
    total-sessions: uint,
    last-accessed: uint
  }
)

;; Quality assurance data
(define-map quality-scores
  { universe-id: uint }
  {
    performance-score: uint,
    stability-score: uint,
    user-satisfaction: uint,
    last-updated: uint
  }
)

;; Helper function to calculate subscription price
(define-private (calculate-subscription-price (base-price uint) (subscription-type (string-ascii 20)))
  (if (is-eq subscription-type "monthly")
    (* base-price u30)
    (if (is-eq subscription-type "yearly")
      (* base-price u300) ;; 10 months price for yearly
      (* base-price u3000) ;; Lifetime = ~8 years
    )
  )
)

;; Helper function to calculate revenue split
(define-private (calculate-revenue-split (amount uint))
  {
    creator-share: (/ (* amount CREATOR-REVENUE-PERCENTAGE) u100),
    platform-share: (/ (* amount (- u100 CREATOR-REVENUE-PERCENTAGE)) u100)
  }
)

;; Helper function to get subscription duration in blocks
(define-private (get-subscription-duration (subscription-type (string-ascii 20)))
  (if (is-eq subscription-type "monthly")
    u4320 ;; ~30 days in blocks (assuming 10-minute blocks)
    (if (is-eq subscription-type "yearly")
      u52560 ;; ~365 days in blocks
      u999999999 ;; Lifetime (very large number)
    )
  )
)

;; Read-only function to check user access
(define-read-only (check-user-access (user principal) (universe-id uint))
  (match (map-get? user-access { user: user, universe-id: universe-id })
    access-data 
    {
      has-access: (and 
        (get is-active access-data)
        (>= (get expires-at access-data) stacks-block-height)
      ),
      access-type: (get access-type access-data),
      expires-at: (get expires-at access-data)
    }
    {
      has-access: false,
      access-type: "none",
      expires-at: u0
    }
  )
)

;; Read-only function to get universe ratings
(define-read-only (get-universe-ratings (universe-id uint))
  (map-get? universe-ratings { universe-id: universe-id })
)

;; Read-only function to get user's rating for a universe
(define-read-only (get-user-rating (user principal) (universe-id uint))
  (map-get? user-ratings { user: user, universe-id: universe-id })
)

;; Read-only function to get creator earnings
(define-read-only (get-creator-earnings (creator principal))
  (map-get? creator-earnings { creator: creator })
)

;; Read-only function to get platform statistics
(define-read-only (get-platform-statistics)
  {
    total-revenue: (var-get total-revenue),
    total-subscriptions: (var-get total-subscriptions),
    platform-revenue: (var-get platform-revenue)
  }
)

;; Initialize creator earnings if not exists
(define-private (initialize-creator-earnings (creator principal))
  (match (map-get? creator-earnings { creator: creator })
    existing-earnings true
    (map-set creator-earnings
      { creator: creator }
      {
        total-earnings: u0,
        pending-withdrawal: u0,
        last-withdrawal: u0,
        withdrawal-count: u0
      }
    )
  )
)

;; Public function to purchase one-time access
(define-public (purchase-access (universe-id uint) (universe-creator principal) (access-price uint))
  (let (
    (revenue-split (calculate-revenue-split access-price))
    (creator-share (get creator-share revenue-split))
    (platform-share (get platform-share revenue-split))
  )
    ;; Validate parameters
    (asserts! (> access-price u0) ERR-INVALID-PARAMETERS)
    
    ;; Check if user already has active access
    (match (map-get? user-access { user: tx-sender, universe-id: universe-id })
      existing-access
      (asserts! (not (and 
        (get is-active existing-access)
        (>= (get expires-at existing-access) stacks-block-height)
      )) ERR-SUBSCRIPTION-EXISTS)
      true
    )
    
    ;; Transfer payment from user
    (try! (stx-transfer? access-price tx-sender (as-contract tx-sender)))
    
    ;; Initialize creator earnings tracking
    (initialize-creator-earnings universe-creator)
    
    ;; Create or update access record
    (map-set user-access
      { user: tx-sender, universe-id: universe-id }
      {
        access-type: "one-time",
        purchased-at: stacks-block-height,
        expires-at: (+ stacks-block-height u1440), ;; ~10 days access
        total-paid: access-price,
        access-count: u1,
        is-active: true
      }
    )
    
    ;; Update creator earnings
    (match (map-get? creator-earnings { creator: universe-creator })
      earnings-data
      (map-set creator-earnings
        { creator: universe-creator }
        (merge earnings-data {
          total-earnings: (+ (get total-earnings earnings-data) creator-share),
          pending-withdrawal: (+ (get pending-withdrawal earnings-data) creator-share)
        })
      )
      false
    )
    
    ;; Update platform revenue
    (var-set total-revenue (+ (var-get total-revenue) access-price))
    (var-set platform-revenue (+ (var-get platform-revenue) platform-share))
    
    (ok true)
  )
)

;; Public function to subscribe to universe
(define-public (subscribe-to-universe 
  (universe-id uint) 
  (universe-creator principal)
  (base-price uint)
  (subscription-type (string-ascii 20))
  (auto-renewal bool)
)
  (let (
    (subscription-price (calculate-subscription-price base-price subscription-type))
    (duration (get-subscription-duration subscription-type))
    (revenue-split (calculate-revenue-split subscription-price))
    (creator-share (get creator-share revenue-split))
    (platform-share (get platform-share revenue-split))
    (subscription-id (var-get total-subscriptions))
  )
    ;; Validate parameters
    (asserts! (> subscription-price u0) ERR-INVALID-PARAMETERS)
    (asserts! (or 
      (is-eq subscription-type "monthly")
      (is-eq subscription-type "yearly")
      (is-eq subscription-type "lifetime")
    ) ERR-INVALID-PARAMETERS)
    
    ;; Transfer payment
    (try! (stx-transfer? subscription-price tx-sender (as-contract tx-sender)))
    
    ;; Initialize creator earnings
    (initialize-creator-earnings universe-creator)
    
    ;; Create subscription record
    (map-set subscriptions
      { subscription-id: subscription-id }
      {
        user: tx-sender,
        universe-id: universe-id,
        subscription-type: subscription-type,
        price-per-period: subscription-price,
        started-at: stacks-block-height,
        expires-at: (+ stacks-block-height duration),
        auto-renewal: auto-renewal,
        is-active: true
      }
    )
    
    ;; Update user access
    (map-set user-access
      { user: tx-sender, universe-id: universe-id }
      {
        access-type: "subscription",
        purchased-at: stacks-block-height,
        expires-at: (+ stacks-block-height duration),
        total-paid: subscription-price,
        access-count: u1,
        is-active: true
      }
    )
    
    ;; Update creator earnings
    (match (map-get? creator-earnings { creator: universe-creator })
      earnings-data
      (map-set creator-earnings
        { creator: universe-creator }
        (merge earnings-data {
          total-earnings: (+ (get total-earnings earnings-data) creator-share),
          pending-withdrawal: (+ (get pending-withdrawal earnings-data) creator-share)
        })
      )
      false
    )
    
    ;; Update global counters
    (var-set total-subscriptions (+ subscription-id u1))
    (var-set total-revenue (+ (var-get total-revenue) subscription-price))
    (var-set platform-revenue (+ (var-get platform-revenue) platform-share))
    
    (ok subscription-id)
  )
)

;; Public function to rate universe experience
(define-public (rate-experience (universe-id uint) (rating uint) (review (string-ascii 256)))
  (let (
    (current-ratings (default-to 
      { total-ratings: u0, sum-ratings: u0, average-rating: u0, total-reviews: u0 }
      (map-get? universe-ratings { universe-id: universe-id })
    ))
    (new-total-ratings (+ (get total-ratings current-ratings) u1))
    (new-sum-ratings (+ (get sum-ratings current-ratings) rating))
    (new-average (/ new-sum-ratings new-total-ratings))
  )
    ;; Validate rating
    (asserts! (and (>= rating u1) (<= rating MAX-RATING)) ERR-INVALID-RATING)
    
    ;; Check if user has access to this universe
    (let (
      (access-info (check-user-access tx-sender universe-id))
    )
      (asserts! (get has-access access-info) ERR-ACCESS-DENIED)
    )
    
    ;; Check if user has already rated
    (asserts! (is-none (map-get? user-ratings { user: tx-sender, universe-id: universe-id })) ERR-ALREADY-RATED)
    
    ;; Store individual rating
    (map-set user-ratings
      { user: tx-sender, universe-id: universe-id }
      {
        rating: rating,
        review: review,
        rated-at: stacks-block-height
      }
    )
    
    ;; Update aggregate ratings
    (map-set universe-ratings
      { universe-id: universe-id }
      {
        total-ratings: new-total-ratings,
        sum-ratings: new-sum-ratings,
        average-rating: new-average,
        total-reviews: (if (> (len review) u0) 
          (+ (get total-reviews current-ratings) u1)
          (get total-reviews current-ratings)
        )
      }
    )
    
    (ok true)
  )
)

;; Public function for creators to withdraw earnings
(define-public (withdraw-earnings (amount uint))
  (let (
    (earnings-data (unwrap! (map-get? creator-earnings { creator: tx-sender }) ERR-UNAUTHORIZED))
    (pending-amount (get pending-withdrawal earnings-data))
  )
    ;; Validate withdrawal
    (asserts! (<= amount pending-amount) ERR-INSUFFICIENT-FUNDS)
    (asserts! (> amount u0) ERR-INVALID-PARAMETERS)
    
    ;; Transfer funds to creator
    (try! (as-contract (stx-transfer? amount tx-sender tx-sender)))
    
    ;; Update earnings record
    (map-set creator-earnings
      { creator: tx-sender }
      (merge earnings-data {
        pending-withdrawal: (- pending-amount amount),
        last-withdrawal: stacks-block-height,
        withdrawal-count: (+ (get withdrawal-count earnings-data) u1)
      })
    )
    
    (ok amount)
  )
)

;; Public function to cancel subscription (user only)
(define-public (cancel-subscription (subscription-id uint))
  (let (
    (subscription-data (unwrap! (map-get? subscriptions { subscription-id: subscription-id }) ERR-SUBSCRIPTION-NOT-FOUND))
  )
    ;; Check authorization
    (asserts! (is-eq tx-sender (get user subscription-data)) ERR-UNAUTHORIZED)
    (asserts! (get is-active subscription-data) ERR-SUBSCRIPTION-NOT-FOUND)
    
    ;; Deactivate subscription
    (map-set subscriptions
      { subscription-id: subscription-id }
      (merge subscription-data {
        is-active: false,
        auto-renewal: false
      })
    )
    
    ;; Update user access to expire at current block
    (match (map-get? user-access { user: tx-sender, universe-id: (get universe-id subscription-data) })
      access-data
      (map-set user-access
        { user: tx-sender, universe-id: (get universe-id subscription-data) }
        (merge access-data { expires-at: stacks-block-height })
      )
      false
    )
    
    (ok true)
  )
)


;; title: reality-experience-distributor
;; version:
;; summary:
;; description:

;; traits
;;

;; token definitions
;;

;; constants
;;

;; data vars
;;

;; data maps
;;

;; public functions
;;

;; read only functions
;;

;; private functions
;;

