#!/usr/bin/env python3
"""Extract one linked RISC-V kernel function for standalone benchmarking.

The extracted function retains its linked internal branch layout.  Optional
RISC-V alternatives are applied exactly as the kernel does at boot.  Direct
JAL calls to named external symbols are emitted as assembler calls so the
standalone link can retarget them without changing instruction width.
"""

import argparse
import pathlib
import struct


ELF_HEADER = struct.Struct("<16sHHIQQQIHHHHHH")
SECTION_HEADER = struct.Struct("<IIQQQQIIQQ")
SYMBOL = struct.Struct("<IBBHQQ")
ALT_ENTRY = struct.Struct("<iiHHI")


def c_string(data, offset):
    end = data.find(b"\0", offset)
    if end < 0:
        raise ValueError("unterminated ELF string")
    return data[offset:end].decode("ascii")


def sign_extend(value, bits):
    sign = 1 << (bits - 1)
    return (value ^ sign) - sign


def jal_target(address, instruction):
    if instruction & 0x7f != 0x6f:
        return None
    immediate = 0
    immediate |= ((instruction >> 31) & 0x1) << 20
    immediate |= ((instruction >> 21) & 0x3ff) << 1
    immediate |= ((instruction >> 20) & 0x1) << 11
    immediate |= ((instruction >> 12) & 0xff) << 12
    return address + sign_extend(immediate, 21)


class Elf:
    def __init__(self, path):
        self.path = pathlib.Path(path)
        self.data = self.path.read_bytes()
        header = ELF_HEADER.unpack_from(self.data)
        ident = header[0]
        if ident[:4] != b"\x7fELF" or ident[4] != 2 or ident[5] != 1:
            raise ValueError("expected a little-endian ELF64 image")
        section_offset = header[6]
        section_size = header[11]
        section_count = header[12]
        string_index = header[13]
        if section_size != SECTION_HEADER.size:
            raise ValueError("unexpected ELF64 section-header size")
        raw_sections = [
            SECTION_HEADER.unpack_from(
                self.data, section_offset + index * section_size)
            for index in range(section_count)
        ]
        string_header = raw_sections[string_index]
        strings = self.data[
            string_header[4]:string_header[4] + string_header[5]
        ]
        self.sections = []
        for index, raw in enumerate(raw_sections):
            self.sections.append({
                "index": index,
                "name": c_string(strings, raw[0]),
                "type": raw[1],
                "flags": raw[2],
                "address": raw[3],
                "offset": raw[4],
                "size": raw[5],
                "link": raw[6],
                "entry_size": raw[9],
            })
        self.section_by_name = {
            section["name"]: section for section in self.sections
        }
        self.symbols = self._read_symbols()

    def _read_symbols(self):
        result = {}
        symtab = self.section_by_name[".symtab"]
        strings_header = self.sections[symtab["link"]]
        strings = self.data[
            strings_header["offset"]:
            strings_header["offset"] + strings_header["size"]
        ]
        entry_size = symtab["entry_size"] or SYMBOL.size
        if entry_size != SYMBOL.size:
            raise ValueError("unexpected ELF64 symbol size")
        for offset in range(0, symtab["size"], entry_size):
            raw = SYMBOL.unpack_from(self.data, symtab["offset"] + offset)
            name = c_string(strings, raw[0])
            if name:
                result.setdefault(name, []).append({
                    "value": raw[4],
                    "size": raw[5],
                    "section_index": raw[3],
                })
        return result

    def symbol(self, name):
        matches = [symbol for symbol in self.symbols.get(name, [])
                   if symbol["section_index"] != 0]
        if not matches:
            raise ValueError(f"defined symbol not found: {name}")
        matches.sort(key=lambda symbol: (symbol["size"] == 0,
                                         -symbol["size"]))
        return matches[0]

    def bytes_at(self, address, size):
        for section in self.sections:
            start = section["address"]
            if (section["type"] != 8 and start <= address and
                    address + size <= start + section["size"]):
                offset = section["offset"] + address - start
                return self.data[offset:offset + size]
        raise ValueError(f"address range is not file-backed: 0x{address:x}+{size}")


def apply_alternatives(elf, function_address, function_data):
    section = elf.section_by_name.get(".alternative")
    if section is None:
        return 0
    if section["size"] % ALT_ENTRY.size:
        raise ValueError("malformed .alternative section")
    count = 0
    for offset in range(0, section["size"], ALT_ENTRY.size):
        entry_address = section["address"] + offset
        old_offset, alt_offset, _vendor, alt_len, _patch = \
            ALT_ENTRY.unpack_from(elf.data, section["offset"] + offset)
        old_address = entry_address + old_offset
        alt_address = entry_address + 4 + alt_offset
        function_offset = old_address - function_address
        if 0 <= function_offset and \
                function_offset + alt_len <= len(function_data):
            replacement = elf.bytes_at(alt_address, alt_len)
            function_data[function_offset:function_offset + alt_len] = replacement
            count += 1
    return count


def write_assembly(path, binary_path, output_symbol, function_size,
                   redirects):
    binary = str(binary_path.resolve()).replace("\\", "\\\\").replace('"', '\\"')
    lines = [
        '/* Generated by tools/extract-riscv-kernel-function.py. */',
        f'.section .text.{output_symbol}, "ax", @progbits',
        '.option norvc',
        '.option norelax',
        '.balign 64',
        f'.globl {output_symbol}',
        f'.type {output_symbol}, @function',
        f'{output_symbol}:',
    ]
    cursor = 0
    for offset, target in redirects:
        if offset > cursor:
            lines.append(f'.incbin "{binary}", {cursor}, {offset - cursor}')
        lines.append(f'jal ra, {target}')
        cursor = offset + 4
    if cursor < function_size:
        lines.append(f'.incbin "{binary}", {cursor}, {function_size - cursor}')
    lines.extend([
        f'.size {output_symbol}, .-{output_symbol}',
        '',
    ])
    path.write_text("\n".join(lines))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--vmlinux", required=True)
    parser.add_argument("--symbol", required=True)
    parser.add_argument("--output-symbol", required=True)
    parser.add_argument("--output-bin", required=True)
    parser.add_argument("--output-asm", required=True)
    parser.add_argument("--apply-alternatives", action="store_true")
    parser.add_argument("--redirect", action="append", default=[],
                        metavar="SOURCE=TARGET")
    args = parser.parse_args()

    elf = Elf(args.vmlinux)
    function = elf.symbol(args.symbol)
    if function["size"] == 0:
        raise ValueError(f"symbol has no size: {args.symbol}")
    function_address = function["value"]
    function_data = bytearray(elf.bytes_at(function_address,
                                           function["size"]))
    alternative_count = 0
    if args.apply_alternatives:
        alternative_count = apply_alternatives(
            elf, function_address, function_data)

    redirect_targets = {}
    for redirect in args.redirect:
        source, separator, target = redirect.partition("=")
        if not separator:
            raise ValueError(f"invalid redirect: {redirect}")
        redirect_targets[elf.symbol(source)["value"]] = target

    redirects = []
    for offset in range(0, len(function_data) - 3, 4):
        instruction = struct.unpack_from("<I", function_data, offset)[0]
        target_address = jal_target(function_address + offset, instruction)
        if target_address in redirect_targets:
            redirects.append((offset, redirect_targets[target_address]))

    output_bin = pathlib.Path(args.output_bin)
    output_asm = pathlib.Path(args.output_asm)
    output_bin.parent.mkdir(parents=True, exist_ok=True)
    output_asm.parent.mkdir(parents=True, exist_ok=True)
    output_bin.write_bytes(function_data)
    write_assembly(output_asm, output_bin, args.output_symbol,
                   len(function_data), redirects)
    print(f"symbol={args.symbol} size={len(function_data)} "
          f"alternatives={alternative_count} redirects={len(redirects)}")


if __name__ == "__main__":
    main()

