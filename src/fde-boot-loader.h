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

#ifndef FDE_BOOT_LOADER_H
#define FDE_BOOT_LOADER_H

#include <stdint.h>
#include <stddef.h>

#define MAX_PATH_SIZE 4096

#ifndef EFIDP_END_TYPE
#define EFIDP_END_TYPE   0x7f
#endif

#ifndef EFIDP_MEDIA_TYPE
#define EFIDP_MEDIA_TYPE 0x04
#endif

#ifndef EFIDP_MEDIA_FILE
#define EFIDP_MEDIA_FILE 0x04
#endif

/*
 * Parse the binary EFI Load Option structure in @data of size @size.
 * If a file device path is present, converts it to an ASCII POSIX path
 * (forward slashes with a leading '/') in @path of size @max_path_size.
 * If no file device path is present (e.g. PXE or direct disk boot),
 * sets @path to "" and returns 0.
 *
 * Returns 0 on success, or -1 on malformed data, buffer truncation,
 * invalid characters, or path traversal components.
 */
int parse_load_option(const uint8_t *data, size_t size, char *path, size_t max_path_size);

#endif /* FDE_BOOT_LOADER_H */
