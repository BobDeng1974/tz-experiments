#include <types_ext.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <arm.h>
#include <assert.h>
#include <kernel/mutex.h>
#include <kernel/panic.h>
#include <kernel/pseudo_ta.h>
#include <kernel/tee_common.h>
#include <kernel/tee_misc.h>
#include <kernel/tee_ta_manager.h>
#include <kernel/tee_time.h>
#include <kernel/thread.h>
#include <kernel/user_ta.h>
#include <mm/core_mmu.h>
#include <mm/core_memprot.h>
#include <mm/mobj.h>
#include <mm/tee_mmu.h>
#include <tee/tee_svc_cryp.h>
#include <tee/tee_obj.h>
#include <tee/tee_svc_storage.h>
#include <tee_api_types.h>
#include <trace.h>
#include <utee_types.h>
#include <util.h>
struct mutex tee_ta_mutex = MUTEX_INITIALIZER;
struct tee_ta_ctx_head tee_ctxes = TAILQ_HEAD_INITIALIZER(tee_ctxes);
#ifndef CFG_CONCURRENT_SINGLE_INSTANCE_TA
static struct condvar tee_ta_cv = CONDVAR_INITIALIZER;
static int tee_ta_single_instance_thread = THREAD_ID_INVALID;
static size_t tee_ta_single_instance_count;
#endif
#ifdef CFG_CONCURRENT_SINGLE_INSTANCE_TA
static void lock_single_instance(void)
{
}
static void unlock_single_instance(void)
{
}
static bool has_single_instance_lock(void)
{
	return false;
}
#else
static void lock_single_instance(void)
{
	if (tee_ta_single_instance_thread != thread_get_id()) {
		while (tee_ta_single_instance_thread != THREAD_ID_INVALID)
			condvar_wait(&tee_ta_cv, &tee_ta_mutex);
		tee_ta_single_instance_thread = thread_get_id();
		assert(tee_ta_single_instance_count == 0);
	}
	tee_ta_single_instance_count++;
}
static void unlock_single_instance(void)
{
	assert(tee_ta_single_instance_thread == thread_get_id());
	assert(tee_ta_single_instance_count > 0);
	tee_ta_single_instance_count--;
	if (tee_ta_single_instance_count == 0) {
		tee_ta_single_instance_thread = THREAD_ID_INVALID;
		condvar_signal(&tee_ta_cv);
	}
}
static bool has_single_instance_lock(void)
{
	return tee_ta_single_instance_thread == thread_get_id();
}
#endif
static bool tee_ta_try_set_busy(struct tee_ta_ctx *ctx)
{
	bool rc = true;
	if (ctx->flags & TA_FLAG_CONCURRENT)
		return true;
	mutex_lock(&tee_ta_mutex);
	if (ctx->flags & TA_FLAG_SINGLE_INSTANCE)
		lock_single_instance();
	if (has_single_instance_lock()) {
		if (ctx->busy) {
			rc = false;
			if (ctx->flags & TA_FLAG_SINGLE_INSTANCE)
				unlock_single_instance();
		}
	} else {
		while (ctx->busy)
			condvar_wait(&ctx->busy_cv, &tee_ta_mutex);
	}
	ctx->busy = true;
	mutex_unlock(&tee_ta_mutex);
	return rc;
}
static void tee_ta_set_busy(struct tee_ta_ctx *ctx)
{
	if (!tee_ta_try_set_busy(ctx))
		panic();
}
static void tee_ta_clear_busy(struct tee_ta_ctx *ctx)
{
	if (ctx->flags & TA_FLAG_CONCURRENT)
		return;
	mutex_lock(&tee_ta_mutex);
	assert(ctx->busy);
	ctx->busy = false;
	condvar_signal(&ctx->busy_cv);
	if (ctx->flags & TA_FLAG_SINGLE_INSTANCE)
		unlock_single_instance();
	mutex_unlock(&tee_ta_mutex);
}
static void dec_session_ref_count(struct tee_ta_session *s)
{
	assert(s->ref_count > 0);
	s->ref_count--;
	if (s->ref_count == 1)
		condvar_signal(&s->refc_cv);
}
void tee_ta_put_session(struct tee_ta_session *s)
{
	mutex_lock(&tee_ta_mutex);
	if (s->lock_thread == thread_get_id()) {
		s->lock_thread = THREAD_ID_INVALID;
		condvar_signal(&s->lock_cv);
	}
	dec_session_ref_count(s);
	mutex_unlock(&tee_ta_mutex);
}
static struct tee_ta_session *find_session(uint32_t id,
			struct tee_ta_session_head *open_sessions)
{
	struct tee_ta_session *s;
	TAILQ_FOREACH(s, open_sessions, link) {
		if ((vaddr_t)s == id)
			return s;
	}
	return NULL;
}
struct tee_ta_session *tee_ta_get_session(uint32_t id, bool exclusive,
			struct tee_ta_session_head *open_sessions)
{
	struct tee_ta_session *s;
	mutex_lock(&tee_ta_mutex);
	while (true) {
		s = find_session(id, open_sessions);
		if (!s)
			break;
		if (s->unlink) {
			s = NULL;
			break;
		}
		s->ref_count++;
		if (!exclusive)
			break;
		assert(s->lock_thread != thread_get_id());
		while (s->lock_thread != THREAD_ID_INVALID && !s->unlink)
			condvar_wait(&s->lock_cv, &tee_ta_mutex);
		if (s->unlink) {
			dec_session_ref_count(s);
			s = NULL;
			break;
		}
		s->lock_thread = thread_get_id();
		break;
	}
	mutex_unlock(&tee_ta_mutex);
	return s;
}
static void tee_ta_unlink_session(struct tee_ta_session *s,
			struct tee_ta_session_head *open_sessions)
{
	mutex_lock(&tee_ta_mutex);
	assert(s->ref_count >= 1);
	assert(s->lock_thread == thread_get_id());
	assert(!s->unlink);
	s->unlink = true;
	condvar_broadcast(&s->lock_cv);
	while (s->ref_count != 1)
		condvar_wait(&s->refc_cv, &tee_ta_mutex);
	TAILQ_REMOVE(open_sessions, s, link);
	mutex_unlock(&tee_ta_mutex);
}
static struct tee_ta_ctx *tee_ta_context_find(const TEE_UUID *uuid)
{
	struct tee_ta_ctx *ctx;
	TAILQ_FOREACH(ctx, &tee_ctxes, link) {
		if (memcmp(&ctx->uuid, uuid, sizeof(TEE_UUID)) == 0)
			return ctx;
	}
	return NULL;
}
static TEE_Result check_client(struct tee_ta_session *s, const TEE_Identity *id)
{
	if (id == KERN_IDENTITY)
		return TEE_SUCCESS;
	if (id == NSAPP_IDENTITY) {
		if (s->clnt_id.login == TEE_LOGIN_TRUSTED_APP) {
			DMSG("nsec tries to hijack TA session");
			return TEE_ERROR_ACCESS_DENIED;
		}
		return TEE_SUCCESS;
	}
	if (memcmp(&s->clnt_id, id, sizeof(TEE_Identity)) != 0) {
		DMSG("client id mismatch");
		return TEE_ERROR_ACCESS_DENIED;
	}
	return TEE_SUCCESS;
}
#ifndef CFG_SECURE_DATA_PATH
static bool check_params(struct tee_ta_session *sess __unused,
			 struct tee_ta_param *param __unused)
{
	return true;
}
#else
static bool check_params(struct tee_ta_session *sess,
			 struct tee_ta_param *param)
{
	int n;
	if (sess->ctx->flags & TA_FLAG_SECURE_DATA_PATH)
		return true;
	for (n = 0; n < TEE_NUM_PARAMS; n++) {
		uint32_t param_type = TEE_PARAM_TYPE_GET(param->types, n);
		struct param_mem *mem = &param->u[n].mem;
		if (param_type != TEE_PARAM_TYPE_MEMREF_INPUT &&
		    param_type != TEE_PARAM_TYPE_MEMREF_OUTPUT &&
		    param_type != TEE_PARAM_TYPE_MEMREF_INOUT)
			continue;
		if (!mem->size)
			continue;
		if (mobj_is_sdp_mem(mem->mobj))
			return false;
	}
	return true;
}
#endif
static void set_invoke_timeout(struct tee_ta_session *sess,
				      uint32_t cancel_req_to)
{
	TEE_Time current_time;
	TEE_Time cancel_time;
	if (cancel_req_to == TEE_TIMEOUT_INFINITE)
		goto infinite;
	if (tee_time_get_sys_time(&current_time) != TEE_SUCCESS)
		goto infinite;
	if (ADD_OVERFLOW(current_time.seconds, cancel_req_to / 1000,
			 &cancel_time.seconds))
		goto infinite;
	cancel_time.millis = current_time.millis + cancel_req_to % 1000;
	if (cancel_time.millis > 1000) {
		if (ADD_OVERFLOW(current_time.seconds, 1,
				 &cancel_time.seconds))
			goto infinite;
		cancel_time.seconds++;
		cancel_time.millis -= 1000;
	}
	sess->cancel_time = cancel_time;
	return;
infinite:
	sess->cancel_time.seconds = UINT32_MAX;
	sess->cancel_time.millis = UINT32_MAX;
}
TEE_Result tee_ta_close_session(struct tee_ta_session *csess,
				struct tee_ta_session_head *open_sessions,
				const TEE_Identity *clnt_id)
{
	struct tee_ta_session *sess;
	struct tee_ta_ctx *ctx;
	bool keep_alive;
	DMSG("tee_ta_close_session(0x%" PRIxVA ")",  (vaddr_t)csess);
	if (!csess)
		return TEE_ERROR_ITEM_NOT_FOUND;
	sess = tee_ta_get_session((vaddr_t)csess, true, open_sessions);
	if (!sess) {
		EMSG("session 0x%" PRIxVA " to be removed is not found",
		     (vaddr_t)csess);
		return TEE_ERROR_ITEM_NOT_FOUND;
	}
	if (check_client(sess, clnt_id) != TEE_SUCCESS) {
		tee_ta_put_session(sess);
		return TEE_ERROR_BAD_PARAMETERS; 
	}
	ctx = sess->ctx;
	DMSG("Destroy session");
	tee_ta_set_busy(ctx);
	if (!ctx->panicked) {
		set_invoke_timeout(sess, TEE_TIMEOUT_INFINITE);
		ctx->ops->enter_close_session(sess);
	}
	tee_ta_unlink_session(sess, open_sessions);
#if defined(CFG_TA_GPROF_SUPPORT)
	free(sess->sbuf);
#endif
	free(sess);
	tee_ta_clear_busy(ctx);
	mutex_lock(&tee_ta_mutex);
	if (ctx->ref_count <= 0)
		panic();
	ctx->ref_count--;
	keep_alive = (ctx->flags & TA_FLAG_INSTANCE_KEEP_ALIVE) &&
			(ctx->flags & TA_FLAG_SINGLE_INSTANCE);
	if (!ctx->ref_count && !keep_alive) {
		DMSG("Destroy TA ctx");
		TAILQ_REMOVE(&tee_ctxes, ctx, link);
		mutex_unlock(&tee_ta_mutex);
		condvar_destroy(&ctx->busy_cv);
		pgt_flush_ctx(ctx);
		ctx->ops->destroy(ctx);
	} else
		mutex_unlock(&tee_ta_mutex);
	return TEE_SUCCESS;
}
static TEE_Result tee_ta_init_session_with_context(struct tee_ta_ctx *ctx,
			struct tee_ta_session *s)
{
	if ((ctx->flags & TA_FLAG_SINGLE_INSTANCE) == 0)
		return TEE_ERROR_ITEM_NOT_FOUND;
	if (!(ctx->flags & TA_FLAG_MULTI_SESSION) && ctx->ref_count)
		return TEE_ERROR_BUSY;
	DMSG("Re-open TA %pUl", (void *)&ctx->uuid);
	ctx->ref_count++;
	s->ctx = ctx;
	return TEE_SUCCESS;
}
static TEE_Result tee_ta_init_session(TEE_ErrorOrigin *err,
				struct tee_ta_session_head *open_sessions,
				const TEE_UUID *uuid,
				struct tee_ta_session **sess)
{
	TEE_Result res;
	struct tee_ta_ctx *ctx;
	struct tee_ta_session *s = calloc(1, sizeof(struct tee_ta_session));
	*err = TEE_ORIGIN_TEE;
	if (!s)
		return TEE_ERROR_OUT_OF_MEMORY;
	s->cancel_mask = true;
	condvar_init(&s->refc_cv);
	condvar_init(&s->lock_cv);
	s->lock_thread = THREAD_ID_INVALID;
	s->ref_count = 1;
	mutex_lock(&tee_ta_mutex);
	TAILQ_INSERT_TAIL(open_sessions, s, link);
	ctx = tee_ta_context_find(uuid);
	if (ctx) {
		res = tee_ta_init_session_with_context(ctx, s);
		if (res == TEE_SUCCESS || res != TEE_ERROR_ITEM_NOT_FOUND)
			goto out;
	}
	res = tee_ta_init_pseudo_ta_session(uuid, s);
	if (res == TEE_SUCCESS || res != TEE_ERROR_ITEM_NOT_FOUND)
		goto out;
	res = tee_ta_init_user_ta_session(uuid, s);
out:
	if (res == TEE_SUCCESS) {
		*sess = s;
	} else {
		TAILQ_REMOVE(open_sessions, s, link);
		free(s);
	}
	mutex_unlock(&tee_ta_mutex);
	return res;
}
TEE_Result tee_ta_open_session(TEE_ErrorOrigin *err,
			       struct tee_ta_session **sess,
			       struct tee_ta_session_head *open_sessions,
			       const TEE_UUID *uuid,
			       const TEE_Identity *clnt_id,
			       uint32_t cancel_req_to,
			       struct tee_ta_param *param)
{
	TEE_Result res;
	struct tee_ta_session *s = NULL;
	struct tee_ta_ctx *ctx;
	bool panicked;
	bool was_busy = false;
	res = tee_ta_init_session(err, open_sessions, uuid, &s);
	if (res != TEE_SUCCESS) {
		DMSG("init session failed 0x%x", res);
		return res;
	}
	if (!check_params(s, param))
		return TEE_ERROR_BAD_PARAMETERS;
	ctx = s->ctx;
	if (ctx->panicked) {
		DMSG("panicked, call tee_ta_close_session()");
		tee_ta_close_session(s, open_sessions, KERN_IDENTITY);
		*err = TEE_ORIGIN_TEE;
		return TEE_ERROR_TARGET_DEAD;
	}
	*sess = s;
	s->clnt_id = *clnt_id;
	if (tee_ta_try_set_busy(ctx)) {
		set_invoke_timeout(s, cancel_req_to);
		res = ctx->ops->enter_open_session(s, param, err);
		tee_ta_clear_busy(ctx);
	} else {
		res = TEE_ERROR_BUSY;
		was_busy = true;
	}
	panicked = ctx->panicked;
	tee_ta_put_session(s);
	if (panicked || (res != TEE_SUCCESS))
		tee_ta_close_session(s, open_sessions, KERN_IDENTITY);
	if (panicked || was_busy)
		*err = TEE_ORIGIN_TEE;
	else
		*err = TEE_ORIGIN_TRUSTED_APP;
	if (res != TEE_SUCCESS)
		EMSG("Failed. Return error 0x%x", res);
	return res;
}
TEE_Result tee_ta_invoke_command(TEE_ErrorOrigin *err,
				 struct tee_ta_session *sess,
				 const TEE_Identity *clnt_id,
				 uint32_t cancel_req_to, uint32_t cmd,
				 struct tee_ta_param *param)
{
	TEE_Result res;
	if (check_client(sess, clnt_id) != TEE_SUCCESS)
		return TEE_ERROR_BAD_PARAMETERS; 
	if (!check_params(sess, param))
		return TEE_ERROR_BAD_PARAMETERS;
	if (sess->ctx->panicked) {
		DMSG("Panicked !");
		*err = TEE_ORIGIN_TEE;
		return TEE_ERROR_TARGET_DEAD;
	}
	tee_ta_set_busy(sess->ctx);
	set_invoke_timeout(sess, cancel_req_to);
	res = sess->ctx->ops->enter_invoke_cmd(sess, cmd, param, err);
	if (sess->ctx->panicked) {
		*err = TEE_ORIGIN_TEE;
		res = TEE_ERROR_TARGET_DEAD;
	}
	tee_ta_clear_busy(sess->ctx);
	if (res != TEE_SUCCESS && res != TEE_ERROR_SHORT_BUFFER)
		DMSG("Error: %x of %d\n", res, *err);
	return res;
}
TEE_Result tee_ta_cancel_command(TEE_ErrorOrigin *err,
				 struct tee_ta_session *sess,
				 const TEE_Identity *clnt_id)
{
	*err = TEE_ORIGIN_TEE;
	if (check_client(sess, clnt_id) != TEE_SUCCESS)
		return TEE_ERROR_BAD_PARAMETERS; 
	sess->cancel = true;
	return TEE_SUCCESS;
}
bool tee_ta_session_is_cancelled(struct tee_ta_session *s, TEE_Time *curr_time)
{
	TEE_Time current_time;
	if (s->cancel_mask)
		return false;
	if (s->cancel)
		return true;
	if (s->cancel_time.seconds == UINT32_MAX)
		return false;
	if (curr_time != NULL)
		current_time = *curr_time;
	else if (tee_time_get_sys_time(&current_time) != TEE_SUCCESS)
		return false;
	if (current_time.seconds > s->cancel_time.seconds ||
	    (current_time.seconds == s->cancel_time.seconds &&
	     current_time.millis >= s->cancel_time.millis)) {
		return true;
	}
	return false;
}
static void update_current_ctx(struct thread_specific_data *tsd)
{
	struct tee_ta_ctx *ctx = NULL;
	struct tee_ta_session *s = TAILQ_FIRST(&tsd->sess_stack);
	if (s) {
		if (is_pseudo_ta_ctx(s->ctx))
			s = TAILQ_NEXT(s, link_tsd);
		if (s)
			ctx = s->ctx;
	}
	if (tsd->ctx != ctx)
		tee_mmu_set_ctx(ctx);
	if (((ctx && is_user_ta_ctx(ctx) ?
			to_user_ta_ctx(ctx)->vm_info : NULL) == NULL) ==
					core_mmu_user_mapping_is_active())
		panic("unexpected active mapping");
}
void tee_ta_push_current_session(struct tee_ta_session *sess)
{
	struct thread_specific_data *tsd = thread_get_tsd();
	TAILQ_INSERT_HEAD(&tsd->sess_stack, sess, link_tsd);
	update_current_ctx(tsd);
}
struct tee_ta_session *tee_ta_pop_current_session(void)
{
	struct thread_specific_data *tsd = thread_get_tsd();
	struct tee_ta_session *s = TAILQ_FIRST(&tsd->sess_stack);
	if (s) {
		TAILQ_REMOVE(&tsd->sess_stack, s, link_tsd);
		update_current_ctx(tsd);
	}
	return s;
}
TEE_Result tee_ta_get_current_session(struct tee_ta_session **sess)
{
	struct tee_ta_session *s = TAILQ_FIRST(&thread_get_tsd()->sess_stack);
	if (!s)
		return TEE_ERROR_BAD_STATE;
	*sess = s;
	return TEE_SUCCESS;
}
struct tee_ta_session *tee_ta_get_calling_session(void)
{
	struct tee_ta_session *s = TAILQ_FIRST(&thread_get_tsd()->sess_stack);
	if (s)
		s = TAILQ_NEXT(s, link_tsd);
	return s;
}
TEE_Result tee_ta_get_client_id(TEE_Identity *id)
{
	TEE_Result res;
	struct tee_ta_session *sess;
	res = tee_ta_get_current_session(&sess);
	if (res != TEE_SUCCESS)
		return res;
	if (id == NULL)
		return TEE_ERROR_BAD_PARAMETERS;
	*id = sess->clnt_id;
	return TEE_SUCCESS;
}
static void dump_state(struct tee_ta_ctx *ctx)
{
	struct tee_ta_session *s = NULL;
	bool active __maybe_unused;
	active = ((tee_ta_get_current_session(&s) == TEE_SUCCESS) &&
		  s && s->ctx == ctx);
	EMSG_RAW("Status of TA %pUl (%p) %s", (void *)&ctx->uuid, (void *)ctx,
		active ? "(active)" : "");
	ctx->ops->dump_state(ctx);
}
void tee_ta_dump_current(void)
{
	struct tee_ta_session *s = NULL;
	if (tee_ta_get_current_session(&s) != TEE_SUCCESS) {
		EMSG("no valid session found, cannot log TA status");
		return;
	}
	dump_state(s->ctx);
}
#if defined(CFG_TA_GPROF_SUPPORT)
void tee_ta_gprof_sample_pc(vaddr_t pc)
{
	struct tee_ta_session *s;
	struct sample_buf *sbuf;
	size_t idx;
	if (tee_ta_get_current_session(&s) != TEE_SUCCESS)
		return;
	sbuf = s->sbuf;
	if (!sbuf || !sbuf->enabled)
		return; 
	idx = (((uint64_t)pc - sbuf->offset)/2 * sbuf->scale)/65536;
	if (idx < sbuf->nsamples)
		sbuf->samples[idx]++;
	sbuf->count++;
}
static void tee_ta_update_session_utime(bool suspend)
{
	struct tee_ta_session *s;
	struct sample_buf *sbuf;
	uint64_t now;
	if (tee_ta_get_current_session(&s) != TEE_SUCCESS)
		return;
	sbuf = s->sbuf;
	if (!sbuf)
		return;
	now = read_cntpct();
	if (suspend) {
		assert(sbuf->usr_entered);
		sbuf->usr += now - sbuf->usr_entered;
		sbuf->usr_entered = 0;
	} else {
		assert(!sbuf->usr_entered);
		if (!now)
			now++; 
		sbuf->usr_entered = now;
	}
}
void tee_ta_update_session_utime_suspend(void)
{
	tee_ta_update_session_utime(true);
}
void tee_ta_update_session_utime_resume(void)
{
	tee_ta_update_session_utime(false);
}
#endif
