
(module port mzscheme
  (require (lib "etc.ss"))

  (provide open-output-nowhere
	   make-input-port/read-to-peek
	   merge-input
	   copy-port
	   input-port-append
	   convert-stream
	   make-limited-input-port)

  (define open-output-nowhere
    (opt-lambda ([name 'nowhere])
      (make-output-port 
       name
       always-evt
       (lambda (s start end non-block? breakable?) (- end start))
       void
       (lambda (special non-block?) #t)
       (lambda (s start end) (convert-evt
			      always-evt
			      (lambda (x)
				(- end start))))
       (lambda (special) (convert-evt always-evt (lambda (x) #t))))))

  (define (copy-port src dest . dests)
    (unless (input-port? src)
      (raise-type-error 'copy-port "input-port" src))
    (for-each
     (lambda (dest)
       (unless (output-port? dest)
	 (raise-type-error 'copy-port "output-port" dest)))
     (cons dest dests))
    (let ([s (make-bytes 4096)])
      (let loop ()
	(let ([c (read-bytes-avail! s src)])
	  (unless (eof-object? c)
	    (for-each
	     (lambda (dest)
	       (let loop ([start 0])
		 (unless (= start c)
		   (let ([c2 (write-bytes-avail s dest start c)])
		     (loop (+ start c2))))))
	     (cons dest dests))
	    (loop))))))
  
  (define merge-input
    (case-lambda
     [(a b) (merge-input a b 4096)]
     [(a b limit)
      (or (input-port? a)
	  (raise-type-error 'merge-input "input-port" a))
      (or (input-port? b)
	  (raise-type-error 'merge-input "input-port" b))
      (or (not limit)
	  (and (number? limit) (positive? limit) (exact? limit) (integer? limit))
	  (raise-type-error 'merge-input "positive exact integer or #f" limit))
      (let-values ([(rd wt) (make-pipe limit)]
		   [(other-done?) #f]
		   [(sema) (make-semaphore 1)])
	(let ([copy
	       (lambda (from)
                 (thread 
                  (lambda ()
                    (copy-port from wt)
                    (semaphore-wait sema)
                    (if other-done?
                        (close-output-port wt)
                        (set! other-done? #t))
                    (semaphore-post sema))))])
	  (copy a)
	  (copy b)
	  rd))]))

  ;; Not kill-safe.
  ;; Works only when read proc never returns an event.
  (define (make-input-port/read-to-peek name read fast-peek close)
    (define lock-semaphore (make-semaphore 1))
    (define-values (peeked-r peeked-w) (make-pipe))
    (define peeked-end 0)
    (define special-peeked null)
    (define special-peeked-tail #f)
    (define progress-requested? #f)
    (define (try-again)
      (convert-evt
       (semaphore-peek-evt lock-semaphore)
       (lambda (x) 0)))
    (define (make-progress)
      (write-byte 0 peeked-w)
      (read-byte peeked-r))
    (define (read-it s)
      (call-with-semaphore
       lock-semaphore
       (lambda ()
	 (do-read-it s))
       try-again))
    (define (do-read-it s)
      (if (char-ready? peeked-r)
	  (read-bytes-avail!* s peeked-r)
	  ;; If nothing is saved from a peeking read,
	  ;; dispatch to `read', otherwise
	  (cond
	   [(null? special-peeked) 
	    (when progress-requested? (make-progress))
	    (read s)]
	   [else (if (bytes? (car special-peeked))
		     (let ([b (car special-peeked)])
		       (set! peeked-end (+ (file-position peeked-r) (bytes-length b)))
		       (write-bytes b peeked-w)
		       (set! special-peeked (cdr special-peeked))
		       (when (null? special-peeked)
			 (set! special-peeked-tail #f))
		       (read-bytes-avail!* s peeked-r))
		     (begin0
		      (car special-peeked)
		      (make-progress)
		      (set! special-peeked (cdr special-peeked))
		      (when (null? special-peeked)
			(set! special-peeked-tail #f))))])))
    (define (peek-it s skip unless-evt)
      (call-with-semaphore
       lock-semaphore
       (lambda ()
	 (do-peek-it s skip unless-evt))
       try-again))
    (define (do-peek-it s skip unless-evt)
      (let ([v (peek-bytes-avail!* s skip unless-evt peeked-r)])
	(if (zero? v)
	    ;; The peek may have failed because peeked-r is empty,
	    ;; because unless-evt is ready, or because the skip is
	    ;; far. Handle nicely the common case where there are no
	    ;; specials.
	    (cond
	     [(and unless-evt (sync/timeout 0 unless-evt))
	      0]
	     [(null? special-peeked)
	      ;; Empty special queue, so read through the original proc
	      (let ([r (read s)])
		(cond
		 [(number? r)
		  ;; The nice case --- reading gave us more bytes
		  (set! peeked-end (+ r peeked-end))
		  (write-bytes s peeked-w 0 r)
		  ;; Now try again
		  (peek-bytes-avail!* s skip #f peeked-r)]
		 [else
		  (set! special-peeked (cons r null))
		  (set! special-peeked-tail special-peeked)
		  ;; Now try again
		  (peek-it s skip)]))]
	     [else
	      ;; Non-empty special queue, so try to use it
	      (let* ([pos (file-position peeked-r)]
		     [avail (- peeked-end pos)]
		     [skip (- skip avail)])
		(let loop ([skip (- skip avail)]
			   [l special-peeked])
		  (cond
		   [(null? l)
		    ;; Not enough even in the special queue.
		    ;; Read once and add it.
		    (let* ([t (make-bytes (min 4096 (+ skip (bytes-length s))))]
			   [r (read s)])
		      (cond
		       [(evt? r) 
			;; We can't deal with an event, so complain
			(error 'make-input-port/read-to-peek 
			       "original read produced an event: ~e"
			       r)]
		       [(eq? r 0) 
			;; Original read thinks a spin is ok,
			;;  so we return 0 to skin, too.
			0]
		       [else (let ([v (if (number? r)
					  (subbytes t 0 r)
					  r)])
			       (set-cdr! special-peeked-tail v)
			       ;; Got something; now try again
			       (do-peek-it s skip))]))]
		   [(eof-object? (car l)) 
		    ;; No peeking past an EOF
		    eof]
		   [(procedure? (car l))
		    (if (skip . < . 1)
			(car l)
			(loop (sub1 skip) (cdr l)))]
		   [(bytes? (car l))
		    (let ([len (bytes-length (car l))])
		      (if (skip . < . len)
			  (let ([n (min (bytes-length s)
					(- len skip))])
			    (bytes-copy! s 0 (car l) skip (+ skip n))
			    n)
			  (loop (- skip len) (cdr l))))])))])
	    v)))
    (define (commit-it amt unless-evt dont-evt)
      (call-with-semaphore
       lock-semaphore
       (lambda ()
	 (do-commit-it amt unless-evt dont-evt))))
    (define (do-commit-it amt unless-evt dont-evt)
      (if (sync/timeout 0 unless-evt)
	  #f
	  (let* ([pos (file-position peeked-r)]
		 [avail (- peeked-end pos)]
		 [p-commit (min avail amt)])
	    (let loop ([amt (- amt p-commit)]
		       [l special-peeked])
	      (cond
	       [(amt . <= . 0)
		;; Enough has been peeked...
		(unless (zero? p-commit)
		  (peek-byte peeked-r (sub1 amt))
		  (port-commit-peeked amt peeked-r))
		(set! special-peeked l)
		(when (null? special-peeked)
		  (set! special-peeked-tail #f))
		#t]
	       [(null? l)
		;; Requested commit was larger than previous peeks
		#f]
	       [(bytes? (car l))
		(let ([bl (bytes-length (car l))])
		  (if (bl . > . amt)
		      ;; Split the string
		      (let ([next (cons
				   (subbytes (car l) amt)
				   (cdr l))])
			(set-car! l (subbytes (car l) 0 amt))
			(set-cdr! l next)
			(when (eq? l special-peeked-tail)
			  (set! special-peeked-tail next))
			(loop 0 (cdr l)))
		      ;; Consume this string...
		      (loop  (- amt bl) (cdr l))))]
	       [else
		(loop (sub1 amt) (cdr l))])))))
    (make-input-port
     name
     ;; Read
     read-it
     ;; Peek
     (if fast-peek
	 (lambda (s skip)
	   (fast-peek s skip peek-it))
	 peek-it)
     close
     (lambda ()
       (set! progress-requested? #t)
       (port-progress-evt peeked-r))
     commit-it))
       

  (define input-port-append
    (opt-lambda (close-orig? . ports)
      (make-input-port
       (map object-name ports)
       (lambda (str)
	 ;; Reading is easy -- read from the first port,
	 ;;  and get rid of it if the result is eof
	 (if (null? ports)
	     eof
	     (let ([n (read-bytes-avail!* str (car ports))])
	       (cond
		[(eq? n 0) (car ports)]
		[(eof-object? n)
		 (when close-orig?
		   (close-input-port (car ports)))
		 (set! ports (cdr ports))
		 0]
		[else n]))))
       (lambda (str skip unless-evt)
	 ;; Peeking is more difficult, due to skips.
	 (let loop ([ports ports][skip skip])
	   (if (null? ports)
	       eof
	       (let ([n (peek-bytes-avail!* str skip unless-evt (car ports))])
		 (cond
		  [(eq? n 0) 
		   ;; Not ready, yet.
		   (car ports)]
		  [(eof-object? n)
		   ;; Port is exhausted, or we skipped past its input.
		   ;; If skip is not zero, we need to figure out
		   ;;  how many chars were skipped.
		   (loop (cdr ports)
			 (- skip (compute-avail-to-skip skip (car ports))))]
		  [else n])))))
       (lambda ()
	 (when close-orig?
	   (map close-input-port ports))))))

  (define (convert-stream from from-port
			  to to-port)
    (let ([c (bytes-open-converter from to)]
	  [in (make-bytes 4096)]
	  [out (make-bytes 4096)])
      (unless c
	(error 'convert-stream "could not create converter from ~e to ~e"
	       from to))
      (dynamic-wind
	  void
	  (lambda ()
	    (let loop ([got 0])
	      (let ([n (read-bytes-avail! in from-port got)])
		(let ([got (+ got (if (eof-object? n)
				      0
				      n))])
		  (let-values ([(wrote used status) (bytes-convert c in 0 got out)])
		    (when (eq? status 'error)
		      (error 'convert-stream "conversion error"))
		    (unless (zero? wrote)
		      (write-bytes out to-port 0 wrote))
		    (bytes-copy! in 0 in used got)
		    (if (eof-object? n)
			(begin
			  (unless (= got used)
			    (error 'convert-stream "input stream ended with a partial conversion"))
			  (let-values ([(wrote status) (bytes-convert-end c out)])
			    (when (eq? status 'error)
			      (error 'convert-stream "conversion-end error"))
			    (unless (zero? wrote)
			      (write-bytes out to-port 0 wrote))
			    ;; Success
			    (void)))
			(loop (- got used))))))))
	  (lambda () (bytes-close-converter c)))))

  ;; Helper for input-port-append; given a skip count
  ;;  and an input port, determine how many characters
  ;;  (up to upto) are left in the port. We figure this
  ;;  out using binary search.
  (define (compute-avail-to-skip upto p)
    (let ([str (make-bytes 1)])
      (let loop ([upto upto][skip 0])
	(if (zero? upto)
	    skip
	    (let* ([half (quotient upto 2)]
		   [n (peek-bytes-avail!* str (+ skip half) #f p)])
	      (if (eq? n 1)
		  (loop (- upto half 1) (+ skip half 1))
		  (loop half skip)))))))

  (define make-limited-input-port
    (opt-lambda (port limit [close-orig? #t])
      (let ([got 0])
	(make-input-port
	 (object-name port)
	 (lambda (str)
	   (let ([count (min (- limit got) (bytes-length str))])
	     (if (zero? count)
		 eof
		 (let ([n (read-bytes-avail!* str port 0 count)])
		   (cond
		    [(eq? n 0) port]
		    [(number? n) (set! got (+ got n)) n]
		    [else n])))))
	 (lambda (str skip)
	   (let ([count (max 0 (min (- limit got skip) (bytes-length str)))])
	     (if (zero? count)
		 eof
		 (let ([n (peek-bytes-avail!* str skip #f port 0 count)])
		   (if (eq? n 0)
		       port
		       n)))))
	 (lambda ()
	   (when close-orig?
	     (close-input-port port))))))))