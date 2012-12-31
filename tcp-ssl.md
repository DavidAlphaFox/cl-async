---
title: SSL over TCP | Documentation
layout: documentation
---

SSL over TCP
============
Libevent's [bufferevents](http://www.wangafu.net/~nickm/libevent-book/Ref6a_advanced_bufferevents.html)
provide an easy way to wrap sockets in SSL. Cl-async provides a very simple
interface for setting this up.

Note that SSL in cl-async must be specifically loaded via the package
`cl-async-ssl`, otherwise it won't be available. This is because it must load a
separate library (`libevent_openssl`) which may not be available on the system
by default. `cl-async-ssl` depends on the `cl-libevent2-ssl` package, present in
the [latest versions of the libevent2 bindings](https://github.com/orthecreedence/cl-libevent2).

- [ssl-socket](#ssl-socket) _class_
- [tcp-ssl-connect](#tcp-ssl-connect) _function_
- [init-tcp-ssl-socket](#init-tcp-ssl-socket) _function_
- [tcp-ssl-error](#tcp-ssl-error) _condition_

<a id="ssl-socket"></a>
### ssl-socket
_extends [socket](/cl-async/tcp#socket)_

This class is much like the [socket](/cl-async/tcp#socket) class, except that it
houses a socket that has been wrapped in an SSL filter. It exposes no public
accessors, except for the ones it inherits from `socket`.

It can be passed to any cl-async function that takes a `socket` argument.

<a id="tcp-ssl-connect"></a>
### tcp-ssl-connect
{% highlight cl %}
(defun tcp-ssl-connect (host port read-cb event-cb
                        &key data stream ssl-ctx
                             connect-cb write-cb
                             (read-timeout -1) (write-timeout -1)
                             (dont-drain-read-buffer nil dont-drain-read-buffer-supplied-p)))
  => ssl-socket/stream
{% endhighlight %}

Much like [tcp-connect](/cl-async/tcp#tcp-connect), `tcp-connect-ssl` opens and
connects an async socket, but wrapped in the SSL protocol. In fact just about
every argument is the same for `tcp-connect` as it is for `tcp-connect-ssl`,
except `tcp-ssl-connect` takes an (optional) SSL context object in the keyword
`:ssl-ctx` parameter. This tells it to use the given context instead of the
global/generic context created by `cl+ssl` when initializing.

`tcp-ssl-connect` takes an (optional) `:ssl-ctx` argument which is a
generic/global SSL context object which is used to create the *client* context
used to initialize the socket. If a context is not specified, the global context
in the `cl+ssl` package will be used: `cl+ssl::*ssl-global-context*`. See the
[note on using the global context](#init-tcp-ssl-socket-context-note) if you
run into problems.

`tcp-ssl-connect` returns an [ssl-socket](#ssl-socket) object, which is an
extension of the [socket](/cl-async/tcp#socket) class, and can be used with all
the same functions/methods.

{% highlight cl %}
;; simple SSL socket example
(tcp-ssl-connect "www.google.com" 443
                 (lambda (socket data)
                   (declare (ignore socket))
                   (format t "GOT: ~a~%" (babel:octets-to-string data)))
                 (lambda (ev)
                   (format t "EV: ~a~%" ev))
                 :read-timeout 3
                 :data (format nil "GET /~c~c" #\return #\newline))
{% endhighlight %}

<a id="tcp-ssl-connect-read-cb"></a>
##### read-cb definition (default)

{% highlight cl %}
(lambda (socket byte-array) ...)
{% endhighlight %}

<a id="tcp-ssl-connect-read-cb-stream"></a>
##### read-cb definition (when tcp-ssl-connect's :stream is t)

{% highlight cl %}
(lambda (socket stream) ...)
{% endhighlight %}

Note that in this case, `stream` replaces the data byte array's position. Also,
when calling `:stream t` in `tcp-ssl-connect`, the read buffer for the socket is
not drained and is only done so by [reading from the stream](/cl-async/tcp-stream).

`stream` is always the same object returned from `tcp-ssl-connect` with
`:stream t`.  It wraps the [ssl-socket](#ssl-socket) object.

<a id="tcp-ssl-connect-connect-cb"></a>
##### connect-cb definition
{% highlight cl %}
(lambda (socket) ...)
{% endhighlight %}

The `connect-cb` will be fired when the connection from `tcp-ssl-connect` has been
established. Since sending data over the socket is somewhat transparent (either
via `:data` or [write-socket-data](#write-socket-data)), you don't really have
to know when a socket is ready to be written to. In some instances though, it
may be useful to know when the connection has been established, which is why
`:connect-cb` is exposed.

<a id="tcp-ssl-connect-write-cb"></a>
##### write-cb definition

{% highlight cl %}
(lambda (socket) ...)
{% endhighlight %}

The `write-cb` will be called after data written to the socket's buffer is
flushed out to the socket. If you want to send a command to a server and
immediately disconnect once you know the data was sent, you could close the
connection in your `write-cb`.


<a id="init-tcp-ssl-socket"></a>
### init-tcp-ssl-socket
{% highlight cl %}
(defun init-tcp-ssl-socket (read-cb event-cb
                            &key data stream ssl-ctx (fd -1)
                                 connect-cb write-cb
                                 (read-timeout -1) (write-timeout -1)
                                 (dont-drain-read-buffer nil dont-drain-read-buffer-supplied-p))
  => socket/stream
{% endhighlight %}

This function is much like [tcp-ssl-connect](#tcp-ssl-connect) but with a few
exceptions:

 1. It only *initializes* an [ssl-socket](#ssl-socket) object, it doesn't connect
 it.
 2. It doesn't accept host/port arguments.
 3. It accepts a `:fd` keyword argument, which allows wrapping the socket being
 initialized around an existing file descriptor.

In other words, `init-tcp-ssl-socket` is `tcp-ssl-connect`'s lower-level brother.
Once initialized, an unconnected socket can be connected using
[connect-tcp-socket](/cl-async/tcp#connect-tcp-socket).

Note that `init-tcp-ssl-socket` is almost the exact same as [init-tcp-socket](/cl-async/tcp#init-tcp-socket)
but it takes an `:ssl-ctx` argument which is a global SSL context used to
create the client context.

The socket returned by `init-tcp-ssl-socket` can be passed to
[connect-tcp-socket](/cl-async/tcp#connect-tcp-socket) if you want to directly
connect it.

<a id="init-tcp-ssl-socket-context-note"></a>
##### Context note
If `:ssl-ctx` is not supplied, `cl+ssl::*ssl-global-context*` is used to create
the client context. This is generally fine, however you can run into problems
using the global context when connecting the SSL socket to an SSL server that
already exists in the same process. In this case, you can do this:

{% highlight cl %}
(init-tcp-ssl-socket ... :ssl-ctx (cl+ssl::ssl-ctx-new (cl+ssl::ssl-v23-client-method)))
{% endhighlight %}


{% comment %}
<a id="wrap-in-ssl"></a>
### wrap-in-ssl
{% highlight cl %}
(defun wrap-in-ssl (socket/stream &key certificate key password
                                       (method 'cl+ssl::ssl-v23-client-method)
                                       close-cb))
  => socket/stream
{% endhighlight %}

_Note: `wrap-in-ssl` has only been testing with outgoing sockets, not servers.
There is more work to do before server SSL sockets are supported._

Wraps a socket or stream in SSL. The callbacks and timeouts on the original
socket/stream are reattached to the new SSL socket/stream, meaning you can
convert a non-SSL socket to SSL fairly simply. It's important to note that this
function does *not* replace the socket/stream passed to it, it returns a *new*
socket if a socket was passed in, and a *new* stream if a stream was passed in.

It's a bad idea to use the original socket/stream after wrapping it in SSL. Most
likely your writes will trigger SSL errors and your reads will be blank. So make
sure your app updates any references to the old socket/stream with the one
returned from `wrap-in-ssl`.

This function works by setting up an SSL filtering bufferevent that wraps the
one attached to the given socket/stream. Although this is handled transparently
by libevent, it still requires that an SSL context be set up, which
`wrap-in-ssl` uses [cl+ssl](http://common-lisp.net/project/cl-plus-ssl/) for.

The `close-cb` function passed in will be called when the SSL socket is closed.

{% highlight cl %}
;; example
(let\* ((socket (tcp-connect "www.google.com" 443
                            (lambda (sock data)
                              (declare (ignore sock))
                              (format t "GOT: ~a~%" (babel:octets-to-string data)))
                            (lambda (ev)
                              (format t "event: ~a~%" ev))
                            :read-timeout 3))
       ;; now wrap the normal socket in SSL, save the new socket
       (socket-ssl (wrap-in-ssl socket)))
  ;; send out the request on the SSL socket
  (write-socket-data socket-ssl (format nil "GET /~c~c" #\return #\newline)))
{% endhighlight %}

<a id="wrap-in-ssl-close-cb"></a>
##### close-cb definition
`close-cb` is a lambda with no arguments.
{% highlight cl %}
(lambda () ...)
{% endhighlight %}
{% endcomment %}

{% comment %}
<a id="tcp-ssl-server-class"></a>
### tcp-ssl-server (class)
_extends [tcp-server](/cl-async/tcp#tcp-server-class)_

This is an opaque class which is returned by the function [tcp-ssl-server](#tcp-server)
to allow [closing the server](/cl-async/tcp#close-tcp-server) and allowing for
future expansion of the server's abilities. It has no public accessors.

<a id="tcp-ssl-server"></a>
### tcp-ssl-server
{% highlight cl %}
(defun tcp-ssl-server (bind-address port read-cb event-cb
                       &key connect-cb (backlog -1) stream
                            certificate key password)
  => tcp-ssl-server
{% endhighlight %}

This function works by calling [tcp-server](/cl-async/tcp#tcp-server) to bind to
the given address/port. It then replaces the callback that is fired when a new
connection is accepted with one that wraps the incoming socket in the SSL
protocol. In other words, `tcp-ssl-server` functions almost exactly like
[tcp-server](/cl-async/tcp#tcp-server) except the connecting client must speak
SSL.

It takes `:certificate`, `:key`, and `:password` keyword arguments which are
used for loading a certificate and a (possibly passworded) private key. The
certificate file can be a chain file, so if you have a Certificate Authority
you want to use, you can just dump it in the same file (much like how [NginX
handles SSL](http://nginx.org/en/docs/http/configuring_https_servers.html#chains).

Like [tcp-server](/cl-async/tcp#tcp-server), `tcp-ssl-server` can be closed
gracefully by calling [close-tcp-server](/cl-async/tcp#close-tcp-server) on the
[tcp-ssl-server](/cl-async/tcp#tcp-server-class) object it returns.

{% highlight cl %}
;; example
(tcp-ssl-server "127.0.0.1" 443
                (lambda (socket data)
                  (format t "data: ~a~%" data)
                  (write-socket-data socket "THIS IS A SECURE LINE!"
                                     :write-cb (lambda (socket)
                                                 (close-socket socket))))
                (lambda (ev)
                  (format t "SSL ev: ~a~%" ev)))
{% endhighlight %}

<a id="tcp-ssl-server-read-cb"></a>
##### read-cb definition (default)

{% highlight cl %}
(lambda (socket byte-array) ...)
{% endhighlight %}

<a id="tcp-ssl-server-read-cb-stream"></a>
##### read-cb definition (when tcp-ssl-server is called with :stream t)

{% highlight cl %}
(lambda (socket stream) ...)
{% endhighlight %}

Note that in this case, `stream` replaces the data byte array's position. Also,
when calling `:stream t` in `tcp-stream`, the read buffer for the connecting
socket is not drained and is only done so by [reading from the stream](/cl-async/tcp-stream).

<a id="tcp-ssl-server-connect-cb"></a>
##### connect-cb definition

{% highlight cl %}
(lambda (socket) ...)
{% endhighlight %}

Called when a client connects (but not necessarily when it has sent data). If
present, is *always* called before the [read-cb](#tcp-ssl-server-read-cb).
{% endcomment %}

<a id="tcp-ssl-error"></a>
### tcp-ssl-error
_extends [tcp-error](/cl-async/tcp#tcp-error)_

Triggered when an error happens while communicating over an SSL socket.