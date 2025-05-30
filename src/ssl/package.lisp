(defpackage :cl-async-ssl
  (:use :cl :cl-async-base :cl-async :cl-async-util)
  (:nicknames :as-ssl)
  (:shadow cl-async-util:exit-event-loop)
  (:export #:+ssl-op-all+
           #:+ssl-op-no-query-mtu+
           #:+ssl-op-cookie-exchange+
           #:+ssl-op-no-ticket+
           #:+ssl-op-cisco-anyconnect+
           #:+ssl-op-no-session-resumption-on-renegotiation+
           #:+ssl-op-no-compression+
           #:+ssl-op-allow-unsafe-legacy-renegotiation+
           #:+ssl-op-single-ecdh-use+
           #:+ssl-op-single-dh-use+
           #:+ssl-op-ephemeral-rsa+
           #:+ssl-op-cipher-server-preference+
           #:+ssl-op-tls-rollback-bug+
           #:+ssl-op-no-sslv2+
           #:+ssl-op-no-sslv3+
           #:+ssl-op-no-tlsv1+
           #:+ssl-op-no-tlsv1-2+
           #:+ssl-op-no-tlsv1-1+

           #:+ssl-verify-none+
           #:+ssl-verify-peer+
           #:+ssl-verify-fail-if-no-peer-cert+
           #:+ssl-verify-client-once+

           #:ssl-socket
           #:tcp-ssl-error
           #:tcp-ssl-connect
           #:tcp-ssl-server)
  (:import-from :cl-async
                #:*output-buffer*
                #:*input-buffer*
                #:event-handler
                #:socket-connected
                #:socket-buffer
                #:socket-buffering-p
                #:socket-direction
                #:check-socket-open
                #:check-event-loop-running
                #:socket-drain-read-buffer
                #:write-to-uvstream
                #:write-socket-data
                #:write-pending-socket-data
                #:init-incoming-socket
                #:stream-append-bytes))
(in-package :cl-async-ssl)

;; NOTE: the loading code is verbatim from cl+ssl

(eval-when (:compile-toplevel :load-toplevel)
  (cffi:define-foreign-library libcrypto
    (:openbsd "libcrypto.so")
    (:linux (:or "libcrypto.so.1.1"
              "libcrypto.so.1.0.2"
              "libcrypto.so"))
    (:windows (:or #+(and windows x86-64) "libcrypto-3-x64.dll"
                #+(and windows x86) "libcrypto-3.dll"
                #+(and windows x86-64) "libcrypto-1_1-x64.dll"
                #+(and windows x86) "libcrypto-1_1.dll"
                "libeay32.dll"))
    (:darwin (:or "/opt/local/lib/libcrypto.dylib" ;; MacPorts
               "/sw/lib/libcrypto.dylib"        ;; Fink
               "/usr/local/opt/openssl/lib/libcrypto.dylib" ;; Homebrew
               "/opt/homebrew/opt/openssl/lib/libcrypto.dylib" ;; Homebrew Arm64
               "/usr/local/lib/libcrypto.dylib" ;; personalized install
               ;; System-provided libraries. Must be loaded from files with
               ;; names that include version explicitly, instead of any
               ;; versionless symlink file. Otherwise macOS crushes the
               ;; process (starting from macOS > 10.15 that was just a
               ;; warning, and finally macOS >= 11 crashes the process with a
               ;; fatal error) Please note that in macOS >= 11.0, these paths
               ;; may not exist in the file system anymore, but trying to
               ;; load them via dlopen will work. This is because macOS ships
               ;; all system-provided libraries as a single dyld_shared_cache
               ;; bundle.
               "/usr/lib/libcrypto.46.dylib"
               "/usr/lib/libcrypto.44.dylib"
               "/usr/lib/libcrypto.42.dylib"
               "/usr/lib/libcrypto.41.dylib"
               "/usr/lib/libcrypto.35.dylib"

               ;; The default old system libcrypto, versionless file name,
               ;; which may have insufficient crypto and can cause process
               ;; crash on macOS >= 11. Currently we are protected from the
               ;; crash by the presence of the versioned paths above, but in
               ;; a few years, when those versions are not available anymore,
               ;; the crash may re-appear. So eventually we will need to
               ;; delete the unversioned paths. Keeping them for a while for
               ;; compatibility. See
               ;; https://github.com/cl-plus-ssl/cl-plus-ssl/pull/115
               "libcrypto.dylib"
               "/usr/lib/libcrypto.dylib"))
    ((and :unix (not :cygwin)) (:or "libcrypto.so.1.1"
                                 "libcrypto.so.1.0.0"
                                 "libcrypto.so.3"
                                 "libcrypto.so"))
    (:cygwin (:or "cygcrypto-1.1.dll" "cygcrypto-1.0.0.dll")))
  (cffi:use-foreign-library libcrypto)

  (cffi:define-foreign-library libssl
    (:windows (:or  #+(and windows x86-64) "libssl-3-x64.dll"
                #+(and windows x86) "libssl-3.dll"
                #+(and windows x86-64) "libssl-1_1-x64.dll"
                #+(and windows x86) "libssl-1_1.dll"
                "libssl32.dll"
                "ssleay32.dll"))
    ;; The default OS-X libssl seems have had insufficient crypto algos
    ;; (missing TLSv1_[1,2]_XXX methods,
    ;; see https://github.com/cl-plus-ssl/cl-plus-ssl/issues/56)
    ;; so first try to load possible custom installations of libssl
    (:darwin (:or "/opt/local/lib/libssl.dylib" ;; MacPorts
               "/sw/lib/libssl.dylib"        ;; Fink
               "/usr/local/opt/openssl/lib/libssl.dylib" ;; Homebrew
               "/opt/homebrew/opt/openssl/lib/libssl.dylib" ;; Homebrew Arm64
               "/usr/local/lib/libssl.dylib" ;; personalized install
               ;; System-provided libraries, with version in the file name.
               ;; See the comment for the libcryto equivalents above.
               "/usr/lib/libssl.48.dylib"
               "/usr/lib/libssl.46.dylib"
               "/usr/lib/libssl.44.dylib"
               "/usr/lib/libssl.43.dylib"
               "/usr/lib/libssl.35.dylib"
               ;; Default system libssl, versionless file name.
               ;; See the coment for the corresponding libcrypto.
               ;; default system libssl, which may have insufficient crypto
               "libssl.dylib"
               "/usr/lib/libssl.dylib"))
    (:solaris (:or "/lib/64/libssl.so"
                   "libssl.so.0.9.8" "libssl.so" "libssl.so.4"))
    ;; Unlike some other systems, OpenBSD linker,
    ;; when passed library name without versions at the end,
    ;; will locate the library with highest macro.minor version,
    ;; so we can just use just "libssl.so".
    ;; More info at https://github.com/cl-plus-ssl/cl-plus-ssl/pull/2.
    (:openbsd "libssl.so")
    ((and :unix (not :cygwin)) (:or "libssl.so.1.1"
                                    "libssl.so.1.0.2m"
                                    "libssl.so.1.0.2k"
                                    "libssl.so.1.0.2"
                                    "libssl.so.1.0.1l"
                                    "libssl.so.1.0.1j"
                                    "libssl.so.1.0.1f"
                                    "libssl.so.1.0.1e"
                                    "libssl.so.1.0.1"
                                    "libssl.so.1.0.0q"
                                    "libssl.so.1.0.0"
                                    "libssl.so.0.9.8ze"
                                    "libssl.so.0.9.8"
                                    "libssl.so.10"
                                    "libssl.so.4"
                                    "libssl.so"))
    (:cygwin (:or "cygssl-1.1.dll" "cygssl-1.0.0.dll"))
    (t (:default "libssl3")))

  (cffi:use-foreign-library libssl)

  (when (cffi:foreign-symbol-pointer "TLS_method")
    (pushnew ':tls-method *features*)))
