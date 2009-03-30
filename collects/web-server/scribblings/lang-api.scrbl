#lang scribble/doc
@(require "web-server.ss")

@title[#:tag "stateless"]{Stateless Servlets}

@defmodulelang[web-server]

A stateless servlet should @scheme[provide] the following exports:

@(require (for-label web-server/http
                     scheme/serialize
                     web-server/stuffers
                     (except-in "dummy-stateless-servlet.ss" stuffer))) @; to give a binding context
@declare-exporting[#:use-sources (web-server/scribblings/dummy-stateless-servlet)]

@defthing[interface-version (one-of/c 'stateless)]{
 This indicates that the servlet is a stateless servlet.
}

@defthing[stuffer (stuffer/c serializable? bytes?)]{
 This is the @scheme[stuffer] that will be used for the servlet.
      
 If it is not provided, it defaults to @scheme[default-stuffer].
}

@defproc[(start [initial-request request?])
         response/c]{
 This function is called when an instance of this servlet is started.
 The argument is the HTTP request that initiated the instance.
}

An example @scheme['stateless] servlet module:
@schememod[
 web-server
 (define interface-version 'stateless)
 (define stuffer
  (stuffer-chain
   serialize-stuffer
   (md5-stuffer (build-path (find-system-path 'home-dir) ".urls"))))
 (define (start req)
   `(html (body (h2 "Look ma, no state!"))))
]


These servlets have an extensive API available to them: @schememodname[net/url], @schememodname[web-server/http],
@schememodname[web-server/lang/abort-resume], @schememodname[web-server/lang/web], @schememodname[web-server/lang/web-param],
@schememodname[web-server/lang/web-cells], @schememodname[web-server/lang/file-box], @schememodname[web-server/dispatch], and
@schememodname[web-server/stuffers].
      Some of these are documented in the subsections that follow.

@include-section["lang.scrbl"]
@include-section["lang-web-cells.scrbl"]
@include-section["file-box.scrbl"]
@include-section["web-param.scrbl"]
@include-section["stuffers.scrbl"]
@include-section["stateless-usage.scrbl"]