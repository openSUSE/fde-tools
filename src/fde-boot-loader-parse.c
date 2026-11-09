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

#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include "fde-boot-loader.h"

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
parse_load_option(const uint8_t *data, size_t size, char *path, size_t max_path_size)
{
	uint16_t dp_len;
	size_t desc_offset;
	size_t dp_offset;
	const uint8_t *cur;
	size_t rem;
	uint8_t type;
	uint8_t subtype;
	uint16_t node_len;
	size_t path_len = 0;
	bool in_file_path = false;

	if (!data || !path || max_path_size == 0)
		return -1;

	path[0] = '\0';

	if (size < 8) {
		fprintf(stderr, "Load option is too short (%zu bytes)\n", size);
		return -1;
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
		fprintf(stderr, "Unterminated description\n");
		return -1;
	}

	dp_offset = desc_offset + 2;
	if (dp_offset + dp_len > size) {
		fprintf(stderr, "Device path length %u exceeds variable size\n", dp_len);
		return -1;
	}

	/* Walk device path nodes within [dp_offset, dp_offset + dp_len) */
	cur = data + dp_offset;
	rem = dp_len;

	while (rem > 0) {
		if (rem < 4) {
			fprintf(stderr, "Truncated device path node header\n");
			return -1;
		}

		type = cur[0];
		subtype = cur[1];
		node_len = le16(cur + 2);

		if (node_len < 4 || node_len > rem) {
			fprintf(stderr, "Invalid device path node length %u (remaining: %zu)\n",
				node_len, rem);
			return -1;
		}

		if (type == EFIDP_END_TYPE)
			break;

		if (type == EFIDP_MEDIA_TYPE && subtype == EFIDP_MEDIA_FILE) {
			in_file_path = true;
			if ((node_len - 4) % sizeof(uint16_t) != 0) {
				fprintf(stderr, "Invalid file node length %u\n", node_len);
				return -1;
			}
			if (append_file_node(path, &path_len, max_path_size, cur + 4, node_len - 4) < 0)
				return -1;
		} else if (in_file_path) {
			break;
		}

		cur += node_len;
		rem -= node_len;
	}

	if (has_dot_component(path)) {
		fprintf(stderr, "Path traversal component in boot loader path\n");
		path[0] = '\0';
		return -1;
	}

	return 0;
}
