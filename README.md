<!-- texlive-auto-package-install
     https://github.com/gucci-on-fleek/texlive-auto-package-install
     SPDX-License-Identifier: MPL-2.0+ OR CC-BY-SA-4.0+
     SPDX-FileCopyrightText: 2026 Max Chernoff
-->

`texlive-auto-package-install`
==============================

A script that automatically installs missing TeX Live packages during
compilation.


Usage
-----

When compiling a LaTeX document, if any files are missing from your
TeX Live installation, this package will automatically download and
install them. To do so, make sure to put
`\RequirePackage{auto-package-install}` as the very first line of your
document preamble.


Licence
-------

`texlive-auto-package-install` is licensed under the [_Mozilla Public
License_, version 2.0](https://www.mozilla.org/en-US/MPL/2.0/) or
greater. The documentation is additionally licensed under [CC-BY-SA,
version 4.0](https://creativecommons.org/licenses/by-sa/4.0/legalcode)
or greater.

---
_v0.0.0 (2025-01-20)_ <!--%%version %%dashdate-->
