#!/usr/bin/env python3
# texlive-auto-package-install
# https://github.com/gucci-on-fleek/texlive-auto-package-install
# SPDX-License-Identifier: MPL-2.0+
# SPDX-FileCopyrightText: 2026 Max Chernoff

"""Generate the filename database used by the network-install LaTeX package."""

###############
### Imports ###
###############

from argparse import ArgumentDefaultsHelpFormatter, ArgumentParser, Namespace
from gzip import decompress as gzip_decompress
from lzma import decompress as lzma_decompress
from pathlib import Path
from pprint import pp as pprint
from re import MULTILINE, VERBOSE, compile as re_compile
from sys import exit, stderr
from time import time
from typing import Literal, NamedTuple
from urllib.request import urlopen


########################
### Type Definitions ###
########################


class FileEntry(NamedTuple):
    """A file entry in the database."""

    filename: str
    """The name of the file, without any path components."""

    path: str
    """The path of the file, relative to the current root."""

    source: Literal["tlpdb", "ctan"]
    """The source of the file information: either "tlpdb" or "ctan"."""

    date: int | None
    """The date the file was last modified, as an integer like "YYYYMMDD", or
    None if the date is unknown."""

    revision: int | None
    """The SVN revision of the file, as an integer, or None if the revision is
    unknown."""


#################
### Constants ###
#################

__VERSION__ = "0.1.2"  # %%version
DEFAULT_MIRROR = "https://mirror.ctan.org"
FILES_PATH = "/FILES.byname.gz"
IGNORE_EXTENSIONS = {"pdf", "png", "jpg", "4ht"}
IGNORE_PREFIXES = {"lwarp"}
START_TIME = time()
TLPDB_PATH = "/systems/texlive/tlnet/tlpkg/texlive.tlpdb.xz"
TLPDB_REVISION_REGEX = re_compile(r"^revision (\d+)\s*$", MULTILINE)

TLPDB_FILE_REGEX = re_compile(
    r"""
        # Only match things that look like paths in $TEXMFDIST
        (texmf-dist | RELOC ) /

        (?P<path>
            # We only care about files in the $TEXMFDIST/tex/ directory, since
            # everything else should be included unpacked in the CTAN archive.
            tex/

            # The network-install package is LuaLaTeX-only, so we only care
            # about the following formats.
            (?: latex | generic | lualatex | luatex )/

            # Match the rest of the path
            \S*?

            # Match the filename
            / (?P<filename> [^ / \s ]+)
        )
    """,
    VERBOSE | MULTILINE,
)

CTAN_FILE_REGEX = re_compile(
    r"""
        # Match the beginning of the line
        ^

        # The date, in YYYY/MM/DD format
        (?P<date> \d{4} / \d{2} / \d{2} )
        \ \|\ # Column separator

        # The file size, in bytes
        \s* # Right-aligned
        (?P<size> \d+ )
        \ \|\ # Column separator

        # The file path, relative to the root of the CTAN archive
        (?P<path>
            \S+?

            # Just the filename, without any path components
            / (?P<filename> [^ / \s ]+ )
        )

        # Match the end of the line
        $
    """,
    VERBOSE | MULTILINE,
)


#########################################
### General-Purpose Utility Functions ###
#########################################


def msg(message: str) -> None:
    """Print a message to the console.

    Args:
        message: The message to print.
    """

    print(  # noqa: T201
        f"\x1b[0;36m[network-install {time() - START_TIME:7.3f}] {message}",
        file=stderr,
    )


def download_file(url: str) -> bytes:
    """Download a file from the given URL and return its contents as bytes.

    Args:
        url: The URL to download the file from.

    Returns:
        The contents of the file as bytes.
    """

    msg(f"Downloading {url}...")
    with urlopen(url) as response:
        data = response.read()
    msg(f"Finished downloading {url}.")
    return data


##################################
### Package-Specific Functions ###
##################################


def download_files(mirror_url: str) -> tuple[str, str]:
    """Download the files from the CTAN mirror.

    Args:
        mirror_url: The CTAN mirror to download from.

    Returns:
        A tuple containing the contents of the FILES.byname and texlive.tlpdb files as strings.
    """

    # Download the files
    files_byname_compressed = download_file(mirror_url + FILES_PATH)
    tlpdb_compressed = download_file(mirror_url + TLPDB_PATH)

    # Decompress the files
    files_byname = gzip_decompress(files_byname_compressed).decode("utf-8")
    tlpdb = lzma_decompress(tlpdb_compressed).decode("utf-8")

    return files_byname, tlpdb


def filelist_from_tlpdb(tlpdb: str) -> dict[str, list[FileEntry]]:
    """Extract the filelist from the tlpdb file.

    Args:
        tlpdb: The contents of the tlpdb file as a string.

    Returns:
        A dictionary mapping file names to their corresponding FileEntry
        objects.
    """

    files: dict[str, list[FileEntry]] = {}

    for package in tlpdb.split("\n\n"):
        revision_match = TLPDB_REVISION_REGEX.search(package)
        if revision_match is not None:
            revision = int(revision_match.group(1))
        else:
            revision = None

        for file_match in TLPDB_FILE_REGEX.finditer(package):
            filename = file_match.group("filename")
            path = file_match.group("path")

            if filename not in files:
                files[filename] = []

            files[filename].append(
                FileEntry(
                    filename=filename,
                    path=path,
                    source="tlpdb",
                    date=None,
                    revision=revision,
                )
            )

    return files


def filelist_from_ctan(
    files_byname: str,
) -> dict[str, list[FileEntry]]:
    """Extract the filelist from the FILES.byname file.

    Args:
        files_byname: The contents of the FILES.byname file as a string.

    Returns:
        A dictionary mapping file names to their corresponding FileEntry
        objects.
    """

    files: dict[str, list[FileEntry]] = {}

    for file_match in CTAN_FILE_REGEX.finditer(files_byname):
        filename = file_match.group("filename")
        path = file_match.group("path")
        date_str = file_match.group("date")
        date = int(date_str.replace("/", ""))

        if filename not in files:
            files[filename] = []

        files[filename].append(
            FileEntry(
                filename=filename,
                path=path,
                source="ctan",
                date=date,
                revision=None,
            )
        )

    return files


def get_missing_ctan_files(
    tlpdb_files: dict[str, list[FileEntry]],
    ctan_files: dict[str, list[FileEntry]],
) -> set[FileEntry]:
    """Get the list of files that are in the tlpdb but not in the ctan filelist.

    Args:
        tlpdb_files: The filelist extracted from the texlive.tlpdb file.
        ctan_files: The filelist extracted from the FILES.byname file.

    Returns:
        A set of FileEntry objects representing the files that are in the tlpdb
        but not in the ctan filelist.
    """

    missing = set(tlpdb_files.keys()) - set(ctan_files.keys())
    out: set[FileEntry] = set()

    # Filter the missing files
    for filename in missing:
        # Ignore files with certain extensions since they're large and are meant
        # to be included in the CTAN archive as-is.
        extension = filename.split(".")[-1]
        if extension in IGNORE_EXTENSIONS:
            continue

        # Ignore files with certain prefixes
        prefix = filename.split("-")[0]
        if prefix in IGNORE_PREFIXES:
            continue

        # Now, get the FileEntry objects for this file
        entries = tlpdb_files[filename]

        # If there are duplicate entries for this file, just ignore it since
        # there's nothing sensible that we can do here.
        if len(entries) > 1:
            continue

        # Otherwise, add the single entry for this file to the output set.
        out.add(entries[0])

    return out


def run(
    output_directory: Path,
    mirror_url: str,
    texmf_dist: Path,
    generate_database: bool,
    generate_zip: bool,
) -> None:
    """Run the commands.

    Args:
        output_directory: The output directory for the database.
        mirror_url: The CTAN mirror to use.
        texmf_dist: The path to the texmf-dist directory on the local filesystem.
        generate_database: Whether to generate the filename database.
        generate_zip: Whether to generate the zip file.
    """

    # Download the files
    ctan, tlpdb = download_files(mirror_url)

    # Extract the filelists
    ctan_files = filelist_from_ctan(ctan)
    tlpdb_files = filelist_from_tlpdb(tlpdb)

    if generate_zip:
        msg("Generating zip file...")
        # Get the list of files in TL but not in CTAN
        ctan_missing = get_missing_ctan_files(tlpdb_files, ctan_files)
        pprint(ctan_missing)

    # if generate_database:
    #     msg("Generating database...")


####################
### Entry Points ###
####################


def main() -> int:
    """Entry point."""

    # Main parser
    parser = ArgumentParser(
        description="network-install filename database generator",
        formatter_class=ArgumentDefaultsHelpFormatter,
        suggest_on_error=True,
    )

    parser.add_argument(
        "--version",
        action="version",
        version=__VERSION__,
    )

    parser.add_argument(
        "--mirror",
        help="The CTAN mirror to use",
        default=DEFAULT_MIRROR,
    )

    parser.add_argument(
        "--texmf-dist",
        help="The path to the texmf-dist directory on the local filesystem",
        default=Path("/usr/local/texlive/2026/texmf-dist/"),
    )

    parser.add_argument(
        "--output-directory",
        help="The output directory for the database",
        default=Path("./build/"),
        type=Path,
    )

    parser.add_argument(
        "--generate-database",
        choices=("true", "false"),
        default="true",
        help="Generate the filename database",
    )

    parser.add_argument(
        "--generate-zip",
        choices=("true", "false"),
        default="true",
        help="Generate the zip file",
    )

    # Parse the arguments
    args: Namespace = parser.parse_args()

    output_directory: Path = args.output_directory
    generate_database: bool = args.generate_database.casefold() == "true"
    generate_zip: bool = args.generate_zip.casefold() == "true"
    mirror_url: str = args.mirror
    texmf_dist: Path = args.texmf_dist

    # Run the commands
    run(
        output_directory=output_directory,
        mirror_url=mirror_url,
        texmf_dist=texmf_dist,
        generate_database=generate_database,
        generate_zip=generate_zip,
    )

    return 0


if __name__ == "__main__":
    exit_code = main()
    exit(exit_code)
