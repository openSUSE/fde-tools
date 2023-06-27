/*
 * grub-tpm2 LUKS2 token handler
 *
 * Copyright (C) 2023 Gary Lin <glin@suse.com>
 *
 * This file is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This file is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this file; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <json-c/json.h>
#include <libcryptsetup.h>

#define TOKEN_NAME "grub-tpm2"
#define TOKEN_VERSION_MAJOR "1"
#define TOKEN_VERSION_MINOR "0"

const char *
cryptsetup_token_version(void)
{
	return TOKEN_VERSION_MAJOR "." TOKEN_VERSION_MINOR;
}

int
cryptsetup_token_open_pin(struct crypt_device *cd __attribute__((unused)),
			  int token __attribute__((unused)),
			  const char *pin __attribute__((unused)),
			  size_t pin_size __attribute__((unused)),
			  char **password __attribute__((unused)),
			  size_t *password_len __attribute__((unused)),
			  void *usrptr __attribute__((unused)))
{
	return -ENOTSUP;
}

int
cryptsetup_token_open(struct crypt_device *cd, int token, char **password,
		      size_t *password_len, void *usrptr)
{
	return cryptsetup_token_open_pin(cd, token, NULL, 0, password,
					 password_len, usrptr);
}

void
cryptsetup_token_dump(struct crypt_device *cd, const char *json)
{
	json_object *jobj_token;
	json_object *jobj_timestamp;
	char buf[80];

	jobj_token = json_tokener_parse(json);
	if (!jobj_token)
		return;

	json_object_object_get_ex(jobj_token, "timestamp", &jobj_timestamp);
	if (snprintf(buf, sizeof(buf) - 1, "\ttimestamp:  %s\n",
	    json_object_get_string(jobj_timestamp)) > 0)
		crypt_log(cd, CRYPT_LOG_NORMAL, buf);

	json_object_put(jobj_token);
}

int
cryptsetup_token_validate(struct crypt_device *cd __attribute__((unused)),
			  const char *json)
{
	enum json_tokener_error jerr;
	json_object *jobj_token;

	jobj_token = json_tokener_parse_verbose(json, &jerr);
	if (!jobj_token)
		return -EINVAL;

	json_object_put(jobj_token);
	return 0;
}

void
cryptsetup_token_buffer_free (void *buffer __attribute__((unused)),
			      size_t buffer_len __attribute__((unused)))
{

}
