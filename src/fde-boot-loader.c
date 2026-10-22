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

#define MAX_PATH_SIZE 4096

/* Read a little-endian 16-bit value from a byte buffer */
static inline uint16_t
le16(const uint8_t *p)
{
	return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

static bool
has_dot_component(const char *s)
{
	const char *p;

	for (p = s; *p; p++) {
		if ((p == s || p[-1] == '/') && p[0] == '.') {
			if (p[1] == '/' || p[1] == '\0')
				return true;
			if (p[1] == '.' && (p[2] == '/' || p[2] == '\0'))
				return true;
		}
	}
	return false;
}

/* Append one character, keeping room for the terminating NUL */
static int
append_char(char *path, size_t *path_len, size_t max_size, char c)
{
	if (*path_len + 1 >= max_size) {
		fprintf(stderr, "Path buffer exceeded\n");
		return -1;
	}
	path[(*path_len)++] = c;
	return 0;
}

/* Append a file node; the node start and each '\' begin a new component */
static int
append_file_node(char *path, size_t *path_len, size_t max_size,
		 const uint8_t *payload, size_t payload_len)
{
	bool new_comp = true;
	size_t i;
	uint16_t c;

	for (i = 0; i + 1 < payload_len; i += 2) {
		c = le16(payload + i);
		if (c == 0)
			break;
		if (c == '\\' || c == '/') {
			new_comp = true;
			continue;
		}
		if (c < 0x20 || c >= 0x7f) {
			fprintf(stderr, "Invalid character in boot loader path: 0x%04x\n", c);
			return -1;
		}
		if (new_comp && append_char(path, path_len, max_size, '/') < 0)
			return -1;
		new_comp = false;
		if (append_char(path, path_len, max_size, (char)c) < 0)
			return -1;
	}
	path[*path_len] = '\0';
	return 0;
}

int
main(int argc, char *argv[])
{
	char var_name[32];
	uint8_t *data = NULL;
	size_t size = 0;
	uint32_t attr = 0;
	uint16_t id;
	uint16_t dp_len;
	size_t desc_offset;
	size_t dp_offset;
	const uint8_t *cur;
	size_t rem;
	uint8_t type;
	uint8_t subtype;
	uint16_t node_len;
	char path[MAX_PATH_SIZE];
	size_t path_len = 0;
	bool in_file_path = false;
	const char *hex_str;
	int ret = 1;
	int i;

	path[0] = '\0';

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
		id = le16(data);
		free(data);
		data = NULL;
	}

	snprintf(var_name, sizeof(var_name), "Boot%04X", id);

	if (efi_get_variable(EFI_GLOBAL_GUID, var_name, &data, &size, &attr) < 0) {
		fprintf(stderr, "Failed to read %s\n", var_name);
		goto out;
	}

	if (size < 8) {
		fprintf(stderr, "Load option in %s is too short (%zu bytes)\n", var_name, size);
		goto out;
	}

	dp_len = le16(data + 4);

	/* Find end of UCS-2 Description starting at offset 6 */
	desc_offset = 6;
	while (desc_offset + 1 < size) {
		if (data[desc_offset] == 0 && data[desc_offset + 1] == 0)
			break;
		desc_offset += 2;
	}

	if (desc_offset + 1 >= size) {
		fprintf(stderr, "Unterminated description in %s\n", var_name);
		goto out;
	}

	dp_offset = desc_offset + 2;
	if (dp_offset + dp_len > size) {
		fprintf(stderr, "Device path length %u exceeds variable size in %s\n", dp_len, var_name);
		goto out;
	}

	/* Walk device path nodes within [dp_offset, dp_offset + dp_len) */
	cur = data + dp_offset;
	rem = dp_len;

	while (rem > 0) {
		if (rem < 4) {
			fprintf(stderr, "Truncated device path node header in %s\n", var_name);
			goto out;
		}

		type = cur[0];
		subtype = cur[1];
		node_len = le16(cur + 2);

		if (node_len < 4 || node_len > rem) {
			fprintf(stderr, "Invalid device path node length %u (remaining: %zu) in %s\n",
				node_len, rem, var_name);
			goto out;
		}

		if (type == EFIDP_END_TYPE)
			break;

		if (type == EFIDP_MEDIA_TYPE && subtype == EFIDP_MEDIA_FILE) {
			in_file_path = true;
			if ((node_len - 4) % sizeof(uint16_t) != 0) {
				fprintf(stderr, "Invalid file node length %u in %s\n", node_len, var_name);
				goto out;
			}
			if (append_file_node(path, &path_len, sizeof(path), cur + 4, node_len - 4) < 0)
				goto out;
		} else if (in_file_path) {
			break;
		}

		cur += node_len;
		rem -= node_len;
	}

	if (has_dot_component(path)) {
		fprintf(stderr, "Path traversal component in boot loader path\n");
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
