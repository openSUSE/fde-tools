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
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "fde-boot-loader.h"

static uint8_t *
read_file(const char *path, size_t *out_size)
{
	FILE *f = fopen(path, "rb");
	uint8_t *buf;
	long sz;

	if (!f) {
		fprintf(stderr, "Failed to open fixture: %s\n", path);
		return NULL;
	}

	fseek(f, 0, SEEK_END);
	sz = ftell(f);
	fseek(f, 0, SEEK_SET);

	if (sz < 0) {
		fclose(f);
		return NULL;
	}

	buf = malloc((size_t)sz);
	if (!buf) {
		fclose(f);
		return NULL;
	}

	if (fread(buf, 1, (size_t)sz, f) != (size_t)sz) {
		free(buf);
		fclose(f);
		return NULL;
	}

	fclose(f);
	*out_size = (size_t)sz;
	return buf;
}

static int test_fixture_expect_path(const char *fixtures_dir, const char *file, const char *expected_path)
{
	char file_path[512];
	uint8_t *data;
	size_t size = 0;
	char path[MAX_PATH_SIZE];
	int ret;

	snprintf(file_path, sizeof(file_path), "%s/%s", fixtures_dir, file);
	data = read_file(file_path, &size);
	if (!data)
		return 1;

	ret = parse_load_option(data, size, path, sizeof(path));
	free(data);

	if (ret != 0) {
		fprintf(stderr, "parse_load_option failed with %d for %s\n", ret, file);
		return 1;
	}

	if (strcmp(path, expected_path) != 0) {
		fprintf(stderr, "expected '%s', got '%s' for %s\n", expected_path, path, file);
		return 1;
	}

	return 0;
}

static int test_fixture_expect_failure(const char *fixtures_dir, const char *file)
{
	char file_path[512];
	uint8_t *data;
	size_t size = 0;
	char path[MAX_PATH_SIZE];
	int ret;

	snprintf(file_path, sizeof(file_path), "%s/%s", fixtures_dir, file);
	data = read_file(file_path, &size);
	if (!data)
		return 1;

	ret = parse_load_option(data, size, path, sizeof(path));
	free(data);

	if (ret == 0) {
		fprintf(stderr, "expected failure for %s, but got success (path: '%s')\n", file, path);
		return 1;
	}

	return 0;
}

static int test_valid_shim(const char *fixtures_dir)
{
	if (test_fixture_expect_path(fixtures_dir, "valid_opensuse_shim.bin", "/EFI/opensuse/shim.efi") != 0)
		return 1;

	if (test_fixture_expect_path(fixtures_dir, "multi_file_nodes.bin", "/EFI/opensuse/shim.efi") != 0)
		return 1;

	return 0;
}

static int test_boundaries(const char *fixtures_dir)
{
	char path[MAX_PATH_SIZE];
	char small_buf[5];
	char file_path[512];
	uint8_t *data;
	size_t size = 0;

	/* NULL data check */
	if (parse_load_option(NULL, 100, path, sizeof(path)) == 0) {
		fprintf(stderr, "C-B02: expected failure for NULL data\n");
		return 1;
	}

	/* 0 size check */
	if (parse_load_option((const uint8_t *)"dummy", 0, path, sizeof(path)) == 0) {
		fprintf(stderr, "C-B02: expected failure for 0 size\n");
		return 1;
	}

	/* Truncated header (< 8 bytes) */
	if (test_fixture_expect_failure(fixtures_dir, "truncated_header.bin") != 0)
		return 1;

	/* Unterminated description */
	if (test_fixture_expect_failure(fixtures_dir, "unterminated_desc.bin") != 0)
		return 1;

	/* Device path length exceeds data */
	if (test_fixture_expect_failure(fixtures_dir, "dp_len_exceeds.bin") != 0)
		return 1;

	/* Truncated device path node header (< 4 bytes remaining) */
	if (test_fixture_expect_failure(fixtures_dir, "truncated_node_header.bin") != 0)
		return 1;

	/* Bad node length exceeding remaining buffer */
	if (test_fixture_expect_failure(fixtures_dir, "bad_node_len.bin") != 0)
		return 1;

	/* Odd file node length */
	if (test_fixture_expect_failure(fixtures_dir, "odd_file_node_len.bin") != 0)
		return 1;

	/* Non-ASCII character */
	if (test_fixture_expect_failure(fixtures_dir, "non_ascii_char.bin") != 0)
		return 1;

	/* Small destination buffer */
	snprintf(file_path, sizeof(file_path), "%s/valid_opensuse_shim.bin", fixtures_dir);
	data = read_file(file_path, &size);
	if (!data)
		return 1;
	if (parse_load_option(data, size, small_buf, sizeof(small_buf)) == 0) {
		fprintf(stderr, "C-B02: expected failure for insufficient buffer\n");
		free(data);
		return 1;
	}
	free(data);

	return 0;
}

static int test_dotdot_traversal(const char *fixtures_dir)
{
	/* Trailing .. */
	if (test_fixture_expect_failure(fixtures_dir, "dotdot_traversal.bin") != 0)
		return 1;

	/* Mid-path .. */
	if (test_fixture_expect_failure(fixtures_dir, "mid_dotdot_traversal.bin") != 0)
		return 1;

	/* Lone . component */
	if (test_fixture_expect_failure(fixtures_dir, "dot_component.bin") != 0)
		return 1;

	return 0;
}

static int test_non_file_entry(const char *fixtures_dir)
{
	/* Hardware PCI node (Type 01, SubType 01) */
	if (test_fixture_expect_path(fixtures_dir, "non_file_pci.bin", "") != 0)
		return 1;

	/* IPv4 messaging node (Type 03, SubType 0c) */
	if (test_fixture_expect_path(fixtures_dir, "network_ipv4.bin", "") != 0)
		return 1;

	return 0;
}

static int test_cli_parsing(void)
{
	const char *bin = "../../fde-boot-loader";

	if (access(bin, X_OK) != 0) {
		/* Binary not built in this tree; skip CLI test */
		return -1;
	}

	/* --help should exit 0 */
	if (system("../../fde-boot-loader --help >/dev/null 2>&1") != 0) {
		fprintf(stderr, "C-B05: fde-boot-loader --help failed\n");
		return 1;
	}

	/* -h should exit 0 */
	if (system("../../fde-boot-loader -h >/dev/null 2>&1") != 0) {
		fprintf(stderr, "C-B05: fde-boot-loader -h failed\n");
		return 1;
	}

	/* Invalid hex digit Boot00ZZ should exit non-zero */
	if (system("../../fde-boot-loader Boot00ZZ >/dev/null 2>&1") == 0) {
		fprintf(stderr, "C-B05: expected failure for Boot00ZZ\n");
		return 1;
	}

	/* Invalid length Boot12345 should exit non-zero */
	if (system("../../fde-boot-loader Boot12345 >/dev/null 2>&1") == 0) {
		fprintf(stderr, "C-B05: expected failure for Boot12345\n");
		return 1;
	}

	/* Invalid short id 12 should exit non-zero */
	if (system("../../fde-boot-loader 12 >/dev/null 2>&1") == 0) {
		fprintf(stderr, "C-B05: expected failure for 12\n");
		return 1;
	}

	return 0;
}

int main(int argc, char *argv[])
{
	const char *fixtures_dir = "../fixtures/bootopt";
	int failed = 0;

	if (argc > 1)
		fixtures_dir = argv[1];

	printf("1..5\n");

	if (test_valid_shim(fixtures_dir) == 0)
		printf("ok 1 - C-B01: valid load option and split file nodes return /EFI/opensuse/shim.efi\n");
	else {
		printf("not ok 1 - C-B01: valid load option and split file nodes return /EFI/opensuse/shim.efi\n");
		failed++;
	}

	if (test_boundaries(fixtures_dir) == 0)
		printf("ok 2 - C-B02: boundary and corruption checks reject malformed inputs\n");
	else {
		printf("not ok 2 - C-B02: boundary and corruption checks reject malformed inputs\n");
		failed++;
	}

	if (test_dotdot_traversal(fixtures_dir) == 0)
		printf("ok 3 - C-B03: path traversal components are strictly rejected\n");
	else {
		printf("not ok 3 - C-B03: path traversal components are strictly rejected\n");
		failed++;
	}

	if (test_non_file_entry(fixtures_dir) == 0)
		printf("ok 4 - C-B04: non-file entries print nothing and return 0\n");
	else {
		printf("not ok 4 - C-B04: non-file entries print nothing and return 0\n");
		failed++;
	}

	int cli_status = test_cli_parsing();
	if (cli_status == 0)
		printf("ok 5 - C-B05: CLI option parsing validates boot entry id format\n");
	else if (cli_status < 0)
		printf("ok 5 # skip fde-boot-loader not built\n");
	else {
		printf("not ok 5 - C-B05: CLI option parsing validates boot entry id format\n");
		failed++;
	}

	return failed ? 1 : 0;
}
