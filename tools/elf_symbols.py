#!/usr/bin/env python3
"""Small ELF function-symbol index shared by simulation log tools."""

from __future__ import annotations

import argparse
import bisect
import dataclasses
import pathlib
import subprocess


@dataclasses.dataclass(frozen=True)
class ElfImage:
    name: str
    path: pathlib.Path


@dataclasses.dataclass(frozen=True)
class FunctionSymbol:
    address: int
    name: str


@dataclasses.dataclass(frozen=True)
class SymbolizedPc:
    image: str
    function: str
    base: int
    offset: int

    def text(self) -> str:
        return (
            f"{self.image}:{self.function}+0x{self.offset:x}"
            f"@0x{self.base:016x}"
        )


class SymbolTable:
    def __init__(
        self,
        image: ElfImage,
        symbols: list[FunctionSymbol],
    ) -> None:
        if not symbols:
            raise ValueError(f"ELF has no function symbols: {image.path}")
        self.image = image
        self.symbols = symbols
        self.addresses = [symbol.address for symbol in symbols]

    def lookup(self, pc: int) -> SymbolizedPc | None:
        position = bisect.bisect_right(self.addresses, pc) - 1
        if position < 0:
            return None
        symbol = self.symbols[position]
        if position + 1 < len(self.symbols):
            if pc >= self.symbols[position + 1].address:
                return None
        elif pc - symbol.address > 1024 * 1024:
            return None
        return SymbolizedPc(
            self.image.name,
            symbol.name,
            symbol.address,
            pc - symbol.address,
        )


def parse_elf_image(value: str) -> ElfImage:
    try:
        name, path_text = value.split("=", 1)
    except ValueError as error:
        raise argparse.ArgumentTypeError(
            "ELF must be named as IMAGE=PATH"
        ) from error
    if not name:
        raise argparse.ArgumentTypeError("ELF image name must not be empty")
    if not path_text:
        raise argparse.ArgumentTypeError("ELF path must not be empty")
    return ElfImage(name, pathlib.Path(path_text))


def load_symbol_table(image: ElfImage, nm: str) -> SymbolTable:
    result = subprocess.run(
        (nm, "-n", "--defined-only", str(image.path)),
        check=True,
        capture_output=True,
        text=True,
    )
    symbols: list[FunctionSymbol] = []
    for line in result.stdout.splitlines():
        fields = line.split(maxsplit=2)
        if len(fields) != 3 or fields[1] not in "tTwW":
            continue
        try:
            address = int(fields[0], 16)
        except ValueError:
            continue
        symbols.append(FunctionSymbol(address, fields[2]))

    # nm may emit aliases at one address.  Keep the final name at each address;
    # global names normally follow local aliases and are more useful in reports.
    by_address = {symbol.address: symbol for symbol in symbols}
    return SymbolTable(
        image,
        [by_address[address] for address in sorted(by_address)],
    )


def load_symbol_tables(
    images: list[ElfImage],
    nm: str,
) -> list[SymbolTable]:
    return [load_symbol_table(image, nm) for image in images]


def symbolize(
    tables: list[SymbolTable],
    pc: int,
) -> SymbolizedPc | None:
    candidates = [
        result
        for table in tables
        if (result := table.lookup(pc)) is not None
    ]
    if not candidates:
        return None
    return min(candidates, key=lambda result: result.offset)
