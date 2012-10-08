(in-package :cl-async)

(define-condition tcp-info (connection-info)
  ((socket :initarg :socket :accessor tcp-socket :initform nil))
  (:documentation "Base TCP condition. Holds the socket object."))

(define-condition tcp-error (connection-error tcp-info) ()
  (:report (lambda (c s) (format s "TCP connection error: ~a: ~a" (conn-errcode c) (conn-errmsg c))))
  (:documentation "Describes a general TCP connection error."))

(define-condition tcp-eof (tcp-info) ()
  (:report (lambda (c s) (format s "TCP connection EOF: ~a" (tcp-socket c))))
  (:documentation "Passed to an event callback when a peer closes a TCP connection."))

(define-condition tcp-timeout (tcp-error) ()
  (:report (lambda (c s) (format s "TCP connection timeout: ~a: ~a" (conn-errcode c) (conn-errmsg c))))
  (:documentation "Passed to an event callback when a TCP connection times out."))

(define-condition tcp-refused (tcp-error) ()
  (:report (lambda (c s) (format s "TCP connection refused: ~a: ~a" (conn-errcode c) (conn-errmsg c))))
  (:documentation "Passed to an event callback when a TCP connection is refused."))

(define-condition socket-closed (tcp-error) ()
  (:report (lambda (c s) (format s "Closed TCP socket being operated on: ~a." (tcp-socket c))))
  (:documentation "Thrown when a closed socket is being operated on."))

(defclass socket ()
  ((c :accessor socket-c :initarg :c :initform (cffi:null-pointer))
   (closed :accessor socket-closed :initarg :closed :initform nil)
   (direction :accessor socket-direction :initarg :direction :initform nil))
  (:documentation "Wraps around a libevent bufferevent socket."))

(defclass tcp-server ()
  ((c :accessor tcp-server-c :initarg :c :initform (cffi:null-pointer))
   (closed :accessor tcp-server-closed :initarg :closed :initform nil))
  (:documentation "Wraps around a libevent connection listener."))

(defun get-last-tcp-err ()
  "Since libevent provides a macro but not a function for getting the last error
   code, we have to essentially rebuild that macro here.

   NOTE: As libevent says, this function cannot be considered idempotent. In
   other words, calling it more than once may result in different values
   returned. So, call once and save the result until the next time an error
   happens."
  #+(or :windows :win32 :win64)
    (let ((code (cffi:foreign-funcall "WSAGetLastError" :int)))
      (values code
              (cffi:foreign-funcall "evutil_socket_error_to_string" :int code :string)))
  #-(or :windows :win32 :win64)
    (let ((code (cffi:mem-aref (cffi:foreign-symbol-pointer "errno") :int)))
      (values code
              (cffi:foreign-funcall "strerror" :int code :string))))

(defun check-socket-open (socket)
  "Throw a socket-closed condition if given a socket that's closed."
  (when (subtypep (type-of socket) 'socket)
    (when (socket-closed socket)
      (error 'socket-closed :code -1 :msg "Trying to operate on a closed socket"))))

(defun close-socket (socket)
  "Free a socket (bufferevent) and clear out all associated data."
  ;; grab the data pointer associated with the bufferevent and free it. see
  ;; comment tcp-send about data-pointer for a better explanation.
  (check-socket-open socket)
  (let* ((bev (socket-c socket))
         (bev-data (deref-data-from-pointer bev))
         (bev-data-pointer (getf bev-data :data-pointer)))
    (le:bufferevent-disable bev (logior le:+ev-read+ le:+ev-write+))
    (if (eq (socket-direction socket) 'in)
        (decf *incoming-connection-count*)
        (decf *outgoing-connection-count*))
    (le:bufferevent-free bev)
    (setf (socket-closed socket) t)
    (free-pointer-data bev-data-pointer)
    (free-pointer-data bev :preserve-pointer t)))

(defun close-tcp-server (tcp-server)
  "Closes a TCP server. If already closed, does nothing."
  (unless (tcp-server-closed tcp-server)
    (le:evconnlistener-free (tcp-server-c tcp-server))
    (setf (tcp-server-closed tcp-server) t)))

(defun set-socket-timeouts (socket read-sec write-sec &key socket-is-bufferevent)
  "Given a pointer to a libevent socket (bufferevent), set the read/write
   timeouts on the bufferevent."
  (check-socket-open socket)
  (let ((socket (if socket-is-bufferevent
                    socket
                    (socket-c socket))))
    (multiple-value-bind (read-sec read-usec) (split-usec-time read-sec)
      (multiple-value-bind (write-sec write-usec) (split-usec-time write-sec)
        (make-foreign-type (read-to (le::cffi-type le::timeval))
                           (('le::tv-sec read-sec)
                            ('le::tv-usec read-usec))
          (make-foreign-type (write-to (le::cffi-type le::timeval))
                             (('le::tv-sec write-sec)
                              ('le::tv-usec write-usec))
            (let ((read-to (if (numberp read-sec) read-to (cffi:null-pointer)))
                  (write-to (if (numberp write-sec) write-to (cffi:null-pointer))))
            (le:bufferevent-set-timeouts socket read-to write-to))))))))

(defun enable-socket (socket &key read write)
  "Enable read/write monitoring on a socket. If :read or :write are nil, they
   are not disabled, but rather just not enabled."
  (check-socket-open socket)
  (let ((bev (socket-c socket)))
    (le:bufferevent-enable bev (logior (if read le:+ev-read+ 0)
                                       (if write le:+ev-write+ 0)))))

(defun disable-socket (socket &key read write)
  "Disable read/write monitoring on a socket. If :read or :write are nil, they
   are not enabled, but rather just not disabled."
  (check-socket-open socket)
  (let ((bev (socket-c socket)))
    (le:bufferevent-disable bev (logior (if read le:+ev-read+ 0)
                                        (if write le:+ev-write+ 0)))))

(defun read-socket-data (socket data-cb &key socket-is-evbuffer)
  "Read the data out of a bufferevent (or directly, an evbuffer)."
  (check-socket-open socket)
  (let ((bufsize *buffer-size*)
        (buffer-c *socket-buffer-c*)
        (buffer-lisp *socket-buffer-lisp*)
        (input (if socket-is-evbuffer
                   socket
                   (le:bufferevent-get-input (socket-c socket)))))
    (loop for n = (le:evbuffer-remove input buffer-c bufsize)
          while (< 0 n) do
      (dotimes (i n)
        (setf (aref buffer-lisp i) (cffi:mem-aref buffer-c :char i)))
      (funcall data-cb (subseq buffer-lisp 0 n)))))

(defun write-to-evbuffer (evbuffer data)
  "Writes data directly to evbuffer."
  (let* ((data (if (stringp data)
                   (babel:string-to-octets data :encoding :utf-8)
                   data))
         (data-length (length data))
         (data-index 0)
         (buffer-c *socket-buffer-c*))
    ;; copy into evbuffer using existing c buffer
    (loop while (< 0 data-length) do
      (let ((bufsize (min data-length *buffer-size*)))
      (dotimes (i bufsize)
        (setf (cffi:mem-aref buffer-c :unsigned-char i) (aref data data-index))
        (incf data-index))
      (le:evbuffer-add evbuffer buffer-c bufsize)
      (decf data-length bufsize)))))

(defun write-socket-data (socket data &key read-cb write-cb event-cb)
  "Write data into a cl-async socket. Allows specifying read/write/event
   callbacks. Any callback left nil will use that current callback from the
   socket (so they only override when specified, otherwise keep the current
   callback)"
  (check-socket-open socket)

  ;; if a write-cb was passed, set it into the socket's callbacks
  (let* ((bev (socket-c socket))
         ;; since this gets called in multiple places, wrap it in a function
         (do-send (lambda ()
                    ;; enable the bufferevent (callbacks and timeouts)
                    (le:bufferevent-enable bev (logior le:+ev-read+ le:+ev-write+))
                    ;; write our data to the sockets buffer
                    (write-to-evbuffer (le:bufferevent-get-output bev) data))))

    (if (or read-cb write-cb event-cb)
        ;; we're specifying callbacks. since we're most likely calling this from
        ;; inside a socket callback and we don't necessarily want to overwrite
        ;; that socket's callbacks until it finishes, we set a delay here so the
        ;; callback binding happens after the caller returns to the event loop.
        (as:delay
          (lambda ()
            (let* ((bev-data (deref-data-from-pointer bev))
                   (socket-data-pointer (getf bev-data :data-pointer))
                   (callbacks (get-callbacks socket-data-pointer))
                   (read-cb-current (getf callbacks :read-cb))
                   (write-cb-current (getf callbacks :write-cb))
                   (event-cb-current (getf callbacks :event-cb)))
              (save-callbacks socket-data-pointer
                              (list :read-cb (if (functionp read-cb) read-cb read-cb-current)
                                    :write-cb (if (functionp write-cb) write-cb write-cb-current)
                                    :event-cb (if (functionp event-cb) event-cb event-cb-current))))
            (funcall do-send)))

        ;; we're not setting callbacks, so just enable the socket and send the
        ;; data
        (funcall do-send))))

(defun drain-evbuffer (evbuffer)
  "Grab all data in an evbuffer and put it into a byte array (returned)."
  (let ((body nil))
    (read-socket-data evbuffer
                      (lambda (data)
                        (if body
                            (setf body (append-array body data))
                            data))
                      :socket-is-evbuffer t)
    body))

(cffi:defcallback tcp-read-cb :void ((bev :pointer) (data-pointer :pointer))
  "Called whenever a read event happens on a TCP socket. Ties into the anonymous
   callback system to run user-specified anonymous callbacks on read events."
  (let* ((bev-data (deref-data-from-pointer bev))
         (socket (getf bev-data :socket))
         (callbacks (get-callbacks data-pointer))
         (read-cb (getf callbacks :read-cb))
         (event-cb (getf callbacks :event-cb)))
    (catch-app-errors event-cb
      (if read-cb
          ;; we have a callback, so grab the data form the socket and send it in
          (read-socket-data socket (lambda (data) (funcall read-cb socket data)))
          ;; no callback associated, so just drain the buffer so it doesn't pile up
          (le:evbuffer-drain (le:bufferevent-get-input bev) *buffer-size*)))))

(cffi:defcallback tcp-write-cb :void ((bev :pointer) (data-pointer :pointer))
  "Called when data is finished being written to a socket."
  (let* ((socket (getf (deref-data-from-pointer bev) :socket))
         (callbacks (get-callbacks data-pointer))
         (write-cb (getf callbacks :write-cb))
         (event-cb (getf callbacks :event-cb)))
    (catch-app-errors event-cb
      (when write-cb
        (funcall write-cb socket)))))

(cffi:defcallback tcp-event-cb :void ((bev :pointer) (events :short) (data-pointer :pointer))
  "Called whenever anything happens on a TCP socket. Ties into the anonymous
   callback system to track failures/disconnects."
  (let* ((event nil)
         (bev-data (deref-data-from-pointer bev))
         (socket (getf bev-data :socket))
         (event-cb (getf (get-callbacks data-pointer) :event-cb)))
    (catch-app-errors event-cb
      (unwind-protect
        (cond
          ((< 0 (logand events (logior le:+bev-event-error+
                                       le:+bev-event-timeout+)))
           (multiple-value-bind (errcode errstr) (get-last-tcp-err)
             (let ((dns-err (le:bufferevent-socket-get-dns-error bev)))
               (cond
                 ;; DNS error
                 ((and (< 0 (logand events le:+bev-event-error+))
                       (not (zerop dns-err)))
                  (setf event (make-instance 'dns-error
                                             :code dns-err
                                             :msg (le:evutil-gai-strerror dns-err))))

                 ;; socket timeout
                 ((< 0 (logand events le:+bev-event-timeout+))
                  (setf event (make-instance 'tcp-timeout :socket socket :code -1 :msg "Socket timed out")))

                 ;; since we don't know what the error was, just spawn a general
                 ;; error.
                 (t
                  (setf event (make-instance 'tcp-error :socket socket :code errcode :msg errstr)))))))
          ;; peer closed connection.
          ((< 0 (logand events le:+bev-event-eof+))
           (setf event (make-instance 'tcp-eof :socket socket)))
          ((< 0 (logand events le:+bev-event-connected+))
           (release-dns-base)))
        (when event
          (unwind-protect
            (when event-cb (funcall event-cb event))
            ;; if the app closed the socket in the event cb (perfectly fine),
            ;; make sure we don't trigger an error trying to close it again.
            (handler-case (close-socket socket)
              (socket-closed () nil))))))))

(cffi:defcallback tcp-accept-cb :void ((listener :pointer) (fd :int) (addr :pointer) (socklen :int) (data-pointer :pointer))
  "Called when a connection is accepted. Creates a bufferevent for the socket
   and sets up the callbacks onto that socket."
  (declare (ignore socklen addr))
  (let* ((per-conn-data-pointer (create-data-pointer))
         (event-base (le:evconnlistener-get-base listener))
         (bev (le:bufferevent-socket-new event-base
                                         fd
                                         +bev-opt-close-on-free+))
         (socket (make-instance 'socket :c bev :direction 'in))
         (callbacks (get-callbacks data-pointer))
         (event-cb (getf callbacks :event-cb)))
    (catch-app-errors event-cb
      ;; attach our data-pointer/socket class to the bev
      (attach-data-to-pointer bev (list :data-pointer per-conn-data-pointer :socket socket))

      ;; track the connection. will be decf'ed when close-socket is called
      (incf *incoming-connection-count*)

      ;; save the callbacks given to the listener onto each socket individually
      (save-callbacks per-conn-data-pointer callbacks)
      (le:bufferevent-setcb bev
                            (cffi:callback tcp-read-cb)
                            (cffi:callback tcp-write-cb)
                            (cffi:callback tcp-event-cb)
                            per-conn-data-pointer)
      ;(set-socket-timeouts bev 5 5 :socket-is-bufferevent t)
      (le:bufferevent-enable bev (logior le:+ev-read+ le:+ev-write+)))))

(cffi:defcallback tcp-accept-err-cb :void ((listener :pointer) (ctx :pointer))
  "Called when an error occurs accepting a connection."
  (declare (ignore ctx))
  (let* ((event-base (le:evconnlistener-get-base listener)))
    ;; TODO: why does the error handler segfault?!?!?
    (format t "There was an error and I don't know how to get the code.~%")
    (le:event-base-loopexit event-base (cffi:null-pointer))))

(defun tcp-send (host port data read-cb event-cb &key write-cb (read-timeout 30) (write-timeout 30))
  "Open a TCP connection asynchronously. An event loop must be running for this
   to work."
  (check-event-loop-running)

  ;; this may get nasty...create a reference where data-pointer points to the
  ;; callbacks and dns-base for the current bufferevent, and the current
  ;; bufferevent has a reference to the current data-pointer. this is so that
  ;; when a bufferevent is re-used with new callbacks, the original data-pointer
  ;; isn't lost (since this would essentially be a memory leak, and cause a lot
  ;; of callbacks/dns-bases to be un-garbage-collectable...disaster). this way
  ;; is messy, but ensures that the bufferevent has only one data-pointer
  ;; attached to it for the duration of its life.
  (let* ((data-pointer (create-data-pointer))
         (bev (le:bufferevent-socket-new *event-base* -1 +bev-opt-close-on-free+))
         (socket (make-instance 'socket :c bev :direction 'out)))
    (le:bufferevent-setcb bev (cffi:callback tcp-read-cb) (cffi:callback tcp-write-cb) (cffi:callback tcp-event-cb) data-pointer)
    (le:bufferevent-enable bev (logior le:+ev-read+ le:+ev-write+))
    (save-callbacks data-pointer (list :read-cb read-cb :event-cb event-cb :write-cb write-cb))
    (write-to-evbuffer (le:bufferevent-get-output bev) data)
    (set-socket-timeouts bev read-timeout write-timeout :socket-is-bufferevent t)
    (attach-data-to-pointer bev (list :data-pointer data-pointer :socket socket))

    ;; connect the socket
    (incf *outgoing-connection-count*)
    (if (ip-address-p host)
        ;; got an IP so just connect directly
        (with-ipv4-to-sockaddr (sockaddr host port)
          (le:bufferevent-socket-connect bev sockaddr +sockaddr-size+))

        ;; get a DNS base and do an async lookup
        (let ((dns-base (get-dns-base)))
          (attach-data-to-pointer data-pointer dns-base)
          (le:bufferevent-socket-connect-hostname bev dns-base le:+af-unspec+ host port)))))

(defun tcp-server (bind-address port read-cb event-cb &key (backlog -1))
  "Start a TCP listener on the current event loop. Returns a tcp-server class
   which can be closed with close-tcp-server"
  (check-event-loop-running)
  (with-ipv4-to-sockaddr (sockaddr bind-address port)
    (let* ((data-pointer (create-data-pointer))
           (listener (le:evconnlistener-new-bind *event-base*
                                                  (cffi:callback tcp-accept-cb)
                                                  data-pointer
                                                  (logior le:+lev-opt-reuseable+ le:+lev-opt-close-on-free+)
                                                  backlog
                                                  sockaddr
                                                  +sockaddr-size+))
           (server-class (make-instance 'tcp-server :c listener)))
      (add-event-loop-exit-callback (lambda ()
                                      (close-tcp-server server-class)
                                      (free-pointer-data data-pointer)))
      (when (and (not (cffi:pointerp listener)) (zerop listener))
        (error "Couldn't create listener: ~a~%" listener))
      ;; NOTE: this segfaults for wahtever reason...
      ;(le:evconnlistener-set-error-cb listener (cffi:callback tcp-accept-err-cb))
      (save-callbacks data-pointer (list :read-cb read-cb :event-cb event-cb))
      ;; return the listener, which can be closed by the app if needed
      server-class)))

