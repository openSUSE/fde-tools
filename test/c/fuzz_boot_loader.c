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

#include <stdint.h>
#include <stddef.h>
#include "fde-boot-loader.h"

/*
 * LibFuzzer entrypoint for parse_load_option().
 * Passes arbitrary byte buffers into parse_load_option() to ensure
 * no out-of-bounds reads, memory corruptions, or crashes occur.
 */
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	char path[MAX_PATH_SIZE];

	(void)parse_load_option(data, size, path, sizeof(path));
	return 0;
}

#ifdef STANDALONE_FUZZER
/*
 * Standalone driver for compilers lacking -fsanitize=fuzzer (e.g. GCC).
 * Feeds files provided on the command line to LLVMFuzzerTestOneInput.
 */
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char *argv[])
{
	int i;
	int tested = 0;

	for (i = 1; i < argc; i++) {
		FILE *f = fopen(argv[i], "rb");
		uint8_t *buf;
		long sz;

		if (!f)
			continue;

		fseek(f, 0, SEEK_END);
		sz = ftell(f);
		fseek(f, 0, SEEK_SET);

		if (sz <= 0) {
			fclose(f);
			continue;
		}

		buf = malloc((size_t)sz);
		if (buf && fread(buf, 1, (size_t)sz, f) == (size_t)sz) {
			LLVMFuzzerTestOneInput(buf, (size_t)sz);
			tested++;
		}
		free(buf);
		fclose(f);
	}

	printf("Standalone fuzzer tested %d inputs successfully\n", tested);
	return 0;
}
#endif
