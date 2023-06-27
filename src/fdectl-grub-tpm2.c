/*
 * Copyright (C) 2023 Gary Lin <glin@suse.com>
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
#include <errno.h>
#include <fcntl.h>
#include <time.h>
#include <argp.h>
#include <json-c/json.h>
#include <libcryptsetup.h>
#include "nls.h"

#define TOKEN_NAME "grub-tpm2"

#define l_err(cd, x...) crypt_logf(cd, CRYPT_LOG_ERROR, x)
#define l_dbg(cd, x...) crypt_logf(cd, CRYPT_LOG_DEBUG, x)

#define OPT_DEBUG	1
#define OPT_DEBUG_JSON	2
#define OPT_KEY_SLOT	3

static int
check_existing_tokens(struct crypt_device *cd, int keyslot, int *token_id)
{
	const char *json;
	json_object *jobj;
	json_object *jobj_tokens;
	json_object *jobj_type;
	json_object *jobj_keyslots;
	json_object *jobj_keyslot;
	struct array_list *keyslots;
	const char *keyslot_str;
	int i, r;

	if (!cd || !token_id)
		return -1;

	*token_id = CRYPT_ANY_TOKEN;

	r = crypt_dump_json(cd, &json, 0);
	if (r) {
		l_err(cd, _("Failed to dump json."));
		return -EINVAL;
	}

	jobj = json_tokener_parse(json);
	if (!jobj) {
		l_err(cd, _("Failed to parse LUKS2 json metadata"));
		return -EINVAL;
	}

	if (!json_object_object_get_ex(jobj, "tokens", &jobj_tokens)) {
		l_err(cd, _("Failed to get tokens."));
		r = -EINVAL;
		goto out;
	}

	if (json_object_object_length(jobj_tokens) == 0) {
		r = 0;
		goto out;
	}

	json_object_object_foreach(jobj_tokens, slot, val) {
		if (!json_object_object_get_ex(val, "type", &jobj_type)) {
			l_err(cd, _("Failed to get type for token %s."), slot);
			continue;
		}

		if (strcmp(json_object_get_string(jobj_type), TOKEN_NAME) != 0)
			continue;

		l_dbg(cd, _("Token %s is %s."), slot, TOKEN_NAME);

		if (!json_object_object_get_ex(val, "keyslots", &jobj_keyslots)) {
			l_err(cd, _("Failed to get keyslots for token %s."), slot);
			continue;
		}

		if (json_object_array_length(jobj_keyslots) == 0)
			continue;

		keyslots = json_object_get_array(jobj_keyslots);
		if (keyslots == NULL) {
			l_err(cd, _("Failed to get the keyslots array for token %s."), slot);
			continue;
		}

		for (i = 0; i < array_list_length(keyslots); i++) {
			jobj_keyslot = array_list_get_idx(keyslots, i);
			keyslot_str = json_object_get_string(jobj_keyslot);
			l_dbg(cd, _("keyslot %s in token %s"), keyslot_str, slot);
			if (atoi(keyslot_str) == keyslot) {
				*token_id = atoi(slot);
				r = 0;
				goto out;
			}
		}
	}

	r = 0;
out:
	json_object_put(jobj);
	return r;

}

static int
add_new_token(struct crypt_device *cd, int keyslot)
{
	json_object *jobj = NULL;
	json_object *jobj_keyslots = NULL;
	json_object *jobj_timestamp = NULL;
	time_t cur_time;
	struct tm gmt_time;
	char time_str[24];
	const char *string_token;
	int r, token;

	jobj = json_object_new_object();
	if (!jobj) {
		r = -ENOMEM;
		goto out;
	}

	/* type is mandatory field in all tokens and must match handler name member */
	json_object_object_add(jobj, "type", json_object_new_string(TOKEN_NAME));

	jobj_keyslots = json_object_new_array();
	if (!jobj_keyslots) {
		r = -ENOMEM;
		goto out;
	}

	/* mandatory array field (may be empty and assigned later */
	json_object_object_add(jobj, "keyslots", jobj_keyslots);

	/* add timestamp */
	cur_time = time(NULL);
	gmtime_r(&cur_time, &gmt_time);
	strftime(time_str, sizeof(time_str), "%Y-%m-%d %H:%M:%S UTC", &gmt_time);
	jobj_timestamp = json_object_new_string(time_str);
	if (!jobj_timestamp) {
		r = -ENOMEM;
		goto out;
	}
	json_object_object_add(jobj, "timestamp", jobj_timestamp);

	string_token = json_object_to_json_string_ext(jobj, JSON_C_TO_STRING_PLAIN);
	if (!string_token) {
		r = -EINVAL;
		goto out;
	}

	l_dbg(cd, "Token JSON: %s", string_token);

	r = crypt_token_json_set(cd, CRYPT_ANY_TOKEN, string_token);
	if (r < 0) {
		l_err(cd, _("Failed to write grub-tpm2 token json."));
		goto out;
	}

	token = r;
	r = crypt_token_assign_keyslot(cd, token, keyslot);
	if (r != token) {
		crypt_token_json_set(cd, token, NULL);
		r = -EINVAL;
		goto out;
	}

	r = 0;
out:
	json_object_put(jobj);
	return r;
}

static int
clean_empty_tokens (struct crypt_device *cd)
{
	const char *json;
	json_object *jobj;
	json_object *jobj_tokens;
	json_object *jobj_type;
	json_object *jobj_keyslots;
	int token;
	int r;

	if (!cd)
		return -1;

	r = crypt_dump_json(cd, &json, 0);
	if (r) {
		l_err(cd, _("Failed to dump json."));
		return -EINVAL;
	}

	jobj = json_tokener_parse(json);
	if (!jobj) {
		l_err(cd, _("Failed to parse LUKS2 json metadata"));
		return -EINVAL;
	}

	if (!json_object_object_get_ex(jobj, "tokens", &jobj_tokens)) {
		l_err(cd, _("Failed to get tokens."));
		r = -EINVAL;
		goto out;
	}

	if (json_object_object_length(jobj_tokens) == 0) {
		r = 0;
		goto out;
	}

	json_object_object_foreach(jobj_tokens, slot, val) {
		if (!json_object_object_get_ex(val, "type", &jobj_type)) {
			l_err(cd, _("Failed to get type for token %s."), slot);
			continue;
		}

		if (strcmp(json_object_get_string(jobj_type), TOKEN_NAME) != 0)
			continue;

		if (!json_object_object_get_ex(val, "keyslots", &jobj_keyslots)) {
			l_err(cd, _("Failed to get keyslots for token %s."), slot);
			continue;
		}

		/* check 'keyslots' and remove this token if the array is empty */
		if (json_object_array_length(jobj_keyslots) == 0) {
			token = atoi(slot);
			crypt_token_json_set(cd, token, NULL);
		}
	}

	r = 0;
out:
	json_object_put(jobj);
	return r;
}

static int
list_tokens(struct crypt_device *cd)
{
	const char *json;
	json_object *jobj;
	json_object *jobj_tokens;
	json_object *jobj_type;
	json_object *jobj_output = NULL;
	const char *string_out;
	int r;

	if (!cd)
		return -1;

	r = crypt_dump_json(cd, &json, 0);
	if (r) {
		l_err(cd, _("Failed to dump json."));
		return -EINVAL;
	}

	jobj = json_tokener_parse(json);
	if (!jobj) {
		l_err(cd, _("Failed to parse LUKS2 json metadata"));
		return -EINVAL;
	}

	if (!json_object_object_get_ex(jobj, "tokens", &jobj_tokens)) {
		l_err(cd, _("Failed to get tokens."));
		r = -EINVAL;
		goto out;
	}

	if (json_object_object_length(jobj_tokens) == 0) {
		r = 0;
		goto out;
	}

	jobj_output = json_object_new_object();
	if (!jobj_output) {
		r = -ENOMEM;
		goto out;
	}

	json_object_object_foreach(jobj_tokens, slot, val) {
		if (!json_object_object_get_ex(val, "type", &jobj_type)) {
			l_err(cd, _("Failed to get type for token %s."), slot);
			continue;
		}

		if (strcmp(json_object_get_string(jobj_type), TOKEN_NAME) != 0)
			continue;

		json_object_object_add(jobj_output, slot, json_object_get(val));
	}

	if (json_object_object_length(jobj_output) != 0) {
		string_out = json_object_to_json_string_ext(jobj_output, JSON_C_TO_STRING_PRETTY);
		if (!string_out) {
			r = -EINVAL;
			goto out;
		}

		printf ("%s\n", string_out);
	}

	r = 0;
out:
	json_object_put(jobj);
	if (jobj_output)
		json_object_put(jobj_output);
	return r;

}

static int
init_luks2_device(const char *device, struct crypt_device **cd)
{
	int r;

	r = crypt_init(cd, device);
	if (r)
		return r;

	r = crypt_load(*cd, CRYPT_LUKS2, NULL);
	if (r) {
		l_err(*cd, _("Device %s is not a valid LUKS2 device."), device);
		return r;
	}

	return r;
}

static char doc[] = N_("fdectl utility to manage LUKS2 keyslots\v"
		       "This utility program helps fdectl to manage LUKS2 keyslots.\n"
		       "Actions:\n"
		       "  add\tadd the specified keyslot into a new grub-tpm2 token.\n"
		       "  list\tshow all the grub-tpm2 tokens in the device.\n"
		       "  clean\tremove all the grub-tpm2 tokens without any keyslot assigned.");

static char args_doc[] = N_("<action> <device>");

static struct argp_option options[] = {
	{0,		0,		0,	  0, N_("Options for the 'add' action:")},
	{"key-slot",	OPT_KEY_SLOT,	"NUM",	  0, N_("Keyslot to assign the token to.")},
	{0,		0,		0,	  0, N_("Generic options:")},
	{"verbose",	'v',		0,	  0, N_("Shows more detailed error messages")},
	{"debug",	OPT_DEBUG,	0,	  0, N_("Show debug messages")},
	{"debug-json",  OPT_DEBUG_JSON, 0,	  0, N_("Show debug messages including JSON metadata")},
	{ NULL,		0, 		0, 0, NULL }
};

struct arguments {
	char *device;
	char *action;
	int keyslot;
	int verbose;
	int debug;
	int debug_json;
};

static error_t
parse_opt (int key, char *arg, struct argp_state *state) {
	struct arguments *arguments = state->input;

	switch (key) {
	case OPT_KEY_SLOT:
		arguments->keyslot = atoi(arg);
		break;
	case 'v':
		arguments->verbose = 1;
		break;
	case OPT_DEBUG:
		arguments->debug = 1;
		break;
	case OPT_DEBUG_JSON:
		arguments->debug = 1;
		arguments->debug_json = 1;
		break;
	case ARGP_KEY_NO_ARGS:
		argp_usage(state);
		break;
	case ARGP_KEY_ARG:
		arguments->action = arg;
		arguments->device = state->argv[state->next];
		state->next = state->argc;
		break;
	default:
		return ARGP_ERR_UNKNOWN;
	}

	return 0;
}

static struct argp argp = { options, parse_opt, args_doc, doc };


static void _log(int level, const char *msg, void *usrptr)
{
	struct arguments *arguments = (struct arguments *)usrptr;

	switch (level) {
	case CRYPT_LOG_NORMAL:
		fprintf(stdout, "%s", msg);
		break;
	case CRYPT_LOG_VERBOSE:
		if (arguments && arguments->verbose)
			fprintf(stdout, "%s", msg);
		break;
	case CRYPT_LOG_ERROR:
		fprintf(stderr, "%s", msg);
		break;
	case CRYPT_LOG_DEBUG_JSON:
		if (arguments && arguments->debug_json)
			fprintf(stdout, "# %s", msg);
		break;
	case CRYPT_LOG_DEBUG:
		if (arguments && arguments->debug)
			fprintf(stdout, "# %s", msg);
		break;
	}
}

int main(int argc, char *argv[])
{
	int ret = 0;
	struct arguments arguments = { 0 };
	struct crypt_device *cd = NULL;
	int token_id = CRYPT_ANY_TOKEN;

	arguments.keyslot = CRYPT_ANY_SLOT;

	setlocale(LC_ALL, "");
	bindtextdomain(PACKAGE, LOCALEDIR);
	textdomain(PACKAGE);

	ret = argp_parse (&argp, argc, argv, 0, 0, &arguments);
	if (ret != 0) {
		printf(_("Failed to parse arguments.\n"));
		return EXIT_FAILURE;
	}

	crypt_set_log_callback(NULL, _log, &arguments);
	if (arguments.debug)
		crypt_set_debug_level(CRYPT_DEBUG_ALL);
	if (arguments.debug_json)
		crypt_set_debug_level(CRYPT_DEBUG_JSON);

	if (arguments.action == NULL) {
		printf(_("An action must be specified\n"));
		return EXIT_FAILURE;
	}

	if (strcmp("add", arguments.action) == 0) {
		if (!arguments.device) {
			printf(_("Device must be specified for '%s' action.\n"), arguments.action);
			return EXIT_FAILURE;
		}

		if (arguments.keyslot == CRYPT_ANY_SLOT) {
			printf (_("Please specify the key slot to be added\n"));
			return EXIT_FAILURE;
		}

		ret = init_luks2_device(arguments.device, &cd);
		if (ret < 0)
			return EXIT_FAILURE;

		/* check existing tokens with the same keyslot */
		ret = check_existing_tokens(cd, arguments.keyslot, &token_id);
		if (ret != 0) {
			return EXIT_FAILURE;
		} else if (token_id != CRYPT_ANY_TOKEN) {
			printf (_("Keyslot %d already in token %d\n"), arguments.keyslot, token_id);
			goto out;
		}

		ret = add_new_token(cd, arguments.keyslot);
	} else if (strcmp("clean", arguments.action) == 0) {
		if (!arguments.device) {
			printf(_("Device must be specified for '%s' action.\n"), arguments.action);
			return EXIT_FAILURE;
		}

		ret = init_luks2_device(arguments.device, &cd);
		if (ret < 0)
			return EXIT_FAILURE;

		ret = clean_empty_tokens(cd);
	} else if (strcmp("list", arguments.action) == 0) {
		if (!arguments.device) {
			printf(_("Device must be specified for '%s' action.\n"), arguments.action);
			return EXIT_FAILURE;
		}

		ret = init_luks2_device(arguments.device, &cd);
		if (ret < 0)
			return EXIT_FAILURE;

		ret = list_tokens(cd);

	} else {
		printf(_("Unsupported action.\n"));
		ret = EXIT_FAILURE;
	}

out:
	if (cd)
		crypt_free(cd);

	return ret;
}
