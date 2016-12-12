;; Fibers: cooperative, event-driven user-space threads.

;;;; Copyright (C) 2016 Free Software Foundation, Inc.
;;;;
;;;; This library is free software; you can redistribute it and/or
;;;; modify it under the terms of the GNU Lesser General Public
;;;; License as published by the Free Software Foundation; either
;;;; version 3 of the License, or (at your option) any later version.
;;;;
;;;; This library is distributed in the hope that it will be useful,
;;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;;;; Lesser General Public License for more details.
;;;;
;;;; You should have received a copy of the GNU Lesser General Public
;;;; License along with this library; if not, write to the Free Software
;;;; Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
;;;;

(define-module (fibers internal)
  #:use-module (srfi srfi-9)
  #:use-module (fibers deque)
  #:use-module (fibers epoll)
  #:use-module (fibers psq)
  #:use-module (fibers nameset)
  #:use-module (ice-9 atomic)
  #:use-module (ice-9 control)
  #:use-module (ice-9 match)
  #:use-module (ice-9 fdes-finalizers)
  #:use-module ((ice-9 threads) #:select (current-thread))
  #:export (;; Low-level interface: schedulers and threads.
            make-scheduler
            with-scheduler
            scheduler-name
            (current-scheduler/public . current-scheduler)
            (scheduler-kernel-thread/public . scheduler-kernel-thread)
            run-scheduler
            destroy-scheduler

            resume-on-readable-fd
            resume-on-writable-fd
            resume-on-timer

            create-fiber
            (current-fiber/public . current-fiber)
            kill-fiber
            fiber-scheduler
            fiber-continuation

            fold-all-schedulers
            scheduler-by-name
            fold-all-fibers
            fiber-by-name

            suspend-current-fiber
            resume-fiber))

(define-once fibers-nameset (make-nameset))
(define-once schedulers-nameset (make-nameset))

(define (fold-all-schedulers f seed)
  "Fold @var{f} over the set of known schedulers.  @var{f} will be
invoked as @code{(@var{f} @var{name} @var{scheduler} @var{seed})}."
  (nameset-fold f schedulers-nameset seed))
(define (scheduler-by-name name)
  "Return the scheduler named @var{name}, or @code{#f} if no scheduler
of that name is known."
  (nameset-ref schedulers-nameset name))

(define (fold-all-fibers f seed)
  "Fold @var{f} over the set of known fibers.  @var{f} will be
invoked as @code{(@var{f} @var{name} @var{fiber} @var{seed})}."
  (nameset-fold f fibers-nameset seed))
(define (fiber-by-name name)
  "Return the fiber named @var{name}, or @code{#f} if no fiber of that
name is known."
  (nameset-ref fibers-nameset name))

(define-record-type <scheduler>
  (%make-scheduler name epfd active-fd-count prompt-tag runqueue
                   sources timers kernel-thread)
  scheduler?
  (name scheduler-name set-scheduler-name!)
  (epfd scheduler-epfd)
  (active-fd-count scheduler-active-fd-count set-scheduler-active-fd-count!)
  (prompt-tag scheduler-prompt-tag)
  ;; atomic box of deque of fiber
  (runqueue scheduler-runqueue)
  ;; fd -> ((total-events . min-expiry) #(events expiry fiber) ...)
  (sources scheduler-sources)
  ;; PSQ of thunk -> expiry
  (timers scheduler-timers set-scheduler-timers!)
  ;; atomic parameter of thread
  (kernel-thread scheduler-kernel-thread))

(define-record-type <fiber>
  (make-fiber scheduler continuation)
  fiber?
  ;; The scheduler that a fiber runs in.  As a scheduler only runs in
  ;; one kernel thread, this binds a fiber to a kernel thread.
  (scheduler fiber-scheduler)
  ;; What the fiber should do when it resumes, or #f if the fiber is
  ;; currently running.
  (continuation fiber-continuation set-fiber-continuation!))

(define (make-atomic-parameter init)
  (let ((box (make-atomic-box init)))
    (case-lambda
      (() (atomic-box-ref box))
      ((new)
       (if (eq? new init)
           (atomic-box-set! box new)
           (let ((prev (atomic-box-compare-and-swap! box init new)))
             (unless (eq? prev init)
               (error "owned by other thread" prev))))))))

(define (make-scheduler)
  "Make a new scheduler in which to run fibers."
  (let ((epfd (epoll-create))
        (active-fd-count 0)
        (prompt-tag (make-prompt-tag "fibers"))
        (runqueue (make-atomic-box (make-empty-deque)))
        (sources (make-hash-table))
        (timers (make-psq (match-lambda*
                            (((t1 . c1) (t2 . c2)) (< t1 t2)))
                          <))
        (kernel-thread (make-atomic-parameter #f)))
    (let ((sched (%make-scheduler #f epfd active-fd-count prompt-tag
                                  runqueue sources timers kernel-thread)))
      (set-scheduler-name! sched (nameset-add! schedulers-nameset sched))
      sched)))

(define-syntax-rule (with-scheduler scheduler body ...)
  "Evaluate @code{(begin @var{body} ...)} in an environment in which
@var{scheduler} is bound to the current kernel thread and marked as
current.  Signal an error if @var{scheduler} is already running in
some other kernel thread."
  (let ((sched scheduler))
    (dynamic-wind (lambda ()
                    ((scheduler-kernel-thread sched) (current-thread)))
                  (lambda ()
                    (parameterize ((current-scheduler sched))
                      body ...))
                  (lambda ()
                    ((scheduler-kernel-thread sched) #f)))))

(define (scheduler-kernel-thread/public sched)
  "Return the kernel thread on which @var{sched} is running, or
@code{#f} if @var{sched} is not running."
  ((scheduler-kernel-thread sched)))

(define current-scheduler (make-parameter #f))
(define (current-scheduler/public)
  "Return the current scheduler, or @code{#f} if no scheduler is
current."
  (current-scheduler))
(define (make-source events expiry fiber) (vector events expiry fiber))
(define (source-events s) (vector-ref s 0))
(define (source-expiry s) (vector-ref s 1))
(define (source-fiber s) (vector-ref s 2))

(define current-fiber (make-parameter #f))
(define (current-fiber/public)
  "Return the current fiber, or @code{#f} if no fiber is current."
  (current-fiber))

(define (schedule-fiber! fiber thunk)
  ;; The fiber will be resumed at most once, and we are the ones that
  ;; will resume it, so we can set the thunk directly.  Adding the
  ;; fiber to the runqueue is an atomic operation with SEQ_CST
  ;; ordering, so that will make sure this operation is visible even
  ;; for a fiber scheduled on a remote thread.
  (set-fiber-continuation! fiber thunk)
  (let ((sched (fiber-scheduler fiber)))
    (enqueue! (scheduler-runqueue sched) fiber)
    (unless (eq? sched (current-scheduler))
      (epoll-wake! (scheduler-epfd sched)))
    (values)))

(define internal-time-units-per-millisecond
  (/ internal-time-units-per-second 1000))

(define (schedule-fibers-for-fd fd revents sched)
  (match (hashv-ref (scheduler-sources sched) fd)
    (#f (warn "scheduler for unknown fd" fd))
    (sources
     (set-scheduler-active-fd-count! sched
                                     (1- (scheduler-active-fd-count sched)))
     (for-each (lambda (source)
                 ;; FIXME: This fiber might have been woken up by
                 ;; another event.  A moot point while file descriptor
                 ;; operations aren't proper CML operations, though.
                 (unless (zero? (logand revents
                                        (logior (source-events source) EPOLLERR)))
                   (resume-fiber (source-fiber source) (lambda () revents))))
               (cdr sources))
     (cond
      ((zero? (logand revents EPOLLERR))
       (hashv-remove! (scheduler-sources sched) fd)
       (epoll-remove! (scheduler-epfd sched) fd))
      (else
       (set-cdr! sources '())
       ;; Reset active events and expiration time, respectively.
       (set-car! (car sources) #f)
       (set-cdr! (car sources) #f))))))

(define (scheduler-poll-timeout sched)
  (cond
   ((not (empty-deque? (atomic-box-ref (scheduler-runqueue sched))))
    ;; Don't sleep if there are fibers in the runqueue already.
    0)
   ((psq-empty? (scheduler-timers sched))
    ;; If there are no timers, only sleep if there are active fd's. (?)
    (cond
     ((zero? (scheduler-active-fd-count sched)) 0)
     (else -1)))
   (else
    (match (psq-min (scheduler-timers sched))
      ((expiry . thunk)
       (let ((now (get-internal-real-time)))
         (if (< expiry now)
             0
             (round/ (- expiry now)
                     internal-time-units-per-millisecond))))))))

(define (run-timers sched)
  ;; Run expired timer thunks in the order that they expired.
  (let ((now (get-internal-real-time)))
    (let run-timers ((timers (scheduler-timers sched)))
      (cond
       ((or (psq-empty? timers)
            (< now (car (psq-min timers))))
        (set-scheduler-timers! sched timers))
       (else
        (call-with-values (lambda () (psq-pop timers))
          (match-lambda*
            (((_ . thunk) timers)
             (thunk)
             (run-timers timers)))))))))

(define (schedule-runnables-for-next-turn sched)
  ;; Called when all runnables from the current turn have been run.
  ;; Note that there may be runnables already scheduled for the next
  ;; turn; one way this can happen is if a fiber suspended itself
  ;; because it was blocked on a channel, but then another fiber woke
  ;; it up, or if a remote thread scheduled a fiber on this scheduler.
  ;; In any case, check the kernel to see if any of the fd's that we
  ;; are interested in are active, and in that case schedule their
  ;; corresponding fibers.  Also run any timers that have timed out.
  (epoll (scheduler-epfd sched)
         #:get-timeout (lambda () (scheduler-poll-timeout sched))
         #:folder (lambda (fd revents seed)
                    (schedule-fibers-for-fd fd revents sched)
                    seed))
  (run-timers sched))

(define* (run-fiber fiber)
  (parameterize ((current-fiber fiber))
    (call-with-prompt
        (scheduler-prompt-tag (fiber-scheduler fiber))
      (lambda ()
        (let ((thunk (fiber-continuation fiber)))
          (set-fiber-continuation! fiber #f)
          (thunk)))
      (lambda (k after-suspend)
        (set-fiber-continuation! fiber k)
        (after-suspend fiber)))))

(define* (run-scheduler sched)
  "Run @var{sched} until there are no more fibers ready to run, no
file descriptors being waited on, and no more timers pending to run.
Return zero values."
  (let lp ()
    (schedule-runnables-for-next-turn sched)
    (match (dequeue-all! (scheduler-runqueue sched))
      (()
       ;; Could be the scheduler is stopping, or it could be that we
       ;; got a spurious wakeup.  In any case, this is the place to
       ;; check to see whether the scheduler is really done.
       (cond
        ((not (zero? (scheduler-active-fd-count sched))) (lp))
        ((not (psq-empty? (scheduler-timers sched))) (lp))
        (else (values))))
      (runnables
       (for-each run-fiber runnables)
       (lp)))))

(define (destroy-scheduler sched)
  "Release any resources associated with @var{sched}."
  #;
  (for-each kill-fiber (list-copy (scheduler-fibers sched)))
  (epoll-destroy (scheduler-epfd sched)))

(define (create-fiber sched thunk)
  "Spawn a new fiber in @var{sched} with the continuation @var{thunk}.
The fiber will be scheduled on the next turn."
  (let ((fiber (make-fiber sched #f)))
    (nameset-add! fibers-nameset fiber)
    (schedule-fiber! fiber thunk)))

(define (kill-fiber fiber)
  "Try to kill @var{fiber}, causing it to raise an exception.  Note
that this is currently unimplemented!"
  (error "kill-fiber is unimplemented"))

;; Shim for Guile 2.1.5.
(unless (defined? 'suspendable-continuation?)
  (define! 'suspendable-continuation? (lambda (tag) #t)))

;; The AFTER-SUSPEND thunk allows the user to suspend the current
;; fiber, saving its state, and then perform some other nonlocal
;; control flow.
;;
(define* (suspend-current-fiber #:optional
                                (after-suspend (lambda (fiber) #f)))
  "Suspend the current fiber.  Call the optional @var{after-suspend}
callback, if present, with the suspended thread as its argument."
  (let ((tag (scheduler-prompt-tag (current-scheduler))))
    (unless (suspendable-continuation? tag)
      (error "Attempt to suspend fiber within continuation barrier"))
    ((abort-to-prompt tag after-suspend))))

(define* (resume-fiber fiber thunk)
  "Resume @var{fiber}, adding it to the run queue of its scheduler.
The fiber will start by applying @var{thunk}.  A fiber @emph{must}
only be resumed when it is suspended.  This function is thread-safe
even if @var{fiber} is running on a remote scheduler."
  (let ((cont (fiber-continuation fiber)))
    (unless cont (error "invalid fiber" fiber))
    (schedule-fiber! fiber (lambda () (cont thunk)))))

(define (finalize-fd sched fd)
  "Remove data associated with @var{fd} from the scheduler @var{ctx}.
Called by Guile just before Guile goes to close a file descriptor, in
response either to an explicit call to @code{close-port}, or because
the port became unreachable.  In the latter case, this call may come
from a finalizer thread."
  ;; When a file descriptor is closed, the kernel silently removes it
  ;; from any associated epoll sets, so we don't need to do anything
  ;; there.
  ;;
  ;; FIXME: Take a lock on the sources table?
  ;; FIXME: Wake all sources with EPOLLERR.
  (let ((sources-table (scheduler-sources sched)))
    (when (hashv-ref sources-table fd)
      (set-scheduler-active-fd-count! sched
                                      (1- (scheduler-active-fd-count sched)))
      (hashv-remove! sources-table fd))))

(define (resume-on-fd-events fd events fiber)
  "Arrange to resume @var{fiber} when the file descriptor @var{fd} has
the given @var{events}, expressed as an epoll bitfield."
  (let* ((sched (fiber-scheduler fiber))
         (sources (hashv-ref (scheduler-sources sched) fd)))
    (cond
     (sources
      (set-cdr! sources (cons (make-source events #f fiber) (cdr sources)))
      (let ((active-events (caar sources)))
        (unless active-events
          (set-scheduler-active-fd-count! sched
                                          (1+ (scheduler-active-fd-count sched))))
        (unless (and active-events
                     (= (logand events active-events) events))
          (set-car! (car sources) (logior events (or active-events 0)))
          (epoll-modify! (scheduler-epfd sched) fd
                         (logior (caar sources) EPOLLONESHOT)))))
     (else
      (set-scheduler-active-fd-count! sched
                                      (1+ (scheduler-active-fd-count sched)))
      (hashv-set! (scheduler-sources sched)
                  fd (acons events #f
                            (list (make-source events #f fiber))))
      (add-fdes-finalizer! fd (lambda (fd) (finalize-fd sched fd)))
      (epoll-add! (scheduler-epfd sched) fd (logior events EPOLLONESHOT))))))

(define (resume-on-readable-fd fd fiber)
  "Arrange to resume @var{fiber} when the file descriptor @var{fd}
becomes readable."
  (resume-on-fd-events fd (logior EPOLLIN EPOLLRDHUP) fiber))

(define (resume-on-writable-fd fd fiber)
  "Arrange to resume @var{fiber} when the file descriptor @var{fd}
becomes writable."
  (resume-on-fd-events fd EPOLLOUT fiber))

(define (resume-on-timer fiber expiry get-thunk)
  "Arrange to resume @var{fiber} when the absolute real time is
greater than or equal to @var{expiry}, expressed in internal time
units.  The fiber will be resumed with the result of calling
@var{get-thunk}.  If @var{get-thunk} returns @code{#f}, that indicates
that some other operation performed this operation first, and so no
resume is performed."
  (let ((sched (fiber-scheduler fiber)))
    (define (maybe-resume)
      (let ((thunk (get-thunk)))
        (when thunk (resume-fiber fiber thunk))))
    (set-scheduler-timers! sched
                           (psq-set (scheduler-timers sched)
                                    (cons expiry maybe-resume)
                                    expiry))))
