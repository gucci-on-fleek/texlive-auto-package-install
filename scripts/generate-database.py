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
from gzip import compress as gzip_compress, decompress as gzip_decompress
from lzma import decompress as lzma_decompress
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


class ZipRow(NamedTuple):
    """A row in the exported filename database for a file from the zip file."""

    path: str
    """The name of the file inside the zip file."""

    revision: int
    """The SVN revision of the file, as an integer."""

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
DATABASE_FILENAME = "network-install.files.lut.gz"
DEFAULT_MIRROR = "https://mirror.ctan.org"
FILES_PATH = "/FILES.byname.gz"
IGNORE_EXTENSIONS = {"pdf", "png", "jpg", "4ht"}
IGNORE_PREFIXES = {"lwarp"}
START_TIME = time()
TLPDB_PATH = "/systems/texlive/tlnet/tlpkg/texlive.tlpdb.xz"
TLPDB_REVISION_REGEX = re_compile(r"^revision (\d+)\s*$", MULTILINE)
ZIP_EPOCH = (1980, 1, 1, 0, 0, 0)
ZIP_LOCAL_FILE_HEADER_SIZE = 30
ZIP_NAME = "network-install.files.zip"

TLPDB_FILE_REGEX = re_compile(
    r"""
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
                ) |
            ) /

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
            macros/context/contrib
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
        revision_match = TLPDB_REVISION_REGEX.search(package)
        if revision_match is not None:
            revision = int(revision_match.group(1))
        else:
            revision = None

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


def get_found_ctan_files(
    tlpdb_files: FileList,
    ctan_files: FileList,
) -> dict[str, CTANRow]:
    """Get the list of files that are in both the tlpdb and the ctan filelist.

    Args:
        tlpdb_files: The filelist extracted from the texlive.tlpdb file.
        ctan_files: The filelist extracted from the FILES.byname file.

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
        out[filename] = CTANRow(
            path=ctan_entry.path,
            revision=tlpdb_entry.revision,
        )

    return out


def get_zip_files(
    tlpdb_files: FileList,
    zip_path: Path,
) -> dict[str, ZipRow]:
    """Get the list of files that are in the zip file.

    Args:
        tlpdb_files: The filelist extracted from the texlive.tlpdb file.
        zip_path: The path to the zip file containing the missing files.

    Returns:
        A dictionary mapping file names to ZipRow objects representing the files
        that are in the zip file.
    """

    zip_files: dict[str, ZipRow] = {}

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
    zip_path: Path,
) -> None:
    """Save the database to a compressed Lua table.

    Args:
        output_file: The path to the output Lua file.

        files: The dictionary of DatabaseRow objects representing the files to
            include in the database.

        zip_path: The path to the zip file containing the missing files.
    """

    # Sort by revision and then by path to ensure deterministic output.
    sorted_files = sorted(
        files.items(),
        key=lambda row: (
            row[1].revision,
            row[1].path,
        ),
    )

    lines = [
        "return {",
    ]
    for filename, row in sorted_files:
        if isinstance(row, CTANRow):
            lines.append(
                f'["{filename}"]={{source="ctan",path="{row.path}",revision={row.revision}}},'
            )
        elif isinstance(row, ZipRow):
            lines.append(
                f'["{filename}"]={{source="zip",path="{row.path}",revision={row.revision},offset={{{row.start_offset},{row.end_offset}}}}},'
            )
        else:
            raise ValueError(f"Invalid row type for file {filename}.")
    lines.append("}")

    # Join the lines into a single string and encode it as bytes.
    data = "".join(lines).encode("utf-8")

    # Compress the data using gzip and write it to the output file.
    compressed_data = gzip_compress(data, compresslevel=9)
    with output_file.open("wb") as f:
        f.write(compressed_data)


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
        ctan_found = get_found_ctan_files(all_tlpdb_files, ctan_files)
        zip_files = get_zip_files(zip_tlpdb_files, output_directory / ZIP_NAME)

        # Generate the filename database and save it to a file.
        save_database(
            output_file=output_directory / DATABASE_FILENAME,
            files=ctan_found | zip_files,
            zip_path=output_directory / ZIP_NAME,
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
