#lang scribble/manual

@(require (for-label racket/base))

@title{Scripty: Distributable shell scripts with dependencies}
@author{@author+email["Alexis King" "lexi.lambda@gmail.com"]}

@defmodule[scripty #:lang]

The @racketmodname[scripty] language is a tool for developing self-installing shell scripts. Every
Scripty script is composed of two parts: a @tech{script preamble}, which describes metadata about the
script, such as its dependencies, and a @tech{script body}, which is the runnable body of the script.
The body can be written in any Racket language, and it is not coupled to @racketmodname[scripty]’s
reader syntax.

@section[#:tag "usage"]{Using Scripty}

Making a script with Scripty is not complicated, since the bulk of any Scripty script is just an
ordinary Racket module. Since Racket treats lines starting with @litchar{#!} as comments, it’s quite
easy to turn any module into a runnable Unix script. Here’s a simple example:

@filebox["hello.rkt"]{
  @codeblock{
    #!/usr/bin/env racket
    #lang racket/base

    (displayln "Hello, world!")}}

Now it’s possible to run the above file as a Unix executable:

@commandline{$ chmod +x hello.rkt}
@commandline{$ ./hello.rkt}
@commandline{Hello, world!}

This is great, but unfortunately, this approach won’t work so well if your script depends on some
libraries a user doesn’t have. That’s where @racketmodname[scripty] comes in.

To convert any Racket module into a Scripty-managed script, add @hash-lang[] @racketmodname[scripty]
to the top, followed by a @deftech{script preamble}:

@filebox["parse.rkt"]{
  @codeblock{
    #!/usr/bin/env racket
    #lang scripty                              ; \ script preamble
    #:dependencies '("base" "megaparsack-lib") ; /
    ------------------------------------------
    #lang racket/base

    (require megaparsack)}}

The preamble contains metadata about the script, such as its dependencies, as demonstrated by the
above example, and it must be separated from the rest of the module by a line composed exclusively of
at least 3 @litchar{-} characters.

The script preamble is followed by an ordinary Racket module, which forms the @deftech{script body},
and usually begins with a second @hash-lang[] line. When the script is run from the command line, the
script body will be run after dependencies have been installed.

When a user runs a Scripty script, but they don’t have all of the required dependencies already
installed, they will be interactively prompted to ask if they would like to install them. If they
agree, then the packages will be installed, and the script will be run. Otherwise, the script will
terminate. If all packages are already installed, the script will run as usual.

Packages installed by scripty are marked as “auto-installed”, so running
@elem[#:style 'tt]{@literal{raco pkg remove --auto}} will remove them if they are not depended upon by
other packages. If packages that a script depends on are uninstalled, then the user will simply be
prompted to reinstall them the next time they run the script.

@section[#:tag "options"]{Script Options}

Currently, the only option supported by the @tech{script preamble} is @racket[#:dependencies].

@racketgrammar[script-preamble (code:line #:dependencies deps-expr)]

The @racket[_deps-expr] form is evaluated at phase one, and it should produce a list of package
dependencies in the same format as the @racket[deps] key of @hash-lang[] @racketmodname[info].
