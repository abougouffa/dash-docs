# Dash Docs

## What's it

This package provides an elisp interface to query and show documenation using
[Dash](http://www.kapeli.com/dash) docsets.

It doesn't require Dash app.

This package is a fork of
[dash-docs-el/dash-docs](https://github.com/dash-docs-el/dash-docs). It provide
a cleaner and updated implementation.

## Requirements

- Emacs 29.1+ built with SQLite support

## Installation

```elisp
;; Using builtin `package-vc`
(package-vc-install "https://github.com/abougouffa/dash-docs")


;; Using `straight`
(use-package dash-docs
  :straight (:host github :repo "abougouffa/dash-docs"))
```

## Installing docsets

`dash-docs` uses the same docsets as [Dash](http://www.kapeli.com/dash). You can
install them with `m-x dash-docs-install-docset` for the official docsets or
`m-x dash-docs-install-extra-docset` for user contributed, automatically
generated and cheat sheets docsets from
[https://zealusercontributions.vercel.app](https://zealusercontributions.vercel.app).

To install a docset from a file in your drive you can use `m-x
dash-docs-install-docset-from-file`. That function takes as input a `tgz` file
that you obtained, starting from a folder named `<docset name>.docset`, with the
command:

`tar --exclude='.DS_Store' -cvzf <docset name>.tgz <docset name>.docset`

As explained [here](https://kapeli.com/docsets#dashdocsetfeed).

## Usage

Search all currently enabled docsets (docsets in `dash-docs-docsets` or
`dash-docs-common-docsets`):

    (dash-docs-search "<pattern>")

Search a specific docset:

    (dash-docs-search-docset "<docset>" "<pattern>")

The command `dash-docs-reset-connections` will clear the connections
to all sqlite db's. Use it in case of errors when adding new docsets.
The next call to a search function will recreate them.

## Variables to customize

`dash-docs-docsets-path` is the prefix for your docsets. Defaults to ~/.docsets

`dash-docs-min-length` tells dash-docs from which length to start
searching. Defaults to 3.

`dash-docs-browser-function` is a function to encapsulate the way to browse
Dash' docsets. Defaults to `browse-url`. For example, if you want to use `eww`
to browse your docsets, you can do:

```elisp
(setq dash-docs-browser-function 'eww-browse-url)
```

## Sets of Docsets

### Common docsets

`dash-docs-common-docsets` is a list that should contain the docsets to be
active always. In all buffers.

### Buffer local docsets

Different subsets of docsets can be activated depending on the buffer. For the
moment (it may change in the future) we decided it's a plain local variable you
should setup for every different filetype. This way you can also do fancier
things like project-wise docsets sets.

``` elisp
(defun go-doc ()
  (interactive)
  (setq-local dash-docs-docsets '("Go")))

(add-hook 'go-mode-hook 'go-doc)
```

Or you can enable some docsets in the current buffer interactively using `M-x
dash-docs-activate-docset-for-buffer`.

### Only one docset

To narrow the search to just one docset, type its name in the beginning of the
search followed by a space. If the docset contains spaces, no problemo, we
handle it :D.

### use-package integration

If you use `use-package`, a `:dash` keyboard will be added to configure the
`dash-docs-docsets` variable. For example to register the CMake Dash
documentation with `cmake-mode`:

``` elisp
(use-package cmake-mode
  :dash "CMake")
```

You can also register multiple docsets:
``` elisp
(use-package cmake-mode
  :dash "CMake" "Foobar")
```

By default, `dash-docs` will link the docset to the package name mode hook, you
can explicitly set the mode if it is different from the package name:

``` elisp
(use-package my-package
  :dash (my-mode "Docset1" "Docset2"))
```

And you can register to multiple modes:

``` elisp
(use-package my-package
  :dash (my-mode "Docset1" "Docset2")
        (my-other-mode "Docset3"))
```

The way it works is by registering a hook to the given mode (`<mode-name>-hook`)
and setting up `dash-docs-docsets` local variable in that hook.

## Authors

- Toni Reina <areina0@gmail.com>
- Raimon Grau <raimonster@gmail.com>
- Abdelhak Bougouffa
