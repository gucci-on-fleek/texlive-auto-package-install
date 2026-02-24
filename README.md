<!-- network-install
     https://github.com/gucci-on-fleek/network-install
     SPDX-License-Identifier: MPL-2.0+ OR CC-BY-SA-4.0+
     SPDX-FileCopyrightText: 2026 Max Chernoff
-->

`network-install`
=================

A package that automatically installs missing TeX Live packages during
compilation.


Usage
-----

When compiling a LaTeX document, if any files are missing from your
TeX Live installation, this package will automatically download and
install them. To do so, make sure to put
`\RequirePackage{network-install}` as the very first line of your
document preamble. Make sure to compile with `--shell-escape`, otherwise
the package won't work.


Demonstration
-------------

After installing only `scheme-basic`, the following file compiles
without any errors:

```tex
\RequirePackage{auto-package-install}
\documentclass{article}

\usepackage{amsmath}

\usepackage{lua-widow-control}

\usepackage{fontspec}
\setmainfont{NewCM10-Regular.otf}

\begin{document}
     Hello, world!
\end{document}
```

Platform Support
----------------

The following platforms are supported and have been extensively tested:

- `x86_64-linux`

The following platforms are supported and have been partially tested:

- `windows`

The following platforms are supported, but are completely untested:

- `aarch64-linux`
- `armhf-linux`
- `i386-linux`
- `universal-darwin`
- `x86_64-darwinlegacy`

The following platforms _might_ be supported, but might not work at all:

- `amd64-freebsd`
- `amd64-netbsd`
- `i386-freebsd`
- `i386-netbsd`
- `x86_64-linuxmusl`

`libcurl` binaries are provided for Windows; users on all other
platforms will need to supply them themselves.

Licence
-------

`network-install` is licensed under the [_Mozilla Public
License_, version 2.0](https://www.mozilla.org/en-US/MPL/2.0/) or
greater. The documentation is additionally licensed under [CC-BY-SA,
version 4.0](https://creativecommons.org/licenses/by-sa/4.0/legalcode)
or greater.

---
_v0.2.2 (2026-02-24)_ <!--%%version %%dashdate-->
