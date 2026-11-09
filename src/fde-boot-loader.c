/*
 * Copyright (C) 2026 Gary Lin <glin@suse.com>
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
 */

/*
 * fde-boot-loader: Print the EFI bootloader file path from UEFI load options.
 *
 * This helper utility determines the bootloader path by reading BootCurrent
 * (or a specified Boot#### entry) directly via libefivar and parsing the binary
 * EFI load option structure with explicit bounds checking.
 *
 * Parsing the binary device path directly avoids text-formatting ambiguities
 * present in efibootdump/efibootmgr CLI output, where optional data can be
 * printed immediately adjacent to the device path without a delimiter.
 * Explicit bounds checks on node lengths and offsets ensure resilience against
 * corrupted or malformed firmware entries.
 *
 * Consecutive file nodes are joined into a single path, and the extracted
 * UCS-2 path is converted to an ASCII POSIX path (forward slashes with a
 * leading '/') and printed to stdout. Control characters, non-ASCII characters,
 * and '.' or '..' path traversal components are strictly rejected. If the boot
 * entry has no file device path node (e.g. direct disk or network boot), the
 * utility prints nothing and exits with status 0, allowing callers to fall
 * back to the default boot path.
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <strings.h>
#include <ctype.h>
#include <efivar/efivar.h>
#include "fde-boot-loader.h"

int
main(int argc, char *argv[])
{
	char var_name[32];
	uint8_t *data = NULL;
	size_t size = 0;
	uint32_t attr = 0;
	uint16_t id;
	char path[MAX_PATH_SIZE];
	const char *hex_str;
	int ret = 1;
	int i;

	if (argc > 1) {
		if (strcmp(argv[1], "-h") == 0 || strcmp(argv[1], "--help") == 0) {
			fprintf(stderr, "Usage: %s [Boot####]\n", argv[0]);
			return 0;
		}

		if (strncasecmp(argv[1], "Boot", 4) == 0)
			hex_str = argv[1] + 4;
		else
			hex_str = argv[1];

		if (strlen(hex_str) != 4) {
			fprintf(stderr, "Invalid boot entry id: %s\n", argv[1]);
			return 1;
		}

		for (i = 0; i < 4; i++) {
			if (!isxdigit((unsigned char)hex_str[i])) {
				fprintf(stderr, "Invalid hex digit in boot entry id: %s\n", argv[1]);
				return 1;
			}
		}

		id = (uint16_t)strtoul(hex_str, NULL, 16);
	} else {
		if (efi_get_variable(EFI_GLOBAL_GUID, "BootCurrent",
				     &data, &size, &attr) < 0 ||
		    size < sizeof(uint16_t)) {
			fprintf(stderr, "Failed to read BootCurrent\n");
			goto out;
		}
		id = (uint16_t)data[0] | ((uint16_t)data[1] << 8);
		free(data);
		data = NULL;
	}

	snprintf(var_name, sizeof(var_name), "Boot%04X", id);

	if (efi_get_variable(EFI_GLOBAL_GUID, var_name, &data, &size, &attr) < 0) {
		fprintf(stderr, "Failed to read %s\n", var_name);
		goto out;
	}

	if (parse_load_option(data, size, path, sizeof(path)) != 0) {
		fprintf(stderr, "Failed to parse %s\n", var_name);
		goto out;
	}

	/* Non-file boot entries (direct disk or network boot) print nothing */
	if (path[0] != '\0')
		printf("%s\n", path);
	ret = 0;

out:
	free(data);
	return ret;
}
