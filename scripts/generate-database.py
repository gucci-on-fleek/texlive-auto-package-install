#!/usr/bin/env python3
# texlive-auto-package-install
# https://github.com/gucci-on-fleek/texlive-auto-package-install
# SPDX-License-Identifier: MPL-2.0+
# SPDX-FileCopyrightText: 2026 Max Chernoff

"""Generate the filename database used by the network-install LaTeX package."""

###############
### Imports ###
###############

from argparse import (
    ArgumentDefaultsHelpFormatter,
    ArgumentParser,
    Namespace,
)
from ctypes import CDLL, c_uint8, cdll
from gzip import compress as gzip_compress, decompress as gzip_decompress
from lzma import decompress as lzma_decompress
from os import environ
from pathlib import Path
from pprint import pp as pprint
from re import MULTILINE, VERBOSE, compile as re_compile
from sys import exit, stderr
from time import time
from typing import Literal, NamedTuple, TypeAlias
from urllib.request import urlopen
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo


########################
### Type Definitions ###
########################


class FileEntry(NamedTuple):
    """A file entry in the filename list sources."""

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


class CTANRow(NamedTuple):
    """A row in the exported filename database for a file from CTAN."""

    path: str
    """The path of the file, relative to the root of the CTAN archive."""

    revision: int
    """The SVN revision of the file, as an integer."""

    hash: bytes
    """The hash of the file contents, as bytes."""


class ZipRow(NamedTuple):
    """A row in the exported filename database for a file from the zip file."""

    path: str
    """The name of the file inside the zip file."""

    revision: int
    """The SVN revision of the file, as an integer."""

    hash: bytes
    """The hash of the file contents, as bytes."""

    start_offset: int
    """The byte offset of the start of gzip-compressed file data in the zip file."""

    end_offset: int
    """The byte offset of the end of gzip-compressed file data in the zip file."""


DatabaseRow: TypeAlias = CTANRow | ZipRow
FileList: TypeAlias = dict[str, list[FileEntry]]

#################
### Constants ###
#################

__VERSION__ = "0.1.2"  # %%version
CONTEXT_LENGTH = 8
DATABASE_FILENAME = "network-install.files.lut.gz"
DEFAULT_MIRROR = "https://mirror.ctan.org"
FILES_PATH = "/FILES.byname.gz"
IGNORE_EXTENSIONS = {"pdf", "png", "jpg", "4ht"}
LIBHYDROGEN_CONTEXT = b"netinst1"
SECRET_KEY_LENGTH = 64
SIGNATURE_LENGTH = 64
START_TIME = time()
TLPDB_PATH = "/systems/texlive/tlnet/tlpkg/texlive.tlpdb.xz"
TLPDB_REVISION_REGEX = re_compile(r"^revision (\d+)\s*$", MULTILINE)
TLPDB_PACKAGE_NAME_REGEX = re_compile(r"^name (\S+)\s*$", MULTILINE)
ZIP_EPOCH = (1980, 1, 1, 0, 0, 0)
ZIP_LOCAL_FILE_HEADER_SIZE = 30
ZIP_NAME = "network-install.files.zip"
HASH_SIZE_BYTES = 16

IGNORE_PACKAGES = {
    "lwarp",  # Too many extra files
    "00texlive.image",  # Never actually installed
    "latex",  # Guaranteed to already be installed
    "l3kernel",  # Bad things happen when this doesn't match the format
}

TLPDB_FILE_REGEX = re_compile(
    r"""
        # Match the beginning of the line
        ^

        # Match a literal space
        \ #

        # Only match things that look like paths in $TEXMFDIST
        (texmf-dist | RELOC ) /

        (?P<path>
            # We only care about files in the following subdirectories.
            (?P<format>
                dvips |  # For PSTricks
                metapost |  # For luamplib
                scripts |  # Maybe some of the stuff here is used at runtime?

                # TeX
                tex / (?:
                    latex | generic | lualatex | luatex
                ) |

                # Fonts
                fonts / (?:
                    tfm | type1 | vf | afm | enc | # Type 1 fonts
                    cmap | map |  # Map files
                    opentype | truetype # OpenType and TrueType fonts
                )
            ) /

            # Match the rest of the path
            \S+?

            # Match the filename
            / (?P<filename> [^ / \s ]+)
        )

        # Match the end of the line
        $
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

CTAN_IGNORE_REGEX = re_compile(
    r"""
        ^(?:
            # The latex-dev files are always going to be duplicates of files in
            # the main archive, so we need to ignore them to avoid accidental
            # duplications.
            macros/latex-dev |

            # These files are automatically synced from
            # modules.contextgarden.net, so there can be duplicate files here
            # too.
            macros/context/contrib |

            # No runtime files in here, and some of the files conflict with
            # files in the main archive, so we'll just ignore the whole tree.
            info
        ) /
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


def lua_string(s: str | bytes) -> bytes:
    """Converts a string to a Lua string literal.

    Args:
        s: The string to convert.

    Returns:
        The string converted to a Lua string literal, as bytes.
    """

    if isinstance(s, str):
        s = s.encode("ascii")

    if (b"\r" in s) or (b"\n" in s):
        return repr(s)[1:].encode("ascii")
    elif (b'"' not in s) and (b"\\" not in s):
        return b'"' + s + b'"'
    elif (b"]]" not in s) and (not s.endswith(b"]")):
        return b"[[" + s + b"]]"
    elif b"]=]" not in s:
        return b"[=[" + s + b"]=]"
    else:
        raise ValueError(
            "String cannot be safely represented as a Lua string literal."
        )


def lua_key(s: bytes | str) -> bytes:
    """Converts a string to a valid Lua table key.

    Args:
        s: The string to convert.

    Returns:
        The string converted to a valid Lua table key.
    """
    if isinstance(s, str):
        s = s.encode("utf-8")

    if s.isalpha():
        return s
    else:
        s = lua_string(s)
        if s.startswith(b"["):
            return b"[ " + s + b" ]"
        else:
            return b"[" + s + b"]"


#############################
### libhydrogen Interface ###
#############################

libhydrogen: CDLL | None = None


def initialize_libhydrogen(lib_path: Path) -> None:
    """Initialize the libhydrogen library.

    Args:
        lib_path: The path to the hydrogen.so file.
    """

    # Load the library
    global libhydrogen
    libhydrogen = cdll.LoadLibrary(lib_path.as_posix())

    # Initialize the library
    result = libhydrogen.hydro_init()
    if result != 0:
        raise RuntimeError(f"Failed to initialize libhydrogen: {result}")


def create_signature(message: bytes, secret_key: bytes) -> bytes:
    """Create a signature for the given message.

    Args:
        message: The message to create a signature for.
        secret_key: The secret key to use for creating the signature. Must be
            32 bytes long.

    Returns:
        The signature as bytes, which will be 64 bytes long.
    """

    if libhydrogen is None:
        raise RuntimeError("libhydrogen is not initialized.")

    if len(secret_key) != SECRET_KEY_LENGTH:
        raise ValueError(f"Secret key must be {SECRET_KEY_LENGTH} bytes long.")

    if len(LIBHYDROGEN_CONTEXT) != CONTEXT_LENGTH:
        raise ValueError(f"Context must be {CONTEXT_LENGTH} bytes long.")

    signature = (c_uint8 * SIGNATURE_LENGTH)()
    result = libhydrogen.hydro_sign_create(
        signature,
        message,
        len(message),
        LIBHYDROGEN_CONTEXT,
        secret_key,
    )
    if result != 0:
        raise RuntimeError(f"Failed to create signature: {result}")

    return bytes(signature)


def hash_message(message: bytes) -> bytes:
    """Hash the given message using libhydrogen.

    Args:
        message: The message to hash.

    Returns:
        The hash of the message as bytes, which will be 16 bytes long.
    """

    if libhydrogen is None:
        raise RuntimeError("libhydrogen is not initialized.")

    hash = (c_uint8 * HASH_SIZE_BYTES)()
    result = libhydrogen.hydro_hash_hash(
        hash,
        HASH_SIZE_BYTES,
        message,
        len(message),
        LIBHYDROGEN_CONTEXT,
        None,
    )
    if result != 0:
        raise RuntimeError(f"Failed to hash message: {result}")

    return bytes(hash)


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


def filelist_from_tlpdb(
    tlpdb: str,
) -> tuple[FileList, FileList]:
    """Extract the filelist from the tlpdb file.

    Args:
        tlpdb: The contents of the tlpdb file as a string.

    Returns:
        A tuple of two dictionaries mapping file names to their corresponding
        FileEntry objects.

        The first dictionary contains _all_ files that could potentially be used
        at runtime; the second dictionary contains only the files that should be
        included in the zip file if they're missing from the CTAN filelist.
    """

    all_files: FileList = {}
    zip_files: FileList = {}

    for package in tlpdb.split("\n\n"):
        # Check to see if we should ignore this package
        pkg_name_match = TLPDB_PACKAGE_NAME_REGEX.search(package)
        if pkg_name_match is None:
            if package.strip():
                raise ValueError(
                    "Failed to parse package name from tlpdb file."
                )
            else:
                continue
        pkg_name = pkg_name_match.group(1)
        if pkg_name in IGNORE_PACKAGES:
            continue

        # Get the revision of the package
        revision_match = TLPDB_REVISION_REGEX.search(package)
        if revision_match is not None:
            revision = int(revision_match.group(1))
        else:
            revision = None

        # Loop over all the files
        for file_match in TLPDB_FILE_REGEX.finditer(package):
            filename = file_match.group("filename")
            path = file_match.group("path")
            entry = FileEntry(
                filename=filename,
                path=path,
                source="tlpdb",
                date=None,
                revision=revision,
            )

            if filename not in all_files:
                all_files[filename] = []

            all_files[filename].append(entry)

            if file_match.group("format").startswith("tex/"):
                if filename not in zip_files:
                    zip_files[filename] = []
                zip_files[filename].append(entry)

    return all_files, zip_files


def filelist_from_ctan(
    files_byname: str,
) -> FileList:
    """Extract the filelist from the FILES.byname file.

    Args:
        files_byname: The contents of the FILES.byname file as a string.

    Returns:
        A dictionary mapping file names to their corresponding FileEntry
        objects.
    """

    files: FileList = {}

    for file_match in CTAN_FILE_REGEX.finditer(files_byname):
        # Parse the file information from the regex match
        filename = file_match.group("filename")
        path = file_match.group("path")
        date_str = file_match.group("date")
        date = int(date_str.replace("/", ""))

        # Special cases: exclude certain files
        if CTAN_IGNORE_REGEX.match(path):
            continue

        # Add the file entry to the filelist
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
    tlpdb_files: FileList,
    ctan_files: FileList,
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

        # Now, get the FileEntry objects for this file
        entries = tlpdb_files[filename]

        # If there are duplicate entries for this file, just ignore it since
        # there's nothing sensible that we can do here.
        if len(entries) > 1:
            continue

        # Otherwise, add the single entry for this file to the output set.
        out.add(entries[0])

    return out


def hash_file(texmf_dist: Path, path: str) -> bytes:
    """Compute the hash of a file in the texmf-dist directory.

    Args:
        texmf_dist: The path to the texmf-dist directory on the local
            filesystem.
        path: The path to the file within texmf_dist.

    Returns:
        The hash of the file contents, as bytes.
    """

    with (texmf_dist / path).open("rb") as f:
        contents = f.read()
    return hash_message(contents)


def get_found_ctan_files(
    tlpdb_files: FileList,
    ctan_files: FileList,
    texmf_dist: Path,
) -> dict[str, CTANRow]:
    """Get the list of files that are in both the tlpdb and the ctan filelist.

    Args:
        tlpdb_files: The filelist extracted from the texlive.tlpdb file.
        ctan_files: The filelist extracted from the FILES.byname file.
        texmf_dist: The path to the texmf-dist directory on the local
            filesystem, used to compute the hashes of the files.

    Returns:
        A dictionary mapping file names to CTANRow objects representing the
        files that are in both the tlpdb and the ctan filelist.
    """
    found = set(tlpdb_files.keys()).intersection(set(ctan_files.keys()))
    out: dict[str, CTANRow] = {}

    for filename in found:
        # If there are multiple entries for this file, just ignore it since
        # there's nothing sensible that we can do here.
        if len(ctan_files[filename]) > 1 or len(tlpdb_files[filename]) > 1:
            continue

        # Get the entries for this file
        ctan_entry = ctan_files[filename][0]
        tlpdb_entry = tlpdb_files[filename][0]

        # If the revision is missing (shouldn't be possible), fail with an error
        if tlpdb_entry.revision is None:
            raise ValueError(
                f"Revision is missing for file {filename} in tlpdb filelist."
            )

        # Otherwise, add the single entry for this file to the output list.
        try:
            out[filename] = CTANRow(
                path=ctan_entry.path,
                revision=tlpdb_entry.revision,
                hash=hash_file(texmf_dist, tlpdb_entry.path),
            )
        except IsADirectoryError:
            # If the file is actually a directory, just skip it since we only
            # care about files.
            continue

    return out


def get_zip_files(
    tlpdb_files: FileList,
    zip_path: Path,
    texmf_dist: Path,
) -> dict[str, ZipRow]:
    """Get the list of files that are in the zip file.

    Args:
        tlpdb_files: The filelist extracted from the texlive.tlpdb file.
        zip_path: The path to the zip file containing the missing files.
        texmf_dist: The path to the texmf-dist directory on the local
            filesystem, used to compute the hashes of the files.

    Returns:
        A dictionary mapping file names to ZipRow objects representing the files
        that are in the zip file.
    """

    zip_files: dict[str, ZipRow] = {}

    with Path(zip_path).open("rb") as f:
        zip_bytes = f.read()

    with ZipFile(zip_path, "r") as zip_file:
        for zip_info in zip_file.infolist():
            filename = zip_info.filename

            # We only care about files that are in the tlpdb filelist, but it
            # should be impossible for a file to be missing from there.
            try:
                tlpdb_entry = tlpdb_files[filename][0]
            except KeyError:
                raise ValueError(
                    f"File {filename} is in the zip file but not in the tlpdb filelist."
                )

            # The revision should also be present in the tlpdb filelist
            revision = tlpdb_entry.revision
            if revision is None:
                raise ValueError(
                    f"Revision is missing for file {filename} in tlpdb filelist."
                )

            # Get the byte offsets of the compressed file data in the zip file.
            start_offset = (
                zip_info.header_offset
                + ZIP_LOCAL_FILE_HEADER_SIZE
                + len(zip_info.filename)
                + len(zip_info.extra)
            )
            end_offset = start_offset + zip_info.compress_size

            # Now, add the entry for this file to the output dictionary.
            zip_files[filename] = ZipRow(
                path=filename,
                revision=revision,
                hash=hash_message(zip_bytes[start_offset : end_offset + 1]),
                start_offset=start_offset,
                end_offset=end_offset,
            )

    return zip_files


def create_zip(
    output_file: Path, texmf_dist: Path, files: set[FileEntry]
) -> None:
    """Create a zip file containing the specified files.

    Args:
        output_file: The path to the output zip file.
        texmf_dist: The path to the texmf-dist directory on the local filesystem.
        files: The set of FileEntry objects representing the files to include in the zip file.
    """

    # Sort the files to ensure deterministic output. We'll sort first by the
    # revision and then by the full path so that newer files are placed later
    # in the zip file, which should reduce the number of bytes changed with
    # every update.
    sorted_files = sorted(
        files,
        key=lambda entry: (
            entry.revision if entry.revision is not None else -1,
            entry.path,
        ),
    )

    # Delete the zip file first to make sure that we're starting from scratch.
    try:
        output_file.unlink()
    except FileNotFoundError:
        pass

    with ZipFile(
        output_file,
        "w",
        compression=ZIP_DEFLATED,
        allowZip64=False,
        compresslevel=9,
    ) as zip_file:
        for file in sorted_files:
            # Create a ZipInfo object for this file. We're avoiding using the
            # ZipFile.write() method since it doesn't allow us to specify the
            # date of the file.
            zip_info = ZipInfo(
                filename=file.filename,
                # Set the date of the file to a fixed value to ensure
                # deterministic output. We'll use the ZIP epoch, which is the
                # earliest date that can be represented in a zip file.
                date_time=ZIP_EPOCH,
            )

            # Set the file permissions to 444 (r--r--r--) to ensure
            # deterministic output and to make sure that the files are read-only
            # when extracted.
            zip_info.external_attr = 0o444 << 16

            # Python sets the create_system attribute depending on the operating
            # system, but this causes non-deterministic output since the same
            # file will have different create_system values on different
            # operating systems. To avoid this, we'll just set it to a fixed
            # value that works on all operating systems. The value 3 corresponds
            # to Unix.
            zip_info.create_system = 3

            # Now, write the file to the zip file using the ZipInfo object and
            # the contents of the file.
            try:
                with (texmf_dist / file.path).open("rb") as f:
                    zip_file.writestr(
                        zip_info,
                        f.read(),
                        compress_type=ZIP_DEFLATED,
                        compresslevel=9,
                    )
            except IsADirectoryError:
                # If the file is a directory, just skip it since we only care
                # about files.
                continue


def save_database(
    output_file: Path,
    files: dict[str, DatabaseRow],
    secret_key: bytes,
) -> None:
    """Save the database to a compressed Lua table.

    Args:
        output_file: The path to the output Lua file.

        files: The dictionary of DatabaseRow objects representing the files to
            include in the database.

        secret_key: The secret key to use for signing the database, as bytes.
    """

    # Sort by revision and then by path to ensure deterministic output.
    sorted_files = sorted(
        files.items(),
        key=lambda row: (
            row[1].revision,
            row[1].path,
        ),
    )

    output = [
        b"return {",
    ]

    for filename, row in sorted_files:
        # fmt: off
        if isinstance(row, CTANRow):
            output += [
                lua_key(filename), b"={",
                    b'source="ctan",',
                    b"path=", lua_string(row.path), b",",
                    b"revision=", str(row.revision).encode(), b",",
                    b"hash=", lua_string(row.hash),
                b"},",
            ]
        elif isinstance(row, ZipRow):
            output += [
                lua_key(filename), b"={",
                    b'source="zip",',
                    b"path=", lua_string(row.path), b",",
                    b"revision=", str(row.revision).encode(), b",",
                    b"hash=", lua_string(row.hash), b",",
                    lua_key("offset"), b"=", b"{",
                        str(row.start_offset).encode(), b",",
                        str(row.end_offset).encode(),
                    b"}",
                b"},",
            ]
        else:
            raise ValueError(f"Invalid row type for file {filename}.")
        # fmt: on
    output.append(b"}")

    # Join the lines into a single string and encode it as bytes.
    data = b"".join(output)

    # Compress the data using gzip.
    compressed_data = gzip_compress(data, compresslevel=9)

    # Sign the compressed data
    signature = create_signature(compressed_data, secret_key)

    # Append the signature to the end of the compressed data and save it to the
    # output file.
    with output_file.open("wb") as f:
        f.write(compressed_data)
        f.write(signature)


def run(  # noqa: PLR0917 PLR0913
    output_directory: Path,
    mirror_url: str,
    texmf_dist: Path,
    generate_database: bool,
    generate_zip: bool,
    secret_key: bytes,
) -> None:
    """Run the commands.

    Args:
        output_directory: The output directory for the database.
        mirror_url: The CTAN mirror to use.
        texmf_dist: The path to the texmf-dist directory on the local filesystem.
        generate_database: Whether to generate the filename database.
        generate_zip: Whether to generate the zip file.
        secret_key: The secret key to use for encryption, as bytes.
    """

    # Download the files
    ctan, tlpdb = download_files(mirror_url)

    # Extract the filelists
    ctan_files = filelist_from_ctan(ctan)
    all_tlpdb_files, zip_tlpdb_files = filelist_from_tlpdb(tlpdb)

    if generate_zip:
        msg("Generating zip file...")
        # Get the list of files in TL but not in CTAN
        ctan_missing = get_missing_ctan_files(zip_tlpdb_files, ctan_files)

        # Generate the zip file containing the missing files
        output_directory.mkdir(parents=True, exist_ok=True)
        create_zip(
            output_file=output_directory / ZIP_NAME,
            texmf_dist=texmf_dist,
            files=ctan_missing,
        )

        msg(
            f"Finished generating zip file. {len(ctan_missing)} files were included."
        )

    if generate_database:
        if not generate_zip:
            raise NotImplementedError(
                "Generating the database without generating the zip file is not supported since the database would be incomplete."
            )
        msg("Generating database...")

        # Get the list of files needed
        ctan_found = get_found_ctan_files(
            tlpdb_files=all_tlpdb_files,
            ctan_files=ctan_files,
            texmf_dist=texmf_dist,
        )
        zip_files = get_zip_files(
            tlpdb_files=zip_tlpdb_files,
            zip_path=output_directory / ZIP_NAME,
            texmf_dist=texmf_dist,
        )

        # Generate the filename database and save it to a file.
        save_database(
            output_file=output_directory / DATABASE_FILENAME,
            files=ctan_found | zip_files,
            secret_key=secret_key,
        )
        msg("Finished generating database.")


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
        epilog="""environment variables:
  $NETINST_SECRET_KEY: The secret key to use for encryption, specified as a hex
                       string. This is required and must be 32 bytes long
                       (64 hex characters).""",
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

    parser.add_argument(
        "--libhydrogen-path",
        help="The path to hydrogen.so",
        default=Path("./source/c/third-party/libhydrogen/hydrogen.so"),
        type=Path,
    )

    # Parse the arguments
    args: Namespace = parser.parse_args()

    output_directory: Path = args.output_directory
    generate_database: bool = args.generate_database.casefold() == "true"
    generate_zip: bool = args.generate_zip.casefold() == "true"
    mirror_url: str = args.mirror
    texmf_dist: Path = args.texmf_dist
    libhydrogen_path: Path = args.libhydrogen_path

    try:
        secret_key: bytes = bytes.fromhex(environ["NETINST_SECRET_KEY"])
    except KeyError:
        parser.error("The NETINST_SECRET_KEY environment variable is required.")

    # Run the commands
    initialize_libhydrogen(libhydrogen_path)

    run(
        output_directory=output_directory,
        mirror_url=mirror_url,
        texmf_dist=texmf_dist,
        generate_database=generate_database,
        generate_zip=generate_zip,
        secret_key=secret_key,
    )

    return 0


if __name__ == "__main__":
    exit_code = main()
    exit(exit_code)
